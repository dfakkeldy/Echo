// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ABSBrowseViewStateTests {
    private func source() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: "EchoCore/Views/ABSBrowseView.swift")
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func browseViewHasExplicitEmptyAndLoadingStates() throws {
        let src = try source()

        #expect(src.contains("@State private var isLoadingItems = false"))
        #expect(src.contains("@State private var isSearching = false"))
        #expect(src.contains("ProgressView(\"Loading books"))
        #expect(src.contains("ProgressView(\"Searching"))
        #expect(src.contains("ContentUnavailableView(\"No Libraries\""))
        #expect(src.contains("ContentUnavailableView(\"No Books\""))
        #expect(src.contains("ContentUnavailableView(\"No Results\""))
    }

    @Test func librarySwitchRefreshesSearchForCurrentLibrary() throws {
        let src = try source()

        #expect(src.contains(".task(id: selectedLibrary?.id)"))
        #expect(src.contains("await runSearch()"))
    }
}
