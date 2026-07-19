// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VideoExportUIWiringTests {
    @Test func rootTabViewPresentsVideoExportSheetWithBookDependencies() throws {
        let text = try source("EchoCore/Views/RootTabView.swift")
        let sheet = try section(
            in: text,
            startingAt: ".sheet(isPresented: $showingVideoExport)",
            endingAt: ".sheet(isPresented: $showingStudyNotesExport)")

        #expect(text.contains("@State private var showingVideoExport = false"))
        #expect(sheet.contains("model.folderURL?.absoluteString"))
        #expect(sheet.contains("VideoExportProgressView("))
        #expect(sheet.contains("audiobookID: id"))
        #expect(sheet.contains("bookTitle: model.currentTitle"))
        #expect(sheet.contains("cacheDirectory: PlayerModel.narrationCacheDirectory()"))
        #expect(sheet.contains("databaseWriter: writer"))
    }

    @Test func bottomDockForwardsVideoExportToItsMenuRow() throws {
        let root = try source("EchoCore/Views/RootTabView.swift")
        let dock = try source("EchoCore/Views/Components/UnifiedBottomDock.swift")
        let toolbar = try source("EchoCore/Views/BottomToolbarView.swift")
        let menu = try source("EchoCore/Views/PlayerMoreMenu.swift")

        #expect(root.contains("onVideoExport: (model.folderURL != nil"))
        #expect(root.contains("? { showingVideoExport = true } : nil"))
        #expect(dock.contains("var onVideoExport: (() -> Void)?"))
        #expect(dock.contains("onVideoExport: onVideoExport"))
        #expect(toolbar.contains("var onVideoExport: (() -> Void)?"))
        #expect(toolbar.contains("onVideoExport: onVideoExport"))
        #expect(menu.contains("var onVideoExport: (() -> Void)?"))

        let menuRow = try section(
            in: menu,
            startingAt: "if let onVideoExport",
            endingAt: "if let onStudyNotesExport")
        #expect(menuRow.contains("Button(action: onVideoExport)"))
        #expect(menuRow.contains("Label(\"Export Video…\", systemImage: \"film\")"))
    }

    @Test func progressViewUsesStructuredCancellationAndSharesEveryOutput() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let export = try section(
            in: text,
            startingAt: "private func runExport() async",
            endingAt: "#endif")

        #expect(text.contains(".task { await runExport() }"))
        #expect(text.contains("Button(isExporting ? \"Cancel\" : \"Done\") { dismiss() }"))
        #expect(!text.contains("@State private var exportTask"))
        #expect(export.contains("try await VideoExportService().exportVideo("))
        #expect(export.contains("mode: .karaoke"))
        #expect(export.contains("catch is CancellationError"))

        let share = try section(
            in: text,
            startingAt: "ShareLink(",
            endingAt: "} else if let errorText")
        #expect(share.contains("output.videoURL"))
        #expect(share.contains("output.srtURL"))
        #expect(share.contains("output.chaptersURL"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(
        in source: String,
        startingAt start: String,
        endingAt end: String
    ) throws -> Substring {
        guard let startRange = source.range(of: start) else {
            throw SourceInspectionError.missingMarker(start)
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else {
            throw SourceInspectionError.missingMarker(end)
        }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    private enum SourceInspectionError: Error {
        case missingMarker(String)
    }
}
