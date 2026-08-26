// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct MetricKitDiagnosticsArchive {
    let directory: URL
    let maxRetainedPayloads: Int
    var fileManager: FileManager = .default

    func storeDiagnosticPayloads(_ payloads: [Data], receivedAt: Date = Date()) throws -> [URL] {
        guard !payloads.isEmpty else { return [] }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var urls: [URL] = []
        let timestamp = Self.filenameTimestamp(for: receivedAt)
        for (index, payload) in payloads.enumerated() {
            let url = directory.appending(
                path: "diagnostic-\(timestamp)-\(Self.indexString(index)).json",
                directoryHint: .notDirectory
            )
            try payload.write(to: url, options: .atomic)
            urls.append(url)
        }

        try enforceRetentionLimit()
        return urls
    }

    func storedPayloadURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { url in
                url.lastPathComponent.hasPrefix("diagnostic-")
                    && url.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func enforceRetentionLimit() throws {
        guard maxRetainedPayloads >= 0 else { return }

        let files = try storedPayloadURLs()
        guard files.count > maxRetainedPayloads else { return }

        for file in files.prefix(files.count - maxRetainedPayloads) {
            try fileManager.removeItem(at: file)
        }
    }

    private static func filenameTimestamp(for date: Date) -> String {
        date.ISO8601Format()
            .replacing(":", with: "-")
    }

    private static func indexString(_ index: Int) -> String {
        if index < 10 { return "00\(index)" }
        if index < 100 { return "0\(index)" }
        return "\(index)"
    }
}
