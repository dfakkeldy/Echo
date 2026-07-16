// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// `nonisolated`: pure `Sendable` value result. Under the iOS target's Swift 6
// MainActor default isolation its init would be inferred `@MainActor`, which the
// `nonisolated ApkgImportService` cannot call.
nonisolated struct ImportDeckResult: Equatable, Sendable {
    let importedCount: Int
    let anchoredCount: Int
    /// The number of imported cards with an attached image, derived from
    /// committed database rows (`media_json IS NOT NULL`) rather than the
    /// write plan's card count — see `DeckImportService.importDeckVNext(
    /// from:targetAudiobookID:db:)`. Defaults to 0 so APKG/legacy callers
    /// that never populate images can omit it.
    let imageCount: Int
    let warningCount: Int
    let warnings: [ImportDeckWarning]

    init(importedCount: Int, anchoredCount: Int, imageCount: Int = 0, warnings: [ImportDeckWarning])
    {
        self.importedCount = importedCount
        self.anchoredCount = anchoredCount
        self.imageCount = imageCount
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
    /// `PortableDeckImageStager.commit` failed to remove a superseded
    /// image directory's backup after a successful reimport replaced it.
    /// The newly committed database rows and the newly published image
    /// directory are both valid; only the now-unused backup failed to
    /// clean up, and is left on disk for the next launch's orphan cleanup
    /// pass (`DeckImportService.cleanupOrphanedImageStaging`).
    case imageBackupCleanupFailed(deckID: String)
}
