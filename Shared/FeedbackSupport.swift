// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FeedbackSupport {
    nonisolated static let supportEmail = "echo@kinnokilabs.com"
    nonisolated static let githubIssuesURL = URL(string: "https://github.com/dfakkeldy/Echo/issues")!
    nonisolated static let manualURL = URL(string: "https://dfakkeldy.github.io/Echo/manual.html")!

    nonisolated static func emailURL(buildMetadata: AppBuildMetadata = AppBuildMetadata()) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Echo feedback"),
            URLQueryItem(name: "body", value: emailBody(buildMetadata: buildMetadata)),
        ]
        return components.url ?? URL(string: "mailto:\(supportEmail)")!
    }

    nonisolated static func emailBody(buildMetadata: AppBuildMetadata) -> String {
        """


        ---
        Echo \(buildMetadata.versionString)
        Commit: \(buildMetadata.commitString)
        """
    }
}
