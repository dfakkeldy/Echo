// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct VoiceMemoDAOTests {
    /// Inserts an audiobook row so the `voice_memo.audiobook_id` FK is satisfiable.
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["bk1", "Test Book", 3600.0])
        }
    }

    @Test func insertThenFetchByAudiobook() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)

        let memo = VoiceMemoRecord(
            id: "vm1", audiobookID: "bk1", epubBlockID: "blk-5",
            mediaTimestamp: 42.0, filePath: "memos/vm1.m4a", duration: 3.2,
            isEnabled: true, createdAt: "2026-06-22T00:00:00Z",
            modifiedAt: "2026-06-22T00:00:00Z")
        try dao.insert(memo)

        let fetched = try dao.memos(for: "bk1")
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == "vm1")
        #expect(fetched.first?.epubBlockID == "blk-5")
        #expect(fetched.first?.filePath == "memos/vm1.m4a")
    }

    @Test func fetchByEpubBlockIDsFiltersToRequestedBlocks() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)

        try dao.insert(
            VoiceMemoRecord(
                id: "vmA", audiobookID: "bk1", epubBlockID: "blk-1",
                mediaTimestamp: 1, filePath: "a.m4a", duration: nil,
                isEnabled: true, createdAt: "t", modifiedAt: "t"))
        try dao.insert(
            VoiceMemoRecord(
                id: "vmB", audiobookID: "bk1", epubBlockID: "blk-2",
                mediaTimestamp: 2, filePath: "b.m4a", duration: nil,
                isEnabled: true, createdAt: "t", modifiedAt: "t"))

        let onlyB = try dao.memos(withEpubBlockIDsIn: ["blk-2"], audiobookID: "bk1")
        #expect(onlyB.map(\.id) == ["vmB"])
    }

    @Test func deleteRemovesRow() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)
        try dao.insert(
            VoiceMemoRecord(
                id: "vm1", audiobookID: "bk1", epubBlockID: nil,
                mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
                isEnabled: true, createdAt: "t", modifiedAt: "t"))
        try dao.delete(id: "vm1")
        #expect(try dao.memos(for: "bk1").isEmpty)
    }
}
