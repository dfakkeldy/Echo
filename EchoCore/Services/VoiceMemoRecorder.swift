// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Records a standalone voice memo to an `.m4a` in `destinationDirectory`.
/// Caller persists the returned URL/duration into `voice_memo` via `VoiceMemoDAO`.
@MainActor
final class VoiceMemoRecorder {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private let destinationDirectory: URL

    var isRecording: Bool { recorder?.isRecording ?? false }

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    /// Configures the audio session and begins recording a fresh `.m4a`.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)
        let url = destinationDirectory.appendingPathComponent("memo-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw NSError(
                domain: "VoiceMemoRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        }
        self.recorder = recorder
        self.currentURL = url
    }

    /// Stops recording and returns the file URL + measured duration, or nil if
    /// nothing was being recorded.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = currentURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        self.recorder = nil
        self.currentURL = nil
        return (url, duration)
    }

    /// Aborts recording and deletes the partial file.
    func cancel() {
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false)
        recorder = nil
        currentURL = nil
    }
}
