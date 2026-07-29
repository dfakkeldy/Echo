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

    @Test func readableHashChangesForSpokenCaptionAndOrderChanges() throws {
        let service = ArticleRevisionService()
        let original = service.reset(snapshot: snapshot())
        let changedText = service.reset(snapshot: snapshot(blocks: [
            block(id: 0, kind: .heading, text: "Changed heading"), block(id: 1, text: "First"), block(id: 2, text: "Second"),
        ]))
        let changedCaption = service.reset(snapshot: snapshot(blocks: [
            block(id: 0, kind: .heading, text: "Heading", caption: "Spoken caption"), block(id: 1, text: "First"), block(id: 2, text: "Second"),
        ]))
        let reordered = service.reset(snapshot: snapshot(blocks: [
            block(id: 0, kind: .heading, text: "Heading"), block(id: 2, text: "Second"), block(id: 1, text: "First"),
        ]))

        #expect(changedText.readableContentSHA256 != original.readableContentSHA256)
        #expect(changedCaption.readableContentSHA256 != original.readableContentSHA256)
        #expect(reordered.readableContentSHA256 != original.readableContentSHA256)
    }

    @Test func readableHashIgnoresMetadataBlockIDsAndURLs() throws {
        let service = ArticleRevisionService()
        let original = service.reset(snapshot: snapshot())
        let changedMetadata = try service.apply(
            snapshot: snapshot(),
            recipe: ArticleEditRecipe(metadataOverrides: .init(title: "Different metadata")))
        let changedIDs = service.reset(snapshot: snapshot(blocks: [
            block(id: 100, kind: .heading, text: "Heading"), block(id: 101, text: "First"), block(id: 102, text: "Second"),
        ]))
        let changedURLs = service.reset(snapshot: snapshot(blocks: [
            block(id: 0, kind: .heading, text: "Heading", sourceURL: URL(string: "https://example.test/a")),
            block(id: 1, text: "First", imageCandidateURL: URL(string: "https://example.test/b")),
            block(id: 2, text: "Second"),
        ]))

        #expect(changedMetadata.readableContentSHA256 == original.readableContentSHA256)
        #expect(changedIDs.readableContentSHA256 == original.readableContentSHA256)
        #expect(changedURLs.readableContentSHA256 == original.readableContentSHA256)
    }

    private func snapshot(blocks: [ArticleBlock]? = nil) -> ArticleSnapshot {
        let captureID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return ArticleSnapshot(
            captureID: captureID,
            metadata: ArticleMetadata(title: "Original title", author: nil, siteName: nil, language: nil, publishedTime: nil),
            blocks: blocks ?? [
                block(id: 0, kind: .heading, text: "Heading"), block(id: 1, text: "First"), block(id: 2, text: "Second"),
            ],
            warnings: [],
            contentState: .ready,
            snapshotSHA256: "fixture")
    }

    private func block(
        id: Int,
        kind: ArticleBlockKind = .paragraph,
        text: String,
        sourceURL: URL? = nil,
        imageCandidateURL: URL? = nil,
        caption: String? = nil
    ) -> ArticleBlock {
        ArticleBlock(
            id: "article-11111111-1111-1111-1111-111111111111-b\(id)",
            stableOrdinal: id,
            kind: kind,
            text: text,
            sourceURL: sourceURL,
            imageCandidateURL: imageCandidateURL,
            caption: caption,
            codeLanguage: nil)
    }
}
