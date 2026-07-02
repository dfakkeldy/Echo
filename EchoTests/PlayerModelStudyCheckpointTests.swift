// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct PlayerModelStudyCheckpointTests {
    @Test func settingTheDatabaseCreatesTheCoordinator() throws {
        let model = PlayerModel()
        #expect(model.checkpointCoordinator == nil)

        model.databaseService = try DatabaseService(inMemory: ())

        #expect(model.checkpointCoordinator != nil)
    }

    @Test func remoteSkipBecomesAGradeOnlyWhileACheckpointIsActive() throws {
        let model = PlayerModel()
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        model.databaseService = service

        #expect(model.consumeRemoteSkipAsCheckpointGrade(.good) == false)

        let coordinator = try #require(model.checkpointCoordinator)
        let claimed = coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        #expect(claimed == true)

        #expect(model.consumeRemoteSkipAsCheckpointGrade(.good) == true)
        #expect(coordinator.state == .idle)

        let graded = try #require(
            try service.read { db in
                try Flashcard.fetchOne(
                    db,
                    sql: "SELECT * FROM flashcard WHERE front_text = 'Book A Chapter 1'"
                )
            })
        #expect(graded.lastGrade == 3)
    }
}
