// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct AppBuildMetadataTests {
    @Test func readsVersionBuildAndCommitFromBundle() throws {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: bundleURL) }

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.echo.tests.build-metadata",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
            "GitCommitHash": "abcdef1234-dirty",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: bundleURL.appending(path: "Info.plist"))

        let bundle = try #require(Bundle(path: bundleURL.path))
        let metadata = AppBuildMetadata(bundle: bundle)

        #expect(metadata.marketingVersion == "1.2.3")
        #expect(metadata.buildNumber == "456")
        #expect(metadata.gitCommitHash == "abcdef1234-dirty")
        #expect(metadata.versionString == "1.2.3 (456)")
        #expect(metadata.commitString == "abcdef1234-dirty")
    }
}
