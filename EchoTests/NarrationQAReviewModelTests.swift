// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAReviewModelTests {
    private struct MarkerClassifier: DivergenceClassifier {
        func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
            DivergenceClassification(
                issueType: .pronunciation,
                suggestedSpokenForm: "marker",
                suggestedIPA: "mˈɑɹkɚ",
                confidence: 0.99)
        }
    }

    private func seed(_ db: DatabaseService, book: String) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [book, "Test", 3600.0])
        }
        try NarrationQualityIssueDAO(db: db.writer).insert([
            NarrationQualityIssueRecord(
                id: "i1", audiobookID: book, sourceBlockID: "blk1", sourceWordStart: 0,
                sourceWordEnd: 1, audioStartTime: 0, audioEndTime: 1, expectedText: "colonel",
                heardText: "kernel", issueType: NarrationQAIssueType.substitution.rawValue,
                confidence: 0.8, suggestedFixJSON: nil,
                status: NarrationQAIssueStatus.open.rawValue, createdAt: "t", resolvedAt: nil)
        ])
    }

    @Test func loadShowsOpenIssues() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        #expect(model.issues.count == 1)
    }

    @Test func ignoreRemovesFromOpenList() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.ignore(model.issues[0])
        #expect(model.issues.isEmpty)
        // Persisted as ignored.
        let ignored = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.ignored.rawValue)
        #expect(ignored.count == 1)
    }

    @Test func markResolvedPersistsResolvedAt() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.markResolved(model.issues[0])
        let resolved = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.resolved.rawValue)
        #expect(resolved.count == 1)
        #expect(resolved[0].resolvedAt != nil)
    }

    @Test func runFullQAWithNoRenderedAudioSurfacesError() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        // Nothing rendered → must not silently show an empty queue.
        await model.runFullQA(chapters: []) { _, _ in }
        #expect(model.lastError != nil)
    }

    @Test func runFullQASurfacesRunFailure() async throws {
        struct Boom: Error {}
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, _ in throw Boom() }
        #expect(model.lastError != nil)
    }

    @Test func runFullQASuccessReloadsAndClearsError() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.lastError = "stale"
        var ran = false
        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, _ in ran = true }
        #expect(ran)
        #expect(model.lastError == nil)
        // Reload surfaced the seeded open issue.
        #expect(model.issues.count == 1)
    }

    @Test func runFullQAUsesConfiguredClassifierFactory() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        var capturedPreference: String?
        var capturedAvailability: Bool?
        var classifierWasInjected = false
        let dependencies = NarrationQAReviewModel.Dependencies(
            classifierPreference: { "auto" },
            foundationModelsAvailable: { true },
            classifierFactory: { preference, availability in
                capturedPreference = preference
                capturedAvailability = availability
                return MarkerClassifier()
            })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: "b1", dependencies: dependencies)

        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, classifier in
            classifierWasInjected = classifier is MarkerClassifier
        }

        #expect(capturedPreference == "auto")
        #expect(capturedAvailability == true)
        #expect(classifierWasInjected)
        #expect(model.lastError == nil)
    }
}
