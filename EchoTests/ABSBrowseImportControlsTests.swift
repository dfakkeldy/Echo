// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@Suite struct ABSBrowseImportControlsTests {
    private func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path),
               let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func itemDetailImportTracksCancelableTask() throws {
        let src = try source("EchoCore/Views/ABSBrowseView.swift")

        #expect(src.contains("@State private var importTask: Task<Void, Never>?"))
        #expect(src.contains("importTask?.cancel()"))
        #expect(src.contains("Button(role: .destructive)"))
        #expect(src.contains("Cancel Import"))
    }

    @Test func itemDetailImportShowsRecoveryStateForCanceledLargeDownloads() throws {
        let src = try source("EchoCore/Views/ABSBrowseView.swift")

        #expect(src.contains("TimelineView(.periodic"))
        #expect(src.contains("Elapsed"))
        #expect(src.contains("catch is CancellationError"))
        #expect(src.contains("Import canceled. Partial download data was removed; you can retry."))
    }
}
