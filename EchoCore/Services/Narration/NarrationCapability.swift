// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whether on-device Kokoro narration is supported on this hardware.
///
/// History: the *old* FluidAudio dynamic-shape vocoder trapped the A14 Neural
/// Engine (uncatchable `EXC_BREAKPOINT`/SIGTRAP in `libBNNS`) on real-book-length
/// input (audit §3.1, device-confirmed 2026-06-15), so narration was gated to
/// **A15-or-newer** chips. The engine has since been swapped to the fixed-shape
/// `KokoroFixedShapeEngine` (decoder as fixed-shape CoreML, hn-NSF source in
/// Accelerate, off the ANE), which is the routing a competitor (Fox Reader) ships
/// successfully on the same A14 iPhone 12 Pro. The A15+ gate therefore now stands
/// only **pending an on-device A14 no-wedge verification**, not pending the swap.
/// Until that verification passes the production gate stays A15+; a DEBUG developer
/// override (`developerForceEnableKey`) unblocks A14 so the verify can be run.
/// The audio-less reader stays fully functional; only synthesis is gated.
///
/// Detection is by **chip generation via the device model identifier**, not OS
/// version (the plan's explicit requirement): an iPhone needs model major ≥ 14
/// (`iPhone14,x` = A15). Other families (iPad, Mac/Apple Silicon, Simulator) run
/// the CPU/GPU path fine and default to supported.
enum NarrationCapability {

    /// `UserDefaults` key for the **DEBUG-only** developer override that allows
    /// narration on hardware the production gate blocks (e.g. A14), so the
    /// fixed-shape engine can be verified on the very device the gate exists for.
    /// Honoured only in DEBUG builds — App Store builds keep the A15+ gate.
    static let developerForceEnableKey = "narration.developerForceEnableA14"

    static var supportsOnDeviceNarration: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return isSupported(
                modelIdentifier: modelIdentifier, developerOverride: developerOverride)
        #endif
    }

    /// True only when a developer has flipped the override **in a DEBUG build**.
    /// Always false in release, so the production gate is never affected.
    static var developerOverride: Bool {
        #if DEBUG
            return UserDefaults.standard.bool(forKey: developerForceEnableKey)
        #else
            return false
        #endif
    }

    /// Pure, testable gate. iPhones require A15+ (model major ≥ 14); every other
    /// device family defaults to supported. A `developerOverride` short-circuits
    /// the hardware check entirely (used only for on-device verification builds).
    static func isSupported(modelIdentifier id: String, developerOverride: Bool = false) -> Bool {
        if developerOverride { return true }
        guard id.hasPrefix("iPhone") else { return true }
        let digits = id.dropFirst("iPhone".count).prefix { $0.isNumber }
        guard let major = Int(digits) else { return true }
        return major >= 14
    }

    /// The hardware model identifier, e.g. `"iPhone13,3"` (iPhone 12 Pro, A14).
    static var modelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
