// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Thread-safe, ordered fan-out of prepare-progress to one or more subscribers,
/// so a caller that JOINS an in-flight `prepare` still receives events. A small
/// locked box rather than the engine actor itself, because `emit` is called
/// synchronously (and in order: download events, then load, then ready) from a
/// non-isolated progress callback inside the engine's background prepare task.
///
/// Terminal-replay: once `.ready` is emitted it is stored as `terminalProgress`.
/// Any subscriber added AFTER the terminal event immediately receives a synchronous
/// replay rather than being silently dropped — defending against a race where a
/// UI component joins after the engine's prepare task has already completed.
///
/// Safety boundary: `@unchecked Sendable` is intentional — all mutable state
/// (`subscribers`, `terminalProgress`) is protected by `lock`. No mutation ever
/// escapes the lock-protected region, so the class is safe across isolation
/// domains despite the compiler-unseen lock discipline.
///
/// (Originally defined alongside the CoreML `KokoroFixedShapeEngine`; lifted into
/// its own file when that engine was removed, since `OnnxKokoroEngine` still uses it.)
nonisolated final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [@Sendable (NarrationPrepareProgress) -> Void] = []
    private var terminalProgress: NarrationPrepareProgress?

    func add(_ subscriber: @escaping @Sendable (NarrationPrepareProgress) -> Void) {
        let replay: NarrationPrepareProgress?
        lock.lock()
        if let terminalProgress {
            replay = terminalProgress
        } else {
            subscribers.append(subscriber)
            replay = nil
        }
        lock.unlock()

        if let replay {
            subscriber(replay)
        }
    }

    func emit(_ progress: NarrationPrepareProgress) {
        let current: [@Sendable (NarrationPrepareProgress) -> Void]
        lock.lock()
        if progress == .ready {
            terminalProgress = progress
        }
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
        terminalProgress = nil
    }
}
