// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct BatchQueueRunnerTests {
    @Test func processesAllItemsFIFOAndMarksCompleted() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(item("A"))
        _ = try dao.enqueue(item("B"))

        var processedOrder: [String] = []
        let runner = BatchQueueRunner(
            dao: dao,
            stages: .init(
                run: { rec, _ in processedOrder.append(rec.displayName) }))
        await runner.drain()

        #expect(processedOrder == ["A", "B"])
        #expect(try dao.allItems().allSatisfy { $0.status == .completed })
    }

    @Test func failingStageMarksItemFailedAndContinues() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(item("A"))
        _ = try dao.enqueue(item("B"))
        let runner = BatchQueueRunner(
            dao: dao,
            stages: .init(
                run: { rec, _ in if rec.displayName == "A" { throw TestError.boom } }))
        await runner.drain()
        let items = try dao.allItems()
        #expect(items.first(where: { $0.displayName == "A" })?.status == .failed)
        #expect(items.first(where: { $0.displayName == "B" })?.status == .completed)
    }

    enum TestError: Error { case boom }
    private func item(_ n: String) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: "bk-\(n)", sourceBookmark: Data(), displayName: n,
            queuePosition: 0, status: .queued, progress: 0,
            enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
