// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing

@testable import Echo

/// Covers the incremental ("stream-to-sink") path of `AVFoundationAudioWriter`:
/// each chunk is encoded to disk on `append`, so a chapter's peak memory is one
/// sub-chunk's PCM rather than the whole chapter's. The losslessness guard in
/// `AVFoundationAudioWriterTests` covers the batch `write`; here we prove the
/// streaming session concatenates multiple appends correctly and losslessly.
@Suite struct StreamingAudioWriterTests {

    private static let sampleRate: Double = 24_000

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString).m4a")
    }

    /// A constant-valued chunk of `frames` samples lasting `frames / sampleRate`.
    private func constChunk(value: Float, frames: Int) -> TTSChunk {
        TTSChunk(
            samples: [Float](repeating: value, count: frames),
            sampleRate: Self.sampleRate, duration: Double(frames) / Self.sampleRate)
    }

    @Test func appendedChunksSumDurationAndWriteAllFrames() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try AVFoundationAudioWriter().makeStream(
            to: url, sampleRate: Self.sampleRate)
        try await stream.append(constChunk(value: 0.5, frames: 24_000))  // 1.0 s
        try await stream.append(constChunk(value: -0.3, frames: 48_000))  // 2.0 s
        let total = try await stream.finalize()

        #expect(abs(total - 3.0) < 0.001)  // 1.0 + 2.0
        #expect(FileManager.default.fileExists(atPath: url.path))

        // The file holds all 72 000 frames the two appends wrote.
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 72_000) <= 2)
        #expect(file.processingFormat.sampleRate == Self.sampleRate)
        #expect(file.processingFormat.channelCount == 1)
    }

    /// Streaming must not corrupt the join between appends: the second chunk's
    /// samples land immediately after the first, byte-for-byte (ALAC is lossless).
    @Test func appendsConcatenateLosslesslyAcrossTheBoundary() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstFrames = 1_200
        let secondFrames = 800
        let stream = try AVFoundationAudioWriter().makeStream(
            to: url, sampleRate: Self.sampleRate)
        try await stream.append(constChunk(value: 0.25, frames: firstFrames))
        try await stream.append(constChunk(value: -0.5, frames: secondFrames))
        _ = try await stream.finalize()

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
            let channel = buffer.floatChannelData?[0]
        else {
            Issue.record("Could not allocate read buffer")
            return
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        #expect(n >= firstFrames + secondFrames - 2)

        // First region ≈ 0.25, second region ≈ -0.5, with a clean boundary.
        var maxErrFirst: Float = 0
        for i in 0..<min(firstFrames, n) { maxErrFirst = max(maxErrFirst, abs(channel[i] - 0.25)) }
        var maxErrSecond: Float = 0
        for i in firstFrames..<min(firstFrames + secondFrames, n) {
            maxErrSecond = max(maxErrSecond, abs(channel[i] - (-0.5)))
        }
        #expect(maxErrFirst < 1e-4, "first-region round-trip error \(maxErrFirst)")
        #expect(maxErrSecond < 1e-4, "second-region round-trip error \(maxErrSecond)")
    }

    /// A stream with no real content finalizes to 0 and creates no file — the
    /// file is opened lazily on the first non-empty append, so an all-skipped /
    /// all-decorative chapter leaves no empty artifact (parity with the old
    /// batch `write([])`).
    @Test func emptyStreamFinalizesToZeroWithoutCreatingAFile() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try AVFoundationAudioWriter().makeStream(
            to: url, sampleRate: Self.sampleRate)
        let total = try await stream.finalize()

        #expect(total == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A zero-sample chunk is a no-op (e.g. a fully-skipped sub-chunk), not an error.
    @Test func zeroSampleChunkIsANoOp() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try AVFoundationAudioWriter().makeStream(
            to: url, sampleRate: Self.sampleRate)
        try await stream.append(
            TTSChunk(samples: [], sampleRate: Self.sampleRate, duration: 0))
        let total = try await stream.finalize()
        #expect(total == 0)
    }

    @Test func appendAfterFinalizeThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try AVFoundationAudioWriter().makeStream(
            to: url, sampleRate: Self.sampleRate)
        _ = try await stream.finalize()

        await #expect(throws: AudioWriterError.self) {
            try await stream.append(constChunk(value: 0.1, frames: 240))
        }
    }
}
