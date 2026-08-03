// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

/// Covers the chapter ordering + titling step of the audiobook exporter
/// — specifically the >=10 chapter alignment bug, where a lexicographic file sort
/// (ch0, ch1, ch10, ch11, ch2…) silently attached titles to the wrong chapters
/// when titles were looked up by enumerated file position.
@Suite struct NarrationExportOrderingTests {

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    private func lexicographicFiles(count: Int) -> [URL] {
        (0..<count)
            .map { "book_id-ch\($0)-af_heart-v4.m4a" }
            .sorted()
            .map(file)
    }

    @Test func ordersFilesByNumericChapterIndexNotLexicographically() {
        let files = lexicographicFiles(count: 12)
        let items = NarrationCacheSource.orderedItems(files: files, titlesByChapterIndex: [:])
        let recovered = items.map {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent)
        }
        #expect(recovered == Array(0..<12))
    }

    @Test func attachesTitlesByChapterIndexAcrossDoubleDigitBoundary() {
        let titles = Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, "Title \($0)") })
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 12), titlesByChapterIndex: titles)
        for item in items {
            let index = NarrationFileNaming.chapterIndex(fromFileName: item.url.lastPathComponent)
            #expect(item.title == "Title \(index!)")
        }
        let ch10 = items.first {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent) == 10
        }
        #expect(ch10?.title == "Title 10")
    }

    @Test func fallsBackToPositionalLabelWhenTitleMissing() {
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 3), titlesByChapterIndex: [:])
        #expect(items.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    @Test func ignoresGapsAndExtraTitleKeys() {
        let files = [file("book_id-ch5-af_heart-v4.m4a"), file("book_id-ch0-af_heart-v4.m4a")]
        let items = NarrationCacheSource.orderedItems(
            files: files, titlesByChapterIndex: [0: "Prologue", 5: "Finale", 99: "Stray"])
        #expect(items.map(\.title) == ["Prologue", "Finale"])
    }

    @MainActor
    @Test func anthologyExportUsesPersistedStableTracksInCurrentSortOrder() async throws {
        let fixture = try await NarrationExportAnthologyFixture()
        try await fixture.persistCurrentSegment(entryIndex: 0, sortOrder: 0)
        try await fixture.persistCurrentSegment(entryIndex: 1, sortOrder: 1000)
        try fixture.updateSortOrders([0: 1000, 1: 0])

        let items = try await NarrationCacheSource(
            audiobookID: fixture.audiobookID,
            cacheDirectory: fixture.cacheDirectory,
            databaseWriter: fixture.database.writer,
            preferredVoice: fixture.preferredVoice
        ).items()

        #expect(items.map(\.title) == ["Chapter 2", "Chapter 1"])
        #expect(items.allSatisfy { $0.url.lastPathComponent.contains("-ck") })
        #expect(items.allSatisfy { $0.emitsChapterMarker })
    }

    @MainActor
    @Test func anthologyExportMarksOnlyFirstSegmentAndUsesPersistedFileNames() async throws {
        let fixture = try await NarrationExportAnthologyFixture()
        try fixture.makeFirstChapterMultiSegment()
        try await fixture.persistCurrentSegment(entryIndex: 0, sortOrder: 0)
        try await fixture.persistCurrentSegment(entryIndex: 1, sortOrder: 1000)

        let items = try await NarrationCacheSource(
            audiobookID: fixture.audiobookID,
            cacheDirectory: fixture.cacheDirectory,
            databaseWriter: fixture.database.writer,
            preferredVoice: fixture.preferredVoice
        ).items()

        #expect(items.map(\.emitsChapterMarker) == [true, false, true])
        #expect(items.map(\.url) == fixture.persistedURLs)
    }

    @MainActor
    @Test func anthologyExportRejectsMissingChapterWithoutLegacyGlobFallback() async throws {
        let fixture = try await NarrationExportAnthologyFixture()
        try await fixture.persistCurrentSegment(entryIndex: 0, sortOrder: 0)
        let orphan = fixture.cacheDirectory.appendingPathComponent(
            NarrationFileNaming.chapterFileName(
                audiobookID: fixture.audiobookID, chapterIndex: 1,
                voice: fixture.preferredVoice))
        try Data([0x01]).write(to: orphan)

        await #expect(
            throws: AnthologyNarrationReadinessError.incomplete(chapterDisplayNumbers: [2])
        ) {
            try await NarrationCacheSource(
                audiobookID: fixture.audiobookID,
                cacheDirectory: fixture.cacheDirectory,
                databaseWriter: fixture.database.writer,
                preferredVoice: fixture.preferredVoice
            ).items()
        }
    }
}

@MainActor
private final class NarrationExportAnthologyFixture {
    let database: DatabaseService
    let audiobookID = "export-anthology"
    let preferredVoice = VoiceID("af_heart")
    let cacheDirectory: URL
    private let anthologyID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let entryIDs = [
        UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
    ]
    private var blocksByEntry: [[EPubBlockRecord]] = []
    private(set) var persistedURLs: [URL] = []

