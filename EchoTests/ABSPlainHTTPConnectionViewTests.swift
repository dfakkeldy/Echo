// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct ABSPlainHTTPConnectionViewTests {
    @Test func settingsPromptsBeforePlainHTTPConnect() throws {
        let source = try Self.source("EchoCore/Views/ABSConnectionsSettingsView.swift")

        #expect(source.contains("pendingPlaintextConnection"))
        #expect(source.contains("ABSEndpoints.requiresPlainHTTPConfirmation(url)"))
        #expect(source.contains("Send Credentials Over Plain HTTP?"))
        #expect(source.contains("connect(to: warning.url)"))
    }

    @Test func settingsShowsPersistentPlainHTTPStateForConnectedServer() throws {
        let source = try Self.source("EchoCore/Views/ABSConnectionsSettingsView.swift")

        #expect(source.contains("server.isPlainHTTP"))
        #expect(source.contains("Plain HTTP connection"))
        #expect(source.contains("Credentials and audiobook data are not encrypted"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
