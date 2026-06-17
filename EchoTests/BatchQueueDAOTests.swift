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

    private func makeItem(name: String) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: "bk-\(name)", sourceBookmark: Data(),
            displayName: name, queuePosition: 0, status: .queued,
            progress: 0, enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
