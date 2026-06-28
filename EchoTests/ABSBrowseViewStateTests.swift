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
        #expect(src.contains("\"No Books\", systemImage: \"book.closed\""))
        #expect(src.contains("\"No Results\", systemImage: \"magnifyingglass\""))
    }

    @Test func librarySwitchRefreshesSearchForCurrentLibrary() throws {
        let src = try source()

        #expect(src.contains(".task(id: selectedLibrary?.id)"))
        #expect(src.contains("await runSearch()"))
    }

    @Test func loadedRowsPrecedeSupplementalLoadingAndBrowseErrors() throws {
        let src = try source()
        let rows = try #require(src.range(of: "ForEach(displayedItems)"))
        let loading = try #require(src.range(of: "if isLoadingItems", range: rows.upperBound..<src.endIndex))
        let browseError = try #require(
            src.range(of: "if let browseErrorMessage", range: rows.upperBound..<src.endIndex))

        #expect(rows.lowerBound < loading.lowerBound)
        #expect(rows.lowerBound < browseError.lowerBound)
    }

    @Test func searchErrorPrecedesNoResultsEmptyState() throws {
        let src = try source()
        let searchError = try #require(src.range(of: "if let searchErrorMessage"))
        let noResults = try #require(src.range(of: "ContentUnavailableView(\n                                        \"No Results\""))

        #expect(searchError.lowerBound < noResults.lowerBound)
        #expect(src.contains("isShowingSearchResults, searchErrorMessage == nil"))
    }
}
