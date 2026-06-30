// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchConnectivityIsolationTests {
    @Test func phoneLiveSyncCallbacksDoNotInheritMainActorIsolation() throws {
        let source = try Self.source(at: "EchoCore/Services/WatchSyncManager.swift")
        let syncToWatch = try Self.slice(
            of: source,
            after: "func syncToWatch(reason:",
            until: "private func sendThumbnailIfNeeded()"
        )

        #expect(
            syncToWatch.contains("replyHandler: { @Sendable _ in"),
            "WatchSyncManager live-sync reply handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
        #expect(
            syncToWatch.contains("errorHandler: { @Sendable error in"),
            "WatchSyncManager live-sync error handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
    }

    @Test func watchRequestStateCallbacksDoNotInheritMainActorIsolation() throws {
        let source = try Self.source(at: "Echo Watch App/Services/WatchViewModel.swift")
        let requestCurrentState = try Self.slice(
            of: source,
            after: "func requestCurrentState() -> Bool",
            until: "func refreshAfterWake()"
        )

        #expect(
            requestCurrentState.contains("replyHandler: { @Sendable reply in"),
            "Watch requestState reply handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
        #expect(
            requestCurrentState.contains("errorHandler: { @Sendable error in"),
            "Watch requestState error handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
    }

    @Test func watchCommandCallbacksDoNotInheritMainActorIsolation() throws {
        let source = try Self.source(at: "Echo Watch App/Services/WatchViewModel.swift")
        let sendCommand = try Self.slice(
            of: source,
            after: "func sendCommand(_ command:",
            until: "if pendingSnapshot != nil"
        )

        #expect(
            sendCommand.contains("replyHandler: { @Sendable reply in"),
            "Watch command reply handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
        #expect(
            sendCommand.contains("errorHandler: { @Sendable error in"),
            "Watch command error handler must be @Sendable so WCSession background callbacks do not inherit @MainActor isolation."
        )
    }

    private static func source(at relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: relativePath)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private static func slice(of source: String, after: String, until: String) throws -> String {
        guard let startRange = source.range(of: after),
              let endRange = source[startRange.upperBound...].range(of: until)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return String(source[startRange.upperBound..<endRange.lowerBound])
    }
}
