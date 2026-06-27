// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryStatusMapTests {
    @Test func statusMapComputesStudyAndProcessingForManyBooks() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('a', 'A', 100)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b', 'B', 100)")
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('a', 50)")
            try db.execute(sql: """
                INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                VALUES ('t1', 'a', 'c1', 50, '/a/c1.wav', 0, 'af_heart')
                """)
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('b', 99)")
            try db.execute(sql: """
                INSERT INTO transcription_segment (audiobook_id, start_time, end_time, text)
                VALUES ('b', 0, 1, 'hi')
                """)
        }

        let map = try LibraryService(db: db).statusMap(for: ["a", "b"])

        #expect(map["a"]?.study == .inProgress)
        #expect(map["a"]?.processing.contains(.narrated) == true)
        #expect(map["b"]?.study == .finished)
        #expect(map["b"]?.processing.contains(.transcribed) == true)
    }

    @Test func statusSectionsUseBatchedStatusMap() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('a', 'A', 100)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b', 'B', 100)")
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('a', 40)")
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('b', 99)")
        }

        let sections = try LibraryService(db: db).sections(by: .studyStatus, includeUnavailable: false)

        #expect(sections.map(\.title) == ["In Progress", "Finished"])
    }
}
