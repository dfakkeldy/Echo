import Foundation

/// GRDB suspension notifications affect every opted-in pool in the process.
/// Coordinate across suites without blocking a Swift concurrency executor.
@MainActor
enum DatabaseSuspensionTestGate {
    private static var occupied = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
    }

    static func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
