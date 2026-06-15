import CoreML
import FluidAudio
import Foundation

actor KokoroTTSEngine: TTSEngine {
    // Route ONLY the vocoder off the ANE. The palettized Kokoro vocoder has a
    // large-stride palettized conv the ANE rejects ("Palette weight for Large
    // stride convolution is not supported"); CoreML then silently falls back to
    // CPU/BNNS, which traps with an uncatchable EXC_BREAKPOINT/SIGTRAP in
    // BNNSGraphContextExecute_v2 for any input size. Moving the vocoder to
    // .cpuAndGPU avoids both the ANE rejection and the BNNS trap. Every other
    // stage stays on .default — critically the prosody RNN MUST stay on the ANE
    // (the .cpuAndGpu preset routes it to the GPU, hitting the GPURNNOps
    // MPSGraph JIT crash). GPU vocoder is slower/hotter on A14 but stops the
    // crash; vocoder: .cpuOnly is the fallback if it proves too slow on-device.
    private let manager: KokoroAneManager = {
        var units = KokoroAneComputeUnits.default
        units.vocoder = .cpuAndGPU
        return KokoroAneManager(computeUnits: units)
    }()
    private var initializationTask: Task<Void, Error>?

    init() {}

    func prepare() async throws {
        if let task = initializationTask {
            try await task.value
            return
        }
        let task = Task {
            try await manager.initialize()
        }
        initializationTask = task
        try await task.value
    }

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        // Always await preparation: cheap if already prepared, and (unlike a nil
        // check) it correctly waits for an in-flight init instead of synthesizing early.
        try await prepare()

        let result = try await manager.synthesizeDetailed(text: text, voice: voice.rawValue)
        let samples = result.samples

        let inferenceTime = result.timings.totalMs / 1000.0
        let duration = result.durationSeconds

        print(
            "[Kokoro] Synthesized \(text.count) chars in \(String(format: "%.2f", inferenceTime))s. Audio Duration: \(String(format: "%.2f", duration))s. RTF: \(String(format: "%.2f", duration / inferenceTime))x"
        )

        return TTSChunk(samples: samples, sampleRate: Double(result.sampleRate), duration: duration)
    }
}
