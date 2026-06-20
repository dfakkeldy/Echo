// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whether on-device Kokoro narration is supported on this hardware.
///
/// **Now always true.** The iOS engine is ONNX Runtime (CPU) — it runs the Kokoro
/// graph on the CPU and never touches the Neural Engine, so the A14 `libBNNS`
/// vocoder trap that once forced an A15+ iPhone gate cannot occur. On-device A14
/// measurement confirmed it: ~0.7 s session-load (no AOT compile), RTF ≈ 0.5 (2×
/// realtime), no crash. Every device that meets Echo's iOS 18 / macOS 15 floor can
/// narrate; there is no longer a hardware gate.
///
/// History (for reference): the original FluidAudio dynamic-shape vocoder and the
/// later fixed-shape `KokoroFixedShapeEngine` both ran the wedge-prone stage on the
/// A14 ANE, which trapped on long input — hence the former A15+ gate. The ONNX
/// pivot removed the ANE from the path entirely, obsoleting the gate.
enum NarrationCapability {

    /// On-device narration is universally available with the ONNX (CPU) engine.
    /// Kept as a property (rather than inlined `true`) so call sites — the Listen
    /// guard in `PlayerModel+Narration` and the narration affordances in
    /// `NowPlayingTab` — keep a single, named capability check.
    static var supportsOnDeviceNarration: Bool { true }
}
