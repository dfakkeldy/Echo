// SPDX-License-Identifier: GPL-3.0-or-later
import CoreML
import Foundation
import os.log

#if os(iOS) || os(macOS)
    import FluidAudio
#endif

#if os(iOS) || os(macOS)
    actor KokoroTTSEngine: TTSEngine {
        private let logger = Logger(category: "Kokoro")
        // Pin the vocoder stage OFF the ANE. FluidAudio's default
        // (`.aneTailGpu`) runs the Kokoro vocoder on `.cpuAndNeuralEngine`,
        // whose palettized, dynamic-shape conv graph wedges the Apple Neural
        // Engine mid-book on M-series (and is rejected outright on A14) —
        // unrecoverable until app restart. Moving ONLY the vocoder to CPU+GPU
        // (the other six stages keep their `.aneTailGpu` placement, which the
        // initializer's defaults already match) is FluidAudio's sanctioned
        // per-stage workaround for this crash class. Trades vocoder throughput
        // (GPU vs ANE) for stability — the right call for full-book narration.
        private let manager = KokoroAneManager(
            computeUnits: KokoroAneComputeUnits(vocoder: .cpuAndGPU))
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

            // Guard the RTF divide — `inferenceTime` can be 0 for a trivially short
            // clip, which would log "inf" (§2.1). Route through the logger (debug
            // level, gated out of release) instead of an unconditional `print`.
            let rtf = inferenceTime > 0 ? String(format: "%.2f", duration / inferenceTime) : "n/a"
            let summary =
                "Synthesized \(text.count) chars in \(String(format: "%.2f", inferenceTime))s. Audio Duration: \(String(format: "%.2f", duration))s. RTF: \(rtf)x"
            logger.debug("\(summary, privacy: .public)")

            return TTSChunk(
                samples: samples, sampleRate: Double(result.sampleRate), duration: duration)
        }
    }
#endif
