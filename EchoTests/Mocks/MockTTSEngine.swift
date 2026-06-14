import Foundation

@testable import Echo

/// Deterministic TTS double: duration = characterCount × secondsPerChar.
final class MockTTSEngine: TTSEngine, @unchecked Sendable {
    let secondsPerChar: Double
    private(set) var calls: [(text: String, voice: VoiceID)] = []
    var throwOnText: String?

    init(secondsPerChar: Double = 0.1) { self.secondsPerChar = secondsPerChar }

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        calls.append((text, voice))
        if let bad = throwOnText, text == bad { throw NarrationError.synthesisFailed }
        let duration = Double(text.count) * secondsPerChar
        return TTSChunk(
            samples: [Float](repeating: 0, count: max(1, text.count)),
            sampleRate: 24_000, duration: duration)
    }
}
