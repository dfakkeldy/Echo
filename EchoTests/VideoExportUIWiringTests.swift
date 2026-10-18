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
            startingAt: "private func runExport(",
            endingAt: "#endif")

        // The export is a structured `.task(id:)` keyed by the captured
        // request, never an auto-starting `.task {}` or a detached task, so
        // dismissing the sheet cooperatively cancels `VideoExportService`.
        #expect(text.contains(".task(id: request?.id)"))
        #expect(text.contains("guard let request else { return }"))
        #expect(text.contains("await runExport(request)"))
        #expect(!text.contains(".task { await runExport"))
        #expect(!text.contains("@State private var isExporting"))
        #expect(!text.contains("@State private var exportTask"))
        #expect(!text.contains("Task.detached"))
        #expect(text.contains("Text(isResult ? .done : .cancel)"))
        #expect(export.contains("try await VideoExportService().exportVideo("))
        #expect(export.contains("mode: .karaoke"))
        #expect(export.contains("dimensions: request.dimensions"))
        #expect(export.contains("catch is CancellationError"))

        let share = try section(
            in: text,
            startingAt: "ShareLink(",
            endingAt: "} else if let errorText")
        #expect(share.contains("output.videoURL"))
        #expect(share.contains("output.srtURL"))
        #expect(share.contains("output.chaptersURL"))
    }

    @Test func iOSVideoExportStartsInConfigurationDefaultingToLandscapeWithFormatOnly() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")

        // Three explicit phases; the sheet starts in configuration and never
        // auto-starts an export on appearance.
        #expect(text.contains("private enum VideoExportPhase"))
        #expect(text.contains("case configuration"))
        #expect(text.contains("case exporting(VideoExportRequest)"))
        #expect(text.contains("case result"))
        #expect(text.contains("@State private var phase: VideoExportPhase = .configuration"))
        #expect(!text.contains("@State private var isExporting = true"))
        #expect(!text.contains("isExporting = true"))

        // Every new sheet defaults to Landscape.
        #expect(
            text.contains("@State private var selectedFormat: SlideshowVideoFormat = .landscape"))

        // Configuration content lives in a ScrollView (Dynamic Type / small
        // screen safety) and exposes ONLY the shared format picker -- iPhone v1
        // uses Karaoke implicitly and never surfaces a Karaoke/Simple control.
        #expect(text.contains("ScrollView"))
        #expect(text.contains("SlideshowVideoFormatPicker(selection: $selectedFormat)"))
        #expect(!text.contains("SlideshowExportMode"))
        #expect(!text.contains(".videoExportModeLabel"))
        #expect(!text.contains(".videoExportModeSimple"))
        #expect(!text.contains(".videoExportModeKaraoke"))
    }

    @Test func iOSVideoExportCapturesImmutableRequestAndDisablesDuplicateStarts() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")

        // The captured request is an immutable, identifiable value carrying a
        // fresh UUID and the validated dimensions -- structured-concurrency safe.
        #expect(text.contains("private struct VideoExportRequest: Identifiable, Equatable"))
        #expect(text.contains("let id = UUID()"))
        #expect(text.contains("let dimensions: SlideshowVideoDimensions"))
        #expect(text.contains("@State private var request: VideoExportRequest?"))

        // The Export button captures exactly one request from the selected
        // format, flips into the exporting phase immediately, and cannot start a
        // second request while one is already captured.
        let configuration = try section(
            in: text,
            startingAt: "private var configuration",
            endingAt: "private var exporting")
        #expect(configuration.contains(".videoExportConfigurationExportButton"))
        #expect(configuration.contains("VideoExportRequest("))
        #expect(configuration.contains("dimensions: selectedFormat.dimensions"))
        #expect(configuration.contains("phase = .exporting("))
        #expect(configuration.contains(".disabled(request != nil)"))
    }

    @Test func exportOwnsBackgroundAndTemporaryDirectoryLifecycles() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        let export = try section(
            in: text,
            startingAt: "private func runExport(",
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
            startingAt: "private func runExport(",
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

        // The live-encoder rejection is exhaustively mapped and interpolates the
        // requested width and height through a `FormatStyle`, never C-style
        // `String(format:)`, so the copy stays localized and grouping-safe.
        #expect(mapping.contains("case .unsupportedVideoSettings(let width, let height):"))
        #expect(mapping.contains(".videoExportErrorUnsupportedVideoSettings"))
        #expect(mapping.contains("width.formatted(.number.grouping(.never))"))
        #expect(mapping.contains("height.formatted(.number.grouping(.never))"))
        #expect(!mapping.contains("String(format:"))
    }

    @Test func newVideoExportCopyUsesManualEnglishAndDutchSymbolKeys() throws {
        let progressView = try source("EchoCore/Views/VideoExportProgressView.swift")
        let menu = try source("EchoCore/Views/PlayerMoreMenu.swift")
        let catalog = try stringCatalog()
        let expected: [String: (en: String, nl: String)] = [
            "videoExportComplete": ("Export complete", "Export voltooid"),
            "videoExportConfigurationExportButton": ("Export video", "Video exporteren"),
            "videoExportFormatExplanation": (
                "Portrait is sized for full-screen phone viewing.",
                "Staand is bedoeld om schermvullend op de telefoon te bekijken."
            ),
            "videoExportFormatLabel": ("Format", "Formaat"),
            "videoExportFormatLandscape": ("Landscape", "Liggend"),
            "videoExportFormatLandscapeAccessibilityValue": (
                "Landscape, 1920 by 1080", "Liggend, 1920 bij 1080"
            ),
            "videoExportFormatPortrait": ("Portrait", "Staand"),
            "videoExportFormatPortraitAccessibilityValue": (
                "Portrait, 1080 by 1920", "Staand, 1080 bij 1920"
            ),
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

    @Test func formatPickerBindsSharedFormatUsesLocalizedKeysAndCommunicatesOrientationByText()
        throws
    {
        let text = try source("EchoCore/Views/SlideshowVideoFormatPicker.swift")

        #expect(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-or-later\n"))
        #expect(text.contains("#if os(iOS) || os(macOS)"))
        #expect(text.contains("@Binding var selection: SlideshowVideoFormat"))
        #expect(text.contains(".pickerStyle(.segmented)"))
        #expect(text.contains("ForEach(SlideshowVideoFormat.allCases)"))

        #expect(text.contains(".videoExportFormatLabel"))
        #expect(text.contains(".videoExportFormatLandscape"))
        #expect(text.contains(".videoExportFormatPortrait"))
        #expect(text.contains(".videoExportFormatLandscapeAccessibilityValue"))
        #expect(text.contains(".videoExportFormatPortraitAccessibilityValue"))
        #expect(text.contains(".videoExportFormatExplanation"))

        #expect(text.contains(".accessibilityLabel(Text(.videoExportFormatLabel))"))
        #expect(text.contains(".accessibilityValue(Text(Self.accessibilityValue(for: selection)))"))
        #expect(
            text.contains(
                "static func accessibilityValue(for format: SlideshowVideoFormat) -> String"
            ))

        // Orientation is communicated by text and exact dimensions, never by
        // color or an icon alone: the resolution is derived from the real
        // dimensions and no SF Symbol or color-only cue stands in for it.
        #expect(text.contains("dimensions.width"))
        #expect(text.contains("dimensions.height"))
        #expect(!text.contains("Image(systemName"))
        #expect(!text.contains("systemImage:"))

        // Semantic text styles only -- no fixed point sizes.
        #expect(text.contains(".font(.subheadline)"))
        #expect(text.contains(".font(.footnote)"))
        #expect(!text.contains(".font(.system(size:"))
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
            startingAt: "private func startExport(to panelURL: URL, configuration:",
            endingAt: "private func exportErrorText")

        #expect(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-or-later\n"))
        #expect(text.contains("panel.allowedContentTypes = [.mpeg4Movie]"))
        #expect(text.contains("panel.nameFieldStringValue = \"\\(bookTitle).mp4\""))
        #expect(
            export.contains("let destination = try VideoExportDestination(panelURL: panelURL)"))
        #expect(export.contains("MacVideoExportPublisher.makeStagingDirectory()"))
        #expect(export.contains("outputDirectory: stagingDirectory"))
        #expect(!export.contains("outputDirectory: panelURL.deletingLastPathComponent()"))
        #expect(export.contains("MacVideoExportPublisher.publish("))
        #expect(export.contains("to: destination"))
        #expect(export.contains("FileManager.default.removeItem(at: stagingDirectory)"))
    }

    @Test func macDestinationContractPreservesPunctuationAndRejectsEmptyStems() throws {
        let text = try source("EchoCore/Services/Export/VideoExportDestination.swift")

        #expect(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-or-later\n"))
        #expect(text.contains("nonisolated struct VideoExportDestination"))
        #expect(text.contains("Equatable, Sendable"))
        #expect(!text.contains("SafeFileName"))
        #expect(!text.contains("replacingOccurrences"))
    }

    @Test func sharedVideoDestinationPreservesExactPunctuationAndSidecars() throws {
        let panelURL = URL(fileURLWithPath: "/tmp/100% ready? *final*.mp4")

        let destination = try VideoExportDestination(panelURL: panelURL)

        #expect(destination.videoURL == panelURL)
        #expect(destination.srtURL == URL(fileURLWithPath: "/tmp/100% ready? *final*.srt"))
        #expect(
            destination.chaptersURL
                == URL(fileURLWithPath: "/tmp/100% ready? *final*.chapters.txt"))
    }

    @Test func sharedVideoDestinationRejectsWhitespaceAndExtensionOnlyNames() {
        for fileName in ["   ", " .mp4", ".mp4"] {
            let panelURL = URL(fileURLWithPath: "/tmp").appending(path: fileName)
            #expect(throws: VideoExportDestinationError.emptyFileName) {
                try VideoExportDestination(panelURL: panelURL)
            }
        }

        #expect(
            VideoExportDestinationError.emptyFileName.localizedDescription
                == String(localized: "videoExportErrorEmptyFilename"))
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
        #expect(publisher.contains("try restoreBundle("))
        #expect(publisher.contains("destination.videoURL"))
        #expect(publisher.contains("destination.srtURL"))
        #expect(publisher.contains("destination.chaptersURL"))
    }

    @Test func macPublisherSnapshotsAndRestoresPreexistingBundleItems() throws {
        let text = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let publisher = try section(
            in: text,
            startingAt: "nonisolated enum MacVideoExportPublisher",
            endingAt: "private nonisolated enum MacVideoExportPublishingError")

        #expect(publisher.contains("snapshots = try snapshotBundle("))
        #expect(publisher.contains("makeBackupDirectory()"))
        #expect(publisher.contains("coordinate(readingItemAt:"))
        #expect(publisher.contains("if snapshot.existed"))
        #expect(publisher.contains("snapshot.backupURL"))
        #expect(publisher.contains("guard modifiedItems.contains(snapshot.item) else { continue }"))
        #expect(publisher.contains("try restoreBundle("))
        #expect(publisher.contains("try removeItemIfPresent(at: destinationURL)"))
        #expect(publisher.contains("FileManager.default.removeItem(at: backupDirectory)"))
        #expect(!publisher.contains("FileManager.default.copyItem"))
    }

    @Test func macPublisherSkipsCoordinatedReadsForAbsentRelatedSidecars() throws {
        let text = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let relatedSnapshot = try section(
            in: text,
            startingAt: "private static func snapshotRelatedItem",
            endingAt: "private static func coordinateCopy")
        let publisher = try section(
            in: text,
            startingAt: "nonisolated enum MacVideoExportPublisher",
            endingAt: "private nonisolated enum MacVideoExportPublishingError")

        let existenceCheck = try #require(relatedSnapshot.range(of: "fileExists("))
        let absentReturn = try #require(relatedSnapshot.range(of: "guard existed else"))
        let coordinatedRead = try #require(relatedSnapshot.range(of: "coordinateRead("))
        #expect(existenceCheck.lowerBound < absentReturn.lowerBound)
        #expect(absentReturn.lowerBound < coordinatedRead.lowerBound)
        #expect(relatedSnapshot.contains("existed: false"))
        #expect(relatedSnapshot.contains("backupURL: backupURL"))
        #expect(publisher.contains("options: .forReplacing"))
    }

    @Test func macPublisherPreservesRecoveryBackupsAndTracksOnlyActualMutation() throws {
        let text = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let publish = try section(
            in: text,
            startingAt: "static func publish(",
            endingAt: "private static func makeBackupDirectory")
        let replace = try section(
            in: text,
            startingAt: "private static func replaceItem",
            endingAt: "private static func removeItemIfPresent")
        let restore = try section(
            in: text,
            startingAt: "private static func restore(",
            endingAt: "private static func replaceItem")
        let publishingError = try section(
            in: text,
            startingAt: "private nonisolated enum MacVideoExportPublishingError",
            endingAt: "\n}",
            fromEnd: true)

        #expect(
            !publish.contains("defer { try? FileManager.default.removeItem(at: backupDirectory) }"))
        #expect(publish.contains("cleanupBackupDirectory(backupDirectory)"))
        #expect(publish.contains("backupDirectory: backupDirectory"))
        #expect(publishingError.contains("backupDirectory: URL"))
        #expect(publishingError.contains("backupDirectory.path(percentEncoded: false)"))

        #expect(
            publish.contains(
                "onMutationBegan: { mutationTracker.items.insert(.movie) }"))
        #expect(
            !publish.contains(
                "try Task.checkCancellation()\n            mutationTracker.items.insert(.movie)"))
        #expect(replace.contains("onMutationBegan"))
        let cancellation = try #require(replace.range(of: "Task.checkCancellation()"))
        let mutation = try #require(replace.range(of: "onMutationBegan()"))
        #expect(cancellation.lowerBound < mutation.lowerBound)
        #expect(restore.contains("checkingCancellation: false"))
        #expect(!restore.contains("onMutationBegan"))
    }

    @Test func macPublicationRunsOffMainAndCopiesInCancellableChunks() throws {
        let view = try source("Echo macOS/Views/MacVideoExportView.swift")
        let publisher = try source("Echo macOS/Services/MacVideoExportPublisher.swift")
        let copy = try section(
            in: publisher,
            startingAt: "private static func chunkedCopy",
            endingAt: "private static func")

        #expect(publisher.contains("nonisolated enum MacVideoExportPublisher"))
        #expect(
            publisher.contains("private nonisolated final class MacVideoExportSidecarPresenter"))
        #expect(view.contains("let publicationWorker = Task.detached(priority: .userInitiated)"))
        #expect(view.contains("try await withTaskCancellationHandler"))
        #expect(view.contains("publicationWorker.cancel()"))
        #expect(copy.contains("FileHandle(forReadingFrom:"))
        #expect(copy.contains("FileHandle(forWritingTo:"))
        #expect(copy.contains("Task.checkCancellation()"))
        #expect(copy.contains("read(upToCount:"))
        #expect(!publisher.contains("FileManager.default.copyItem"))
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

    @Test func macInfoPlistRanksEveryDocumentTypeAsAlternate() throws {
        let plist = try macInfoPlist()
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])

        #expect(!documentTypes.isEmpty)
        #expect(documentTypes.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
    }

    @Test func macViewOffersKaraokeAndSimpleModesWithKaraokeDefault() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        #expect(text.contains("@State private var mode: SlideshowExportMode = .karaoke"))
        #expect(
            text.contains(
                "Picker(String(localized: .videoExportModeLabel), selection: $mode)"))
        #expect(text.contains("Text(.videoExportModeKaraoke).tag(SlideshowExportMode.karaoke)"))
        #expect(text.contains("Text(.videoExportModeSimple).tag(SlideshowExportMode.simple)"))

        // The export path reads the mode through the immutable configuration
        // captured before the save panel opens, never the mutable `mode`
        // @State directly, so a picker change while the panel sheet is open
        // cannot race the export. (The capture site itself,
        // `MacVideoExportConfiguration(mode: mode, ...)`, legitimately reads
        // the current @State exactly once -- that invariant belongs to
        // `macViewCapturesImmutableConfigurationBeforeSavePanelBegins`.)
        #expect(text.contains("mode: configuration.mode"))
    }

    @Test func macViewDefaultsToLandscapeFormatAlongsideModePicker() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        // Every new sheet defaults to Landscape, matching the shared iOS
        // default -- and macOS keeps BOTH the Karaoke/Simple mode picker and
        // the new Landscape/Portrait format picker, unlike iPhone v1 which is
        // Karaoke-only.
        #expect(
            text.contains(
                "@State private var selectedFormat: SlideshowVideoFormat = .landscape"))
        #expect(text.contains("SlideshowVideoFormatPicker(selection: $selectedFormat)"))
        #expect(text.contains("@State private var mode: SlideshowExportMode = .karaoke"))
    }

    @Test func macViewDisablesBothPickersWhileExporting() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        // Both controls are interactive before export and frozen during it.
        let modePicker = try section(
            in: text,
            startingAt: "Picker(String(localized: .videoExportModeLabel), selection: $mode)",
            endingAt: "SlideshowVideoFormatPicker(selection: $selectedFormat)")
        #expect(modePicker.contains(".disabled(isExporting)"))

        let formatPickerOnward = try section(
            in: text,
            startingAt: "SlideshowVideoFormatPicker(selection: $selectedFormat)",
            endingAt: "if isExporting {")
        #expect(formatPickerOnward.contains(".disabled(isExporting)"))
    }

    @Test func macViewCapturesImmutableConfigurationBeforeSavePanelBegins() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        #expect(text.contains("private struct MacVideoExportConfiguration: Sendable {"))
        #expect(text.contains("let mode: SlideshowExportMode"))
        #expect(text.contains("let dimensions: SlideshowVideoDimensions"))

        let presentSavePanel = try section(
            in: text,
            startingAt: "private func presentSavePanel()",
            endingAt: "private func startExport(to panelURL: URL, configuration:")

        // The configuration is captured as the FIRST statement in
        // `presentSavePanel()` -- strictly before `NSSavePanel()` is even
        // constructed, let alone shown via `panel.begin` -- so a picker
        // change while the panel is open can never leak into the export.
        #expect(
            presentSavePanel.contains(
                "let configuration = MacVideoExportConfiguration("))
        #expect(presentSavePanel.contains("mode: mode, dimensions: selectedFormat.dimensions)"))
        let captureRange = try #require(
            presentSavePanel.range(of: "let configuration = MacVideoExportConfiguration("))
        let panelInitRange = try #require(presentSavePanel.range(of: "NSSavePanel()"))
        let beginRange = try #require(presentSavePanel.range(of: "panel.begin"))
        #expect(captureRange.lowerBound < panelInitRange.lowerBound)
        #expect(captureRange.lowerBound < beginRange.lowerBound)

        #expect(
            presentSavePanel.contains("startExport(to: panelURL, configuration: configuration)"))
    }

    @Test func macExportTaskReadsOnlyCapturedConfigurationNeverMutableState() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let export = try section(
            in: text,
            startingAt: "private func startExport(to panelURL: URL, configuration:",
            endingAt: "private func exportErrorText")

        #expect(export.contains("mode: configuration.mode"))
        #expect(export.contains("dimensions: configuration.dimensions"))
        #expect(!export.contains("dimensions: .landscape"))
        #expect(!export.contains("selectedFormat.dimensions"))
        #expect(!export.contains("mode: mode"))
    }

    @Test func macViewUsesFlexibleFrameInsteadOfFixedHeightSoBothPickersFitAtLargerTypeSizes()
        throws
    {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")

        // A fixed 460x300 frame predates the format picker and would clip
        // the second control at larger Dynamic Type sizes -- a minimum-size
        // frame lets the window grow to fit both pickers and the
        // result/error content.
        #expect(!text.contains(".frame(width: 460, height: 300)"))
        #expect(text.contains(".frame(minWidth: 460, minHeight: 320)"))
    }

    @Test func macProgressDeliveryIsBoundedWithOneOwnedConsumer() throws {
        let text = try source("Echo macOS/Views/MacVideoExportView.swift")
        let export = try section(
            in: text,
            startingAt: "private func startExport(to panelURL: URL, configuration:",
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
            startingAt: "private func startExport(to panelURL: URL, configuration:",
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
