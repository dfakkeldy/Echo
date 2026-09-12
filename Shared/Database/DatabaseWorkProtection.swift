// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import SQLite3

nonisolated struct DatabaseWorkDeferred: Error, Sendable {}

/// A cancellation flag shared with blocking database workers. The flag remains
/// cancelled after a later foreground transition, unlike process-wide state.
nonisolated final class DatabaseWorkToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if isCancelled { throw DatabaseWorkDeferred() }
    }
}

nonisolated enum DatabaseWorkContext {
    @TaskLocal static var token: DatabaseWorkToken?
}

/// Configuration.prepareDatabase also runs for readers created long after
/// launch. Stop consulting the launch token once opening has finished.
nonisolated final class DatabaseOpeningCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var token: DatabaseWorkToken?
    private var finished = false
    private var connections: [Database] = []
    init(_ token: DatabaseWorkToken?) { self.token = token }
    func check() throws { try lock.withLock { try token?.check() } }

    /// GRDB registers its pool suspension observers *after* WAL setup. Cover
    /// that gap with a temporary SQLite progress handler before any of our
    /// preparation SQL or GRDB's WAL setup can acquire a lock. Each VM step
    /// checks expiration; the handler is removed when opening finishes.
    func prepare(_ db: Database) throws {
        try lock.withLock {
            guard !finished, let token else { return }
            try token.check()
            connections.append(db)
            sqlite3_progress_handler(
                db.sqliteConnection, 1,
                { context in
                    guard let context else { return 0 }
                    let opening = Unmanaged<DatabaseOpeningCheck>.fromOpaque(context).takeUnretainedValue()
                    do { try opening.check(); return 0 }
                    catch { return 1 }
                },
                Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func finish() {
        lock.withLock {
            for db in connections {
                if let connection = db.sqliteConnection {
                    sqlite3_progress_handler(connection, 0, nil, nil)
                }
            }
            connections.removeAll()
            token = nil
            finished = true
        }
    }
}

/// Installed by the iOS app, never implicitly enabled in CLI, widgets or tests.
@MainActor
final class DatabaseWorkProtection {
    let begin: (String) throws -> DatabaseWorkToken
    let end: (DatabaseWorkToken) -> Void
    let waitUntilForeground: () async throws -> Void

    init(
        begin: @escaping (String) throws -> DatabaseWorkToken,
        end: @escaping (DatabaseWorkToken) -> Void,
        waitUntilForeground: @escaping () async throws -> Void
    ) {
        self.begin = begin
        self.end = end
        self.waitUntilForeground = waitUntilForeground
    }

    func run<T>(name: String, operation: () async throws -> T) async throws -> T {
        if let token = DatabaseWorkContext.token {
            try token.check()
            return try await operation()
        }
        try Task.checkCancellation()
        let token = try begin(name)
        defer { end(token) }
        return try await DatabaseWorkContext.$token.withValue(token) {
            do {
                let result = try await operation()
                try token.check()
                try Task.checkCancellation()
                return result
            } catch {
                try token.check()
                throw error
            }
        }
    }
}
