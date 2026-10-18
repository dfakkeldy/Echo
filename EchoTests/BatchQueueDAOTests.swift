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

    /// Every status is removable. The old `deleteQueued` accepted only `queued`
    /// rows, which — together with a `deleteCompleted` that skipped failures —
    /// left a failed book permanently stuck in the queue with no way to clear it.
    @Test func deleteRemovesRowInAnyStatus() throws {
        let dbService = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: dbService.writer)
        let a = try dao.enqueue(rec("a", .queued))
        _ = try dao.enqueue(rec("b", .queued))
        let c = try dao.enqueue(rec("c", .completed))
        let d = try dao.enqueue(rec("d", .failed))
        let e = try dao.enqueue(rec("e", .transcribing))

        try dao.delete(id: a.id!)
        #expect(try dao.allItems().map(\.audiobookID) == ["b", "c", "d", "e"])  // order kept

        // The states the old API refused: finished, failed, and mid-render.
        try dao.delete(id: c.id!)
        try dao.delete(id: d.id!)
        try dao.delete(id: e.id!)
        #expect(try dao.allItems().map(\.audiobookID) == ["b"])
    }

    /// `updateStatus` for a row deleted mid-render must be a silent no-op, not a
    /// throw or a resurrected row — the runner writes a final status after the
    /// stage returns, by which time `remove` may already have deleted it.
    @Test func updateStatusOnDeletedRowIsANoOp() throws {
        let dbService = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: dbService.writer)
        let a = try dao.enqueue(rec("a", .transcribing))
        try dao.delete(id: a.id!)

        try dao.updateStatus(id: a.id!, status: .completed, progress: 1.0)
        #expect(try dao.allItems().isEmpty)
    }

    @Test func deleteFinishedClearsCompletedAndFailedOnly() throws {
        let dbService = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: dbService.writer)
        _ = try dao.enqueue(rec("done", .completed))
        _ = try dao.enqueue(rec("broken", .failed))
        _ = try dao.enqueue(rec("waiting", .queued))
        _ = try dao.enqueue(rec("running", .transcribing))

        try dao.deleteFinished()
        #expect(try dao.allItems().map(\.audiobookID) == ["waiting", "running"])
    }

    private func rec(_ name: String, _ status: BatchItemStatus) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: name, sourceBookmark: Data(), companionBookmark: nil,
            displayName: name, queuePosition: 0, status: status, progress: 0,
            enqueuedAt: "2026-06-18T00:00:00Z")
    }

    private func makeItem(name: String) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: "bk-\(name)", sourceBookmark: Data(),
            displayName: name, queuePosition: 0, status: .queued,
            progress: 0, enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
