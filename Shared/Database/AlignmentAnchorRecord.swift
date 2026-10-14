// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A user-created or system-generated anchor point that pins an EPUB block
/// to a specific audio timestamp. Anchors are the foundation of the manual
/// alignment system — interpolation fills in timestamps between anchors.
nonisolated struct AlignmentAnchorRecord: Identifiable, Equatable, Codable, FetchableRecord,
    MutablePersistableRecord, Sendable
{
    var id: String
    var audiobookID: String
    var epubBlockID: String
    var audioTime: TimeInterval
    var audioEndTime: TimeInterval?
    var anchorKind: String
    var source: String
    var note: String?
    var createdAt: String?
    var modifiedAt: String?

    static let databaseTableName = "alignment_anchor"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case audioTime = "audio_time"
        case audioEndTime = "audio_end_time"
        case anchorKind = "anchor_kind"
        case source
        case note
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

// MARK: - Anchor Kind Constants

extension AlignmentAnchorRecord {
    enum AnchorKind: String, Sendable {
        case point = "point"
        case chapterStart = "chapterStart"
        case chapterEnd = "chapterEnd"
    }

    enum Source: String, Sendable {
        case moveToNow = "moveToNow"
        case searchResult = "searchResult"
        case chapterBoundary = "chapterBoundary"
        case imported = "imported"
        case autoAlignment = "autoAlignment"
        case continuousBackground = "continuousBackground"
        case synthesized = "synthesized"  // TTS-generated narration anchors
        case transcriptAlignment = "transcriptAlignment"  // ASR↔source-block alignment (M2)
    }

    /// The sources a person placed by hand. Every other source is a machine
    /// measurement that a later alignment pass can recompute; these cannot be
    /// recomputed from anything, so no automatic pass may discard one.
    ///
    /// Single definition on purpose — `DocumentImportFinalizer` (which refuses to
    /// overwrite them with a fresh alignment) and `EPUBImportService` (which
    /// restores them across a `.replaceAll` block rebuild) have to agree about
    /// what "human" means, and a second copy would drift.
    ///
    /// `nonisolated` computed so the importer can read it from inside GRDB's
    /// `@Sendable` write closure under this project's MainActor default isolation.
    nonisolated static var humanAnchorSources: Set<String> {
        [
            Source.moveToNow.rawValue,
            Source.searchResult.rawValue,
            Source.chapterBoundary.rawValue,
        ]
    }
}
