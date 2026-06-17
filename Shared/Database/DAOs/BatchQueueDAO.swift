// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct BatchQueueDAO {
    let db: DatabaseWriter

    @discardableResult
    func enqueue(_ item: BatchQueueRecord) throws -> BatchQueueRecord {
        var copy = item
        try db.write { db in
            let maxPos =
                try Int.fetchOne(db, sql: "SELECT MAX(queue_position) FROM batch_queue") ?? -1
            copy.queuePosition = maxPos + 1
            try copy.insert(db)
        }
        return copy
    }

    func nextQueued() throws -> BatchQueueRecord? {
        try db.read { db in
            try BatchQueueRecord
                .filter(Column("status") == BatchItemStatus.queued.rawValue)
                .order(Column("queue_position"))
                .fetchOne(db)
        }
    }

    func allItems() throws -> [BatchQueueRecord] {
        try db.read { db in
            try BatchQueueRecord.order(Column("queue_position")).fetchAll(db)
        }
    }

    func updateStatus(
        id: Int64, status: BatchItemStatus, progress: Double? = nil,
        message: String? = nil, error: String? = nil
    ) throws {
        try db.write { db in
            guard var item = try BatchQueueRecord.fetchOne(db, key: id) else { return }
            item.status = status
            if let progress { item.progress = progress }
            if let message { item.statusMessage = message }
            if let error { item.errorMessage = error }
            if status == .completed || status == .failed {
                item.completedAt = ISO8601DateFormatter().string(from: Date())
            } else if item.startedAt == nil && status != .queued {
                item.startedAt = ISO8601DateFormatter().string(from: Date())
            }
            try item.update(db)
        }
    }

    /// On relaunch, any item left mid-flight (importing/transcribing/aligning)
    /// is reset to queued so the queue resumes cleanly.
    func recoverInFlight() throws {
        try db.write { db in
            let inFlight = [BatchItemStatus.importing, .transcribing, .aligning].map(\.rawValue)
            try db.execute(
                sql: """
                    UPDATE batch_queue SET status = ?, progress = 0, started_at = NULL
                    WHERE status IN (?, ?, ?)
                    """, arguments: StatementArguments([BatchItemStatus.queued.rawValue] + inFlight)
            )
        }
    }

    func deleteCompleted() throws {
        _ = try db.write { db in
            try BatchQueueRecord
                .filter(Column("status") == BatchItemStatus.completed.rawValue)
                .deleteAll(db)
        }
    }
}
