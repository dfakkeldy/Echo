// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

#if os(iOS)
    import UIKit
#endif

/// Owns the finite execution window in which this process may acquire SQLite
/// locks. Expiration interrupts GRDB immediately, without waiting on its queue.
@MainActor
final class DatabaseLifecycleCoordinator {
    private static let logger = Logger(category: "DatabaseLifecycle")
    private let begin: (@escaping @MainActor @Sendable () -> Void) -> Int?
    private let end: (Int) -> Void
    private let post: (Notification.Name) -> Void
    private var assertion: Int?
    private var generation = 0
    private var foreground = false
    private var operations: [ObjectIdentifier: DatabaseWorkToken] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var isSuspended = true

    init(
        begin: @escaping (@escaping @MainActor @Sendable () -> Void) -> Int?,
        end: @escaping (Int) -> Void,
        post: @escaping (Notification.Name) -> Void
    ) {
        self.begin = begin
        self.end = end
        self.post = post
    }

    func enterForeground() {
        foreground = true
        // Pre-arm before synchronous callers can block delivery of a later
        // background notification. UIKit counts this time only in background.
        guard acquireAssertion() else { return }
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func enterBackground() {
        foreground = false
        if operations.isEmpty { suspendAndEnd() }
    }

    func beginOperation(name: String) throws -> DatabaseWorkToken {
        guard acquireAssertion() else { throw DatabaseWorkDeferred() }
        Self.logger.debug("Protecting database operation: \(name, privacy: .public)")
        let token = DatabaseWorkToken()
        operations[ObjectIdentifier(token)] = token
        return token
    }

    func endOperation(_ token: DatabaseWorkToken) {
        operations.removeValue(forKey: ObjectIdentifier(token))
        if !foreground, operations.isEmpty { suspendAndEnd() }
    }

    private func acquireAssertion() -> Bool {
        if assertion != nil { return true }
        generation += 1
        let requestedGeneration = generation
        guard
            let identifier = begin({ [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.suspendAndEnd()
            })
        else {
            suspendAndEnd()
            return false
        }
        assertion = identifier
        isSuspended = false
        post(Database.resumeNotification)
        Self.logger.debug("Database resumed with finite background execution")
        return true
    }

    private func suspendAndEnd() {
        generation += 1
        for token in operations.values { token.cancel() }
        operations.removeAll()
        isSuspended = true
        post(Database.suspendNotification)
        Self.logger.debug("Database suspended; pending work deferred")
        let identifier = assertion
        assertion = nil
        if let identifier { end(identifier) }
    }

    func waitUntilForeground() async throws {
        try Task.checkCancellation()
        if foreground, !isSuspended { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    var protection: DatabaseWorkProtection {
        DatabaseWorkProtection(
            begin: { [self] in try beginOperation(name: $0) },
            end: { [self] in endOperation($0) },
            waitUntilForeground: { [self] in try await waitUntilForeground() })
    }

    #if os(iOS)
        static let shared = DatabaseLifecycleCoordinator(
            begin: { expiration in
                let id = UIApplication.shared.beginBackgroundTask(withName: "Echo database") {
                    MainActor.assumeIsolated { expiration() }
                }
                return id == .invalid ? nil : id.rawValue
            },
            end: {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0))
            },
            post: { NotificationCenter.default.post(name: $0, object: nil) })

        private var lifecycleObservers: [NSObjectProtocol] = []

        func start() {
            guard lifecycleObservers.isEmpty else { return }
            DatabaseService.workProtection = protection
            for name in [
                UIApplication.willEnterForegroundNotification,
                UIApplication.didEnterBackgroundNotification,
            ] {
                lifecycleObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { [weak self] notification in
                        MainActor.assumeIsolated {
                            if notification.name == UIApplication.didEnterBackgroundNotification {
                                self?.enterBackground()
                            } else {
                                self?.enterForeground()
                            }
                        }
                    })
            }
            if UIApplication.shared.applicationState == .background {
                enterBackground()
            } else {
                enterForeground()
            }
        }
    #endif
}
