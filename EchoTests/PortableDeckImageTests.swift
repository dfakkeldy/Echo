// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

/// Covers `PortableDeckImageStager` directly (staging/publish/commit/
/// rollback/discard mechanics) and `DeckImportService.importDeckVNext(
/// from:targetAudiobookID:db:)`'s end-to-end wiring of that stager into the
/// atomic write path: every declared image is required (never a silent
/// text-only downgrade), staged/published files are collision-safe, a
/// database failure after staging rolls the filesystem back too, and
/// `ImportDeckResult.imageCount` reflects committed rows rather than the
/// write plan's card count.
@MainActor
@Suite struct PortableDeckImageTests {

    // MARK: - Shared fixtures

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])

    private func mediaRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "DeckMediaV2", directoryHint: .isDirectory)
    }

    private func safeDeckID(_ deckID: String) -> String {
        SHA256.hash(data: Data(deckID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort removal of every on-disk trace (`<safeDeckID>`,
    /// `.staging-<safeDeckID>-*`, `.backup-<safeDeckID>-*`) a test may have
    /// left behind under the real `DeckMediaV2` directory.
    private func cleanupDeckMedia(deckID: String) {
        let root = mediaRoot()
        let safe = safeDeckID(deckID)
        try? FileManager.default.removeItem(at: root.appending(path: safe, directoryHint: .isDirectory))
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return
        }
        for entry in entries where entry.contains(safe) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }
    }

    private func assertNoStagingDirectoriesRemain(deckID: String) throws {
        let safe = safeDeckID(deckID)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mediaRoot().path)) ?? []
        #expect(!entries.contains { $0.hasPrefix(".staging-\(safe)") })
    }

    private func makeBundleDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-deck-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeImage(in bundleDir: URL, relativePath: String, bytes: Data) throws {
        let target = bundleDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target)
    }

    /// Writes `deck-images/<name>` for each entry in `images` plus the deck
    /// JSON itself, and returns the JSON file's URL.
    private func writeDeckBundle(
        _ dir: URL, deck: FlashcardDeckImport, images: [String: Data]
    ) throws -> URL {
        for (name, bytes) in images {
            try writeImage(in: dir, relativePath: "deck-images/\(name)", bytes: bytes)
        }
        let deckURL = dir.appendingPathComponent("deck.echo-deck.json")
        try JSONEncoder().encode(deck).write(to: deckURL)
        return deckURL
    }

    private struct DatabaseCounts: Equatable {
        let audiobooks: Int
        let decks: Int
        let flashcards: Int
        let timelineItems: Int
    }

    private func databaseCounts(_ writer: DatabaseWriter) throws -> DatabaseCounts {
        try writer.read { db in
            DatabaseCounts(
                audiobooks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audiobook") ?? 0,
                decks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deck") ?? 0,
                flashcards: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flashcard") ?? 0,
                timelineItems: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timeline_item") ?? 0
            )
        }
    }

    private func seedSelectedAudiobook(
        _ writer: DatabaseWriter, id: String, blocks: [EPubBlockRecord]
    ) throws {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: id,
                title: id,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)
            for var block in blocks {
                try block.insert(db)
            }
        }
    }

    private func makeBlock(
        suffix: String,
        audiobookID: String,
        sequenceIndex: Int,
        kind: EPubBlockRecord.Kind = .paragraph,
        text: String = "Block text",
        imagePath: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-\(suffix)",
            audiobookID: audiobookID,
            spineHref: "Text/chapter.xhtml",
            spineIndex: sequenceIndex,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makePortableCard(
        sourceAnchor: String?,
        imageAnchor: String? = nil,
        imageFile: String? = nil,
        frontText: String = "Question"
    ) -> FlashcardDeckImport.ImportedCard {
        FlashcardDeckImport.ImportedCard(
            frontText: frontText,
            backText: "Answer",
            startTime: nil,
            endTime: nil,
            triggerTiming: FlashcardTriggerTiming.manualOnly.rawValue,
            sourceAnchor: sourceAnchor,
            imageAnchor: imageAnchor,
            imageFile: imageFile
        )
    }

    private func makePortableDeckDocument(
        deckID: String,
        deckName: String,
        targetMediaID: String = "echo-portable:test-slug:core",
        sourceSignature: EchoSourceSignature,
        cards: [FlashcardDeckImport.ImportedCard]
    ) -> FlashcardDeckImport {
        FlashcardDeckImport(
            formatVersion: 2,
            deckID: deckID,
            deckName: deckName,
            targetBinding: "selectedBook",
            targetMediaID: targetMediaID,
            sourceSignature: sourceSignature,
            cards: cards
        )
    }

    // MARK: - Stager: staging failures

    @Test
    func stageValidNestedImageProducesCollisionSafeMediaPath() throws {
        let deckID = "stage-nested-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/sub/cue.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let staged = try PortableDeckImageStager().stage(
            relativePaths: ["deck-images/sub/cue.png"], beside: deckURL, deckID: deckID)

        let mediaPath = try #require(staged.mediaPathByRelativePath["deck-images/sub/cue.png"])
        #expect(mediaPath.hasSuffix(".png"))
        #expect(mediaPath.contains(safeDeckID(deckID)))
        // The staged copy lives under `stagingRoot` until `publish` moves it;
        // `mediaPathByRelativePath` already points at the *future* final
        // location, which doesn't exist yet.
        #expect(!FileManager.default.fileExists(atPath: mediaPath))
        let stagedFiles =
            (try? FileManager.default.contentsOfDirectory(atPath: staged.stagingRoot.path)) ?? []
        #expect(stagedFiles.count == 1)
    }

    @Test
    func stageTwoSameBasenameFilesProduceDistinctMediaPaths() throws {
        let deckID = "stage-basename-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/a/cue.png", bytes: pngBytes)
        try writeImage(in: bundleDir, relativePath: "deck-images/b/cue.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let staged = try PortableDeckImageStager().stage(
            relativePaths: ["deck-images/a/cue.png", "deck-images/b/cue.png"],
            beside: deckURL, deckID: deckID)

        let pathA = try #require(staged.mediaPathByRelativePath["deck-images/a/cue.png"])
        let pathB = try #require(staged.mediaPathByRelativePath["deck-images/b/cue.png"])
        #expect(pathA != pathB)
    }

    @Test
    func stageRejectsParentDirectoryTraversalEscape() throws {
        let deckID = "stage-traversal-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        let escapeName = "escape-\(UUID().uuidString).png"
        let escapeTarget = bundleDir.deletingLastPathComponent()
            .appendingPathComponent(escapeName)
        try pngBytes.write(to: escapeTarget)
        defer { try? FileManager.default.removeItem(at: escapeTarget) }
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let thrown = try #require(throws: DeckImportError.self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["../\(escapeName)"], beside: deckURL, deckID: deckID)
        }
        guard case .unsafeImagePath("../\(escapeName)") = thrown else {
            Issue.record("Expected unsafeImagePath, got \(thrown)")
            return
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    /// A leading "/" does not jump to the real filesystem root: `URL.
    /// appending(path:)` treats it as an ordinary nested path component, so
    /// this resolves to a nonexistent path *under* the bundle directory
    /// rather than the real `/etc/hosts` (which does exist on this
    /// machine). Proves the stager never leaks a real absolute-path target
    /// even though the string looks like one.
    @Test
    func stageRejectsAbsoluteLookingPathWithoutLeakingRealFilesystemRoot() throws {
        let deckID = "stage-absolute-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        #expect(throws: (any Error).self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["/etc/hosts"], beside: deckURL, deckID: deckID)
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageRejectsEscapingSymlink() throws {
        let deckID = "stage-symlink-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        let imagesDir = bundleDir.appendingPathComponent("deck-images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let outsideTarget = bundleDir.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString).png")
        try pngBytes.write(to: outsideTarget)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }
        try FileManager.default.createSymbolicLink(
            at: imagesDir.appendingPathComponent("sneaky.png"), withDestinationURL: outsideTarget)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let thrown = try #require(throws: DeckImportError.self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/sneaky.png"], beside: deckURL, deckID: deckID)
        }
        guard case .unsafeImagePath("deck-images/sneaky.png") = thrown else {
            Issue.record("Expected unsafeImagePath, got \(thrown)")
            return
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageRejectsDirectory() throws {
        let deckID = "stage-directory-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try FileManager.default.createDirectory(
            at: bundleDir.appendingPathComponent("deck-images/notafile.png"),
            withIntermediateDirectories: true)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let thrown = try #require(throws: DeckImportError.self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/notafile.png"], beside: deckURL, deckID: deckID)
        }
        guard case .invalidImageFile("deck-images/notafile.png") = thrown else {
            Issue.record("Expected invalidImageFile, got \(thrown)")
            return
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageRejectsMissingFile() throws {
        let deckID = "stage-missing-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        #expect(throws: (any Error).self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/missing.png"], beside: deckURL, deckID: deckID)
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageRejectsEmptyFile() throws {
        let deckID = "stage-empty-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/empty.png", bytes: Data())
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let thrown = try #require(throws: DeckImportError.self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/empty.png"], beside: deckURL, deckID: deckID)
        }
        guard case .invalidImageFile("deck-images/empty.png") = thrown else {
            Issue.record("Expected invalidImageFile, got \(thrown)")
            return
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageRejectsUnsupportedExtension() throws {
        let deckID = "stage-unsupported-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(
            in: bundleDir, relativePath: "deck-images/cue.gif",
            bytes: Data([0x47, 0x49, 0x46, 0x38]))
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        let thrown = try #require(throws: DeckImportError.self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/cue.gif"], beside: deckURL, deckID: deckID)
        }
        guard case .unsupportedImageType("deck-images/cue.gif") = thrown else {
            Issue.record("Expected unsupportedImageType, got \(thrown)")
            return
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    @Test
    func stageCopyFailureCleansUpStagingDirectory() throws {
        let deckID = "stage-copy-fail-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/protected.png", bytes: pngBytes)
        let sourcePath = bundleDir.appendingPathComponent("deck-images/protected.png").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourcePath)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: sourcePath)
        }
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")

        #expect(throws: (any Error).self) {
            try PortableDeckImageStager().stage(
                relativePaths: ["deck-images/protected.png"], beside: deckURL, deckID: deckID)
        }
        try assertNoStagingDirectoriesRemain(deckID: deckID)
    }

    // MARK: - Stager: publish / commit / rollback / discard

    @Test
    func publishBacksUpAndCommitRemovesSupersededDirectory() throws {
        let deckID = "publish-commit-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/v1.png", bytes: pngBytes)
        try writeImage(in: bundleDir, relativePath: "deck-images/v2.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        let stager = PortableDeckImageStager()

        let staged1 = try stager.stage(
            relativePaths: ["deck-images/v1.png"], beside: deckURL, deckID: deckID)
        let published1 = try stager.publish(staged1)
        #expect(published1.hadPreviousDirectory == false)
        try stager.commit(published1)

        let staged2 = try stager.stage(
            relativePaths: ["deck-images/v2.png"], beside: deckURL, deckID: deckID)
        let published2 = try stager.publish(staged2)
        #expect(published2.hadPreviousDirectory == true)
        #expect(FileManager.default.fileExists(atPath: published2.staged.backupRoot.path))
        let newPath = try #require(published2.staged.mediaPathByRelativePath["deck-images/v2.png"])
        #expect(FileManager.default.fileExists(atPath: newPath))

        try stager.commit(published2)
        #expect(!FileManager.default.fileExists(atPath: published2.staged.backupRoot.path))
    }

    @Test
    func commitCleanupFailureThrowsButLeavesFinalRootIntact() throws {
        let deckID = "commit-fail-\(UUID().uuidString)"
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/v1.png", bytes: pngBytes)
        try writeImage(in: bundleDir, relativePath: "deck-images/v2.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        let stager = PortableDeckImageStager()

        let staged1 = try stager.stage(
            relativePaths: ["deck-images/v1.png"], beside: deckURL, deckID: deckID)
        let published1 = try stager.publish(staged1)
        let v1Path = try #require(published1.staged.mediaPathByRelativePath["deck-images/v1.png"])
        let v1Filename = (v1Path as NSString).lastPathComponent
        var protectedURL = URL(fileURLWithPath: v1Path)
        var values = URLResourceValues()
        values.isUserImmutable = true
        try protectedURL.setResourceValues(values)

        let staged2 = try stager.stage(
            relativePaths: ["deck-images/v2.png"], beside: deckURL, deckID: deckID)
        let published2 = try stager.publish(staged2)
        #expect(published2.hadPreviousDirectory == true)

        defer {
            // The immutable file rode along the rename into `backupRoot`;
            // clear the flag there so this test's own cleanup can remove it.
            var clearURL = published2.staged.backupRoot.appendingPathComponent(v1Filename)
            var clearValues = URLResourceValues()
            clearValues.isUserImmutable = false
            try? clearURL.setResourceValues(clearValues)
            try? FileManager.default.removeItem(at: published2.staged.backupRoot)
            try? FileManager.default.removeItem(at: published2.staged.finalRoot)
        }

        #expect(throws: (any Error).self) {
            try stager.commit(published2)
        }
        // Rows and the newly published directory are unaffected by a
        // cleanup failure: the new image is still there and valid.
        #expect(FileManager.default.fileExists(atPath: published2.staged.finalRoot.path))
        let newPath = try #require(published2.staged.mediaPathByRelativePath["deck-images/v2.png"])
        #expect(FileManager.default.fileExists(atPath: newPath))
    }

    @Test
    func rollbackRemovesFinalDirectoryWhenNoPreviousExisted() throws {
        let deckID = "rollback-fresh-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/v1.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        let stager = PortableDeckImageStager()

        let staged = try stager.stage(
            relativePaths: ["deck-images/v1.png"], beside: deckURL, deckID: deckID)
        let published = try stager.publish(staged)
        #expect(published.hadPreviousDirectory == false)
        #expect(FileManager.default.fileExists(atPath: published.staged.finalRoot.path))

        try stager.rollback(published)

        #expect(!FileManager.default.fileExists(atPath: published.staged.finalRoot.path))
    }

    @Test
    func rollbackRestoresPreviousDirectoryAfterPublicationOfReplacement() throws {
        let deckID = "rollback-restore-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/v1.png", bytes: pngBytes)
        try writeImage(in: bundleDir, relativePath: "deck-images/v2.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        let stager = PortableDeckImageStager()

        let staged1 = try stager.stage(
            relativePaths: ["deck-images/v1.png"], beside: deckURL, deckID: deckID)
        let published1 = try stager.publish(staged1)
        try stager.commit(published1)
        let v1Path = try #require(published1.staged.mediaPathByRelativePath["deck-images/v1.png"])

        let staged2 = try stager.stage(
            relativePaths: ["deck-images/v2.png"], beside: deckURL, deckID: deckID)
        let published2 = try stager.publish(staged2)
        #expect(published2.hadPreviousDirectory == true)

        try stager.rollback(published2)

        #expect(FileManager.default.fileExists(atPath: v1Path))
        let v2Path = try #require(published2.staged.mediaPathByRelativePath["deck-images/v2.png"])
        #expect(!FileManager.default.fileExists(atPath: v2Path))
        #expect(!FileManager.default.fileExists(atPath: published2.staged.backupRoot.path))
    }

    @Test
    func discardRemovesStagingDirectoryWithoutPublishing() throws {
        let deckID = "discard-\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try writeImage(in: bundleDir, relativePath: "deck-images/v1.png", bytes: pngBytes)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        let stager = PortableDeckImageStager()

        let staged = try stager.stage(
            relativePaths: ["deck-images/v1.png"], beside: deckURL, deckID: deckID)
        #expect(FileManager.default.fileExists(atPath: staged.stagingRoot.path))

        try stager.discard(staged)

        #expect(!FileManager.default.fileExists(atPath: staged.stagingRoot.path))
        #expect(!FileManager.default.fileExists(atPath: staged.finalRoot.path))
    }

    // MARK: - DeckImportService integration

    @Test
    func importWithBundledImageReturnsExactCounts() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block0 = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        let block1 = makeBlock(
            suffix: "s0-b1", audiobookID: "local-book", sequenceIndex: 1, text: "Second")
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block0, block1])
        let signature = EchoSourceSignature.make(records: [block0, block1])
        let deckID = "com.echo.image.nested.\(UUID().uuidString)"

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Image Deck", sourceSignature: signature,
            cards: [
                makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/cue.png"),
                makePortableCard(sourceAnchor: "s0-b1"),
            ]
        )
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        defer { cleanupDeckMedia(deckID: deckID) }
        let deckURL = try writeDeckBundle(bundleDir, deck: deck, images: ["cue.png": pngBytes])

        let result = try DeckImportService().importDeckVNext(
            from: deckURL, targetAudiobookID: "local-book", db: writer)

        #expect(result.importedCount == 2)
        #expect(result.anchoredCount == 2)
        #expect(result.imageCount == 1)
        #expect(result.warningCount == 0)

        let mediaJSONs: [String?] = try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT media_json FROM flashcard WHERE deck_id = ?",
                arguments: [deckID]
            ).map { $0["media_json"] as String? }
        }
        let paths = mediaJSONs.compactMap { StudyCardMedia.imagePath(fromMediaJSON: $0) }
        #expect(paths.count == 1)
        let path = try #require(paths.first)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.contains("DeckMediaV2"))
    }

    @Test
    func importWithImageAnchorSetsSourceImagePathAndImageCount() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let textBlock = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        let imageBlock = makeBlock(
            suffix: "s0-b1", audiobookID: "local-book", sequenceIndex: 1, kind: .image,
            text: "Figure", imagePath: "/tmp/EPUBAssets/local-book/fig-0.png")
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [textBlock, imageBlock])
        let signature = EchoSourceSignature.make(records: [textBlock, imageBlock])
        let deckID = "com.echo.image.anchor.\(UUID().uuidString)"

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Anchor Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageAnchor: "s0-b1")]
        )
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        let deckURL = try writeDeckBundle(bundleDir, deck: deck, images: [:])

        let result = try DeckImportService().importDeckVNext(
            from: deckURL, targetAudiobookID: "local-book", db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)
        #expect(result.imageCount == 1)
        #expect(result.warningCount == 0)

        let mediaJSON = try writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT media_json FROM flashcard WHERE deck_id = ?", arguments: [deckID])
        }
        #expect(
            StudyCardMedia.imagePath(fromMediaJSON: mediaJSON)
                == "/tmp/EPUBAssets/local-book/fig-0.png")
        // `imageAnchor` never touches the filesystem stager: no deck media
        // directory is ever created for this deck.
        #expect(
            !FileManager.default.fileExists(
                atPath: mediaRoot().appending(path: safeDeckID(deckID)).path))
    }

    @Test
    func importEscapingSymlinkImageFileThrowsAndLeavesDatabaseUnchanged() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.image.symlink.\(UUID().uuidString)"

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Symlink Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/sneaky.png")]
        )
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        defer { cleanupDeckMedia(deckID: deckID) }
        let imagesDir = bundleDir.appendingPathComponent("deck-images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let outsideTarget = bundleDir.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString).png")
        try pngBytes.write(to: outsideTarget)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }
        try FileManager.default.createSymbolicLink(
            at: imagesDir.appendingPathComponent("sneaky.png"), withDestinationURL: outsideTarget)
        let deckURL = bundleDir.appendingPathComponent("deck.echo-deck.json")
        try JSONEncoder().encode(deck).write(to: deckURL)

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL, targetAudiobookID: "local-book", db: writer)
        } throws: { error in
            guard case DeckImportError.unsafeImagePath("deck-images/sneaky.png") = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDatabaseFailureAfterStagingRollsBackPublishedImage() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block0 = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        let block1 = makeBlock(
            suffix: "s0-b1", audiobookID: "local-book", sequenceIndex: 1, text: "Second")
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block0, block1])
        let signature = EchoSourceSignature.make(records: [block0, block1])
        let deckID = "com.echo.image.dbfail.\(UUID().uuidString)"

        try writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_second_insert_image
                    BEFORE INSERT ON flashcard
                    WHEN NEW.front_text = 'FAIL-SECOND-INSERT'
                    BEGIN
                        SELECT RAISE(ABORT, 'fault injection: forced failure on card insert');
                    END
                    """)
        }

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "DB Fail Deck", sourceSignature: signature,
            cards: [
                makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/cue.png"),
                makePortableCard(sourceAnchor: "s0-b1", frontText: "FAIL-SECOND-INSERT"),
            ]
        )
        let bundleDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        defer { cleanupDeckMedia(deckID: deckID) }
        let deckURL = try writeDeckBundle(bundleDir, deck: deck, images: ["cue.png": pngBytes])

        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL, targetAudiobookID: "local-book", db: writer)
        } throws: { error in
            error is GRDB.DatabaseError
        }

        let flashcardCount = try writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?", arguments: [deckID])
        }
        #expect(flashcardCount == 0)

        let finalRoot = mediaRoot().appending(path: safeDeckID(deckID))
        #expect(!FileManager.default.fileExists(atPath: finalRoot.path))
    }

    @Test
    func importPublishFailureDiscardsStagingDirectory() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.image.publishfail.\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }

        // First import publishes `v1.png`, giving this deck a real
        // `finalRoot` directory so the second import's `publish()` takes the
        // `hadPrevious` branch (`moveItem(finalRoot -> backupRoot)`).
        let firstDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Publish Fail Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/v1.png")]
        )
        let firstDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: firstDir) }
        let firstURL = try writeDeckBundle(firstDir, deck: firstDeck, images: ["v1.png": pngBytes])
        _ = try DeckImportService().importDeckVNext(
            from: firstURL, targetAudiobookID: "local-book", db: writer)

        // Make the published `finalRoot` directory itself immutable: `mv`
        // (what `moveItem` performs on the same volume) refuses to rename or
        // delete an immutable item, so the second import's `publish()` call
        // fails at `moveItem(finalRoot -> backupRoot)` — after `stage()` has
        // already created and populated the second staging directory.
        var protectedFinalRoot = mediaRoot().appending(path: safeDeckID(deckID))
        var values = URLResourceValues()
        values.isUserImmutable = true
        try protectedFinalRoot.setResourceValues(values)
        defer {
            var clearValues = URLResourceValues()
            clearValues.isUserImmutable = false
            try? protectedFinalRoot.setResourceValues(clearValues)
        }

        let secondDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Publish Fail Deck v2", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/v2.png")]
        )
        let secondDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: secondDir) }
        let secondURL = try writeDeckBundle(
            secondDir, deck: secondDeck, images: ["v2.png": pngBytes])

        #expect(throws: (any Error).self) {
            try DeckImportService().importDeckVNext(
                from: secondURL, targetAudiobookID: "local-book", db: writer)
        }

        // The regression: without discarding on a `publish` failure, the
        // second `stage()` call's staging directory would still be sitting
        // on disk here, full of copied image bytes nobody will ever clean
        // up (`cleanupOrphanedImageStaging` only sweeps directories older
        // than 24 hours).
        try assertNoStagingDirectoriesRemain(deckID: deckID)
        // The untouched first publication is exactly as it was: `publish`
        // failed before moving anything, so `finalRoot` still holds v1.
        #expect(FileManager.default.fileExists(atPath: protectedFinalRoot.path))
    }

    @Test
    func reimportWithNewImageRemovesStaleBackupOnSuccess() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.image.reimport.\(UUID().uuidString)"
        defer { cleanupDeckMedia(deckID: deckID) }

        let firstDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Reimport Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/v1.png")]
        )
        let firstDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: firstDir) }
        let firstURL = try writeDeckBundle(firstDir, deck: firstDeck, images: ["v1.png": pngBytes])
        let firstResult = try DeckImportService().importDeckVNext(
            from: firstURL, targetAudiobookID: "local-book", db: writer)
        #expect(firstResult.imageCount == 1)
        #expect(firstResult.warningCount == 0)

        let secondDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Reimport Deck v2", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageFile: "deck-images/v2.png")]
        )
        let secondDir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: secondDir) }
        let secondURL = try writeDeckBundle(
            secondDir, deck: secondDeck, images: ["v2.png": pngBytes])
        let secondResult = try DeckImportService().importDeckVNext(
            from: secondURL, targetAudiobookID: "local-book", db: writer)

        #expect(secondResult.imageCount == 1)
        // `commit()` succeeded: the stale (v1) backup was cleaned up rather
        // than downgrading to a warning.
        #expect(secondResult.warningCount == 0)

        let safe = safeDeckID(deckID)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mediaRoot().path)) ?? []
        #expect(!entries.contains { $0.hasPrefix(".backup-\(safe)") })
        #expect(!entries.contains { $0.hasPrefix(".staging-\(safe)") })
    }

    // MARK: - Orphan cleanup

    @Test
    func cleanupRemovesStagingDirectoriesOlderThan24Hours() throws {
        let manager = FileManager.default
        let root = mediaRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staleDir = root.appendingPathComponent(".staging-cleanup-\(UUID().uuidString)")
        try manager.createDirectory(at: staleDir, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staleDir) }
        let now = Date()
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: staleDir.path)

        DeckImportService().cleanupOrphanedImageStaging(now: now)

        #expect(!manager.fileExists(atPath: staleDir.path))
    }

    @Test
    func cleanupKeepsStagingDirectoriesYoungerThan24Hours() throws {
        let manager = FileManager.default
        let root = mediaRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let freshDir = root.appendingPathComponent(".staging-cleanup-\(UUID().uuidString)")
        try manager.createDirectory(at: freshDir, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: freshDir) }
        let now = Date()
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-23 * 60 * 60)],
            ofItemAtPath: freshDir.path)

        DeckImportService().cleanupOrphanedImageStaging(now: now)

        #expect(manager.fileExists(atPath: freshDir.path))
    }

    @Test
    func cleanupRemovesBackupWhenFinalDirectoryExists() throws {
        let manager = FileManager.default
        let root = mediaRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = String(repeating: "b", count: 64)
        let finalDir = root.appendingPathComponent(safe)
        let backupDir = root.appendingPathComponent(".backup-\(safe)-\(UUID().uuidString)")
        try manager.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try manager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: finalDir)
            try? manager.removeItem(at: backupDir)
        }

        DeckImportService().cleanupOrphanedImageStaging(now: Date())

        #expect(manager.fileExists(atPath: finalDir.path))
        #expect(!manager.fileExists(atPath: backupDir.path))
    }

    @Test
    func cleanupNeverRemovesBackupWhenFinalDirectoryIsAbsent() throws {
        let manager = FileManager.default
        let root = mediaRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = String(repeating: "c", count: 64)
        let backupDir = root.appendingPathComponent(".backup-\(safe)-\(UUID().uuidString)")
        try manager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: backupDir) }

        DeckImportService().cleanupOrphanedImageStaging(now: Date())

        #expect(manager.fileExists(atPath: backupDir.path))
    }

    @Test
    func cleanupDeletionFailureDoesNotBlockOtherEntries() throws {
        let manager = FileManager.default
        let root = mediaRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let stuckDir = root.appendingPathComponent(".staging-stuck-\(UUID().uuidString)")
        let removableDir = root.appendingPathComponent(".staging-removable-\(UUID().uuidString)")
        try manager.createDirectory(at: stuckDir, withIntermediateDirectories: true)
        try manager.createDirectory(at: removableDir, withIntermediateDirectories: true)
        let protectedFile = stuckDir.appendingPathComponent("locked.png")
        manager.createFile(atPath: protectedFile.path, contents: pngBytes)
        var fileURL = protectedFile
        var values = URLResourceValues()
        values.isUserImmutable = true
        try fileURL.setResourceValues(values)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: stuckDir.path)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: removableDir.path)
        defer {
            values.isUserImmutable = false
            try? fileURL.setResourceValues(values)
            try? manager.removeItem(at: stuckDir)
            try? manager.removeItem(at: removableDir)
        }

        // Must not throw: cleanup is best-effort and silently logs.
        DeckImportService().cleanupOrphanedImageStaging(now: now)

        #expect(manager.fileExists(atPath: stuckDir.path))
        #expect(!manager.fileExists(atPath: removableDir.path))
    }
}
