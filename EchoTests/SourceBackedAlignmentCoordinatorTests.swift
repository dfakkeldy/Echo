// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentCoordinatorTests {
    /// Seeds 6 single-word blocks so the WordTimingRefiner can match each
    /// block's full text against its corresponding normalized word token.
    private func seedAligned(_ db: DatabaseService, book: String) throws {
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Book', 100)",
                arguments: [book])
            for (i, name) in names.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text, is_hidden)
                        VALUES (?, ?, 'c.xhtml', 0, ?, ?, 'paragraph', ?, 0)
                        """,
                    arguments: ["b\(i)", book, i, i, name])
            }
        }
        let words = names.enumerated().map { i, w in
            StandaloneTranscribedWord(
                word: w, start: Double(i) + 1.0, end: Double(i) + 1.4, confidence: 0.9)
        }
        let json = String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s0', ?, 0, 0, 'alpha bravo charlie delta echo foxtrot',
                            1.0, 6.4, ?, 'now')
                    """,
                arguments: [book, json])
        }
    }

    @Test func writesTranscriptAlignmentAnchorsAndRefinesWordTiming() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)

        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: "bk")
        #expect(!anchors.isEmpty)
        #expect(
            anchors.allSatisfy {
                $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue
            })
        #expect(
            anchors.allSatisfy {
                $0.anchorKind == AlignmentAnchorRecord.AnchorKind.point.rawValue
            })

        let words = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(words.count == 1)
        #expect(words.contains { $0.source == "dtw" })
        if let alpha = words.first(where: { $0.word == "alpha" }) {
            #expect(abs(alpha.audioStartTime - 1.0) < 0.1)
        }
    }

    @Test func reRunClearsOnlyOwnAnchors() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(
            AlignmentAnchorRecord(
                id: "human-1", audiobookID: "bk", epubBlockID: "b0", audioTime: 99,
                audioEndTime: nil, anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: AlignmentAnchorRecord.Source.moveToNow.rawValue, note: nil,
                createdAt: AlignmentService.isoFormatter.string(from: Date()), modifiedAt: nil))

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let firstRunTranscriptIDs = try dao.anchors(for: "bk")
            .filter { $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue }
            .map(\.id)
        #expect(!firstRunTranscriptIDs.isEmpty)

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let all = try dao.anchors(for: "bk")
        #expect(all.contains { $0.id == "human-1" })
        let secondRunTranscriptIDs =
            all
            .filter { $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue }
            .map(\.id)
        #expect(Set(firstRunTranscriptIDs).isDisjoint(with: Set(secondRunTranscriptIDs)))
    }

    @Test func sourceTextRemainsCanonical() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")
        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let blocks = try EPubBlockDAO(db: db.writer).blocks(for: "bk")
        #expect(blocks.count == 6)
        #expect(blocks.first?.text == "alpha")
    }
}
