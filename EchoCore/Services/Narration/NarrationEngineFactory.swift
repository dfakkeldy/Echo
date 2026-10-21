// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Supplies the concrete on-device `TTSEngine` for real narration synthesis.
    /// Gated to iOS + macOS because `OnnxKokoroEngine` (and ONNX Runtime /
    /// MisakiSwift) only link there, and those are the only targets that compile
    /// `EchoCore` *and* synthesize narration (watchOS and the Widget sync neither
    /// `EchoCore` nor the narration deps). Tests inject `MockTTSEngine` straight
    /// into `NarrationService`, so they bypass this factory entirely.
    enum NarrationEngineFactory {
        /// Routes each selected voice to Kokoro (ONNX/CPU, the default) or
        /// Phonon 31M (Core ML). Both models are lazy; preparing a Phonon voice
        /// does not download or load Kokoro, and mixed voice plans can use both.
        ///
        /// - Parameter intraOpThreads: ONNX intra-op thread count; `nil` uses the
        ///   platform default from `defaultIntraOpThreads(jobs:)`.
        static func make(intraOpThreads: Int32? = nil, generateWordTimings: Bool = true)
            -> TTSEngine
        {
            let threads = intraOpThreads ?? defaultIntraOpThreads()
            // Construct actor shells on the calling MainActor. Their models
            // remain lazy; neither initializer downloads or loads weights.
            let kokoro = OnnxKokoroEngine(
                intraOpThreads: threads, generateWordTimings: generateWordTimings)
            #if canImport(PhononTTS)
                return NarrationEngineRouter(kokoro: kokoro, phonon: PhononTTSEngine())
            #else
                return kokoro
            #endif
        }

        /// Pure thread-count policy, unit-tested without sysctl: divide the
        /// performance cores across `jobs` concurrent engines. Preserve the
        /// single-engine A14 baseline of 2, but allow one thread per parallel
        /// worker rather than oversubscribing cores. Never exceed 4 — Kokoro-82M's
        /// intra-op scaling saturates quickly, and threads beyond ~4 only add
        /// scheduling overhead while starving parallel workers.
        static func resolvedIntraOpThreads(performanceCores: Int, jobs: Int) -> Int32 {
            Int32(min(4, max(jobs > 1 ? 1 : 2, performanceCores / max(jobs, 1))))
        }

        /// Platform default for the CPU EP's intra-op parallelism. iOS keeps the
        /// measured A14 tuning (2 performance cores). macOS resolves from the
        /// machine's actual performance-core count so an M-series Mac no longer
        /// runs inference throttled to an iPhone's core budget.
        static func defaultIntraOpThreads(jobs: Int = 1) -> Int32 {
            #if os(macOS)
                return resolvedIntraOpThreads(
                    performanceCores: performanceCoreCount(), jobs: jobs)
            #else
                return 2
            #endif
        }

        #if os(macOS)
            /// The machine's performance-core count via
            /// `hw.perflevel0.physicalcpu`; falls back to half the active
            /// processors (M-series ship roughly half P-cores) when the sysctl
            /// is unavailable.
            static func performanceCoreCount() -> Int {
                var cores: Int32 = 0
                var size = MemoryLayout<Int32>.size
                if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0,
                    cores > 0
                {
                    return Int(cores)
                }
                return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            }
        #endif
    }
#endif
