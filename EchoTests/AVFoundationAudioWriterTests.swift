import AVFoundation
import Foundation
import Testing

@testable import Echo

/// Guards that the narration cache writer is LOSSLESS. The original AAC encoder
/// (64 kbps) introduced a constant high-pitched whine; a lossless round-trip
/// (ALAC/PCM in the same .m4a container) must reproduce the written samples
/// exactly within float epsilon — an AAC writer would fail (d).
@Suite struct AVFoundationAudioWriterTests {

    private static let sampleRate: Double = 24_000

    /// A short, deterministic 440 Hz sine at -6 dBFS so the round-trip has real
    /// spectral content (a silent/ramp buffer can mask encoder artifacts).
    private func sineChunk(frames: Int) -> TTSChunk {
        let sr = Self.sampleRate
        var samples = [Float](repeating: 0, count: frames)
        let twoPiF = 2.0 * Double.pi * 440.0 / sr
        for i in 0..<frames {
            samples[i] = Float(0.5 * sin(twoPiF * Double(i)))
        }
        return TTSChunk(samples: samples, sampleRate: sr, duration: Double(frames) / sr)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("avwriter-\(UUID().uuidString).m4a")
    }

    @Test func roundTripIsLosslessAndPreservesFormat() async throws {
        let frames = 4_800  // 0.2 s at 24 kHz
        let chunk = sineChunk(frames: frames)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = AVFoundationAudioWriter()
        let reportedDuration = try await writer.write([chunk], to: url)

        // (a) readable
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        // (b) format preserved: 24 kHz mono
        #expect(format.sampleRate == Self.sampleRate)
        #expect(format.channelCount == 1)

        // (c) frame count ~= input samples; duration matches within a small tolerance
        #expect(abs(file.length - Int64(frames)) <= 1)
        #expect(abs(reportedDuration - chunk.duration) < 0.0001)

        // Read the whole file back into a float buffer.
        guard
            let readBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else {
            Issue.record("Could not allocate read buffer")
            return
        }
        try file.read(into: readBuffer)
        guard let channel = readBuffer.floatChannelData?[0] else {
            Issue.record("No float channel data in read-back buffer")
            return
        }
        let readCount = Int(readBuffer.frameLength)

        // (d) LOSSLESS round-trip: read-back samples equal written samples within a
        // tiny epsilon. ALAC/PCM hold this; the OLD 64 kbps AAC writer would not —
        // this is the regression guard that proves losslessness.
        let comparable = min(readCount, frames)
        #expect(comparable >= frames - 1)
        var maxErr: Float = 0
        for i in 0..<comparable {
            maxErr = max(maxErr, abs(channel[i] - chunk.samples[i]))
        }
        #expect(maxErr < 1e-4, "max round-trip error \(maxErr) exceeds lossless epsilon")
    }
}
