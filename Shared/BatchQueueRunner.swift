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

    /// Processes queued items until none remain, or until the drain is cancelled.
    ///
    /// Cancellation gets its own exit rather than falling into the generic `catch`.
    /// A cancelled task stays cancelled, so continuing the loop would run every
    /// remaining item straight into its first `Task.checkCancellation()` and mark
    /// the whole queue `.failed` — one user cancelling one book would wipe out the
    /// rest. Instead the in-flight row goes back to `.queued` (the same state
    /// `recoverInFlight` would give it after a relaunch) and the loop stops; the
    /// caller starts a fresh, uncancelled drain for whatever is left.
    func drain() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while !Task.isCancelled, let item = try? dao.nextQueued(), let id = item.id {
            do {
                try await stages.run(item) { [dao] status, progress, message in
                    try? dao.updateStatus(
                        id: id, status: status, progress: progress, message: message)
                }
                try? dao.updateStatus(id: id, status: .completed, progress: 1.0)
            } catch is CancellationError {
                try? dao.updateStatus(id: id, status: .queued, progress: 0)
                return
            } catch {
                try? dao.updateStatus(id: id, status: .failed, error: error.localizedDescription)
            }
        }
    }
}
