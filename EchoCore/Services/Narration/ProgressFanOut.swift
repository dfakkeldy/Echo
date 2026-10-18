// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Thread-safe, ordered fan-out of prepare-progress to one or more subscribers,
/// so a caller that JOINS an in-flight `prepare` still receives events. A small
/// locked box rather than the engine actor itself, because `emit` is called
/// synchronously (and in order: download events, then load, then ready) from a
/// non-isolated progress callback inside the engine's background prepare task.
///
/// Latest-state replay: every emitted value is stored as `latestProgress`. A caller
/// joining an in-flight prepare receives that state synchronously, then subscribes
/// to later values. `.ready` is replayed without retaining a terminal subscriber.
///
/// Safety boundary: `@unchecked Sendable` is intentional — all mutable state
/// (`subscribers`, `latestProgress`) is protected by `lock`. No mutation ever
/// escapes the lock-protected region, so the class is safe across isolation
/// domains despite the compiler-unseen lock discipline.
///
/// (Originally defined alongside the CoreML `KokoroFixedShapeEngine`; lifted into
/// its own file when that engine was removed, since `OnnxKokoroEngine` still uses it.)
nonisolated final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [@Sendable (NarrationPrepareProgress) -> Void] = []
    private var latestProgress: NarrationPrepareProgress?

    func add(_ subscriber: @escaping @Sendable (NarrationPrepareProgress) -> Void) {
        lock.lock()
        if let latestProgress {
            subscriber(latestProgress)
        }
        if latestProgress != .ready {
            subscribers.append(subscriber)
        }
        lock.unlock()
    }

    func emit(_ progress: NarrationPrepareProgress) {
        let current: [@Sendable (NarrationPrepareProgress) -> Void]
        lock.lock()
        latestProgress = progress
        current = subscribers
        lock.unlock()

        for subscriber in current {
            subscriber(progress)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeAll()
        latestProgress = nil
    }
}
