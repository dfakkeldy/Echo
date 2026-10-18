// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NoteDAOEpubBlockTests {
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["bk1", "Test Book", 3600.0])
        }
    }

    @Test func insertedNotePersistsEpubBlockID() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = NoteDAO(db: service.writer)

        let note = NoteRecord(
            id: "n1", audiobookID: "bk1", text: "hello",
            mediaTimestamp: 5.0, realTimestamp: nil, isEnabled: true,
            playlistPosition: nil, createdAt: "t", modifiedAt: "t",
            epubBlockID: "blk-3")
        try dao.insert(note)

        let fetched = try dao.note(id: "n1")
        #expect(fetched?.epubBlockID == "blk-3")
    }

    @Test func notesByEpubBlockIDsFiltersToRequestedBlocks() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = NoteDAO(db: service.writer)

        try dao.insert(
            NoteRecord(
                id: "nA", audiobookID: "bk1", text: "a", mediaTimestamp: 1,
                realTimestamp: nil, isEnabled: true, playlistPosition: nil,
                createdAt: "t", modifiedAt: "t", epubBlockID: "blk-1"))
        try dao.insert(
            NoteRecord(
                id: "nB", audiobookID: "bk1", text: "b", mediaTimestamp: 2,
                realTimestamp: nil, isEnabled: true, playlistPosition: nil,
                createdAt: "t", modifiedAt: "t", epubBlockID: "blk-2"))

        let onlyB = try dao.notes(withEpubBlockIDsIn: ["blk-2"], audiobookID: "bk1")
        #expect(onlyB.map(\.id) == ["nB"])
    }
}
