// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides which `DivergenceClassifier` to build. FM-wrapped-deterministic is
/// returned ONLY when preference is "auto", FM reports available, the FM path is
/// compiled in, and the running OS is iOS 26 / macOS 26+. Otherwise deterministic.
/// `availabilityIsAvailable` is supplied by the caller (computed from
/// `SystemLanguageModel.default.availability`) so this stays testable off-device.
enum DivergenceClassifierFactory {
    @MainActor
    static func make(preference: String, availabilityIsAvailable: Bool) -> DivergenceClassifier {
        let deterministic = DeterministicDivergenceClassifier()
        guard preference == "auto", availabilityIsAvailable else { return deterministic }
        #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                return FoundationModelsDivergenceClassifier(fallback: deterministic)
            }
        #endif
        return deterministic
    }
}
