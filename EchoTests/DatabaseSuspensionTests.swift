import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized) struct DatabaseSuspensionTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "echo-suspension-\(UUID().uuidString)")
            .appending(path: "echo.sqlite")
    }

    @Test func suspendedWriterRejectsMutationsAndResumesWithoutLosingRows() async throws {
        await DatabaseSuspensionTestGate.acquire()
        defer { DatabaseSuspensionTestGate.release() }
        let url = location()
        defer {
            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let lifecycle = DatabaseLifecycleCoordinator(
            begin: { _ in 1 }, end: { _ in },
            post: { NotificationCenter.default.post(name: $0, object: nil) })
        lifecycle.enterForeground()
        let service = try await DatabaseService.openForLaunch(
            databaseURL: url, protection: lifecycle.protection)
        try service.write { db in
            try db.execute(sql: "CREATE TABLE suspension_fixture (value INTEGER)")
            try db.execute(sql: "INSERT INTO suspension_fixture VALUES (1)")
        }
        lifecycle.enterBackground()
        #expect(throws: (any Error).self) {
            try service.write { db in
                try db.execute(sql: "INSERT INTO suspension_fixture VALUES (2)")
            }
        }
        lifecycle.enterForeground()
        try service.write { db in
            try db.execute(sql: "INSERT INTO suspension_fixture VALUES (3)")
        }
        let values = try service.read {
            try Int.fetchAll($0, sql: "SELECT value FROM suspension_fixture ORDER BY value")
        }
        #expect(values == [1, 3])
    }

    @Test func suspensionRollsBackAnInFlightDiskTransaction() async throws {
        await DatabaseSuspensionTestGate.acquire()
        defer { DatabaseSuspensionTestGate.release() }
        let url = location()
        defer {
            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let lifecycle = DatabaseLifecycleCoordinator(
            begin: { _ in 1 }, end: { _ in },
            post: { NotificationCenter.default.post(name: $0, object: nil) })
        lifecycle.enterForeground()
        let service = try await DatabaseService.openForLaunch(
            databaseURL: url, protection: lifecycle.protection)
        try service.write { db in
            try db.execute(sql: "CREATE TABLE suspension_fixture (value INTEGER)")
            try db.execute(sql: "INSERT INTO suspension_fixture VALUES (1)")
        }
        let (events, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = service.writer
        let worker = Task {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    continuation.resume(
                        with: Result {
                            try writer.write { db in
                                db.add(
                                    function: DatabaseFunction(
                                        "pause_for_suspension", argumentCount: 0
                                    ) { _ in
                                        signal.yield(())
                                        // Only the dedicated worker waits. No main-actor
                                        // or Swift concurrency executor is blocked.
                                        _ = release.wait(timeout: .now() + 10)
                                        return 1
                                    })
                                try db.execute(sql: "UPDATE suspension_fixture SET value = 2")
                                _ = try Int.fetchOne(db, sql: "SELECT pause_for_suspension()")
                                try db.execute(sql: "INSERT INTO suspension_fixture VALUES (3)")
                            }
                        })
                }
            }
        }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        lifecycle.enterBackground()
        release.signal()
        await #expect(throws: (any Error).self) { try await worker.value }
        lifecycle.enterForeground()
        let values = try service.read {
            try Int.fetchAll($0, sql: "SELECT value FROM suspension_fixture")
        }
        #expect(values == [1])
    }

    @Test func cancelledOpeningTokenDoesNotCreateDatabase() async throws {
        await DatabaseSuspensionTestGate.acquire()
        defer { DatabaseSuspensionTestGate.release() }
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let token = DatabaseWorkToken()
        token.cancel()
        let protection = DatabaseWorkProtection(
            begin: { _ in token }, end: { _ in }, waitUntilForeground: {})
        await #expect(throws: DatabaseWorkDeferred.self) {
            _ = try await DatabaseService.openForLaunch(databaseURL: url, protection: protection)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func expirationBeforePoolObserversAbortsWALSetupAndAllowsReopen() async throws {
        await DatabaseSuspensionTestGate.acquire()
        defer { DatabaseSuspensionTestGate.release() }
        let url = location()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await AlignmentService.performInBackground { _ in
            let token = DatabaseWorkToken()
            let opening = DatabaseOpeningCheck(token)
            defer { opening.finish() }
            var config = Configuration()
            config.observesSuspensionNotifications = true
            config.prepareDatabase { db in
                try opening.prepare(db)
                // Pool suspension observers do not exist yet. The next SQL is
                // GRDB's own WAL setup, after this callback returns.
                token.cancel()
            }
            #expect(throws: (any Error).self) {
                _ = try DatabasePool(path: url.path, configuration: config)
            }
        }
        let reopened = try await DatabaseService.openForLaunch(databaseURL: url)
        try reopened.write { db in
            try db.execute(sql: "CREATE TABLE resumed_fixture (value INTEGER)")
            try db.execute(sql: "INSERT INTO resumed_fixture VALUES (1)")
        }
        let value = try reopened.read { try Int.fetchOne($0, sql: "SELECT value FROM resumed_fixture") }
        #expect(value == 1)
    }

    @Test func expiredGenerationStaysDeferredAfterForegroundResume() async throws {
        let token = DatabaseWorkToken()
        let protection = DatabaseWorkProtection(
            begin: { _ in token }, end: { _ in }, waitUntilForeground: {})
        await #expect(throws: DatabaseWorkDeferred.self) {
            try await protection.run(name: "fixture") {
                token.cancel()
                let service = try DatabaseService(inMemory: ())
                #expect(service.isWorkDeferred(GRDB.DatabaseError(resultCode: .SQLITE_INTERRUPT)))
                try service.throwIfWorkDeferred(GRDB.DatabaseError(resultCode: .SQLITE_INTERRUPT))
            }
        }
    }
}
