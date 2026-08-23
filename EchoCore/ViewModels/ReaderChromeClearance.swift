// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keeps root-owned overlays out of Reader's usable viewport without making
/// Reader duplicate responsibility for the shared dock itself.
nonisolated enum ReaderChromeClearance {
    static func bottomInset(dockHeight: Double, overlayHeight: Double) -> Double {
        max(0, dockHeight) + max(0, overlayHeight)
    }
}

/// Selects the one iOS surface that replaces the root-owned top row with the
/// Reader's local search and utility chrome.
nonisolated enum ReaderTopChromeLayout {
    static func usesCompactHeader(
        selectedTabIsRead: Bool,
        readPathIsEmpty: Bool,
        hasEPUB: Bool,
        hasPDF: Bool,
        hasStandaloneTranscript: Bool
    ) -> Bool {
        selectedTabIsRead
            && readPathIsEmpty
            && hasEPUB
            && !hasPDF
            && !hasStandaloneTranscript
    }
}
