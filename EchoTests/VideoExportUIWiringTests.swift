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
        #expect(menuRow.contains("Label(.videoExportMenuTitle, systemImage: \"film\")"))
    }

    @Test func progressViewUsesStructuredCancellationAndSharesEveryOutput() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let export = try section(
            in: text,
            startingAt: "private func runExport() async",
            endingAt: "#endif")

        #expect(text.contains(".task { await runExport() }"))
        #expect(text.contains("Text(isExporting ? .cancel : .done)"))
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

    @Test func exportOwnsBackgroundAndTemporaryDirectoryLifecycles() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let export = try section(
            in: text,
            startingAt: "private func runExport() async",
            endingAt: "private func exportErrorText")
        let backgroundTask = try section(
            in: text,
            startingAt: "@MainActor\n    private final class VideoExportBackgroundTask",
            endingAt: "#endif")

        #expect(export.contains("let backgroundTask = VideoExportBackgroundTask()"))
        #expect(export.contains("backgroundTask.begin()"))
        #expect(export.contains("backgroundTask.end()"))
        #expect(export.contains("shouldPreserveOutput"))
        #expect(export.contains("FileManager.default.removeItem(at: outputDirectory)"))

        #expect(backgroundTask.contains("@MainActor"))
        #expect(backgroundTask.contains("UIApplication.shared.beginBackgroundTask"))
        #expect(backgroundTask.contains("expirationHandler"))
        #expect(backgroundTask.contains("self?.end()"))
        #expect(backgroundTask.contains("UIApplication.shared.endBackgroundTask(activeIdentifier)"))
        #expect(backgroundTask.contains("identifier = .invalid"))
    }

    @Test func progressDeliveryIsBoundedAndHasOneOwnedConsumer() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let export = try section(
            in: text,
            startingAt: "private func runExport() async",
            endingAt: "private func exportErrorText")
        let callback = try section(
            in: export,
            startingAt: "onProgress: { value in",
            endingAt: "})")

        #expect(export.contains("bufferingPolicy: .bufferingNewest(1)"))
        #expect(occurrences(of: "let progressConsumer = Task", in: export) == 1)
        #expect(export.contains("for await value in progressStream"))
        #expect(export.contains("progressContinuation.finish()"))
        #expect(export.contains("progressConsumer.cancel()"))
        #expect(callback.contains("progressContinuation.yield(value)"))
        #expect(!callback.contains("Task {"))
    }

    @Test func exportErrorsHaveExplicitLocalizedCopyAndPreserveUnderlyingDescriptions() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let mapping = try section(
            in: text,
            startingAt: "private func exportErrorText",
            endingAt: "@MainActor\n    private final class VideoExportBackgroundTask")

        #expect(mapping.contains("case .noAudio:"))
        #expect(mapping.contains("String(localized: .videoExportErrorNoAudio)"))
        #expect(mapping.contains("case .noAlignment:"))
        #expect(mapping.contains("String(localized: .videoExportErrorNoAlignment)"))
        #expect(mapping.contains("case .writerFailed:"))
        #expect(mapping.contains("String(localized: .videoExportErrorWriterFailed)"))
        #expect(mapping.contains("return error.localizedDescription"))
    }

    @Test func newVideoExportCopyUsesManualEnglishAndDutchSymbolKeys() throws {
        let progressView = try source("EchoCore/Views/VideoExportProgressView.swift")
        let menu = try source("EchoCore/Views/PlayerMoreMenu.swift")
        let catalog = try stringCatalog()
        let expected: [String: (en: String, nl: String)] = [
            "videoExportComplete": ("Export complete", "Export voltooid"),
            "videoExportErrorNoAlignment": (
                "This book needs alignment or narration before video export.",
                "Dit boek moet worden uitgelijnd of verteld voordat je de video kunt exporteren."
            ),
            "videoExportErrorNoAudio": (
                "This book has no local audio to export.",
                "Dit boek heeft geen lokale audio om te exporteren."
            ),
            "videoExportErrorWriterFailed": (
                "Echo couldn't finish writing the video.",
                "Echo kon het schrijven van de video niet voltooien."
            ),
            "videoExportMenuTitle": ("Export Video…", "Video exporteren…"),
            "videoExportProgressMessage": (
                "Rendering the slideshow — this can take a while for long books.",
                "De diavoorstelling wordt gerenderd — dit kan even duren bij lange boeken."
            ),
            "videoExportProgressTitle": (
                "Exporting slideshow video…", "Diavoorstellingsvideo exporteren…"
            ),
            "videoExportShareBundle": ("Share video bundle", "Videobundel delen"),
            "videoExportTitle": ("Export Video", "Video exporteren"),
        ]

        #expect(progressView.contains(".videoExportProgressTitle"))
        #expect(progressView.contains(".videoExportProgressMessage"))
        #expect(progressView.contains(".videoExportComplete"))
        #expect(progressView.contains(".videoExportShareBundle"))
        #expect(progressView.contains(".videoExportTitle"))
        #expect(menu.contains(".videoExportMenuTitle"))

        for (key, translations) in expected {
            let entry = try #require(catalog[key] as? [String: Any])
            #expect(entry["extractionState"] as? String == "manual")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(translation("en", in: localizations) == translations.en)
            #expect(translation("nl", in: localizations) == translations.nl)
        }

        for key in ["Cancel", "Done"] {
            let entry = try #require(catalog[key] as? [String: Any])
            #expect(entry["extractionState"] as? String == "manual")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(translation("nl", in: localizations) != nil)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(
        in source: some StringProtocol,
        startingAt start: String,
        endingAt end: String
    ) throws -> Substring {
        let text = String(source)
        guard let startRange = text.range(of: start) else {
            throw SourceInspectionError.missingMarker(start)
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else {
            throw SourceInspectionError.missingMarker(end)
        }
        return text[startRange.lowerBound..<endRange.lowerBound]
    }

    private func occurrences(of needle: String, in source: some StringProtocol) -> Int {
        String(source).components(separatedBy: needle).count - 1
    }

    private func stringCatalog() throws -> [String: Any] {
        let catalogURL = repositoryRoot.appendingPathComponent(
            "EchoCore/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func translation(
        _ language: String,
        in localizations: [String: Any]
    ) -> String? {
        let localization = localizations[language] as? [String: Any]
        let stringUnit = localization?["stringUnit"] as? [String: Any]
        return stringUnit?["value"] as? String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private enum SourceInspectionError: Error {
        case missingMarker(String)
    }
}
