import Foundation

actor KokoroTTSEngine: TTSEngine {
    
    init() {
        // Model load + inference setup would go here
    }
    
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        // Stub implementation for now.
        // In reality, this would run inference on the MLX/CoreML model.
        let estimatedDuration = Double(text.count) * 0.08
        return TTSChunk(samples: [], sampleRate: 24000, duration: estimatedDuration)
    }
}
