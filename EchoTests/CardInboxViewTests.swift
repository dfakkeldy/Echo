// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct CardInboxViewTests {
    @Test func loadFailureShowsRecoveryInsteadOfEmptyInbox() throws {
        let source = try Self.source(named: "CardInboxView.swift")

        #expect(
            source.contains("@State private var loadError"),
            "CardInboxView must track load failures separately from an empty inbox."
        )
        #expect(
            source.contains("ContentUnavailableView(")
                && source.contains("\"Could Not Load Card Inbox\""),
            "CardInboxView must show a visible load-failure state."
        )
        #expect(
            source.contains("Button(\"Try Again\")"),
            "CardInboxView must offer a retry action after load failure."
        )
        #expect(
            source.contains("let records = try dao.fetchAllInbox()"),
            "Inbox fetch errors must be caught and surfaced, not collapsed through try?."
        )
        #expect(
            !source.contains("let records = (try? dao.fetchAllInbox()) ?? []"),
            "Failed inbox loads must not masquerade as an empty inbox."
        )
        #expect(
            !source.contains("guard let db = model.databaseService else { return }"),
            "A missing database must surface a visible recovery state."
        )
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
