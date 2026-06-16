// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Identifier for a narration voice (e.g. a Kokoro voicepack key).
struct VoiceID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A rendered span of speech audio for one block of text.
/// Samples are mono Float PCM at `sampleRate`. `Sendable` so it can cross
/// the actor→main boundary safely (no non-Sendable AVAudioPCMBuffer).
struct TTSChunk: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval

    /// A run of digital silence `seconds` long at `sampleRate`. Used for the
    /// chapter lead-out pad so the final word isn't clipped when the player
    /// advances to the next chapter. Frame count is rounded to the nearest
    /// sample so the reported `duration` matches the samples actually written.
    static func silence(seconds: TimeInterval, sampleRate: Double) -> TTSChunk {
        let frameCount = max(0, Int((seconds * sampleRate).rounded()))
        return TTSChunk(
            samples: [Float](repeating: 0, count: frameCount),
            sampleRate: sampleRate,
            duration: Double(frameCount) / sampleRate)
    }
}

/// The swappable narration engine boundary. Mocked in tests; Kokoro in Plan 3.
protocol TTSEngine: Sendable {
    func prepare() async throws
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
}
