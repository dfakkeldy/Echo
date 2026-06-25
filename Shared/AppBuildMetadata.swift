// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct AppBuildMetadata: Sendable {
    let marketingVersion: String
    let buildNumber: String
    let gitCommitHash: String?

    nonisolated init(marketingVersion: String, buildNumber: String, gitCommitHash: String?) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.gitCommitHash = gitCommitHash
    }

    nonisolated init(bundle: Bundle = .main) {
        marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
        gitCommitHash = bundle.object(forInfoDictionaryKey: "GitCommitHash") as? String
    }

    nonisolated var versionString: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    nonisolated var commitString: String {
        gitCommitHash ?? "Unavailable"
    }
}
