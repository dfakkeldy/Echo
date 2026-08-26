// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderCardItemPhase4Tests {
    private func makeNote(_ id: String) -> NoteRecord {
        NoteRecord(
            id: id, audiobookID: "bk1", text: "n", mediaTimestamp: 0,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: "blk-1")
    }

    private func makeMemo(_ id: String) -> VoiceMemoRecord {
        VoiceMemoRecord(
            id: id, audiobookID: "bk1", epubBlockID: "blk-1",
            mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t")
    }

    @Test func noteAndMemoHaveDistinctPrefixedIDs() {
        let note = ReaderCardItem.note(makeNote("abc"))
        let memo = ReaderCardItem.voiceMemo(makeMemo("abc"))
        #expect(note.id == "note-abc")
        #expect(memo.id == "vm-abc")
        // Same underlying id, different prefixes → no snapshot collision.
        #expect(note.id != memo.id)
    }

    @Test func equalityIsCaseAndPayloadSensitive() {
        let a = ReaderCardItem.note(makeNote("1"))
        let b = ReaderCardItem.note(makeNote("1"))
        let c = ReaderCardItem.note(makeNote("2"))
        #expect(a == b)
        #expect(a != c)
        #expect(a != ReaderCardItem.voiceMemo(makeMemo("1")))
    }

    @Test func hashMatchesEquality() {
        let a = ReaderCardItem.voiceMemo(makeMemo("1"))
        let b = ReaderCardItem.voiceMemo(makeMemo("1"))
        #expect(a.hashValue == b.hashValue)
    }
}
