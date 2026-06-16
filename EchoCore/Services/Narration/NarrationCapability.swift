// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whether on-device Kokoro narration is supported on this hardware.
///
/// The A14 Neural Engine traps (uncatchable `EXC_BREAKPOINT`/SIGTRAP in
/// `libBNNS`) on the palettized Kokoro vocoder for real-book-length input — it
/// recurs intermittently on certain synthesis shapes (audit §3.1, device-confirmed
/// 2026-06-15). Until the vocoder model is swapped for a non-trapping one, we gate
/// narration to **A15-or-newer** chips. The audio-less reader stays fully
/// functional; only synthesis is gated.
///
/// Detection is by **chip generation via the device model identifier**, not OS
/// version (the plan's explicit requirement): an iPhone needs model major ≥ 14
/// (`iPhone14,x` = A15). Other families (iPad, Mac/Apple Silicon, Simulator) run
/// the CPU/GPU path fine and default to supported.
enum NarrationCapability {

    static var supportsOnDeviceNarration: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return isSupported(modelIdentifier: modelIdentifier)
        #endif
    }

    /// Pure, testable gate. iPhones require A15+ (model major ≥ 14); every other
    /// device family defaults to supported.
    static func isSupported(modelIdentifier id: String) -> Bool {
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
