// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Observation

@Observable
@MainActor
final class WatchVoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 30

    private(set) var isRecording: Bool = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var tickTask: Task<Void, Never>?
    private(set) var recordingURL: URL?

    func startRecording() throws {
        // Permission is already resolved by the caller (startVoiceBookmark).
        // This guard is a safety net for direct calls that skip the check.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw NSError(
                domain: "WatchVoiceMemoRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."])
        }

        let directory = try Self.recordingsDirectory()
        let fileURL = directory.appendingPathComponent("watch-memo-\(UUID().uuidString).m4a")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.prepareToRecord()
        audioRecorder.record(forDuration: Self.maximumDuration)

        recorder = audioRecorder
        recordingURL = fileURL
        elapsed = 0
        isRecording = true
        startTimer()
    }

    @discardableResult
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        tickTask?.cancel()
        tickTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordingURL
    }

    func discardRecording() {
        if isRecording {
            _ = stopRecording()
        }
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        elapsed = 0
    }

    // AVAudioRecorderDelegate's requirement is nonisolated, so this witness must be
    // too (the class is @MainActor). Snapshot the Sendable `currentTime` synchronously,
    // then hop to the main actor to mutate the @MainActor-isolated state.
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        let finalTime = recorder.currentTime
        Task { @MainActor in
            self.tickTask?.cancel()
            self.tickTask = nil
            self.isRecording = false
            self.elapsed = min(finalTime, Self.maximumDuration)
        }
    }

    // A cancellable MainActor poll loop (not `Timer.scheduledTimer`) so the elapsed-time
    // updates and `stopRecording()` happen on the main actor without a non-Sendable
    // `Timer` crossing isolation boundaries under Swift 6.
    private func startTimer() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, let recorder = self.recorder else { return }
                self.elapsed = min(recorder.currentTime, Self.maximumDuration)
                if self.elapsed >= Self.maximumDuration {
                    _ = self.stopRecording()
                    return
                }
            }
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let directory = FileLocations.documentsDirectory
            .appendingPathComponent("WatchVoiceMemos", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}
