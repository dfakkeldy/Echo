// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum StudyDeckFileExporter {
    static func importDeck(
        from draft: GeneratedStudyDeckDraft,
        audiobookID: String,
        deckName: String
    ) -> FlashcardDeckImport {
        FlashcardDeckImport(
            deckName: deckName,
            targetMediaID: audiobookID,
            cards: draft.cards.map { card in
                FlashcardDeckImport.ImportedCard(
                    frontText: card.frontText,
                    backText: card.backText,
                    startTime: nil,
                    endTime: nil,
                    triggerTiming: FlashcardTriggerTiming.manualOnly.rawValue,
                    sourceAnchor: AlignmentSidecar.portableSuffix(of: card.sourceBlockID)
                )
            }
        )
    }

    static func writeImportDeck(
        from draft: GeneratedStudyDeckDraft,
        audiobookID: String,
        deckName: String,
        to url: URL
    ) throws {
        let deck = importDeck(from: draft, audiobookID: audiobookID, deckName: deckName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(deck).write(to: url, options: .atomic)
    }
}
