// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Preflights a portable (formatVersion 2) study deck against a selected
/// local audiobook's persisted canonical EPUB blocks: revalidates the deck's
/// `sourceSignature`, and resolves every card's `sourceAnchor` (and, when
/// present, `imageAnchor`) to a concrete local block, before any database
/// write happens.
///
/// Fail-closed by design, unlike `EPUBSourceAnchorResolver`'s legacy
/// warn-and-continue resolution: a portable deck's whole point is a stable,
/// unattended, cross-device join back to the selected book's text, so any
/// anchor that doesn't resolve to a usable block throws rather than importing
/// a partially-broken card.
///
/// `nonisolated`: a pure, synchronous GRDB-reading preflight (`DatabaseReader`
/// is `Sendable`; the `Database` closure runs synchronously). Under the
/// project's Main Actor default isolation this would otherwise be inferred
/// `@MainActor`, which would block calling it from a background import.
nonisolated enum PortableDeckPreflight {

    /// Builds a `PortableDeckWritePlan` for `deck` against `targetAudiobookID`.
    /// Reads `targetAudiobookID`'s audiobook row and its persisted
    /// `EPubBlockRecord`s; performs no database writes.
    static func prepare(
        deck: PortableDeckImport,
        targetAudiobookID: String,
        deckURL: URL,
        dbReader: any DatabaseReader
    ) throws -> PortableDeckWritePlan {
        let trimmedID = targetAudiobookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw DeckImportError.selectedAudiobookIDMissing
        }

        let (audiobookExists, records): (Bool, [EPubBlockRecord]) = try dbReader.read { db in
            let exists = try AudiobookRecord.fetchOne(db, key: targetAudiobookID) != nil
            let blocks = try EPubBlockRecord
                .filter(Column("audiobook_id") == targetAudiobookID)
                .order(Column("sequence_index"))
                .fetchAll(db)
            return (exists, blocks)
        }
        guard audiobookExists else {
            throw DeckImportError.selectedAudiobookNotFound(targetAudiobookID)
        }
        guard !records.isEmpty else {
            throw DeckImportError.selectedAudiobookHasNoCanonicalBlocks(targetAudiobookID)
        }

        // Compare the recomputed canonical signature against the deck's
        // recorded one before looking at any individual card: a stale or
        // mismatched edition makes every per-card anchor lookup meaningless.
        guard EchoSourceSignature.make(records: records) == deck.sourceSignature else {
            throw DeckImportError.sourceSignatureMismatch
        }

        // Keyed by each block's content-stable portable suffix (`s<i>-b<j>`),
        // not its device-local id, so a portable-form card anchor resolves
        // directly without a per-card database round trip. `isHidden` is
        // deliberately not part of the key or excluded here: hidden blocks
        // still resolve, matching `EchoSourceSignature`'s exclusion of
        // mutable reader state.
        let blocksBySuffix = Dictionary(
            records.map { (AlignmentSidecar.portableSuffix(of: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var sourceBlockIDs: [String] = []
        sourceBlockIDs.reserveCapacity(deck.cards.count)
        var cards: [PortableDeckWritePlan.Card] = []
        cards.reserveCapacity(deck.cards.count)

        for (index, card) in deck.cards.enumerated() {
            let sourceBlockID = try resolveSourceBlockID(
                anchor: card.sourceAnchor, blocksBySuffix: blocksBySuffix, cardIndex: index)
            let media = try resolveMedia(
                card: card, blocksBySuffix: blocksBySuffix, deckURL: deckURL, cardIndex: index)
            sourceBlockIDs.append(sourceBlockID)
            cards.append(
                PortableDeckWritePlan.Card(
                    imported: card, sourceBlockID: sourceBlockID, media: media))
        }

        return PortableDeckWritePlan(
            deckID: deck.deckID,
            deckName: deck.deckName,
            targetAudiobookID: targetAudiobookID,
            sourceSignature: deck.sourceSignature,
            sourceBlockIDs: sourceBlockIDs,
            cards: cards
        )
    }

    /// Resolves a card's `sourceAnchor` to a local EPUB block id. Portable
    /// anchors are always the bare `s<i>-b<j>` suffix form — enforced at
    /// decode time for real documents (`ValidatedDeckImport`), and
    /// defensively re-checked here since `PortableDeckImport` values can also
    /// be constructed directly (e.g. in tests). Must land on a
    /// non-front-matter heading, paragraph, or sentence — never an image,
    /// never front matter.
    private static func resolveSourceBlockID(
        anchor: String?,
        blocksBySuffix: [String: EPubBlockRecord],
        cardIndex: Int
    ) throws -> String {
        guard let anchor, EPUBSourceAnchorResolver.isValidPortableSuffix(anchor) else {
            throw DeckImportError.selectedSourceAnchorMalformed(cardIndex: cardIndex)
        }
        guard let block = blocksBySuffix[anchor] else {
            throw DeckImportError.selectedSourceAnchorUnresolved(cardIndex: cardIndex)
        }
        guard !block.isFrontMatter else {
            throw DeckImportError.selectedSourceAnchorResolvesToFrontMatter(cardIndex: cardIndex)
        }
        guard block.blockKind != EPubBlockRecord.Kind.image.rawValue else {
            throw DeckImportError.selectedSourceAnchorResolvesToImage(cardIndex: cardIndex)
        }
        return block.id
    }

    /// Resolves a card's optional image input. `imageAnchor` (an in-book
    /// figure) takes priority; decode-time validation already guarantees
    /// `imageAnchor` and `imageFile` are mutually exclusive for real
    /// documents. `imageFile`'s path safety is already validated at decode
    /// time (`ValidatedDeckImport`); staging/copying the file into per-deck
    /// storage happens later, at persistence time.
    private static func resolveMedia(
        card: FlashcardDeckImport.ImportedCard,
        blocksBySuffix: [String: EPubBlockRecord],
        deckURL: URL,
        cardIndex: Int
    ) throws -> PreparedCardMedia? {
        if let anchor = card.imageAnchor, !anchor.isEmpty {
            guard EPUBSourceAnchorResolver.isValidPortableSuffix(anchor),
                let block = blocksBySuffix[anchor]
            else {
                throw DeckImportError.selectedImageAnchorUnresolved(cardIndex: cardIndex)
            }
            guard block.blockKind == EPubBlockRecord.Kind.image.rawValue else {
                throw DeckImportError.selectedImageAnchorResolvesToNonImage(cardIndex: cardIndex)
            }
            guard let path = block.imagePath, !path.isEmpty else {
                // An image block with no stored artwork isn't a usable
                // image any more than a missing block is.
                throw DeckImportError.selectedImageAnchorUnresolved(cardIndex: cardIndex)
            }
            return .sourceImage(path: path)
        }
        if let relativePath = card.imageFile, !relativePath.isEmpty {
            let source = deckURL.deletingLastPathComponent()
                .appendingPathComponent(relativePath)
            return .stagedFile(source: source, relativePath: relativePath)
        }
        return nil
    }
}

/// The fully resolved, ready-to-persist form of a portable study deck: every
/// card's `sourceAnchor` (and `imageAnchor`, if present) has already been
/// proven to resolve against `targetAudiobookID`'s canonical blocks.
/// Persisting this plan still re-verifies `sourceSignature` immediately
/// before writing (see `DeckImportService.verifySourceSnapshot`), since a
/// plan can go stale between preflight and the write transaction.
nonisolated struct PortableDeckWritePlan: Sendable {
    struct Card: Sendable {
        let imported: FlashcardDeckImport.ImportedCard
        let sourceBlockID: String
        let media: PreparedCardMedia?
    }

    let deckID: String
    let deckName: String
    /// The caller-selected local audiobook id. Never the portable
    /// `targetMediaID` sentinel carried by `PortableDeckImport` — that value
    /// must never reach a database write as an audiobook id.
    let targetAudiobookID: String
    let sourceSignature: EchoSourceSignature
    let sourceBlockIDs: [String]
    let cards: [Card]
}

/// A card's resolved image input, ready for the persistence step to turn
/// into `Flashcard.mediaJSON`.
nonisolated enum PreparedCardMedia: Sendable {
    /// An in-book figure block's already-stored image path.
    case sourceImage(path: String)
    /// A bundled deck image, not yet copied into per-deck storage.
    case stagedFile(source: URL, relativePath: String)
}
