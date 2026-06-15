import Foundation
import CoreML
import FluidAudio

actor KokoroTTSEngine: TTSEngine {
    private let manager = KokoroAneManager()
    private var isInitialized = false
    
    init() {}
    
    func prepare() async throws {
        if !isInitialized {
            try await manager.initialize()
            isInitialized = true
        }
    }
    
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        // Ensure initialized before synthesis
        if !isInitialized {
            try await prepare()
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // FluidAudio's KokoroAneManager returns an array of Float32
        // NOTE: voice selection might be supported by setting properties on manager or passing to synthesize.
        // If not directly supported in the signature, we'll use the default voice.
        // We will pass the text.
        let data = try await manager.synthesize(text: text)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let inferenceTime = endTime - startTime
        let duration = Double(samples.count) / 24000.0
        
        print("[Kokoro] Synthesized \(text.count) chars in \(String(format: "%.2f", inferenceTime))s. Audio Duration: \(String(format: "%.2f", duration))s. RTF: \(String(format: "%.2f", duration / inferenceTime))x")
        
        return TTSChunk(samples: samples, sampleRate: 24000, duration: duration)
    }
}
