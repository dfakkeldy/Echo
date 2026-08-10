// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import MediaPlayer
import Testing
import UIKit

@testable import Echo

private final class PlayerModelFixtureLocator {}

@MainActor
struct PlayerModelTests {
    private final class FakeEntitlement: ProEntitlementProviding {
        var isPro: Bool

        init(isPro: Bool = false) {
            self.isPro = isPro
        }
    }

    @Test("PlayerModel initializes with default services")
    func initDefaults() {
        let model = PlayerModel()

        #expect(model.isPlaying == false)
        #expect(model.currentTitle == "No track selected")
        #expect(model.currentPlaybackTime == 0)
    }

    @Test("Selecting one MP3 from a folder resolves the whole sibling playlist")
    func selectedMP3ExpandsToSiblingPlaylist() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("01.mp3")
        let selected = folder.appendingPathComponent("02.mp3")
        try Data().write(to: first)
        try Data().write(to: selected)

        let result = PlaylistSelectionResolver.resolve(url: selected) { folderURL in
            [
                Track(url: folderURL.appendingPathComponent("01.mp3"), title: "01"),
                Track(url: folderURL.appendingPathComponent("02.mp3"), title: "02"),
            ]
        }

        #expect(result.isDirectory == false)
        #expect(result.tracks.map(\.url) == [first, selected])
        #expect(result.preferredTrackURL == selected)
    }

    @Test("Selecting one M4B does not enlist unrelated sibling audiobooks")
    func selectedM4BRemainsSingleTrack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let selected = folder.appendingPathComponent("book.m4b")
        try Data().write(to: selected)

        var didEnumerateSiblings = false
        let result = PlaylistSelectionResolver.resolve(url: selected) { folderURL in
            didEnumerateSiblings = true
            return [
                Track(url: folderURL.appendingPathComponent("book.m4b"), title: "Book"),
                Track(
                    url: folderURL.appendingPathComponent("book.pronunciation-reel.m4b"),
                    title: "Pronunciation Review"),
                Track(
                    url: folderURL.appendingPathComponent("unrelated-audiobook.m4b"),
                    title: "Unrelated Audiobook"),
            ]
        }

        #expect(didEnumerateSiblings == false)
        #expect(result.isDirectory == false)
        #expect(result.tracks.map(\.url) == [selected])
        #expect(result.preferredTrackURL == nil)
    }

    @Test("Selecting a folder preserves an intentional multi-volume M4B playlist")
    func selectedFolderPreservesM4BPlaylist() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let volumeOne = Track(
            url: folder.appendingPathComponent("volume-1.m4b"),
            title: "Volume 1")
        let volumeTwo = Track(
            url: folder.appendingPathComponent("volume-2.m4b"),
            title: "Volume 2")

        var enumeratedFolder: URL?
        let result = PlaylistSelectionResolver.resolve(url: folder) { folderURL in
            enumeratedFolder = folderURL
            return [volumeOne, volumeTwo]
        }

        #expect(enumeratedFolder == folder)
        #expect(result.isDirectory)
        #expect(result.tracks.map(\.url) == [volumeOne.url, volumeTwo.url])
        #expect(result.preferredTrackURL == nil)
    }

    @Test("Direct books attach only unambiguous companion documents")
    func directBookCompanionSelectionIsUnambiguous() {
        let folder = URL(fileURLWithPath: "/tmp/Messy Audiobooks", isDirectory: true)
        let book = folder.appendingPathComponent("book.m4b")
        let reviewReel = folder.appendingPathComponent("book-review.m4b")
        let matchingEPUB = folder.appendingPathComponent("book.epub")
        let unrelatedEPUB = folder.appendingPathComponent("other.epub")

        #expect(
            CompanionDocumentSelector.select(
                documents: [unrelatedEPUB, matchingEPUB],
                for: book,
                folderIsDirectory: false,
                siblingFiles: [book, reviewReel, unrelatedEPUB, matchingEPUB]
            ) == matchingEPUB)
        #expect(
            CompanionDocumentSelector.select(
                documents: [unrelatedEPUB],
                for: book,
                folderIsDirectory: false,
                siblingFiles: [book, reviewReel, unrelatedEPUB]
            ) == nil)
        #expect(
            CompanionDocumentSelector.select(
                documents: [unrelatedEPUB],
                for: book,
                folderIsDirectory: false,
                siblingFiles: [book, unrelatedEPUB]
            ) == unrelatedEPUB)
    }

    @Test("Direct M4B PDF availability ignores unrelated sibling documents")
    func directM4BPDFRequiresUnambiguousCompanion() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let selected = folder.appendingPathComponent("book-a.m4b")
        let sibling = folder.appendingPathComponent("book-b.m4b")
        try Data().write(to: selected)
        try Data().write(to: sibling)
        try Data().write(to: folder.appendingPathComponent("book-b.pdf"))

        let model = PlayerModel()
        model.folderURL = folder
        model.state.bookIdentityURL = selected
        #expect(model.hasPDF == false)

        try Data().write(to: folder.appendingPathComponent("book-a.pdf"))
        model.state.documentIngestionTrigger += 1
        #expect(model.hasPDF)
    }

    @Test("A directly selected PDF does not require parent-folder access")
    func directPDFUsesSelectedFileForAvailabilityAndPageMode() async throws {
        let inaccessibleParent = URL(fileURLWithPath: "/provider/no-parent-grant")
        let selectedPDF = inaccessibleParent.appendingPathComponent("selected.pdf")
        let model = PlayerModel()
        model.folderURL = inaccessibleParent
        model.state.bookIdentityURL = inaccessibleParent
        model.state.sourceDocumentURL = selectedPDF

        #expect(model.hasPDF)
        let resolved = try await PDFDocumentView.preferredPDFURL(
            in: inaccessibleParent,
            sourceDocumentURL: selectedPDF,
            bookURL: inaccessibleParent,
            bookTitle: "Selected")
        #expect(resolved == selectedPDF)
    }

    @Test("Opening an audio-less document clears prior book artwork")
    func audiolessDocumentClearsPriorArtwork() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            BookPreferencesService.saveSourceDocumentURL(nil, for: folder.absoluteString)
        }
        let pdf = folder.appendingPathComponent("study.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)

        let model = PlayerModel()
        model.state.thumbnailImage = UIImage()
        model.state.currentDisplayArtwork = UIImage()

        model.loadFolder(pdf, autoplay: false, persistBookmark: false)

        #expect(model.state.thumbnailImage == nil)
        #expect(model.state.currentDisplayArtwork == nil)
    }

    @Test("Opening one M4B replaces stale folder aggregation and uses file book identity")
    func openingM4BResetsFolderAggregationAndIdentity() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let selected = folder.appendingPathComponent("book.m4b")
        try Data().write(to: selected)

        let model = PlayerModel()
        let staleFirst = M4BBook(
            url: folder.appendingPathComponent("old-1.m4b"), title: "Old 1",
            duration: 100, chapters: [])
        let staleSecond = M4BBook(
            url: folder.appendingPathComponent("old-2.m4b"), title: "Old 2",
            duration: 200, chapters: [], cumulativeStartOffset: 100, trackIndex: 1)
        model.state.m4bBooks = [staleFirst, staleSecond]
        model.state.aggregatedChapters = [
            AggregatedChapter(
                bookTitle: "Old 1", bookIndex: 0, chapterTitle: "Old chapter",
                chapterIndex: 0, startSeconds: 0, endSeconds: 100,
                sourceBookURL: staleFirst.url)
        ]
        model.state.totalBookDuration = 300

        model.loadFolder(selected, autoplay: false, persistBookmark: false)

        #expect(model.tracks.map(\.url) == [selected])
        #expect(model.folderURL == folder)
        #expect(model.state.bookIdentityURL == selected)
        #expect(model.persistenceFolderURL == nil)
        #expect(model.state.m4bBooks.isEmpty)
        #expect(model.state.aggregatedChapters.isEmpty)
        #expect(model.state.totalBookDuration == 0)
        #expect(model.state.isMultiM4B == false)
    }

    @Test(
        "PlayerModel importEPUB preserves the source EPUB file when imported from the same folder")
    func importEPUBPreservesSourceWhenSameFolder() async throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create a fake EPUB file inside the folder
        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        // Verify the file exists initially
        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        do {
            _ = try await model.importEPUBDocument(from: epubURL)
            Issue.record("Expected fake EPUB payload to report scanner failure.")
        } catch EPUBImportCoordinator.ImportError.scannerFailed(let url, let underlying) {
            #expect(url == epubURL)
            #expect(underlying != nil)
        } catch {
            Issue.record("Expected scanner failure, got \(error).")
        }

        // Verify the file was NOT deleted!
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test(
        "PlayerModel importEPUB deletes other EPUBs and copies new one when imported from outside folder"
    )
    func importEPUBDeletesOtherEPUBs() async throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let fixtureURL = try #require(
            Bundle(for: PlayerModelFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources"
        )

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir
        model.state.chapters = [
            Chapter(index: 0, title: "Chapter One", startSeconds: 0, endSeconds: 1800),
            Chapter(index: 1, title: "Chapter Two", startSeconds: 1800, endSeconds: 3600),
        ]
        model.state.durationSeconds = 3600
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 3600)",
                arguments: [tmpDir.absoluteString]
            )
        }

        // Create an existing epub in the folder (which should be deleted)
        let oldEpubURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old epub content".utf8).write(to: oldEpubURL)

        // Create source epub outside the folder
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceEpubURL = outerDir.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceEpubURL)
        try Data("[]".utf8).write(
            to: tmpDir.appendingPathComponent("minimal-book.alignment.json")
        )

        // Trigger importEPUB through the async path so cleanup has completed before assertions.
        let result = try await model.importEPUBDocument(from: sourceEpubURL)
        let destinationURL = tmpDir.appendingPathComponent("minimal-book.epub")
        #expect(result.destinationURL == destinationURL)

        // Verify old EPUB is deleted to ensure a single companion document
        #expect(!FileManager.default.fileExists(atPath: oldEpubURL.path))

        // Verify new EPUB is copied into folder
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        // Verify source EPUB at original location is NOT deleted
        #expect(FileManager.default.fileExists(atPath: sourceEpubURL.path))
    }

    @Test("openLibraryBook surfaces the player by switching to the Now Playing tab")
    func openLibraryBookSwitchesToNowPlaying() throws {
        let model = PlayerModel()
        model.databaseService = try DatabaseService(inMemory: ())
        // The user is browsing the Library shelf when they tap a book.
        model.selectedTab = .library

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        model.openLibraryBook(LibraryOpenTarget(url: folder, scopedRoot: nil))

        // Without this the book loads behind the still-visible shelf and the tap
        // looks like it "did nothing".
        #expect(model.selectedTab == .nowPlaying)
    }

    @Test("registerLibraryRoot ignores picked files")
    func registerLibraryRootIgnoresPickedFiles() async throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pickedFile = folder.appendingPathComponent("Book.m4b")
        try Data().write(to: pickedFile)

        await model.registerLibraryRoot(url: pickedFile)

        #expect(try LibraryRootDAO(db: db.writer).all().isEmpty)
    }

    @Test("Reader tab reserves compact bottom dock clearance")
    func readerTabUsesCompactBottomInset() {
        let model = PlayerModel()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        model.folderURL = folder
        model.state.tracks = [
            Track(url: folder.appendingPathComponent("chapter.m4b"), title: "Chapter")
        ]

        model.selectedTab = .nowPlaying
        #expect(model.bottomInset == PlayerModel.nowPlayingBottomInset)

        model.selectedTab = .read
        #expect(model.bottomInset == PlayerModel.compactPlaybackBottomInset)
        #expect(model.bottomInset < PlayerModel.nowPlayingBottomInset)
    }

    @Test("hasPreviousChapter / hasNextChapter reflect chapter bounds")
    func chapterNavBoundsHelpers() {
        let model = PlayerModel()

        // No chapters → both false (single-chapter / marker-less book).
        #expect(model.hasChapterNavigation == false)
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == false)

        // Three chapters, positioned at the first chapter.
        model.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
        model.state.currentChapterIndex = 0
        #expect(model.hasChapterNavigation == true)
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)

        // Middle chapter → both directions available.
        model.state.currentChapterIndex = 1
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == true)

        // Last chapter → only previous.
        model.state.currentChapterIndex = 2
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == false)

        // chapters present but index unresolved (nil) → treated as index 0.
        model.state.currentChapterIndex = nil
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)

        // MP3-folder books load as multiple tracks, but each MP3 usually has a
        // single synthetic chapter. The chapter chevrons still need to navigate
        // between files so users do not have to open the chapter/file picker for
        // every track.
        model.state.chapters = [
            Chapter(index: 0, title: "05 - Chapter 5", startSeconds: 0, endSeconds: 600)
        ]
        model.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/book/04.mp3"), title: "04 - Chapter 4"),
            Track(url: URL(fileURLWithPath: "/tmp/book/05.mp3"), title: "05 - Chapter 5"),
            Track(url: URL(fileURLWithPath: "/tmp/book/06.mp3"), title: "06 - Chapter 6"),
        ]
        model.state.currentIndex = 1
        model.state.currentChapterIndex = nil
        #expect(model.hasChapterNavigation == true)
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == true)
    }

    @Test("togglePlayPause routes start branch through PlayerModel.play")
    func togglePlayPauseUsesNarrationAwarePlayPath() throws {
        let source = try Self.source(named: "PlayerModel.swift")
        #expect(source.contains("func togglePlayPause()"))
        #expect(
            source.contains(
                "if isPlaying {\n            pause()\n        } else {\n            play()\n        }"
            ))
        #expect(
            !source.contains(
                "func togglePlayPause() {\n        playbackController.togglePlayPause()\n    }"))
    }

    @Test("narration books count as playback content before tracks exist")
    func narrationBooksCountAsPlaybackContent() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        #expect(source.contains("var hasPlaybackContent: Bool"))
        #expect(source.contains("!state.tracks.isEmpty"))
        #expect(source.contains("isNarrationBook && NarrationCapability.supportsOnDeviceNarration"))
    }

    @Test("free users hit narration paywall after first uncached chapter")
    func narrationRenderGateShowsPaywallWhenFreeCapReached() {
        let model = PlayerModel()
        model.state.narrationRenderInFlight = true
        model.state.awaitingNarrationChapter = true
        model.setFreeTierGate(
            FreeTierGate(
                entitlement: FakeEntitlement(),
                narratedChapters: { _ in FreeTierGate.freeNarrationChaptersPerBook }
            )
        )

        #expect(
            !model.allowNarrationRenderOrPresentPaywall(
                audiobookID: "book",
                alreadyRenderedThisChapter: false
            )
        )
        #expect(model.showPaywall)
        #expect(model.paywallContext == .narrationCap)
        #expect(!model.state.narrationRenderInFlight)
        #expect(!model.state.awaitingNarrationChapter)
        #expect(model.narrationPlaybackState.phase == .failed)
    }

    @Test("cached narration chapters stay playable at the free cap")
    func cachedNarrationRenderGateBypassesPaywall() {
        let model = PlayerModel()
        model.setFreeTierGate(
            FreeTierGate(
                entitlement: FakeEntitlement(),
                narratedChapters: { _ in FreeTierGate.freeNarrationChaptersPerBook }
            )
        )

        #expect(
            model.allowNarrationRenderOrPresentPaywall(
                audiobookID: "book",
                alreadyRenderedThisChapter: true
            )
        )
        #expect(!model.showPaywall)
    }

    @Test("narration playback renders and queues segment files")
    func narrationPlaybackUsesSegmentPlan() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        #expect(source.contains("let preparation = try await NarrationPlaybackPlanPreparation.prepare("))
        #expect(source.contains("let segments = preparation.segments"))
        #expect(source.contains("NarrationSegmentPlanner.resume("))
        #expect(source.contains("NarrationSegmentPlanner.beforeResume("))
        #expect(source.contains("await service.segmentCacheURL("))
        #expect(source.contains("try await service.renderSegment("))
        #expect(source.contains("sourceChapterKey: segment.sourceChapterKey"))
        #expect(source.contains("voice: segment.voice"))
        #expect(source.contains("NarrationCacheStore.staleFiles("))
        #expect(!source.contains("voice: voice.id"))
        #expect(!source.contains("narrationVoiceForFiles"))
        #expect(!source.contains("try await service.renderChapter("))

        let preparationIndex = try #require(source.range(of: "let preparation = try await"))
        let cleanupIndex = try #require(source.range(of: "NarrationCacheStore.staleFiles("))
        let synthesisIndex = try #require(source.range(of: "self.narrationTTS.prepare("))
        #expect(preparationIndex.lowerBound < cleanupIndex.lowerBound)
        #expect(cleanupIndex.lowerBound < synthesisIndex.lowerBound)
    }

    @Test func narrationTaskGuardRejectsSwitchedBook() {
        #expect(throws: CancellationError.self) {
            try NarrationRenderPolicy.checkTaskIsActive(
                currentFolderURL: "file:///new-book/",
                audiobookID: "file:///old-book/")
        }
    }

    @Test func sameBookRestartRejectsStalePreparationProgress() {
        let model = PlayerModel()
        let bookURL = URL(fileURLWithPath: "/same-book", isDirectory: true)
        model.folderURL = bookURL
        let staleOperation = model.replaceNarrationOperation()
        model.narrationPlaybackState.beginSession(defaultVoiceID: VoiceID("af_heart"))

        model.handleNarrationPreparationProgress(
            .ready,
            operation: staleOperation,
            audiobookID: bookURL.absoluteString)
        #expect(model.narrationPlaybackState.snapshot.render == .modelReady)

        _ = model.replaceNarrationOperation()
        model.narrationPlaybackState.transitionRender(
            to: .planning,
            event: nil)
        model.handleNarrationPreparationProgress(
            .ready,
            operation: staleOperation,
            audiobookID: bookURL.absoluteString)

        #expect(model.narrationPlaybackState.snapshot.render == .planning)
    }

    @Test func preparationProgressMapsToExactLifecycle() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Downloading lifecycle"

        model.handleNarrationPreparationProgress(
            .downloadingModel(receivedBytes: 50, totalBytes: 100),
            operation: operation, audiobookID: audiobookID)

        #expect(
            model.narrationPlaybackState.snapshot.render
                == .downloadingModel(receivedBytes: 50, totalBytes: 100))
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .info,
                    message: "Downloading model (50%)",
                    developerMessage: "model download received=50 total=100"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Downloading lifecycle")
    }

    @Test func checkingModelMapsEventAndPublishesNowPlaying() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Checking lifecycle"

        model.handleNarrationPreparationProgress(
            .checkingModel(expectedBytes: 42),
            operation: operation, audiobookID: audiobookID)

        #expect(
            model.narrationPlaybackState.snapshot.render
                == .checkingModel(expectedBytes: 42))
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .info,
                    message: "Checking narration model",
                    developerMessage: "model cache check expectedBytes=42"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Checking lifecycle")
    }

    @Test func modelCacheHitMapsEventAndPublishesNowPlaying() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Cache lifecycle"

        model.handleNarrationPreparationProgress(
            .modelCacheHit(byteCount: 84),
            operation: operation, audiobookID: audiobookID)

        #expect(
            model.narrationPlaybackState.snapshot.render
                == .validatingModel(byteCount: 84))
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .notice,
                    message: "Narration model found in cache",
                    developerMessage: "model cache hit bytes=84"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Cache lifecycle")
    }

    @Test func validatingModelMapsEventAndPublishesNowPlaying() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Validation lifecycle"

        model.handleNarrationPreparationProgress(
            .validatingModel(byteCount: 126),
            operation: operation, audiobookID: audiobookID)

        #expect(
            model.narrationPlaybackState.snapshot.render
                == .validatingModel(byteCount: 126))
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .info,
                    message: "Validating narration model",
                    developerMessage: "model validating bytes=126"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Validation lifecycle")
    }

    @Test func loadingModelMapsEventAndPublishesNowPlaying() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Loading lifecycle"
        let before = Date()

        model.handleNarrationPreparationProgress(
            .loadingModel,
            operation: operation, audiobookID: audiobookID)

        guard case .loadingModel(let startedAt) = model.narrationPlaybackState.snapshot.render
        else {
            Issue.record("Expected loading-model render activity")
            return
        }
        #expect(startedAt >= before)
        #expect(startedAt <= Date())
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .notice,
                    message: "Loading narration model",
                    developerMessage: "model session loading"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Loading lifecycle")
    }

    @Test func readyMapsEventAndPublishesNowPlaying() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }
        model.state.currentTitle = "Ready lifecycle"

        model.handleNarrationPreparationProgress(
            .ready,
            operation: operation, audiobookID: audiobookID)

        #expect(model.narrationPlaybackState.snapshot.render == .modelReady)
        #expect(
            model.narrationPlaybackState.events.last?.descriptor
                == .init(
                    category: .model, severity: .notice,
                    message: "Narration model ready",
                    developerMessage: "model session ready"))
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Ready lifecycle")
    }

    @Test func modelDownloadPublishesOnlyNewMilestones() {
        let (model, operation, audiobookID) = preparationContext()
        let center = MPNowPlayingInfoCenter.default()
        let priorInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = priorInfo }

        model.state.currentTitle = "Initial milestone"
        model.handleNarrationPreparationProgress(
            .downloadingModel(receivedBytes: 1, totalBytes: 100),
            operation: operation, audiobookID: audiobookID)
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Initial milestone")

        model.state.currentTitle = "Same milestone"
        model.handleNarrationPreparationProgress(
            .downloadingModel(receivedBytes: 4, totalBytes: 100),
            operation: operation, audiobookID: audiobookID)
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Initial milestone")

        model.state.currentTitle = "Next milestone"
        model.handleNarrationPreparationProgress(
            .downloadingModel(receivedBytes: 5, totalBytes: 100),
            operation: operation, audiobookID: audiobookID)
        #expect(
            center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                == "Next milestone")
    }

    @Test func planPreparationRecordsBufferSelectedVoiceAndZeroOverrides() throws {
        let model = PlayerModel()
        let voice = try #require(VoiceCatalog.voice(for: VoiceID("bm_daniel")))
        model.narrationPlaybackState.beginSession(defaultVoiceID: voice.id)

        model.recordNarrationPlanPreparation(
            totalSegments: 7,
            voice: voice,
            voiceOverrideCount: 0)

        #expect(model.narrationPlaybackState.snapshot.buffer.totalSegments == 7)
        #expect(model.state.narrationDefaultVoice == VoiceID("bm_daniel"))
        #expect(model.state.narrationVoiceOverrideCount == 0)
        #expect(
            model.narrationPlaybackState.events.suffix(2).map(\.descriptor)
                == [
                    .init(
                        category: .voice, severity: .notice,
                        message: "Selected voice: Daniel",
                        developerMessage: "default voice selected id=bm_daniel"),
                    .init(
                        category: .voice, severity: .info,
                        message: "Chapter voice overrides: 0",
                        developerMessage: "chapter voice overrides count=0"),
                ])
    }

    @Test func queuedNarrationSegmentUpdatesPlayableBuffer() {
        let model = PlayerModel()
        model.tracks = [
            Track(url: URL(fileURLWithPath: "/segment-0.m4a"), title: "One"),
            Track(url: URL(fileURLWithPath: "/segment-1.m4a"), title: "Two"),
            Track(url: URL(fileURLWithPath: "/segment-2.m4a"), title: "Three"),
        ]
        model.state.currentIndex = 1

        model.recordNarrationSegmentQueued(
            totalSegments: 6,
            chapterDisplayNumber: 2,
            segmentIndex: 1)

        #expect(model.narrationPlaybackState.snapshot.buffer.readyAhead == 1)
        #expect(model.narrationPlaybackState.events.last?.category == .buffer)
        #expect(model.narrationPlaybackState.events.last?.message == "Chapter 2 added to playback queue")
    }

    @Test func startingRenderRecordsStructuredUnitAndVoiceName() {
        let model = PlayerModel()
        let startedAt = Date(timeIntervalSince1970: 100)

        let unit = model.beginNarrationRenderUnit(
            chapterDisplayNumber: 2,
            segmentIndex: 1,
            voiceID: VoiceID("bm_daniel"),
            totalBlocks: 4,
            at: startedAt)

        #expect(
            unit
                == NarrationRenderUnitStatus(
                    chapterDisplayNumber: 2,
                    segmentIndex: 1,
                    voiceID: VoiceID("bm_daniel"),
                    completedBlocks: 0,
                    totalBlocks: 4,
                    startedAt: startedAt,
                    lastProgressAt: startedAt))
        #expect(model.narrationPlaybackState.snapshot.render == .rendering(unit))
        #expect(model.narrationPlaybackState.events.last?.message == "Rendering chapter 2 with Daniel")
    }

    @Test func backpressureRecordsOnceAndResumesTheSameUnit() {
        let model = PlayerModel()
        let unit = model.beginNarrationRenderUnit(
            chapterDisplayNumber: 2,
            segmentIndex: 1,
            voiceID: VoiceID("bm_daniel"),
            totalBlocks: 4,
            at: Date(timeIntervalSince1970: 100))
        let eventCountBeforeHold = model.narrationPlaybackState.events.count

        model.holdNarrationRenderForBackpressure()
        model.holdNarrationRenderForBackpressure()

        #expect(model.narrationPlaybackState.snapshot.render == .heldByBackpressure(unit))
        #expect(model.narrationPlaybackState.events.count == eventCountBeforeHold + 1)

        model.resumeNarrationRenderAfterBackpressure()

        #expect(model.narrationPlaybackState.snapshot.render == .rendering(unit))
        #expect(model.narrationPlaybackState.events.count == eventCountBeforeHold + 1)
    }

    @Test func completingRenderDoesNotCompletePlayback() {
        let model = PlayerModel()
        model.narrationPlaybackState.transitionPlayback(
            to: .playing(chapterDisplayNumber: 2),
            event: nil)

        model.completeNarrationRendering()

        #expect(model.narrationPlaybackState.snapshot.render == .complete)
        #expect(
            model.narrationPlaybackState.snapshot.playback
                == .playing(chapterDisplayNumber: 2))
    }

    @Test func preparationProgressRelayIsOrderedAndAwaited() async throws {
        let probe = PreparationProgressRelayProbe()
        let relayTask = Task {
            try await NarrationPreparationProgressRelay.run(
                prepare: { progress in
                    progress(.checkingModel(expectedBytes: 1))
                    progress(.loadingModel)
                    progress(.ready)
                },
                receive: { progress in
                    await probe.receive(progress)
                })
            await probe.markRelayReturned()
        }

        await probe.waitUntilFirstReceiveStarts()
        await Task.yield()
        #expect(!(await probe.relayReturned))

        await probe.releaseFirstReceive()
        try await relayTask.value

        #expect(
            await probe.received
                == [
                    .checkingModel(expectedBytes: 1),
                    .loadingModel,
                    .ready,
                ])
        #expect(await probe.relayReturned)
    }

    @Test func preparationProgressRelayPropagatesCancellation() async {
        let relayTask = Task {
            try await NarrationPreparationProgressRelay.run(
                prepare: { progress in
                    progress(.checkingModel(expectedBytes: 1))
                    try await Task.sleep(for: .seconds(60))
                },
                receive: { _ in })
        }

        await Task.yield()
        relayTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await relayTask.value
        }
    }

    @Test func preparationProgressRelayThrowsWhenCancelledWhileDraining() async {
        let probe = PreparationProgressCancellationProbe()
        let relayTask = Task {
            try await NarrationPreparationProgressRelay.run(
                prepare: { progress in
                    progress(.checkingModel(expectedBytes: 1))
                },
                receive: { _ in
                    await probe.receive()
                })
        }

        await probe.waitUntilReceiveStarts()
        relayTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await relayTask.value
        }
    }

    @Test func narrationSessionStartsBeforeImportAwait() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        let begin = try #require(source.range(of: "narrationPlaybackState.beginSession("))
        let importAwait = try #require(
            source.range(of: "await self.playerLoadingCoordinator.documentImportTask?.value"))
        #expect(begin.lowerBound < importAwait.lowerBound)
    }

    @Test func sameBookRestartRejectsStaleBlockProgress() {
        let model = PlayerModel()
        let bookURL = URL(fileURLWithPath: "/same-book", isDirectory: true)
        model.folderURL = bookURL
        let staleOperation = model.replaceNarrationOperation()
        let startedAt = Date(timeIntervalSince1970: 100)
        model.narrationPlaybackState.transitionRender(
            to: .rendering(
                NarrationRenderUnitStatus(
                    chapterDisplayNumber: 3,
                    segmentIndex: 0,
                    voiceID: VoiceID("af_heart"),
                    completedBlocks: 0,
                    totalBlocks: 2,
                    startedAt: startedAt,
                    lastProgressAt: startedAt)),
            event: nil)

        model.handleNarrationBlockProgress(
            NarrationRenderProgress(
                chapterDisplayNumber: 3,
                segmentIndex: 0,
                voiceID: VoiceID("af_heart"),
                completedBlocks: 1,
                totalBlocks: 2,
                timestamp: Date(timeIntervalSince1970: 101)),
            operation: staleOperation,
            audiobookID: bookURL.absoluteString)
        #expect(model.state.currentSubtitle == "Preparing chapter 3… 50%")

        _ = model.replaceNarrationOperation()
        model.state.currentSubtitle = "Current operation"
        let renderBeforeStaleCallback = model.narrationPlaybackState.snapshot.render
        let eventCountBeforeStaleCallback = model.narrationPlaybackState.events.count
        model.handleNarrationBlockProgress(
            NarrationRenderProgress(
                chapterDisplayNumber: 8,
                segmentIndex: 4,
                voiceID: VoiceID("bm_daniel"),
                completedBlocks: 3,
                totalBlocks: 4,
                timestamp: Date(timeIntervalSince1970: 102)),
            operation: staleOperation,
            audiobookID: bookURL.absoluteString)

        #expect(model.state.currentSubtitle == "Current operation")
        #expect(model.narrationPlaybackState.snapshot.render == renderBeforeStaleCallback)
        #expect(model.narrationPlaybackState.events.count == eventCountBeforeStaleCallback)
    }

    @Test func blockProgressPreservesRenderStartAndRecordsCompletion() {
        let model = PlayerModel()
        let bookURL = URL(fileURLWithPath: "/same-book", isDirectory: true)
        model.folderURL = bookURL
        let operation = model.replaceNarrationOperation()
        let startedAt = Date(timeIntervalSince1970: 100)
        model.narrationPlaybackState.transitionRender(
            to: .rendering(
                NarrationRenderUnitStatus(
                    chapterDisplayNumber: 3,
                    segmentIndex: 0,
                    voiceID: VoiceID("af_heart"),
                    completedBlocks: 0,
                    totalBlocks: 2,
                    startedAt: startedAt,
                    lastProgressAt: startedAt)),
            event: nil)
        let progressAt = Date(timeIntervalSince1970: 101)

        model.handleNarrationBlockProgress(
            NarrationRenderProgress(
                chapterDisplayNumber: 3,
                segmentIndex: 0,
                voiceID: VoiceID("af_heart"),
                completedBlocks: 1,
                totalBlocks: 2,
                timestamp: progressAt),
            operation: operation,
            audiobookID: bookURL.absoluteString)

        #expect(
            model.narrationPlaybackState.snapshot.render
                == .rendering(
                    NarrationRenderUnitStatus(
                        chapterDisplayNumber: 3,
                        segmentIndex: 0,
                        voiceID: VoiceID("af_heart"),
                        completedBlocks: 1,
                        totalBlocks: 2,
                        startedAt: startedAt,
                        lastProgressAt: progressAt)))
        #expect(model.narrationPlaybackState.events.last?.category == .render)
        #expect(model.narrationPlaybackState.events.last?.message == "Chapter 3 · block 1 of 2")
    }

    @Test func narrationPreparationIsGuardedBeforeMutationAndTTS() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        let importAwait = try #require(
            source.range(of: "await self.playerLoadingCoordinator.documentImportTask?.value"))
        let firstGuard = try #require(
            source.range(
                of: "try NarrationRenderPolicy.checkTaskIsActive(",
                range: importAwait.upperBound..<source.endIndex))
        let preparation = try #require(
            source.range(of: "let preparation = try await NarrationPlaybackPlanPreparation.prepare("))
        let postPreparationGuard = try #require(
            source.range(
                of: "try NarrationRenderPolicy.checkTaskIsActive(",
                range: preparation.upperBound..<source.endIndex))
        let stateMutation = try #require(source.range(of: "self.recordNarrationPlanPreparation("))
        let ttsPreparation = try #require(source.range(of: "self.narrationTTS.prepare("))

        #expect(importAwait.lowerBound < firstGuard.lowerBound)
        #expect(firstGuard.lowerBound < preparation.lowerBound)
        #expect(preparation.lowerBound < postPreparationGuard.lowerBound)
        #expect(postPreparationGuard.lowerBound < stateMutation.lowerBound)
        #expect(postPreparationGuard.lowerBound < ttsPreparation.lowerBound)
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/ViewModels")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private func preparationContext() -> (PlayerModel, NarrationOperationToken, String) {
        let model = PlayerModel()
        let bookURL = URL(fileURLWithPath: "/same-book", isDirectory: true)
        model.folderURL = bookURL
        let operation = model.replaceNarrationOperation()
        model.narrationPlaybackState.beginSession(defaultVoiceID: VoiceID("af_heart"))
        return (model, operation, bookURL.absoluteString)
    }
}

