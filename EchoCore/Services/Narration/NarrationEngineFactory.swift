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
        /// The real on-device synthesis engine for the current platform.
        ///
        /// The previous `KokoroTTSEngine` (FluidAudio dynamic-shape vocoder) is
        /// kept in-tree for a one-line revert if the fixed-shape engine regresses
        /// in Phase 5 verification; it is removed in the Phase 5.3 cleanup once
        /// the macOS + A14 full-book narrations pass.
        static func make() -> TTSEngine {
            KokoroFixedShapeEngine()
        }
    }
#endif
