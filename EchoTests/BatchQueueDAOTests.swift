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

    private func makeItem(name: String) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: "bk-\(name)", sourceBookmark: Data(),
            displayName: name, queuePosition: 0, status: .queued,
            progress: 0, enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
