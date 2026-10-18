// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleRevisionService {
    enum Error: Swift.Error, Equatable, Sendable {
        case unknownBlockID(String)
        case invalidTrimOrder(before: String, after: String)
    }

    func apply(snapshot: ArticleSnapshot, recipe: ArticleEditRecipe) throws -> CleanArticle {
        let positions = Dictionary(uniqueKeysWithValues: snapshot.blocks.enumerated().map { ($0.element.id, $0.offset) })
        for id in recipe.excludedBlockIDs {
            guard positions[id] != nil else { throw Error.unknownBlockID(id) }
        }

        let start = try position(for: recipe.trimBeforeBlockID, in: positions)
        let end = try position(for: recipe.trimAfterBlockID, in: positions)
        if let start, let end, start > end {
            throw Error.invalidTrimOrder(before: recipe.trimBeforeBlockID!, after: recipe.trimAfterBlockID!)
        }

        let lower = start ?? 0
        let upper = end ?? max(-1, snapshot.blocks.count - 1)
        let excluded = Set(recipe.excludedBlockIDs)
        let blocks: [ArticleBlock]
        if lower <= upper {
            blocks = snapshot.blocks.enumerated().compactMap { index, block in
                guard index >= lower, index <= upper, !excluded.contains(block.id) else { return nil }
                return block
            }
        } else {
            blocks = []
        }
        return CleanArticle(
            captureID: snapshot.captureID,
            metadata: recipe.metadataOverrides.applying(to: snapshot.metadata),
            blocks: blocks,
            recipe: recipe,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: blocks))
    }

    func reset(snapshot: ArticleSnapshot) -> CleanArticle {
        let recipe = ArticleEditRecipe()
        return CleanArticle(
            captureID: snapshot.captureID,
            metadata: snapshot.metadata,
            blocks: snapshot.blocks,
            recipe: recipe,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: snapshot.blocks))
    }

    private func position(for id: String?, in positions: [String: Int]) throws -> Int? {
        guard let id else { return nil }
        guard let position = positions[id] else { throw Error.unknownBlockID(id) }
        return position
    }
}
