// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyDeckSourceBuilder {
    let db: DatabaseWriter

    func sources(
        audiobookID: String,
        selection: StudyDeckGenerationSelection = .wholeBook
    ) throws -> [StudyDeckSource] {
        let dao = EPubBlockDAO(db: db)
        let blocks = try dao.visibleBlocks(for: audiobookID)
        let filter = SourceFilter(selection: selection)

        return blocks.compactMap { block in
            guard filter.includes(block),
                  let source = StudyDeckSource(block: block) else {
                return nil
            }
            return source
        }
    }
}

private struct SourceFilter {
    private enum Scope {
        case all
        case chapter(Int)
        case blockIDs(Set<String>)
    }

    private let scope: Scope

    init(selection: StudyDeckGenerationSelection) {
        switch selection {
        case .wholeBook:
            scope = .all
        case .chapter(let chapterIndex):
            scope = .chapter(chapterIndex)
        case .currentSourceBlockID(let sourceBlockID):
            scope = .blockIDs([sourceBlockID])
        case .explicitSourceBlockIDs(let sourceBlockIDs):
            scope = .blockIDs(Set(sourceBlockIDs))
        }
    }

    func includes(_ block: EPubBlockRecord) -> Bool {
        switch scope {
        case .all:
            return true
        case .chapter(let chapterIndex):
            return block.chapterIndex == chapterIndex
        case .blockIDs(let sourceBlockIDs):
            return sourceBlockIDs.contains(block.id)
        }
    }
}

private extension StudyDeckSource {
    init?(block: EPubBlockRecord) {
        guard !block.isFrontMatter,
              Self.isTextBlock(kind: block.blockKind),
              let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        self.init(
            id: block.id,
            sourceBlockID: block.id,
            audiobookID: block.audiobookID,
            blockKind: block.blockKind,
            text: text,
            chapterIndex: block.chapterIndex,
            sequenceIndex: block.sequenceIndex,
            spineIndex: block.spineIndex,
            blockIndex: block.blockIndex
        )
    }

    private static func isTextBlock(kind: String) -> Bool {
        switch EPubBlockRecord.Kind(rawValue: kind) {
        case .heading, .paragraph, .sentence:
            return true
        case .image, nil:
            return false
        }
    }
}
