// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ABSBrowseViewStateTests {
    private func source() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate =
                directory
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

        #expect(src.contains("case .loading"))
        #expect(src.contains("ProgressView(\"Loading books"))
        #expect(src.contains("\"No Libraries\", systemImage: \"books.vertical\""))
        #expect(src.contains("No books in this library"))
        #expect(src.contains("No search results"))
        #expect(src.contains("No books match these filters"))
        #expect(src.contains("Everything is already in Echo"))
    }

    @Test func libraryAndSearchChangesUseSharedModelTransitions() throws {
        let src = try source()

        #expect(src.contains("browseModel.selectLibrary"))
        #expect(src.contains("browseModel.setSearchQuery"))
        #expect(!src.contains("service.search("))
    }

    @Test func loadedRowsRemainVisibleDuringSupplementalLoading() throws {
        let src = try source()
        let rows = try #require(src.range(of: "ForEach(browseModel.displayedItems)"))
        let loading = try #require(
            src.range(of: "if browseModel.isLoadingNextPage", range: rows.upperBound..<src.endIndex)
        )

        #expect(rows.lowerBound < loading.lowerBound)
    }

    @Test func loadFailurePrecedesEmptyState() throws {
        let src = try source()
        let failure = try #require(src.range(of: "case .failed(let message)"))
        let empty = try #require(src.range(of: "emptyResultsView"))

        #expect(failure.lowerBound < empty.lowerBound)
    }
}
