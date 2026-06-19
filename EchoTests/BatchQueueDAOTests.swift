// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct BatchQueueDAOTests {
    @Test func enqueueAssignsIncreasingPositionsAndClaimNextIsFIFO() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(makeItem(name: "A"))
        _ = try dao.enqueue(makeItem(name: "B"))
        let first = try dao.nextQueued()
        #expect(first?.displayName == "A")
    }

    @Test func recoverInFlightResetsToQueued() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        let item = try dao.enqueue(makeItem(name: "A"))
        try dao.updateStatus(id: item.id!, status: .transcribing, progress: 0.4)
        try dao.recoverInFlight()  // simulate relaunch
        #expect(try dao.nextQueued()?.status == .queued)
    }

    @Test func defaultsToAlignKind() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        let item = try dao.enqueue(makeItem(name: "A"))  // no kind → defaults to .align
        #expect(try dao.allItems().first(where: { $0.id == item.id })?.kind == .align)
    }

    @Test func roundTripsNarrateKind() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        let item = try dao.enqueue(
            BatchQueueRecord(
                audiobookID: "bk", sourceBookmark: Data(),
                displayName: "B", queuePosition: 0, status: .queued,
                progress: 0, kind: .narrate, enqueuedAt: "2026-06-17T00:00:00Z"))
        #expect(try dao.allItems().first(where: { $0.id == item.id })?.kind == .narrate)
    }

    /// CODE_AUDIT §5.5: a `kind` written by a future build must decode to the
    /// safe default rather than crashing an older build that reads the queue.
    @Test func unknownKindDecodesToAlignForwardCompat() throws {
        let decoded = try JSONDecoder().decode(
            BatchItemKind.self, from: Data("\"summary\"".utf8))
        #expect(decoded == .align)
    }

    @Test func deleteQueuedRemovesOnlyTheQueuedRow() throws {
        let dbService = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: dbService.writer)
        func rec(_ name: String, _ status: BatchItemStatus) -> BatchQueueRecord {
            BatchQueueRecord(
                audiobookID: name, sourceBookmark: Data(), companionBookmark: nil,
                displayName: name, queuePosition: 0, status: status, progress: 0,
                enqueuedAt: "2026-06-18T00:00:00Z")
        }
        let a = try dao.enqueue(rec("a", .queued))
        _ = try dao.enqueue(rec("b", .queued))
        let c = try dao.enqueue(rec("c", .completed))

        try dao.deleteQueued(id: a.id!)
        #expect(try dao.allItems().map(\.audiobookID) == ["b", "c"])  // a gone, order kept

        // Guard: deleting a non-queued id is a no-op.
        try dao.deleteQueued(id: c.id!)
        #expect(try dao.allItems().count == 2)
    }

    private func makeItem(name: String) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: "bk-\(name)", sourceBookmark: Data(),
            displayName: name, queuePosition: 0, status: .queued,
            progress: 0, enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
