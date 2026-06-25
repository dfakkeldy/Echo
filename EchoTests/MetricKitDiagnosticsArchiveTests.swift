// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct MetricKitDiagnosticsArchiveTests {
    private func makeArchive(maxRetainedPayloads: Int = 30) throws -> (MetricKitDiagnosticsArchive, URL) {
        let root = URL.temporaryDirectory
            .appending(path: "metric-kit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let archive = MetricKitDiagnosticsArchive(
            directory: root,
            maxRetainedPayloads: maxRetainedPayloads
        )
        return (archive, root)
    }

    @Test func storesDiagnosticPayloadsAsLocalJSON() throws {
        let (archive, root) = try makeArchive()
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)

        let written = try archive.storeDiagnosticPayloads(
            [Data(#"{"crashDiagnostics":[]}"#.utf8)],
            receivedAt: receivedAt
        )

        #expect(written.count == 1)
        let file = try #require(written.first)
        #expect(file.deletingLastPathComponent() == root)
        #expect(file.lastPathComponent.hasPrefix("diagnostic-2025-06-15T15-06-40Z-000.json"))
        #expect(try Data(contentsOf: file) == Data(#"{"crashDiagnostics":[]}"#.utf8))
    }

    @Test func keepsNewestPayloadsWithinRetentionLimit() throws {
        let (archive, _) = try makeArchive(maxRetainedPayloads: 2)

        _ = try archive.storeDiagnosticPayloads(
            [Data("one".utf8)],
            receivedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        _ = try archive.storeDiagnosticPayloads(
            [Data("two".utf8)],
            receivedAt: Date(timeIntervalSince1970: 1_750_000_060)
        )
        _ = try archive.storeDiagnosticPayloads(
            [Data("three".utf8)],
            receivedAt: Date(timeIntervalSince1970: 1_750_000_120)
        )

        let files = try archive.storedPayloadURLs()
        #expect(files.map(\.lastPathComponent) == [
            "diagnostic-2025-06-15T15-07-40Z-000.json",
            "diagnostic-2025-06-15T15-08-40Z-000.json",
        ])
    }
}
