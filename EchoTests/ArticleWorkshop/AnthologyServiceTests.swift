import CoreGraphics
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyServiceTests {
    @Test func createsProjectInSelectionOrderAndKeepsStableSlotsThroughEdits() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(suffix: 1, title: "First")
        let captureB = try fixture.installCapture(suffix: 2, title: "Second")
        let captureC = try fixture.installCapture(suffix: 3, title: "Third")
        let service = fixture.service()

        var project = try service.createProject(
            title: "Reading List",
            captureIDs: [captureB.id, captureA.id])
        project = try service.updateEntry(
            anthologyID: project.anthology.id,
            entryID: project.entries[0].entry.id,
            chapterTitleOverride: nil,
            narrationVoiceID: "af_heart")

        #expect(project.entries.map(\.capture.id) == [captureB.id, captureA.id])
        #expect(project.entries.map(\.entry.sortOrder) == [0, 1])
        #expect(project.entries.map(\.entry.stableSlot) == [0, 1])

        project = try service.reorder(
            anthologyID: project.anthology.id,
            entryIDs: project.entries.reversed().map(\.entry.id))
        #expect(project.entries.map(\.capture.id) == [captureA.id, captureB.id])
        #expect(project.entries.map(\.entry.sortOrder) == [0, 1])
        #expect(project.entries.map(\.entry.stableSlot) == [1, 0])

        project = try service.removeEntry(
            anthologyID: project.anthology.id,
            entryID: project.entries[0].entry.id)
        project = try service.addCaptures(
            [captureC.id],
            to: project.anthology.id)

        #expect(project.entries.map(\.capture.id) == [captureB.id, captureC.id])
        #expect(project.entries.map(\.entry.sortOrder) == [0, 1])
        #expect(project.entries.map(\.entry.stableSlot) == [0, 2])
        #expect(project.anthology.nextStableSlot == 3)
        #expect(
            try service.loadProject(id: project.anthology.id)
                .entries[0].entry.narrationVoiceID == "af_heart")
    }

    @Test func manifestFreezesExactCurrentRevisionMaterialAndNormalizesMetadata() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(
            suffix: 10,
            title: "Original A",
            author: "Author A",
            language: "en",
            recipe: .init(excludedBlockIDs: []))
        let captureB = try fixture.installCapture(
            suffix: 11,
            title: "Original B",
            author: "Author B",
            language: "en",
            recipe: .init(excludedBlockIDs: []))
        let service = fixture.service()
        var project = try service.createProject(
            title: "  Exact Book  ",
            subtitle: "   ",
            creator: "  Editor  ",
            captureIDs: [captureA.id, captureB.id])
        project = try service.updateEntry(
            anthologyID: project.anthology.id,
            entryID: project.entries[0].entry.id,
            chapterTitleOverride: "  Opening Chapter  ",
            narrationVoiceID: "  af_heart  ")

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let reloaded = try service.loadProject(id: project.anthology.id)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.anthologyID.uuidString == project.anthology.id)
        #expect(manifest.revision == 1)
        #expect(manifest.epubIdentifier == "urn:uuid:\(project.anthology.id)")
        #expect(manifest.title == "Exact Book")
        #expect(manifest.subtitle == nil)
        #expect(manifest.creator == "Editor")
        #expect(manifest.language == "en")
        #expect(
            manifest.chapters.map(\.entryID.uuidString)
                == reloaded.entries.map(\.entry.id))
        #expect(manifest.chapters.map(\.captureID.uuidString) == [captureA.id, captureB.id])
        #expect(
            manifest.chapters.map(\.articleRevisionID.uuidString)
                == reloaded.entries.map { $0.revision!.id })
        #expect(manifest.chapters.map(\.stableSlot) == [0, 1])
        #expect(manifest.chapters.map(\.order) == [0, 1])
        #expect(manifest.chapters[0].title == "Opening Chapter")
        #expect(manifest.chapters[0].voiceID == "af_heart")
        #expect(manifest.chapters[0].blocks == reloaded.entries[0].cleanArticle!.blocks)
        #expect(
            manifest.chapters[0].readableContentSHA256
                == reloaded.entries[0].revision!.readableContentSHA256)
    }

    @Test func laterCleanupMarksChangesWithoutMutatingSuccessfulBuildEvidence() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(
            suffix: 20,
            title: "Mutable",
            recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let build = try fixture.successfulBuild(for: manifest)
        try fixture.anthologyDAO.saveBuild(build)
        let originalJSON = build.manifestJSON

        try fixture.publishCleanup(
            captureID: capture.id,
            recipe: .init(excludedBlockIDs: [
                try #require(try fixture.fileStore.loadSnapshot(for: capture).blocks.first?.id)
            ]))

        #expect(try service.changesAvailable(anthologyID: project.anthology.id))
        let stored = try #require(
            try fixture.anthologyDAO.latestSuccessfulBuild(anthologyID: project.anthology.id))
        #expect(stored.manifestJSON == originalJSON)
        #expect(
            try JSONDecoder.articleWorkshop.decode(
                AnthologyBuildManifest.self,
                from: Data(stored.manifestJSON.utf8)) == manifest)
    }

    @Test func manifestOmitsUnmappedRemoteImagesAndKeepsTheirCaptionsAsText() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(
            suffix: 19,
            title: "Captioned",
            recipe: .init(),
            contentXHTML: """
                <article><p>Before.</p><figure><img src="https://example.test/image.png"/><figcaption>Useful caption.</figcaption></figure><img src="https://example.test/bare.png"/></article>
                """)
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let blocks = manifest.chapters[0].blocks

        #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(blocks.compactMap(\.text) == ["Before.", "Useful caption."])
        #expect(blocks.allSatisfy { $0.imageCandidateURL == nil })
        #expect(
            manifest.chapters[0].readableContentSHA256
                == ArticleWorkshopDigest.readableContent(blocks: blocks))
    }

    @Test func manifestOmitsEmptyReadableBlocksButPreservesSeparators() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(
            suffix: 20,
            title: "Empty blocks",
            recipe: .init(),
            contentXHTML: """
                <article><p>Before.</p><pre><code>   </code></pre><hr/><p>After.</p></article>
                """)
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let blocks = manifest.chapters[0].blocks

        #expect(blocks.map(\.kind) == [.paragraph, .separator, .paragraph])
        #expect(blocks.compactMap(\.text) == ["Before.", "After."])
    }

    @Test func timestampOnlyProjectSaveDoesNotMarkContentChangesAvailable() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 21, title: "Stable", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: manifest))
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE anthology SET modified_at = ? WHERE id = ?",
                arguments: ["2026-08-01T00:00:00.000Z", project.anthology.id])
        }

        #expect(try service.changesAvailable(anthologyID: project.anthology.id) == false)
    }

    @Test func creatorFallbackIsManifestOnlyAndFailedBuildDoesNotConsumeRevision() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 30, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(
            title: "Book",
            subtitle: nil,
            creator: "   ",
            captureIDs: [capture.id])

        let first = try service.prepareManifest(anthologyID: project.anthology.id)
        #expect(first.creator == "Various Authors")
        #expect(try service.loadProject(id: project.anthology.id).anthology.creator == nil)
        try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: first))
        try fixture.anthologyDAO.saveBuild(
            AnthologyBuildRecord(
                id: UUID().uuidString,
                anthologyID: project.anthology.id,
                revision: 2,
                epubIdentifier: first.epubIdentifier,
                manifestJSON: "{}",
                manifestSHA256: fixture.sha256(Data("{}".utf8)),
                epubPath: nil,
                epubSHA256: nil,
                audiobookID: nil,
                status: "failed",
                errorCode: "fixture",
                createdAt: "2026-07-29T12:00:00Z"))

        let next = try service.prepareManifest(anthologyID: project.anthology.id)
        #expect(next.revision == 2)
    }

    @Test func projectAndEntryEditsPersistImmediatelyWithoutChangingManagedCounters() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(suffix: 40, title: "A", recipe: .init())
        let captureB = try fixture.installCapture(suffix: 41, title: "B", recipe: .init())
        let service = fixture.service()
        var project = try service.createProject(title: "Draft", captureIDs: [captureA.id])
        let counters = (
            project.anthology.nextStableSlot,
            project.anthology.latestBuildRevision
        )
        let coverPath = try fixture.installCover(anthologyID: project.anthology.id)

        project = try service.updateProject(
            anthologyID: project.anthology.id,
            title: "  Final  ",
            subtitle: "  Subtitle  ",
            creator: "  Curator  ",
            coverPath: coverPath)
        project = try service.updateEntry(
            anthologyID: project.anthology.id,
            entryID: project.entries[0].entry.id,
            chapterTitleOverride: "  Chapter One  ",
            narrationVoiceID: "  bf_emma  ")
        project = try service.reorder(
            anthologyID: project.anthology.id,
            entryIDs: project.entries.map(\.entry.id))
        project = try service.addCaptures([captureB.id], to: project.anthology.id)

        let reloaded = try service.loadProject(id: project.anthology.id)
        #expect(reloaded.anthology.title == "Final")
        #expect(reloaded.anthology.subtitle == "Subtitle")
        #expect(reloaded.anthology.creator == "Curator")
        #expect(reloaded.anthology.coverPath == coverPath)
        #expect(reloaded.entries[0].entry.chapterTitleOverride == "Chapter One")
        #expect(reloaded.entries[0].entry.narrationVoiceID == "bf_emma")
        #expect(reloaded.entries[0].entry.stableSlot == 0)
        #expect(counters == (1, 0))
        #expect(reloaded.anthology.nextStableSlot == 2)
        #expect(reloaded.anthology.latestBuildRevision == 0)
    }

    @Test func projectRejectsCoverFilenameWithoutMatchingManagedArtifact() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 104, title: "A", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Draft", captureIDs: [capture.id])

        #expect(throws: AnthologyService.Error.invalidProjectEdit) {
            _ = try service.updateProject(
                anthologyID: project.anthology.id,
                title: "Draft",
                subtitle: nil,
                creator: nil,
                coverPath: "cover.png")
        }
    }

    @Test func sameFormatCoverReplacementMarksChangesAndKeepsFrozenCoverAddressable() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 105, title: "A", recipe: .init())
        let service = fixture.service()
        var project = try service.createProject(title: "Draft", captureIDs: [capture.id])
        let firstCover = try fixture.installCover(
            anthologyID: project.anthology.id,
            width: 2,
            height: 2)
        project = try service.updateProject(
            anthologyID: project.anthology.id,
            title: project.anthology.title,
            subtitle: nil,
            creator: nil,
            coverPath: firstCover)
        let frozen = try service.prepareManifest(anthologyID: project.anthology.id)
        try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: frozen))

        let secondCover = try fixture.installCover(
            anthologyID: project.anthology.id,
            width: 3,
            height: 3)
        let updated = try service.updateProject(
            anthologyID: project.anthology.id,
            title: project.anthology.title,
            subtitle: nil,
            creator: nil,
            coverPath: secondCover)

        #expect(firstCover != secondCover)
        #expect(updated.changesAvailable)
        #expect(frozen.coverPath == firstCover)
        #expect(
            try AnthologyCoverStore(root: fixture.fileStore.root).validateManagedCover(
                named: firstCover,
                anthologyID: #require(UUID(uuidString: project.anthology.id))) == firstCover)
    }

    @Test func addingMultipleCapturesIsAtomicAndConsumesDenseStableSlotsOnce() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(suffix: 44, title: "A", recipe: .init())
        let captureB = try fixture.installCapture(suffix: 45, title: "B", recipe: .init())
        let captureC = try fixture.installCapture(suffix: 46, title: "C", recipe: .init())
        let service = fixture.service()
        var project = try service.createProject(title: "Draft", captureIDs: [captureA.id])

        #expect(throws: AnthologyService.Error.invalidProjectEdit) {
            _ = try service.addCaptures(
                [captureB.id, UUID().uuidString],
                to: project.anthology.id)
        }
        project = try service.loadProject(id: project.anthology.id)
        #expect(project.entries.map(\.capture.id) == [captureA.id])
        #expect(project.anthology.nextStableSlot == 1)

        project = try service.addCaptures(
            [captureB.id, captureC.id],
            to: project.anthology.id)
        #expect(
            project.entries.map(\.capture.id) == [
                captureA.id,
                captureB.id,
                captureC.id,
            ])
        #expect(project.entries.map(\.entry.sortOrder) == [0, 1, 2])
        #expect(project.entries.map(\.entry.stableSlot) == [0, 1, 2])
        #expect(project.anthology.nextStableSlot == 3)
    }

    @Test func emptyAnthologyAndMalformedStoredMaterialFailClosedWithSafeErrors() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 50, title: "One", recipe: .init())
        let service = fixture.service()
        let emptyID = fixture.nextUUID().uuidString
        try fixture.anthologyDAO.save(
            fixture.anthology(id: emptyID, title: "Empty"))
        #expect(throws: AnthologyService.Error.self) {
            _ = try service.prepareManifest(anthologyID: emptyID)
        }

        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        try fixture.database.writer.write { db in
            try db.execute(
                sql:
                    "UPDATE article_capture SET source_url = 'file:///private/article' WHERE id = ?",
                arguments: [capture.id])
        }
        #expect {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        } throws: { error in
            guard let serviceError = error as? AnthologyService.Error else { return false }
            return serviceError.errorDescription?.contains("/private/") == false
        }

        try fixture.database.writer.write { db in
            try db.execute(
                sql:
                    "UPDATE article_capture SET source_url = 'https://example.test/one' WHERE id = ?",
                arguments: [capture.id])
            try db.execute(
                sql: "UPDATE anthology_entry SET sort_order = 3 WHERE anthology_id = ?",
                arguments: [project.anthology.id])
        }
        #expect(throws: AnthologyService.Error.self) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func invalidRevisionHashCaptureAndJSONFailClosed() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 60, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        let revisionID = try #require(
            try fixture.captureDAO.capture(id: capture.id)?.currentRevisionID)
        let original = try #require(
            try fixture.captureDAO.currentRevision(captureID: capture.id))

        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE article_revision SET readable_content_sha256 = 'wrong' WHERE id = ?",
                arguments: [revisionID])
        }
        #expect(throws: AnthologyService.Error.self) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }

        let foreign = try fixture.installCapture(suffix: 61, title: "Foreign", recipe: .init())
        try fixture.database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE article_revision
                    SET capture_id = ?, readable_content_sha256 = ?
                    WHERE id = ?
                    """,
                arguments: [foreign.id, original.readableContentSHA256, revisionID])
        }
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }

        try fixture.database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE article_revision
                    SET capture_id = ?, recipe_json = '{not-json'
                    WHERE id = ?
                    """,
                arguments: [capture.id, revisionID])
        }
        #expect(throws: AnthologyService.Error.self) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func validButDisagreeingRevisionMetadataFailsClosed() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 62, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        let revisionID = try #require(
            try fixture.captureDAO.capture(id: capture.id)?.currentRevisionID)
        let disagreeingOverrides = ArticleMetadataOverrides(title: "Different")
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE article_revision SET metadata_overrides_json = ? WHERE id = ?",
                arguments: [
                    try canonicalJSONString(disagreeingOverrides),
                    revisionID,
                ])
        }

        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func failedCaptureIsNotOfferedByAnthologyPicker() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let selected = try fixture.installCapture(suffix: 63, title: "Selected", recipe: .init())
        let failed = try fixture.installCapture(suffix: 64, title: "Failed", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [selected.id])
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE article_capture SET content_state = ? WHERE id = ?",
                arguments: [ArticleContentState.captureFailed.rawValue, failed.id])
        }

        #expect(try service.availableCaptures(anthologyID: project.anthology.id).isEmpty)
    }

    @Test func staleDraftCannotDeleteCaptureAddedAfterItsBaseSnapshot() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let first = try fixture.installCapture(suffix: 65, title: "First", recipe: .init())
        let concurrent = try fixture.installCapture(
            suffix: 66, title: "Concurrent", recipe: .init())
        let service = fixture.service()
        let created = try service.createProject(title: "Book", captureIDs: [first.id])
        var stale = try service.loadProject(id: created.anthology.id)
        _ = try service.addCaptures([concurrent.id], to: created.anthology.id)
        stale.anthology.title = "Stale Metadata"

        #expect(throws: AnthologyService.Error.revisionConflict) {
            _ = try service.saveDraft(stale)
        }

        let reloaded = try service.loadProject(id: created.anthology.id)
        #expect(reloaded.entries.map(\.capture.id) == [first.id, concurrent.id])
        #expect(reloaded.anthology.title == "Book")
    }

    @Test func failedDurableSnapshotIsIneligibleEvenWhenRecordSaysReady() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let selected = try fixture.installCapture(suffix: 67, title: "Selected", recipe: .init())
        let failed = try fixture.installCapture(
            suffix: 68,
            title: "Failed Snapshot",
            contentXHTML: "<article></article>")
        let reviewRecord = try fixture.installCapture(
            suffix: 69,
            title: "Review Record",
            recordState: .reviewSuggested)
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [selected.id])

        #expect(
            try service.availableCaptures(anthologyID: project.anthology.id).map(\.id)
                == [reviewRecord.id])
        #expect(throws: AnthologyService.Error.invalidSelection) {
            _ = try service.createProject(title: "Invalid", captureIDs: [failed.id])
        }
        #expect(throws: AnthologyService.Error.invalidProjectEdit) {
            _ = try service.addCaptures([failed.id], to: project.anthology.id)
        }
        #expect(try service.loadProject(id: project.anthology.id).entries.count == 1)

        _ = try fixture.anthologyDAO.addCapture(failed.id, to: project.anthology.id)
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.loadProject(id: project.anthology.id)
        }
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func missingCurrentRevisionGetsAtomicEmptyBaseline() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 70, title: "Raw")
        let source = try fixture.fileStore.loadSnapshot(for: capture)
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let current = try #require(try fixture.captureDAO.currentRevision(captureID: capture.id))
        let recipe = try JSONDecoder.articleWorkshop.decode(
            ArticleEditRecipe.self,
            from: Data(current.recipeJSON.utf8))

        #expect(recipe == ArticleEditRecipe())
        #expect(current.parentRevisionID == nil)
        #expect(manifest.chapters[0].articleRevisionID.uuidString == current.id)
        #expect(manifest.chapters[0].blocks == source.blocks)
        #expect(
            manifest.chapters[0].readableContentSHA256
                == ArticleWorkshopDigest.readableContent(blocks: source.blocks))
    }

    @Test func concurrentRealCleanupWinsBaselinePublication() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 80, title: "Raw")
        let source = try fixture.fileStore.loadSnapshot(for: capture)
        let excluded = try #require(source.blocks.first?.id)
        let winnerRecipe = ArticleEditRecipe(excludedBlockIDs: [excluded])
        let winnerClean = try ArticleRevisionService().apply(
            snapshot: source,
            recipe: winnerRecipe)
        let winnerID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let fired = LockedFlag()
        let hookedStore = ArticleWorkshopFileStore(
            root: fixture.fileStore.root,
            validationHook: { _, _ in
                guard fired.takeFirst() else { return }
                let revision = try anthologyFixtureRevision(
                    id: winnerID,
                    captureID: capture.id,
                    parentRevisionID: nil,
                    recipe: winnerRecipe,
                    clean: winnerClean)
                #expect(
                    try fixture.captureDAO.publishRevision(
                        revision,
                        expectedCurrentRevisionID: nil) == .published(revision))
            })
        let service = fixture.service(fileStore: hookedStore)
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)

        #expect(manifest.chapters[0].articleRevisionID.uuidString == winnerID)
        #expect(manifest.chapters[0].blocks == winnerClean.blocks)
        #expect(try fixture.captureDAO.revisions(captureID: capture.id).count == 1)
    }

    @Test func manifestUsesOneDatabaseSnapshotAcrossConcurrentCleanup() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(suffix: 90, title: "A", recipe: .init())
        let captureB = try fixture.installCapture(suffix: 91, title: "B", recipe: .init())
        let oldA = try #require(try fixture.captureDAO.currentRevision(captureID: captureA.id))
        let oldB = try #require(try fixture.captureDAO.currentRevision(captureID: captureB.id))
        let sourceA = try fixture.fileStore.loadSnapshot(for: captureA)
        let sourceB = try fixture.fileStore.loadSnapshot(for: captureB)
        let fired = LockedFlag()
        let captureDAO = fixture.captureDAO
        let fileStore = fixture.fileStore
        let ids = fixture.ids
        let hookedStore = ArticleWorkshopFileStore(
            root: fixture.fileStore.root,
            validationHook: { _, _ in
                guard fired.takeFirst() else { return }
                try publishAnthologyFixtureCleanup(
                    captureDAO: captureDAO,
                    fileStore: fileStore,
                    ids: ids,
                    captureID: captureA.id,
                    recipe: .init(excludedBlockIDs: [sourceA.blocks[0].id]))
                try publishAnthologyFixtureCleanup(
                    captureDAO: captureDAO,
                    fileStore: fileStore,
                    ids: ids,
                    captureID: captureB.id,
                    recipe: .init(excludedBlockIDs: [sourceB.blocks[0].id]))
            })
        let project = try fixture.service().createProject(
            title: "Book",
            captureIDs: [captureA.id, captureB.id])
        let service = fixture.service(fileStore: hookedStore)

        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        let newA = try #require(try fixture.captureDAO.currentRevision(captureID: captureA.id))
        let newB = try #require(try fixture.captureDAO.currentRevision(captureID: captureB.id))
        let revisionPair = manifest.chapters.map(\.articleRevisionID.uuidString)

        #expect(
            revisionPair == [oldA.id, oldB.id]
                || revisionPair == [newA.id, newB.id])
        #expect(revisionPair != [oldA.id, newB.id])
        #expect(revisionPair != [newA.id, oldB.id])
    }

    @Test func mixedOrBlankArticleLanguagesProduceUnd() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let captureA = try fixture.installCapture(
            suffix: 100,
            title: "A",
            language: "en",
            recipe: .init())
        let captureB = try fixture.installCapture(
            suffix: 101,
            title: "B",
            language: "fr",
            recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(
            title: "Book",
            captureIDs: [captureA.id, captureB.id])

        #expect(try service.prepareManifest(anthologyID: project.anthology.id).language == "und")

        let captureC = try fixture.installCapture(
            suffix: 102,
            title: "C",
            language: nil,
            recipe: .init())
        let blankProject = try service.createProject(
            title: "Book with blank language",
            captureIDs: [captureA.id, captureC.id])
        #expect(
            try service.prepareManifest(anthologyID: blankProject.anthology.id).language == "und")
    }

    @Test func credentialBearingArticleSourceURLIsRejectedBeforeManifestFreeze() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 103, title: "Private", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE article_capture SET source_url = ? WHERE id = ?",
                arguments: ["https://reader:secret@example.test/private", capture.id])
        }

        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func newlyAddedUnmaterializedArticleMarksChangesAvailableAfterBuild() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let built = try fixture.installCapture(suffix: 105, title: "Built", recipe: .init())
        let added = try fixture.installCapture(suffix: 106, title: "Added")
        let service = fixture.service()
        var project = try service.createProject(title: "Book", captureIDs: [built.id])
        let manifest = try service.prepareManifest(anthologyID: project.anthology.id)
        try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: manifest))

        project = try service.addCaptures([added.id], to: project.anthology.id)

        #expect(project.changesAvailable)
        #expect(try service.changesAvailable(anthologyID: project.anthology.id))
    }

    @Test func hashValidButSemanticallyInvalidPriorManifestFailsClosed() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 107, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        let valid = try service.prepareManifest(anthologyID: project.anthology.id)
        let invalid = AnthologyBuildManifest(
            schemaVersion: valid.schemaVersion,
            anthologyID: valid.anthologyID,
            revision: valid.revision,
            epubIdentifier: "https://example.test/not-stable",
            title: valid.title,
            subtitle: valid.subtitle,
            creator: valid.creator,
            language: valid.language,
            coverPath: valid.coverPath,
            modifiedAt: valid.modifiedAt,
            chapters: valid.chapters.map {
                AnthologyChapterManifest(
                    entryID: $0.entryID,
                    captureID: $0.captureID,
                    articleRevisionID: $0.articleRevisionID,
                    stableSlot: $0.stableSlot,
                    order: $0.order + 1,
                    title: $0.title,
                    author: $0.author,
                    siteName: $0.siteName,
                    sourceURL: URL(string: "file:///private/article")!,
                    capturedAt: $0.capturedAt,
                    voiceID: $0.voiceID,
                    blocks: $0.blocks,
                    readableContentSHA256: $0.readableContentSHA256)
            })
        try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: invalid))

        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.loadProject(id: project.anthology.id)
        }
    }

    @Test func priorManifestRejectsOrderURLAndContentDigestIndependently() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let service = fixture.service()

        for defect in 0..<3 {
            let capture = try fixture.installCapture(
                suffix: 120 + defect,
                title: "Article \(defect)",
                recipe: .init())
            let project = try service.createProject(
                title: "Book \(defect)",
                captureIDs: [capture.id])
            let valid = try service.prepareManifest(anthologyID: project.anthology.id)
            let chapter = try #require(valid.chapters.first)
            let invalidChapter = AnthologyChapterManifest(
                entryID: chapter.entryID,
                captureID: chapter.captureID,
                articleRevisionID: chapter.articleRevisionID,
                stableSlot: chapter.stableSlot,
                order: defect == 0 ? 1 : chapter.order,
                title: chapter.title,
                author: chapter.author,
                siteName: chapter.siteName,
                sourceURL: defect == 1
                    ? URL(string: "https://reader:secret@example.test/article")!
                    : chapter.sourceURL,
                capturedAt: chapter.capturedAt,
                voiceID: chapter.voiceID,
                blocks: chapter.blocks,
                readableContentSHA256: defect == 2
                    ? String(repeating: "0", count: 64)
                    : chapter.readableContentSHA256)
            let invalid = AnthologyBuildManifest(
                schemaVersion: valid.schemaVersion,
                anthologyID: valid.anthologyID,
                revision: valid.revision,
                epubIdentifier: valid.epubIdentifier,
                title: valid.title,
                subtitle: valid.subtitle,
                creator: valid.creator,
                language: valid.language,
                coverPath: valid.coverPath,
                modifiedAt: valid.modifiedAt,
                chapters: [invalidChapter])
            try fixture.anthologyDAO.saveBuild(try fixture.successfulBuild(for: invalid))

            #expect(throws: AnthologyService.Error.invalidStoredData) {
                _ = try service.loadProject(id: project.anthology.id)
            }
        }
    }

    @Test func invalidStoredEntryVoiceIdentifierAndDateFailClosedIndependently() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 108, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE anthology_entry SET narration_voice_id = ? WHERE anthology_id = ?",
                arguments: ["not-a-real-voice", project.anthology.id])
        }
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }

        try fixture.database.writer.write { db in
            try db.execute(
                sql:
                    "UPDATE anthology_entry SET narration_voice_id = NULL, id = ? WHERE anthology_id = ?",
                arguments: ["not-a-uuid", project.anthology.id])
        }
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }

        try fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE anthology_entry SET id = ? WHERE anthology_id = ?",
                arguments: [fixture.nextUUID().uuidString, project.anthology.id])
            try db.execute(
                sql: "UPDATE article_capture SET captured_at = ? WHERE id = ?",
                arguments: ["not-a-date", capture.id])
        }

        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }

    @Test func missingCapturePackageCannotPartiallyCreateOrAddMembership() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let missingOnCreate = try fixture.installCapture(
            suffix: 109,
            title: "Missing Create",
            recipe: .init())
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: missingOnCreate.packagePath))
        let service = fixture.service()

        #expect(throws: AnthologyService.Error.invalidSelection) {
            _ = try service.createProject(
                title: "Must Not Exist",
                captureIDs: [missingOnCreate.id])
        }
        #expect(try service.projects().isEmpty)

        let existing = try fixture.installCapture(suffix: 110, title: "Existing", recipe: .init())
        let missingOnAdd = try fixture.installCapture(
            suffix: 111,
            title: "Missing Add",
            recipe: .init())
        let project = try service.createProject(title: "Existing", captureIDs: [existing.id])
        let before = try service.loadProject(id: project.anthology.id)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: missingOnAdd.packagePath))

        #expect(throws: AnthologyService.Error.invalidProjectEdit) {
            _ = try service.addCaptures([missingOnAdd.id], to: project.anthology.id)
        }
        let after = try service.loadProject(id: project.anthology.id)
        #expect(after.entries.map(\.capture.id) == before.entries.map(\.capture.id))
        #expect(after.anthology.nextStableSlot == before.anthology.nextStableSlot)
    }

    @Test func missingReferencedCaptureAndFailedContentStateMapToSafeStoredDataError() throws {
        let fixture = try AnthologyServiceFixture()
        defer { fixture.removeFiles() }
        let capture = try fixture.installCapture(suffix: 130, title: "One", recipe: .init())
        let service = fixture.service()
        let project = try service.createProject(title: "Book", captureIDs: [capture.id])

        try fixture.database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "UPDATE anthology_entry SET capture_id = ? WHERE anthology_id = ?",
                arguments: ["missing-sensitive-identifier", project.anthology.id])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        #expect {
            _ = try service.loadProject(id: project.anthology.id)
        } throws: { error in
            error as? AnthologyService.Error == .invalidStoredData
                && error.localizedDescription.contains("missing-sensitive-identifier") == false
        }

        try fixture.database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "UPDATE anthology_entry SET capture_id = ? WHERE anthology_id = ?",
                arguments: [capture.id, project.anthology.id])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(
                sql: "UPDATE article_capture SET content_state = ? WHERE id = ?",
                arguments: [ArticleContentState.captureFailed.rawValue, capture.id])
        }
        #expect(throws: AnthologyService.Error.invalidStoredData) {
            _ = try service.prepareManifest(anthologyID: project.anthology.id)
        }
    }
}

