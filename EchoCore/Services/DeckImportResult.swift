// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// `nonisolated`: pure `Sendable` value result. Under the iOS target's Swift 6
// MainActor default isolation its init would be inferred `@MainActor`, which the
// `nonisolated ApkgImportService` cannot call.
nonisolated struct ImportDeckResult: Equatable, Sendable {
    let importedCount: Int
    let anchoredCount: Int
    let warningCount: Int
    let warnings: [ImportDeckWarning]

    init(importedCount: Int, anchoredCount: Int, warnings: [ImportDeckWarning]) {
        self.importedCount = importedCount
        self.anchoredCount = anchoredCount
        self.warningCount = warnings.count
        self.warnings = warnings
    }
}

// `nonisolated`: pure `Sendable` value enum, built/compared off-actor by the
// `nonisolated` import service.
nonisolated enum ImportDeckWarning: Equatable, Sendable {
    case sourceAnchorUnresolved(cardReference: String, sourceAnchor: String)
    case sourceAnchorWrongBook(cardReference: String, sourceAnchor: String)
    case sourceAnchorMalformed(cardReference: String, sourceAnchor: String)
    case targetAudiobookHasNoEPUBBlocks(targetMediaID: String)
    case apkgSidecarMissingTargetMediaID
    case apkgSidecarDecodeFailed(reason: String)
}
