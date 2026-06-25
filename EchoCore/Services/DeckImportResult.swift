// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ImportDeckResult: Equatable, Sendable {
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

enum ImportDeckWarning: Equatable, Sendable {
    case sourceAnchorUnresolved(cardReference: String, sourceAnchor: String)
    case sourceAnchorWrongBook(cardReference: String, sourceAnchor: String)
    case sourceAnchorMalformed(cardReference: String, sourceAnchor: String)
    case targetAudiobookHasNoEPUBBlocks(targetMediaID: String)
    case apkgSidecarMissingTargetMediaID
    case apkgSidecarCardNotFound(cardReference: String)
    case apkgSidecarDecodeFailed(reason: String)
}