@MainActor
private final class AnthologyServiceFixture: @unchecked Sendable {
    let root: URL
    let database: DatabaseService
    let captureDAO: ArticleCaptureDAO
    let anthologyDAO: AnthologyDAO
    let fileStore: ArticleWorkshopFileStore
    nonisolated let ids = UUIDSequence()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "AnthologyServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseService(inMemory: ())
        captureDAO = ArticleCaptureDAO(db: database.writer)
        anthologyDAO = AnthologyDAO(db: database.writer)
        fileStore = ArticleWorkshopFileStore(
            root: root.appending(path: "Workshop", directoryHint: .isDirectory))
    }

    func nextUUID() -> UUID {
        ids.next()
    }

    func service(fileStore: ArticleWorkshopFileStore? = nil) -> AnthologyService {
        let ids = ids
        return AnthologyService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore ?? self.fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: { ids.next() })
    }

    func installCapture(
        suffix: Int,
        title: String,
        author: String? = nil,
        language: String? = "en",
        recipe: ArticleEditRecipe? = nil,
        contentXHTML: String? = nil,
        recordState: ArticleContentState = .ready
    ) throws -> ArticleCaptureRecord {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: id,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000 + Double(suffix)),
            method: .urlFetch,
            sourceApplication: nil,
            payload: ReadabilityCapturePayload(
                sourceURL: "https://example.test/articles/\(suffix)",
                canonicalURL: "https://example.test/articles/\(suffix)",
                title: title,
                byline: author,
                siteName: "Example",
                language: language,
                publishedTime: nil,
                excerpt: nil,
                contentXHTML: contentXHTML
                    ?? "<article><h1>\(title)</h1><p>Paragraph \(suffix)</p></article>",
                textContent: "\(title) Paragraph \(suffix)",
                imageURLs: []))
        let staging = root.appending(path: "Staging-\(suffix)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let package = try ArticleCaptureStagingWriter(root: staging).stage(envelope)
        let imported = try fileStore.importEnvelope(at: package)
        var record = ArticleCaptureRecord(
            id: id.uuidString,
            sourceURL: envelope.payload.sourceURL,
            canonicalURL: envelope.payload.canonicalURL,
            title: title,
            author: author,
            siteName: "Example",
            language: language,
            publishedAt: nil,
            capturedAt: "2026-07-29T10:00:00Z",
            captureMethod: .urlFetch,
            packagePath: imported.snapshotURL.deletingLastPathComponent().path,
            contentSHA256: imported.sha256,
            extractorVersion: "1",
            contentState: recordState.rawValue,
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-29T10:00:00Z",
            modifiedAt: "2026-07-29T10:00:00Z")
        try captureDAO.saveCapture(record)
        if let recipe {
            let source = try fileStore.loadSnapshot(for: record)
            let clean = try ArticleRevisionService().apply(snapshot: source, recipe: recipe)
            let saved = try revision(
                id: ids.next().uuidString,
                captureID: record.id,
                parentRevisionID: nil,
                recipe: recipe,
                clean: clean)
            try captureDAO.saveRevision(saved, makeCurrent: true)
            record.currentRevisionID = saved.id
        }
        return record
    }

    func publishCleanup(captureID: String, recipe: ArticleEditRecipe) throws {
        let capture = try #require(try captureDAO.capture(id: captureID))
        let source = try fileStore.loadSnapshot(for: capture)
        let clean = try ArticleRevisionService().apply(snapshot: source, recipe: recipe)
        let parent = capture.currentRevisionID
        let next = try revision(
            id: ids.next().uuidString,
            captureID: captureID,
            parentRevisionID: parent,
            recipe: recipe,
            clean: clean)
        #expect(
            try captureDAO.publishRevision(next, expectedCurrentRevisionID: parent)
                == .published(next))
    }

    func installCover(
        anthologyID: String,
        width: Int = 2,
        height: Int = 2
    ) throws -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = root.appending(path: "cover-source.png")
        try (data as Data).write(to: source)
        return try AnthologyCoverStore(root: fileStore.root).importCover(
            from: source,
            anthologyID: #require(UUID(uuidString: anthologyID)))
    }

    func revision(
        id: String,
        captureID: String,
        parentRevisionID: String?,
        recipe: ArticleEditRecipe,
        clean: CleanArticle
    ) throws -> ArticleRevisionRecord {
        try anthologyFixtureRevision(
            id: id,
            captureID: captureID,
            parentRevisionID: parentRevisionID,
            recipe: recipe,
            clean: clean)
    }

    func anthology(id: String, title: String) -> AnthologyRecord {
        AnthologyRecord(
            id: id,
            title: title,
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: "2026-07-29T10:00:00Z",
            modifiedAt: "2026-07-29T10:00:00Z")
    }

    func successfulBuild(for manifest: AnthologyBuildManifest) throws -> AnthologyBuildRecord {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        return AnthologyBuildRecord(
            id: ids.next().uuidString,
            anthologyID: manifest.anthologyID.uuidString,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: sha256(data),
            epubPath: "/managed/edition.epub",
            epubSHA256: "fixture",
            audiobookID: nil,
            status: "succeeded",
            errorCode: nil,
            createdAt: "2026-07-29T12:00:00Z")
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

private nonisolated final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 10_000

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return UUID(uuidString: String(format: "11111111-1111-1111-1111-%012d", value))!
    }
}

private nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func takeFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fired == false else { return false }
        fired = true
        return true
    }
}

private nonisolated func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder.articleWorkshop
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private nonisolated func anthologyFixtureRevision(
    id: String,
    captureID: String,
    parentRevisionID: String?,
    recipe: ArticleEditRecipe,
    clean: CleanArticle
) throws -> ArticleRevisionRecord {
    ArticleRevisionRecord(
        id: id,
        captureID: captureID,
        parentRevisionID: parentRevisionID,
        metadataOverridesJSON: try canonicalJSONString(recipe.metadataOverrides),
        recipeJSON: try canonicalJSONString(recipe),
        readableContentSHA256: clean.readableContentSHA256,
        createdAt: "2026-07-29T11:00:00Z",
        deviceName: "Test")
}

private nonisolated func publishAnthologyFixtureCleanup(
    captureDAO: ArticleCaptureDAO,
    fileStore: ArticleWorkshopFileStore,
    ids: UUIDSequence,
    captureID: String,
    recipe: ArticleEditRecipe
) throws {
    guard let capture = try captureDAO.capture(id: captureID) else {
        throw AnthologyFixtureError.expected
    }
    let source = try fileStore.loadSnapshot(for: capture)
    let clean = try ArticleRevisionService().apply(snapshot: source, recipe: recipe)
    let revision = try anthologyFixtureRevision(
        id: ids.next().uuidString,
        captureID: captureID,
        parentRevisionID: capture.currentRevisionID,
        recipe: recipe,
        clean: clean)
    guard
        try captureDAO.publishRevision(
            revision,
            expectedCurrentRevisionID: capture.currentRevisionID)
            == .published(revision)
    else {
        throw AnthologyFixtureError.expected
    }
}

private nonisolated enum AnthologyFixtureError: Swift.Error {
    case expected
}
