// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Supplies the concrete on-device `TTSEngine` for real narration synthesis.
    /// Gated to iOS + macOS because `KokoroFixedShapeEngine` (and the vendored
    /// KokoroPipeline / MisakiSwift) only exist there, and those are the only
    /// targets that compile `EchoCore` *and* synthesize narration (watchOS and
    /// the Widget sync neither `EchoCore` nor the narration deps). Tests inject
    /// `MockTTSEngine` straight into `NarrationService`, so they bypass this
    /// factory entirely — hence no test/mock branch here.
    enum NarrationEngineFactory {
        #if os(iOS)
            /// DEBUG-only A/B revert (Settings ▸ Debug Menu): force the legacy
            /// fixed-shape CoreML engine instead of the default ONNX engine. Off
            /// (default) → ONNX. Kept until the CoreML stack is removed in cleanup.
            static let useLegacyCoreMLEngineKey = "narration.useLegacyCoreMLEngine"
        #endif

        /// The on-device synthesis engine for the current platform.
        ///
        /// **iOS default: `OnnxKokoroEngine`** (ONNX Runtime, CPU) — instant load,
        /// RTF ≈ 0.5 on A14, never touches the ANE (so no BNNS trap). A DEBUG toggle
        /// reverts to the legacy `KokoroFixedShapeEngine` for A/B. **macOS still uses
        /// `KokoroFixedShapeEngine`** until the ONNX engine is ported there (ORT is
        /// only linked to the iOS target for now).
        static func make() -> TTSEngine {
            #if os(iOS)
                #if DEBUG
                    if UserDefaults.standard.bool(forKey: useLegacyCoreMLEngineKey) {
                        return KokoroFixedShapeEngine()
                    }
                #endif
                return OnnxKokoroEngine()
            #else
                return KokoroFixedShapeEngine()
            #endif
        }
    }
#endif
