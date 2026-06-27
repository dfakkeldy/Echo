// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct FeedbackMailBuilderTests {
    @Test func mailtoURLIncludesRecipientSubjectAndBody() throws {
        let diagnostics = FeedbackDiagnostics(
            appVersion: "0.6",
            buildNumber: "9",
            platform: "iOS",
            osVersion: "26.6",
            deviceModel: "iPhone",
            localeIdentifier: "en_US",
            timeZoneIdentifier: "America/Halifax"
        )
        let entry = FeedbackEntry(
            category: .bugReport,
            rating: 2,
            message: "Chapter navigation jumps unexpectedly.",
            diagnostics: diagnostics,
            createdAt: Date(timeIntervalSince1970: 1_800_000)
        )

        let url = try #require(
            FeedbackMailBuilder.mailtoURL(for: entry, recipient: "echo@kinnokilabs.com")
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        #expect(components.scheme == "mailto")
        #expect(components.path == "echo@kinnokilabs.com")
        #expect(queryItems["subject"] == "Echo Feedback: Bug Report")
        #expect(queryItems["body"]?.contains("Rating: 2/5") == true)
        #expect(queryItems["body"]?.contains("Chapter navigation jumps unexpectedly.") == true)
        #expect(queryItems["body"]?.contains("App: 0.6 (9)") == true)
    }
}
