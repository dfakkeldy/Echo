// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleRevisionServiceTests {
    @Test func resetReturnsTheOriginalBlockSequence() throws {
        let snapshot = snapshot()
        let revised = try ArticleRevisionService().apply(
            snapshot: snapshot,
            recipe: ArticleEditRecipe(
                excludedBlockIDs: [snapshot.blocks[1].id],
                trimBeforeBlockID: snapshot.blocks[1].id,
                trimAfterBlockID: snapshot.blocks[2].id,
                metadataOverrides: .init(title: "Edited")))

        let reset = ArticleRevisionService().reset(snapshot: snapshot)

        #expect(revised.blocks.map(\.id) == [snapshot.blocks[2].id])
        #expect(reset.blocks == snapshot.blocks)
        #expect(reset.metadata == snapshot.metadata)
    }

    @Test func validatesReferencedIDsAndTrimOrderBeforeApplyingChanges() throws {
        let snapshot = snapshot()

        #expect(throws: ArticleRevisionService.Error.self) {
            _ = try ArticleRevisionService().apply(
                snapshot: snapshot,
                recipe: ArticleEditRecipe(
                    excludedBlockIDs: ["missing"],
                    trimBeforeBlockID: nil,
                    trimAfterBlockID: nil,
                    metadataOverrides: .init()))
        }
        #expect(throws: ArticleRevisionService.Error.self) {
            _ = try ArticleRevisionService().apply(
                snapshot: snapshot,
                recipe: ArticleEditRecipe(
                    excludedBlockIDs: [],
                    trimBeforeBlockID: snapshot.blocks[2].id,
                    trimAfterBlockID: snapshot.blocks[0].id,
                    metadataOverrides: .init()))
        }
    }

    @Test func overlaysMetadataAndHashesReadableContentDeterministically() throws {
        let snapshot = snapshot()
        let service = ArticleRevisionService()
        let recipe = ArticleEditRecipe(
            excludedBlockIDs: [],
            trimBeforeBlockID: nil,
            trimAfterBlockID: nil,
            metadataOverrides: .init(title: "Edited title", author: "Editor"))

        let first = try service.apply(snapshot: snapshot, recipe: recipe)
        let second = try service.apply(snapshot: snapshot, recipe: recipe)

        #expect(first.metadata.title == "Edited title")
        #expect(first.metadata.author == "Editor")
        #expect(first.readableContentSHA256 == second.readableContentSHA256)
        #expect(first.readableContentSHA256.count == 64)
    }

    private func snapshot() -> ArticleSnapshot {
        let captureID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return ArticleSnapshot(
            captureID: captureID,
            metadata: ArticleMetadata(title: "Original title", author: nil, siteName: nil, language: nil, publishedTime: nil),
            blocks: [
                ArticleBlock(id: "article-\(captureID.uuidString)-b0", stableOrdinal: 0, kind: .heading, text: "Heading", sourceURL: nil, imageCandidateURL: nil, caption: nil, codeLanguage: nil),
                ArticleBlock(id: "article-\(captureID.uuidString)-b1", stableOrdinal: 1, kind: .paragraph, text: "First", sourceURL: nil, imageCandidateURL: nil, caption: nil, codeLanguage: nil),
                ArticleBlock(id: "article-\(captureID.uuidString)-b2", stableOrdinal: 2, kind: .paragraph, text: "Second", sourceURL: nil, imageCandidateURL: nil, caption: nil, codeLanguage: nil),
            ],
            warnings: [],
            contentState: .ready,
            snapshotSHA256: "fixture")
    }
}
