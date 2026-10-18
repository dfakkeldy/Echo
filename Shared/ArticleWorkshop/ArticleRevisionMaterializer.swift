// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleRevisionMaterializer {
    enum Error: Swift.Error, Equatable, Sendable {
        case revisionBelongsToAnotherCapture
        case malformedRevision
        case inconsistentMetadataOverrides
        case invalidRecipe
        case readableContentDigestMismatch
    }

    func materialize(
        capture: ArticleCaptureRecord,
        revision: ArticleRevisionRecord,
        source: ArticleSnapshot
    ) throws -> CleanArticle {
        guard revision.captureID == capture.id,
            source.captureID.uuidString == capture.id
        else {
            throw Error.revisionBelongsToAnotherCapture
        }
        let recipe: ArticleEditRecipe
        let overrides: ArticleMetadataOverrides
        do {
            recipe = try JSONDecoder.articleWorkshop.decode(
                ArticleEditRecipe.self,
                from: Data(revision.recipeJSON.utf8))
            overrides = try JSONDecoder.articleWorkshop.decode(
                ArticleMetadataOverrides.self,
                from: Data(revision.metadataOverridesJSON.utf8))
        } catch {
            throw Error.malformedRevision
        }
        guard recipe.metadataOverrides == overrides else {
            throw Error.inconsistentMetadataOverrides
        }
        let clean: CleanArticle
        do {
            clean = try ArticleRevisionService().apply(snapshot: source, recipe: recipe)
        } catch {
            throw Error.invalidRecipe
        }
        guard clean.readableContentSHA256 == revision.readableContentSHA256 else {
            throw Error.readableContentDigestMismatch
        }
        return clean
    }
}
