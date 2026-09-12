import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct DatabaseLifecycleCoordinatorTests {
    private final class Host {
        var nextID = 0
        var denied = false
        var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
        var ended: [Int] = []
        var notifications: [Notification.Name] = []

        func coordinator() -> DatabaseLifecycleCoordinator {
            DatabaseLifecycleCoordinator(
                begin: { [self] expiration in
                    guard !denied else { return nil }
                    nextID += 1
                    expirations[nextID] = expiration
                    return nextID
                },
                end: { [self] in ended.append($0) },
                post: { [self] in notifications.append($0) })
        }
    }

    @Test func expirationCancelsAllOperationsBeforeEndingProtection() throws {
        let host = Host()
        let lifecycle = host.coordinator()
        lifecycle.enterForeground()
        let first = try lifecycle.beginOperation(name: "launch")
        let second = try lifecycle.beginOperation(name: "alignment")
        lifecycle.enterBackground()
        lifecycle.endOperation(first)
        #expect(host.ended.isEmpty)
        host.expirations[1]?()
        #expect(second.isCancelled)
        #expect(lifecycle.isSuspended)
        #expect(host.notifications.last == Database.suspendNotification)
        #expect(host.ended == [1])
        lifecycle.endOperation(second)
        #expect(host.ended == [1])
    }

    @Test func staleExpirationCannotSuspendNewForegroundWork() throws {
        let host = Host()
        let lifecycle = host.coordinator()
        lifecycle.enterForeground()
        let old = try lifecycle.beginOperation(name: "old")
        lifecycle.enterBackground()
        host.expirations[1]?()
        lifecycle.enterForeground()
        let current = try lifecycle.beginOperation(name: "current")
        host.expirations[1]?()
        lifecycle.endOperation(old)
        #expect(!current.isCancelled)
        #expect(!lifecycle.isSuspended)
        #expect(host.notifications.last == Database.resumeNotification)
    }

    @Test func denialDefersWorkAndUnprotectedBackgroundSuspends() {
        let host = Host()
        host.denied = true
        let lifecycle = host.coordinator()
        lifecycle.enterBackground()
        #expect(throws: DatabaseWorkDeferred.self) {
            _ = try lifecycle.beginOperation(name: "download")
        }
        #expect(lifecycle.isSuspended)
        #expect(host.ended.isEmpty)
    }

    @Test func lastBackgroundOperationSuspendsButForegroundEndDoesNot() throws {
        let host = Host()
        let lifecycle = host.coordinator()
        lifecycle.enterForeground()
        let first = try lifecycle.beginOperation(name: "first")
        lifecycle.endOperation(first)
        #expect(!lifecycle.isSuspended)
        let second = try lifecycle.beginOperation(name: "second")
        lifecycle.enterBackground()
        lifecycle.endOperation(second)
        #expect(lifecycle.isSuspended)
        #expect(host.ended == [1])
    }
}
