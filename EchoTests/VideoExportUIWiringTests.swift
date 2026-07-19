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

    @Test func macAppPresentsVideoExportSheetAndAdjacentEnabledMenuCommand() throws {
        let app = try source("Echo macOS/Echo_macOSApp.swift")
        let sheet = try section(
            in: app,
            startingAt: ".sheet(isPresented: $showVideoExport)",
            endingAt: "        }\n        .defaultLaunchBehavior")
        let commands = try section(
            in: app,
            startingAt: "Button(\"Export Audiobook (.m4b)…\")",
            endingAt: "            }\n\n            CommandGroup(replacing: .textEditing)")

        #expect(app.contains("@State private var showVideoExport = false"))
        #expect(sheet.contains("player.audiobookID"))
        #expect(sheet.contains("player.dbService?.writer"))
        #expect(sheet.contains("MacVideoExportView("))
        #expect(sheet.contains("audiobookID: id"))
        #expect(sheet.contains("bookTitle: player.currentTitle"))
        #expect(sheet.contains("databaseWriter: db"))
        #expect(commands.contains("Button(.videoExportMenuTitle)"))
        #expect(commands.contains("showVideoExport = true"))
        #expect(occurrences(of: ".disabled(player.audiobookID == nil)", in: commands) == 2)
    }

    @Test func macViewPreservesPanelDestinationAndStagesRendererInsideContainer() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let export = try section(
            in: text,
            startingAt: "private func startExport(to panelURL: URL)",
            endingAt: "private func exportErrorText")

        #expect(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-or-later\n"))
        #expect(text.contains("panel.allowedContentTypes = [.mpeg4Movie]"))
        #expect(text.contains("panel.nameFieldStringValue = \"\\(bookTitle).mp4\""))
        #expect(
            export.contains("let destination = try MacVideoExportDestination(panelURL: panelURL)"))
        #expect(export.contains("MacVideoExportPublisher.makeStagingDirectory()"))
        #expect(export.contains("outputDirectory: stagingDirectory"))
        #expect(!export.contains("outputDirectory: panelURL.deletingLastPathComponent()"))
        #expect(export.contains("MacVideoExportPublisher.publish("))
        #expect(export.contains("to: destination"))
        #expect(export.contains("FileManager.default.removeItem(at: stagingDirectory)"))
    }

    @Test func macDestinationContractPreservesPunctuationAndRejectsEmptyStems() throws {
        let text = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let destination = try section(
            in: text,
            startingAt: "struct MacVideoExportDestination",
            endingAt: "final class MacVideoExportSidecarPresenter")

        #expect(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-or-later\n"))
        #expect(destination.contains("videoURL = panelURL"))
        #expect(destination.contains("let baseURL = panelURL.deletingPathExtension()"))
        #expect(destination.contains("guard !baseURL.lastPathComponent.isEmpty"))
        #expect(destination.contains("srtURL = baseURL.appendingPathExtension(\"srt\")"))
        #expect(
            destination.contains(
                "chaptersURL = baseURL.appendingPathExtension(\"chapters.txt\")"))
        #expect(!destination.contains("SafeFileName"))
        #expect(!destination.contains("replacingOccurrences"))
    }

    @Test func macPublisherCoordinatesRegisteredRelatedSidecarsAndRollsBack() throws {
        let text = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let presenter = try section(
            in: text,
            startingAt: "final class MacVideoExportSidecarPresenter",
            endingAt: "enum MacVideoExportPublisher")
        let publisher = try section(
            in: text,
            startingAt: "enum MacVideoExportPublisher",
            endingAt: "\n}",
            fromEnd: true)

        #expect(presenter.contains("NSFilePresenter"))
        #expect(presenter.contains("let primaryPresentedItemURL: URL?"))
        #expect(presenter.contains("let presentedItemURL: URL?"))
        #expect(publisher.contains("NSFileCoordinator.addFilePresenter(presenter)"))
        #expect(publisher.contains("NSFileCoordinator.removeFilePresenter(presenter)"))
        #expect(
            occurrences(of: "NSFileCoordinator.addFilePresenter(presenter)", in: publisher)
                == occurrences(
                    of: "NSFileCoordinator.removeFilePresenter(presenter)", in: publisher))
        #expect(publisher.contains("NSFileCoordinator(filePresenter: presenter)"))
        #expect(publisher.contains("coordinate(writingItemAt:"))
        #expect(
            publisher.contains(
                "try rollback(destination: destination, presenters: presenters)"))
        #expect(publisher.contains("destination.videoURL"))
        #expect(publisher.contains("destination.srtURL"))
        #expect(publisher.contains("destination.chaptersURL"))
    }

    @Test func macInfoPlistDeclaresRelatedSRTAndPlainTextTypes() throws {
        let plist = try macInfoPlist()
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let relatedTypes = documentTypes.filter { $0["NSIsRelatedItemType"] as? Bool == true }

        #expect(
            relatedTypes.contains {
                ($0["LSItemContentTypes"] as? [String])?.contains(
                    "com.echo.audiobooks.srt") == true
            })
        #expect(
            relatedTypes.contains {
                ($0["LSItemContentTypes"] as? [String])?.contains("public.plain-text") == true
            })

        let importedTypes = try #require(
            plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let srtType = try #require(
            importedTypes.first {
                $0["UTTypeIdentifier"] as? String == "com.echo.audiobooks.srt"
            })
        #expect((srtType["UTTypeConformsTo"] as? [String])?.contains("public.plain-text") == true)
        let tags = try #require(srtType["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String])?.contains("srt") == true)
    }

    @Test func macViewOffersKaraokeAndSimpleModesWithKaraokeDefault() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        #expect(text.contains("@State private var mode: SlideshowExportMode = .karaoke"))
        #expect(
            text.contains(
                "Picker(String(localized: .videoExportModeLabel), selection: $mode)"))
        #expect(text.contains("Text(.videoExportModeKaraoke).tag(SlideshowExportMode.karaoke)"))
        #expect(text.contains("Text(.videoExportModeSimple).tag(SlideshowExportMode.simple)"))
        #expect(text.contains("mode: mode"))
    }

    @Test func macProgressDeliveryIsBoundedWithOneOwnedConsumer() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let export = try section(
            in: text,
            startingAt: "private func startExport(to panelURL: URL)",
            endingAt: "private func exportErrorText")
        let callback = try section(
            in: export,
            startingAt: "onProgress: { value in",
            endingAt: "})")

        #expect(export.contains("bufferingPolicy: .bufferingNewest(1)"))
        #expect(occurrences(of: "let progressConsumer = Task", in: export) == 1)
        #expect(export.contains("for await value in progressStream"))
        #expect(export.contains("fraction = min(max(value, 0), 1)"))
        #expect(export.contains("progressContinuation.finish()"))
        #expect(export.contains("progressConsumer.cancel()"))
        #expect(callback.contains("progressContinuation.yield(value)"))
        #expect(!callback.contains("Task {"))
        #expect(text.contains("ProgressView(value: fraction)"))
    }

    @Test func macExportCancellationErrorsAndPanelAccessHaveOneOwner() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let export = try section(
            in: text,
            startingAt: "private func startExport(to panelURL: URL)",
            endingAt: "private func exportErrorText")
        let mapping = try section(
            in: text,
            startingAt: "private func exportErrorText",
            endingAt: "\n    }\n}")

        #expect(text.contains("@State private var exportTask: Task<Void, Never>?"))
        #expect(text.contains("exportTask?.cancel()"))
        #expect(text.contains(".onDisappear { exportTask?.cancel() }"))
        #expect(!export.contains("startAccessingSecurityScopedResource"))
        #expect(occurrences(of: "panelURL.stopAccessingSecurityScopedResource()", in: export) == 1)
        #expect(
            export.contains(
                "defer {\n                panelURL.stopAccessingSecurityScopedResource()"))
        #expect(export.contains("catch is CancellationError"))
        #expect(mapping.contains("case .noAudio:"))
        #expect(mapping.contains("String(localized: .videoExportErrorNoAudio)"))
        #expect(mapping.contains("case .noAlignment:"))
        #expect(mapping.contains("String(localized: .videoExportErrorNoAlignment)"))
        #expect(mapping.contains("case .writerFailed:"))
        #expect(mapping.contains("String(localized: .videoExportErrorWriterFailed)"))
        #expect(mapping.contains("return error.localizedDescription"))
    }

    @Test func macSuccessRevealsTheFinalMovieAndUsesLocalizedCopy() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let catalog = try stringCatalog()
        let expected: [String: (en: String, nl: String)] = [
            "videoExportChooseDestination": ("Export…", "Exporteren…"),
            "videoExportErrorEmptyFilename": (
                "Choose a file name before exporting.",
                "Kies een bestandsnaam voordat je exporteert."
            ),
            "videoExportErrorRelatedFileAccess": (
                "Echo couldn't access a related sidecar file.",
                "Echo kon geen toegang krijgen tot een gerelateerd sidecarbestand."
            ),
            "videoExportErrorRollbackFailed": (
                "Echo couldn't clean up a partial video export.",
                "Echo kon een gedeeltelijke video-export niet opruimen."
            ),
            "videoExportModeKaraoke": ("Karaoke", "Karaoke"),
            "videoExportModeLabel": ("Mode", "Modus"),
            "videoExportModeSimple": ("Simple", "Eenvoudig"),
            "videoExportRevealInFinder": ("Reveal in Finder", "Toon in Finder"),
            "videoExportSavePanelTitle": (
                "Export slideshow video as .mp4", "Diavoorstellingsvideo exporteren als .mp4"
            ),
        ]

        #expect(text.contains("NSWorkspace.shared.activateFileViewerSelecting([output.videoURL])"))
        #expect(text.contains("Button(.videoExportRevealInFinder)"))
        #expect(text.contains("Button(.videoExportChooseDestination)"))
        #expect(text.contains("panel.title = String(localized: .videoExportSavePanelTitle)"))
        #expect(text.contains("Text(.videoExportProgressTitle)"))
        #expect(text.contains("Label(.videoExportComplete"))
        #expect(text.contains("Text(.videoExportProgressMessage)"))

        for (key, translations) in expected {
            let entry = try #require(catalog[key] as? [String: Any])
            #expect(entry["extractionState"] as? String == "manual")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(translation("en", in: localizations) == translations.en)
            #expect(translation("nl", in: localizations) == translations.nl)
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
        endingAt end: String,
        fromEnd: Bool = false
    ) throws -> Substring {
        let text = String(source)
        guard let startRange = text.range(of: start) else {
            throw SourceInspectionError.missingMarker(start)
        }
        let searchRange = startRange.upperBound..<text.endIndex
        let endRange =
            fromEnd
            ? text.range(of: end, options: .backwards, range: searchRange)
            : text.range(of: end, range: searchRange)
        guard let endRange
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

    private func macInfoPlist() throws -> [String: Any] {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Echo macOS/Info.plist"))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
