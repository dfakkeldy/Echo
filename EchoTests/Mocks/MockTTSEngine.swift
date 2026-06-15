import Foundation

@testable import Echo

/// Deterministic TTS double: duration = characterCount × secondsPerChar.
final class MockTTSEngine: TTSEngine, @unchecked Sendable {
    var preparationCallCount = 0
    func prepare() async throws {
        preparationCallCount += 1
    }
    let secondsPerChar: Double
    private(set) var calls: [(text: String, voice: VoiceID)] = []
    var throwOnText: String?
    /// Sub-chunk text that should raise the skippable length-cap error, so tests
    /// can verify a single over-long sub-chunk is skipped without aborting.
    var lengthCapOnText: String?

    init(secondsPerChar: Double = 0.1) { self.secondsPerChar = secondsPerChar }

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        calls.append((text, voice))
        if let cap = lengthCapOnText, text == cap { throw NarrationError.lengthCapExceeded }
        if let bad = throwOnText, text == bad { throw NarrationError.synthesisFailed }
        let duration = Double(text.count) * secondsPerChar
        return TTSChunk(
            samples: [Float](repeating: 0, count: max(1, text.count)),
            sampleRate: 24_000, duration: duration)
    }
}
