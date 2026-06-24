// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Thread-safe, ordered fan-out of prepare-progress to one or more subscribers,
/// so a caller that JOINS an in-flight `prepare` still receives events. A small
/// locked box rather than the engine actor itself, because `emit` is called
/// synchronously (and in order: download events, then load, then ready) from a
/// non-isolated progress callback inside the engine's background prepare task.
///
/// (Originally defined alongside the CoreML `KokoroFixedShapeEngine`; lifted into
/// its own file when that engine was removed, since `OnnxKokoroEngine` still uses it.)
nonisolated final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [@Sendable (NarrationPrepareProgress) -> Void] = []

    func add(_ subscriber: @escaping @Sendable (NarrationPrepareProgress) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.append(subscriber)
    }

    func emit(_ progress: NarrationPrepareProgress) {
        lock.lock()
        let current = subscribers
        lock.unlock()
        for subscriber in current { subscriber(progress) }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeAll()
    }
}
