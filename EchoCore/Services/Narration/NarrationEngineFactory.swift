// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Supplies the concrete on-device `TTSEngine` (Kokoro via FluidAudio) for
    /// real narration synthesis. Gated to iOS + macOS because `KokoroTTSEngine`
    /// and FluidAudio only exist there, and those are the only targets that
    /// compile `EchoCore` *and* synthesize narration (watchOS and the Widget
    /// sync neither `EchoCore` nor FluidAudio). Tests inject `MockTTSEngine`
    /// straight into `NarrationService`, so they bypass this factory entirely —
    /// hence no test/mock branch here.
    enum NarrationEngineFactory {
        /// The real on-device synthesis engine for the current platform.
        static func make() -> TTSEngine {
            KokoroTTSEngine()
        }
    }
#endif
