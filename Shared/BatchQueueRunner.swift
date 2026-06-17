// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Testable sequential queue engine. Drains `batch_queue` one item at a time,
/// driving the injected `run` closure per item and recording status transitions.
/// The macOS wrapper supplies a real `run` (import → transcribe → align → word
/// timings); tests supply a fake.
@MainActor
final class BatchQueueRunner {
    struct Stages {
        /// Processes one item end-to-end. Throwing marks the item failed.
        /// The `progress` callback (0–1) is forwarded to the DAO.
        let run:
            (
                BatchQueueRecord,
                _ progress: @MainActor (BatchItemStatus, Double, String?) -> Void
            ) async throws -> Void
    }

    private let dao: BatchQueueDAO
    private let stages: Stages
    private(set) var isRunning = false

    init(dao: BatchQueueDAO, stages: Stages) {
        self.dao = dao
        self.stages = stages
    }

    /// Processes queued items until none remain.
    func drain() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while let item = try? dao.nextQueued(), let id = item.id {
            do {
                try await stages.run(item) { [dao] status, progress, message in
                    try? dao.updateStatus(
                        id: id, status: status, progress: progress, message: message)
                }
                try? dao.updateStatus(id: id, status: .completed, progress: 1.0)
            } catch {
                try? dao.updateStatus(id: id, status: .failed, error: error.localizedDescription)
            }
        }
    }
}
