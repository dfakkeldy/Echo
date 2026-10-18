// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if canImport(FoundationModels) && (os(iOS) || os(macOS))
    import FoundationModels
#endif

/// Whether on-device Apple Foundation Models can generate study cards on THIS device,
/// computed exactly like the shipped narration-QA availability check (no locale pre-check).
enum StudyDeckFMAvailability {
    nonisolated static var isAvailable: Bool {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
        #endif
        return false
    }

    nonisolated static var statusMessage: String {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return "On-device generation ready (free, fully private)."
                case .unavailable(.deviceNotEligible):
                    return "This device isn't Apple-Intelligence capable."
                case .unavailable(.appleIntelligenceNotEnabled):
                    return "Turn on Apple Intelligence in Settings to generate on-device."
                case .unavailable(.modelNotReady):
                    return "Apple Intelligence model is still downloading."
                @unknown default: return "On-device generation is unavailable."
                }
            }
        #endif
        return "On-device generation needs iOS 26 or macOS 26."
    }
}