    init() async throws {
        database = try DatabaseService(inMemory: ())
        cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-export-anthology-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0)",
                arguments: [audiobookID, "Export Anthology"])
        }
        try AnthologyDAO(db: database.writer).save(
            AnthologyRecord(
                id: anthologyID.uuidString, title: "Export Anthology", subtitle: nil,
                creator: nil, coverPath: nil, nextStableSlot: 2, latestBuildRevision: 0,
                createdAt: "2026-08-02T12:00:00Z", modifiedAt: "2026-08-02T12:00:00Z"))
        blocksByEntry = entryIDs.enumerated().map { index, entryID in
            [block(entryIndex: index, entryID: entryID, blockIndex: 0)]
        }
        try EPubBlockDAO(db: database.writer).insertAll(blocksByEntry.flatMap { $0 })
        try insertBuild()
    }

    deinit { try? FileManager.default.removeItem(at: cacheDirectory) }

    func makeFirstChapterMultiSegment() throws {
        blocksByEntry[0] = [
            block(
                entryIndex: 0, entryID: entryIDs[0], blockIndex: 0,
                text: String(repeating: "A", count: 120)),
            block(entryIndex: 0, entryID: entryIDs[0], blockIndex: 1, text: "Second segment."),
        ]
        try EPubBlockDAO(db: database.writer).deleteAll(for: audiobookID)
        try EPubBlockDAO(db: database.writer).insertAll(blocksByEntry.flatMap { $0 })
    }

    func persistCurrentSegment(entryIndex: Int, sortOrder: Int) async throws {
        let blocks = blocksByEntry[entryIndex]
        let voice = entryIndex == 1 ? VoiceID("bf_emma") : preferredVoice
        let chapter = NarrationChapterRenderPlan(
            chapterIndex: entryIndex, displayNumber: entryIndex + 1,
            sourceChapterKey: entryIDs[entryIndex].uuidString,
            title: "Chapter \(entryIndex + 1)", blocks: blocks, voice: voice)
        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: entryIndex == 0)
        let pack = await EnglishPronunciationPack.bundledOrEmpty()
        for segment in segments {
            let signature = NarrationService.contentSignature(
                for: segment.blocks, includeLeadOutPad: false,
                overrides: PronunciationOverrideStore.shared.overrides(forBookID: audiobookID),
                occurrenceOverrides: PronunciationOverrideStore.shared.occurrenceOverrides(
                    forBookID: audiobookID),
                normalizationMode: NarrationService.normalizationMode(
                    fmEnabled: UserDefaults.standard.string(forKey: "narrationQAClassifier")
                        ?? "auto"
                        == "auto"),
                pronunciationPack: pack)
            let url = cacheDirectory.appendingPathComponent(
                NarrationFileNaming.segmentFileName(
                    audiobookID: audiobookID, chapterIndex: entryIndex,
                    sourceChapterKey: entryIDs[entryIndex].uuidString,
                    segmentIndex: segment.segmentIndex,
                    voice: voice, contentSignature: signature))
            try Data([0x01]).write(to: url)
            persistedURLs.append(url)
            try TrackDAO(db: database.writer).insertAll(
                [
                    TrackRecord(
                        id: NarrationFileNaming.trackID(
                            audiobookID: audiobookID, chapterIndex: entryIndex,
                            sourceChapterKey: entryIDs[entryIndex].uuidString,
                            segmentIndex: segment.segmentIndex),
                        audiobookID: audiobookID, title: "Old title", duration: 1,
                        filePath: url.path, isEnabled: true,
                        sortOrder: sortOrder + segment.segmentIndex,
                        playlistPosition: nil, narrationVoice: voice.rawValue)
                ],
                audiobookID: audiobookID)
        }
    }

    func updateSortOrders(_ sortOrdersByEntryIndex: [Int: Int]) throws {
        try database.writer.write { db in
            for (entryIndex, sortOrder) in sortOrdersByEntryIndex {
                try db.execute(
                    sql: "UPDATE track SET sort_order = ? WHERE id = ?",
                    arguments: [
                        sortOrder,
                        NarrationFileNaming.trackID(
                            audiobookID: audiobookID, chapterIndex: entryIndex,
                            sourceChapterKey: entryIDs[entryIndex].uuidString, segmentIndex: 0),
                    ])
            }
        }
    }

    private func block(
        entryIndex: Int,
        entryID: UUID,
        blockIndex: Int,
        text: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "export-block-\(entryIndex)-\(blockIndex)", audiobookID: audiobookID,
            spineHref: "chapter-\(entryIndex).xhtml", spineIndex: entryIndex,
            blockIndex: blockIndex, sequenceIndex: entryIndex * 100 + blockIndex,
            blockKind: "paragraph", text: text ?? "Export chapter \(entryIndex + 1).",
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: entryIndex, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            narrationText: nil, sourceChapterKey: entryID.uuidString,
            createdAt: nil, modifiedAt: nil)
    }

    private func insertBuild() throws {
        let chapters = entryIDs.enumerated().map { index, entryID in
            let articleBlocks = [
                ArticleBlock(
                    id: "article-export-\(index)", stableOrdinal: 0, kind: .paragraph,
                    text: "Export chapter \(index + 1).", sourceURL: nil,
                    imageCandidateURL: nil, caption: nil, codeLanguage: nil)
            ]
            return AnthologyChapterManifest(
                entryID: entryID,
                captureID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                articleRevisionID: UUID(
                    uuidString: "11111111-1111-1111-1111-11111111111\(index + 1)")!,
                stableSlot: index, order: index, title: "Chapter \(index + 1)", author: nil,
                siteName: nil, sourceURL: URL(string: "https://example.test/\(index)")!,
                capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
                voiceID: index == 1 ? "bf_emma" : nil, blocks: articleBlocks,
                readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: articleBlocks))
        }
        let manifest = AnthologyBuildManifest(
            schemaVersion: 1, anthologyID: anthologyID, revision: 1,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)", title: "Export Anthology",
            subtitle: nil, creator: "Various Authors", language: "en", coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000), chapters: chapters)
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString, anthologyID: anthologyID.uuidString, revision: 1,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            epubPath: nil, epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID, status: "succeeded", errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try database.writer.write { db in try build.insert(db) }
    }
}
