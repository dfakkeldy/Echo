// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderFollowWiringTests {
    @Test func readerObservesDurableIngestionAndHasNoLocalJumpButton() throws {
        let source = try Self.source("ReaderTab.swift")
        #expect(source.contains(".onChange(of: model.documentIngestionTrigger)"))
        #expect(source.contains("reloadReaderAfterTimelineIngestion"))
        #expect(source.contains("updateActiveReaderBlockForCurrentTrack()"))
        #expect(source.contains("arrow.down.to.line") == false)
    }

    @Test func rootOwnsExplorationAndResetsOnlyForAnotherBook() throws {
        let source = try Self.source("RootTabView.swift")
        #expect(source.contains("@State private var readerFollowState"))
        #expect(source.contains(".onChange(of: model.bookIdentityURL)"))
        #expect(source.contains("Return to current text"))
        #expect(source.contains(".onChange(of: model.selectedTab)") == false)
    }

    private static func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
