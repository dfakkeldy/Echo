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
        #expect(try dao.possibleDuplicates(
            canonicalURL: savedCapture.canonicalURL,
            digest: savedCapture.contentSHA256
        ) == [captureWithCurrentRevision])
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