private actor PreparationProgressRelayProbe {
    private(set) var received: [NarrationPrepareProgress] = []
    private(set) var relayReturned = false
    private var firstReceiveStarted = false
    private var firstReceiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReceiveContinuation: CheckedContinuation<Void, Never>?

    func receive(_ progress: NarrationPrepareProgress) async {
        if case .checkingModel = progress {
            firstReceiveStarted = true
            firstReceiveWaiters.forEach { $0.resume() }
            firstReceiveWaiters.removeAll()
            await withCheckedContinuation { continuation in
                firstReceiveContinuation = continuation
            }
        }
        received.append(progress)
    }

    func waitUntilFirstReceiveStarts() async {
        guard !firstReceiveStarted else { return }
        await withCheckedContinuation { continuation in
            firstReceiveWaiters.append(continuation)
        }
    }

    func releaseFirstReceive() {
        firstReceiveContinuation?.resume()
        firstReceiveContinuation = nil
    }

    func markRelayReturned() {
        relayReturned = true
    }
}

private actor PreparationProgressCancellationProbe {
    private var receiveStarted = false
    private var receiveWaiters: [CheckedContinuation<Void, Never>] = []

    func receive() async {
        receiveStarted = true
        receiveWaiters.forEach { $0.resume() }
        receiveWaiters.removeAll()
        try? await Task.sleep(for: .seconds(60))
    }

    func waitUntilReceiveStarts() async {
        guard !receiveStarted else { return }
        await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }
}
