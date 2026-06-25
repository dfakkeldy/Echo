// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct FeedbackSupportTests {
    @Test func supportURLsUsePublicLaunchSupportDestinations() {
        #expect(FeedbackSupport.supportEmail == "echo@kinnokilabs.com")
        #expect(FeedbackSupport.githubIssuesURL.absoluteString == "https://github.com/dfakkeldy/Echo/issues")
        #expect(FeedbackSupport.manualURL.absoluteString == "https://dfakkeldy.github.io/Echo/manual.html")
    }

    @Test func emailURLPrefillsRecipientSubjectAndBuildContextWithoutPrivateData() throws {
        let metadata = AppBuildMetadata(
            marketingVersion: "1.0",
            buildNumber: "42",
            gitCommitHash: "abcdef1234567890"
        )

        let url = FeedbackSupport.emailURL(buildMetadata: metadata)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let subject = queryItems.first { $0.name == "subject" }?.value
        let body = try #require(queryItems.first { $0.name == "body" }?.value)

        #expect(components.scheme == "mailto")
        #expect(components.path == "echo@kinnokilabs.com")
        #expect(subject == "Echo feedback")
        #expect(body.contains("Echo 1.0 (42)"))
        #expect(body.contains("Commit: abcdef1"))
        #expect(!body.localizedStandardContains("book path"))
        #expect(!body.localizedStandardContains("listening data"))
    }
}
