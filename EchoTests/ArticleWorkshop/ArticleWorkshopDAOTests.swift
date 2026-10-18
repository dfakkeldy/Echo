// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@MainActor
struct ArticleWorkshopDAOTests {
    @Test func captureAndCurrentRevisionRoundTrip() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = ArticleCaptureDAO(db: service.writer)
        let savedCapture = capture("capture-1", digest: "digest-1")
        try dao.saveCapture(savedCapture)
        #expect(try dao.capture(id: savedCapture.id) == savedCapture)

        let revision = ArticleRevisionRecord(
            id: "revision-1",
            captureID: savedCapture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: "{}",
            recipeJSON: "{\"version\":1}",
            readableContentSHA256: "readable-1",
            createdAt: "2026-07-28T12:02:00Z",
            deviceName: "Test Mac"
        )
        try dao.saveRevision(revision, makeCurrent: true)

        #expect(try dao.revisions(captureID: savedCapture.id) == [revision])
        #expect(try dao.currentRevision(captureID: savedCapture.id) == revision)
        #expect(try dao.capture(id: savedCapture.id)?.currentRevisionID == revision.id)
        var captureWithCurrentRevision = savedCapture
        captureWithCurrentRevision.currentRevisionID = revision.id
        #expect(
            try dao.possibleDuplicates(
                canonicalURL: savedCapture.canonicalURL,
                digest: savedCapture.contentSHA256
            ) == [captureWithCurrentRevision])
    }

    @Test func conditionalRevisionPublicationIsAtomicAndRejectsStaleSibling() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = ArticleCaptureDAO(db: service.writer)
        let savedCapture = capture("capture-conditional", digest: "digest")
        try dao.saveCapture(savedCapture)
        let first = revision(
            id: "revision-first",
            captureID: savedCapture.id,
            parentRevisionID: nil)

        #expect(
            try dao.publishRevision(first, expectedCurrentRevisionID: nil)
                == .published(first))
        #expect(try dao.capture(id: savedCapture.id)?.currentRevisionID == first.id)

        let stale = revision(
            id: "revision-stale",
            captureID: savedCapture.id,
            parentRevisionID: nil)
        #expect(
            try dao.publishRevision(stale, expectedCurrentRevisionID: nil)
                == .conflict(actualCurrentRevisionID: first.id))
        #expect(try dao.revisions(captureID: savedCapture.id) == [first])
        #expect(try dao.capture(id: savedCapture.id)?.currentRevisionID == first.id)

        let child = revision(
            id: "revision-child",
            captureID: savedCapture.id,
            parentRevisionID: first.id)
        #expect(
            try dao.publishRevision(child, expectedCurrentRevisionID: first.id)
                == .published(child))
        let revisions = try dao.revisions(captureID: savedCapture.id)
        #expect(revisions.count == 2)
        #expect(revisions.contains(first))
        #expect(revisions.contains(child))
        #expect(!revisions.contains(stale))
        #expect(try dao.capture(id: savedCapture.id)?.currentRevisionID == child.id)
    }

    @Test func conditionalRevisionPublicationRequiresExactCaptureAndParentOwnership() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = ArticleCaptureDAO(db: service.writer)
        try dao.saveCapture(capture("capture-owner", digest: "owner"))
        try dao.saveCapture(capture("capture-other", digest: "other"))
        let foreignParent = revision(
            id: "revision-foreign",
            captureID: "capture-other",
            parentRevisionID: nil)
        try dao.saveRevision(foreignParent, makeCurrent: false)

        let wrongParent = revision(
            id: "revision-wrong-parent",
            captureID: "capture-owner",
            parentRevisionID: foreignParent.id)
        #expect(throws: ArticleRevisionPublicationError.self) {
            _ = try dao.publishRevision(
                wrongParent,
                expectedCurrentRevisionID: foreignParent.id)
        }
        #expect(try dao.revisions(captureID: "capture-owner").isEmpty)

        let missingCapture = revision(
            id: "revision-missing-capture",
            captureID: "capture-missing",
            parentRevisionID: nil)
        #expect(throws: ArticleRevisionPublicationError.self) {
            _ = try dao.publishRevision(
                missingCapture,
                expectedCurrentRevisionID: nil)
        }
    }

    @Test func captureQueryExcludesOnlyPersistedCaptureFailureState() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = ArticleCaptureDAO(db: service.writer)
        var ready = capture("capture-ready", digest: "ready")
        ready.contentState = ArticleContentState.ready.rawValue
        var review = capture("capture-review", digest: "review")
        review.contentState = ArticleContentState.reviewSuggested.rawValue
        var failed = capture("capture-failed", digest: "failed")
        failed.contentState = ArticleContentState.captureFailed.rawValue
        try dao.saveCapture(ready)
        try dao.saveCapture(review)
        try dao.saveCapture(failed)

        #expect(
            Set(try dao.captures(includeFailures: false).map(\.id))
                == [ready.id, review.id])
    }

    @Test func anthologyAllocatesStableSlotsWithoutReusingRemovedSlots() throws {
        let service = try DatabaseService(inMemory: ())
        let captureDAO = ArticleCaptureDAO(db: service.writer)
        let anthologyDAO = AnthologyDAO(db: service.writer)
        try captureDAO.saveCapture(capture("capture-a", digest: "a"))
        try captureDAO.saveCapture(capture("capture-b", digest: "b"))
        try captureDAO.saveCapture(capture("capture-c", digest: "c"))
        try anthologyDAO.save(anthology("anthology-1"))

        let entryA = try anthologyDAO.addCapture("capture-a", to: "anthology-1")
        let entryB = try anthologyDAO.addCapture("capture-b", to: "anthology-1")
        #expect([entryA.stableSlot, entryB.stableSlot] == [0, 1])

        try anthologyDAO.removeEntry(id: entryA.id)
        let entryC = try anthologyDAO.addCapture("capture-c", to: "anthology-1")
        #expect([entryB.stableSlot, entryC.stableSlot] == [1, 2])

        try anthologyDAO.replaceOrder(anthologyID: "anthology-1", entryIDs: [entryC.id, entryB.id])
        let entries = try anthologyDAO.entries(anthologyID: "anthology-1")
        #expect(entries.map(\.id) == [entryC.id, entryB.id])
        #expect(entries.map(\.stableSlot) == [2, 1])
        #expect(try anthologyDAO.anthology(id: "anthology-1")?.nextStableSlot == 3)
    }

    @Test func anthologyEntryOrderChangesWithoutChangingStableSlots() throws {
        let service = try DatabaseService(inMemory: ())
        let captureDAO = ArticleCaptureDAO(db: service.writer)
        let anthologyDAO = AnthologyDAO(db: service.writer)
        try captureDAO.saveCapture(capture("capture-a", digest: "a"))
        try captureDAO.saveCapture(capture("capture-b", digest: "b"))
        try anthologyDAO.save(anthology("anthology-1"))

        let entryA = try anthologyDAO.addCapture("capture-a", to: "anthology-1")
        let entryB = try anthologyDAO.addCapture("capture-b", to: "anthology-1")
        try anthologyDAO.replaceOrder(anthologyID: "anthology-1", entryIDs: [entryB.id, entryA.id])

        let entries = try anthologyDAO.entries(anthologyID: "anthology-1")
        #expect(entries.map(\.id) == [entryB.id, entryA.id])
        #expect(entries.map(\.sortOrder) == [0, 1])
        #expect(entries.map(\.stableSlot) == [1, 0])
    }

    @Test func failedBuildDoesNotReplaceLatestSuccessfulBuild() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = AnthologyDAO(db: service.writer)
        try dao.save(anthology("anthology-1"))

        let successfulBuild = build(id: "build-1", revision: 1, status: "succeeded")
        let failedBuild = build(id: "build-2", revision: 2, status: "failed")
        try dao.saveBuild(successfulBuild)
        try dao.saveBuild(failedBuild)

        #expect(try dao.latestSuccessfulBuild(anthologyID: "anthology-1") == successfulBuild)
    }

    @Test func failedAttemptDoesNotBlockSuccessfulReceiptAtSameEditionRevision() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = AnthologyDAO(db: service.writer)
        try dao.save(anthology("anthology-1"))
        let failed = build(id: "build-failed", revision: 1, status: "failed")
        let succeeded = build(id: "build-succeeded", revision: 1, status: "succeeded")

        try dao.saveBuild(failed)
        try dao.saveBuild(succeeded)

        #expect(try dao.latestSuccessfulBuild(anthologyID: "anthology-1") == succeeded)
    }

    @Test func buildReceiptIsInsertOnlyImmutableEvidence() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = AnthologyDAO(db: service.writer)
        try dao.save(anthology("anthology-1"))
        let original = build(id: "build-immutable", revision: 1, status: "succeeded")
        try dao.saveBuild(original)
        var replacement = original
        replacement.manifestJSON = #"{"title":"Replacement"}"#
        replacement.manifestSHA256 = "replacement"

        #expect(throws: (any Error).self) {
            try dao.saveBuild(replacement)
        }
        #expect(try dao.latestSuccessfulBuild(anthologyID: "anthology-1") == original)
    }

    @Test func savingStaleAnthologyDoesNotRegressManagedCounters() throws {
        let service = try DatabaseService(inMemory: ())
        let captureDAO = ArticleCaptureDAO(db: service.writer)
        let anthologyDAO = AnthologyDAO(db: service.writer)
        let staleAnthology = anthology("anthology-1")
        try anthologyDAO.save(staleAnthology)
        try captureDAO.saveCapture(capture("capture-a", digest: "a"))
        try captureDAO.saveCapture(capture("capture-b", digest: "b"))

        let entryA = try anthologyDAO.addCapture("capture-a", to: staleAnthology.id)
        try anthologyDAO.removeEntry(id: entryA.id)
        try anthologyDAO.saveBuild(build(id: "build-5", revision: 5, status: "succeeded"))

        try anthologyDAO.save(staleAnthology)

        let entryB = try anthologyDAO.addCapture("capture-b", to: staleAnthology.id)
        #expect(entryB.stableSlot == 1)
        let savedAnthology = try #require(try anthologyDAO.anthology(id: staleAnthology.id))
        #expect(savedAnthology.nextStableSlot == 2)
        #expect(savedAnthology.latestBuildRevision == 5)
    }

    private func capture(_ id: String, digest: String) -> ArticleCaptureRecord {
        ArticleCaptureRecord(
            id: id,
            sourceURL: "https://example.com/articles/\(id)",
            canonicalURL: "https://example.com/articles/\(id)",
            title: "Article \(id)",
            author: nil,
            siteName: nil,
            language: nil,
            publishedAt: nil,
            capturedAt: "2026-07-28T12:01:00Z",
            captureMethod: .urlFetch,
            packagePath: "/captures/\(id)",
            contentSHA256: digest,
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z"
        )
    }

    private func anthology(_ id: String) -> AnthologyRecord {
        AnthologyRecord(
            id: id,
            title: "Anthology \(id)",
            subtitle: nil,
            creator: "Echo",
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z"
        )
    }

    private func revision(
        id: String,
        captureID: String,
        parentRevisionID: String?
    ) -> ArticleRevisionRecord {
        ArticleRevisionRecord(
            id: id,
            captureID: captureID,
            parentRevisionID: parentRevisionID,
            metadataOverridesJSON: "{}",
            recipeJSON: #"{"excludedBlockIDs":[],"metadataOverrides":{}}"#,
            readableContentSHA256: "readable-\(id)",
            createdAt: "2026-07-29T00:00:00Z",
            deviceName: "Test")
    }

    private func build(id: String, revision: Int, status: String) -> AnthologyBuildRecord {
        AnthologyBuildRecord(
            id: id,
            anthologyID: "anthology-1",
            revision: revision,
            epubIdentifier: "urn:uuid:\(id)",
            manifestJSON: "{}",
            manifestSHA256: "manifest-\(id)",
            epubPath: status == "succeeded" ? "/builds/\(id).epub" : nil,
            epubSHA256: status == "succeeded" ? "epub-\(id)" : nil,
            audiobookID: nil,
            status: status,
            errorCode: status == "failed" ? "build_failed" : nil,
            createdAt: "2026-07-28T12:03:00Z"
        )
    }
}
