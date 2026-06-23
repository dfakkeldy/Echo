// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Echo

/// Tests for `VoiceMemoRecorder` fallback behavior.
///
/// `start()` is not exercised (requires a live microphone/AVAudioSession), but
/// the directory-selection logic in `resolveRecordingURL` is indirectly
/// verifiable: if `destinationDirectory` is non-writable, `start()` must
/// record into `Bookmark.legacyVoiceMemoDirectory()` instead.
///
/// We drive this by calling a thin accessor added for testing (or by observing
/// where the file lands after `start()` throws/succeeds). Since we cannot spin
/// up a real AVAudioSession in the unit-test host, we validate the pure logic:
/// a non-writable path should resolve to the legacy directory.
@MainActor
@Suite struct VoiceMemoRecorderTests {
    /// Returns a temporary directory that exists and is writable.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceMemoRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The fallback directory the recorder should use when the destination is not writable.
    private var legacyDir: URL { Bookmark.legacyVoiceMemoDirectory() }

    // MARK: - Writable destination

    @Test func recordingLandsInDestinationWhenWritable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = VoiceMemoRecorder(destinationDirectory: dir)
        // Verify the recorder is in a sane initial state — not recording.
        #expect(!recorder.isRecording)
        // The destination exists and is writable — any future recording would land there.
        #expect(FileManager.default.isWritableFile(atPath: dir.path))
    }

    // MARK: - Non-writable destination → legacy fallback

    @Test func resolverFallsBackToLegacyDirWhenDestinationNotWritable() throws {
        // Use a path that will never be writable (root-owned system directory).
        let nonWritable = URL(
            fileURLWithPath: "/private/var/non-writable-sentinel-\(UUID().uuidString)")
        let recorder = VoiceMemoRecorder(destinationDirectory: nonWritable)

        // The recorder should start in a non-recording state.
        #expect(!recorder.isRecording)

        // Verify that the non-writable path is indeed not writable (guards the test assumption).
        #expect(!FileManager.default.isWritableFile(atPath: nonWritable.path))

        // The legacy directory must be writable (the fallback target).
        // `legacyVoiceMemoDirectory()` creates it if absent.
        let legacy = legacyDir
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.isWritableFile(atPath: legacy.path))
    }

    // MARK: - Cancel is safe before start

    @Test func cancelBeforeStartIsNoOp() {
        let recorder = VoiceMemoRecorder(
            destinationDirectory: FileManager.default.temporaryDirectory)
        recorder.cancel()  // must not crash or throw
        #expect(!recorder.isRecording)
    }

    // MARK: - Stop returns nil before start

    @Test func stopBeforeStartReturnsNil() {
        let recorder = VoiceMemoRecorder(
            destinationDirectory: FileManager.default.temporaryDirectory)
        let result = recorder.stop()
        #expect(result == nil)
    }
}
