// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Records a standalone voice memo to an `.m4a` in `destinationDirectory`.
/// Caller persists the returned URL/duration into `voice_memo` via `VoiceMemoDAO`.
///
/// Security scope: for imported books, `destinationDirectory` is a
/// security-scoped bookmark URL. `start()` calls
/// `startAccessingSecurityScopedResource()` before writing and releases it in
/// both `stop()` and `cancel()`. If the directory is not writable, recording
/// falls back to `Bookmark.legacyVoiceMemoDirectory()`.
@MainActor
final class VoiceMemoRecorder {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private let destinationDirectory: URL
    /// Non-nil when `destinationDirectory.startAccessingSecurityScopedResource()`
    /// returned true; released in `stop()` / `cancel()`.
    private var scopedURL: URL?

    var isRecording: Bool { recorder?.isRecording ?? false }

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    /// Configures the audio session and begins recording a fresh `.m4a`.
    ///
    /// Acquires a security scope on `destinationDirectory` for imported books.
    /// Falls back to `Bookmark.legacyVoiceMemoDirectory()` when the target dir
    /// is not writable. The scope is held until `stop()` or `cancel()`.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP])
        #else
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        #endif
        try session.setActive(true)

        let fileName = "memo-\(UUID().uuidString).m4a"
        let url = resolveRecordingURL(fileName: fileName)

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
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        #endif
        releaseScope()
        self.recorder = nil
        self.currentURL = nil
        return (url, duration)
    }

    /// Aborts recording and deletes the partial file.
    func cancel() {
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false)
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        #endif
        releaseScope()
        recorder = nil
        currentURL = nil
    }

    // MARK: - Private helpers

    /// Resolves the URL to record into, acquiring a security scope when needed.
    ///
    /// Prefers `destinationDirectory` (security-scoped, for imported books).
    /// Falls back to `Bookmark.legacyVoiceMemoDirectory()` when the directory
    /// is not writable after scope acquisition.
    private func resolveRecordingURL(fileName: String) -> URL {
        // Try to acquire security-scoped access for the destination directory.
        let didStart = destinationDirectory.startAccessingSecurityScopedResource()
        if didStart { scopedURL = destinationDirectory }

        // Ensure the directory exists before testing writability.
        try? FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)

        if FileManager.default.isWritableFile(atPath: destinationDirectory.path) {
            return destinationDirectory.appendingPathComponent(fileName)
        }

        // Not writable — release scope and fall back to the legacy directory.
        releaseScope()
        let legacy = Bookmark.legacyVoiceMemoDirectory()
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        return legacy.appendingPathComponent(fileName)
    }

    private func releaseScope() {
        if let scoped = scopedURL {
            scoped.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }
}
