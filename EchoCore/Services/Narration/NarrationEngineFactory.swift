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
        /// The on-device synthesis engine for both iOS and macOS:
        /// **`OnnxKokoroEngine`** (ONNX Runtime, CPU) — instant load (no AOT
        /// compile), RTF ≈ 0.5 on A14, and it never touches the ANE so the BNNS
        /// vocoder trap can't occur. (The former FluidAudio + fixed-shape CoreML
        /// engines were removed once this was device-verified.)
        static func make() -> TTSEngine {
            OnnxKokoroEngine()
        }
    }
#endif
