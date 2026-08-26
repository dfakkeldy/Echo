// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyNarrationStatusServiceTests {
    @Test func matchingAnthologyWithNoTracksReportsZeroReadyChapters() async throws {
        let fixture = try await StatusFixture()

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 0)
        #expect(status.totalChapterCount == 2)
        #expect(status.staleSourceChapterKeys == fixture.entryIDs.map(\.uuidString))
        #expect(!status.isComplete)
    }

    @Test func oneCurrentChapterReportsPartialReadiness() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 1)
        #expect(status.totalChapterCount == 2)
        #expect(status.staleSourceChapterKeys == [fixture.entryIDs[1].uuidString])
    }

    @Test func staleSourcePathDoesNotCountAsCurrent() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)
        try await fixture.persistCurrentSegments(forEntryAt: 1, sourceText: "Older source text")

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 1)
        #expect(status.staleSourceChapterKeys == [fixture.entryIDs[1].uuidString])
    }

    @Test func allExactTracksAndDurableFilesAreComplete() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)
        try await fixture.persistCurrentSegments(forEntryAt: 1)

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 2)
        #expect(status.totalChapterCount == 2)
        #expect(status.staleSourceChapterKeys.isEmpty)
        #expect(status.isComplete)
    }

    @Test func reorderKeepsStableTracksCurrent() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)
        try await fixture.persistCurrentSegments(forEntryAt: 1)
        try fixture.reorderEntries()

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.isComplete)
        #expect(status.staleSourceChapterKeys.isEmpty)
    }

    @Test func removedChapterTrackIsIgnored() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)
        try await fixture.persistCurrentSegments(forEntryAt: 1)
        try fixture.removeSecondEntry()

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 1)
        #expect(status.totalChapterCount == 1)
        #expect(status.staleSourceChapterKeys.isEmpty)
        #expect(status.isComplete)
    }

    @Test func hiddenChapterIsExcludedFromReadinessDenominator() async throws {
        let fixture = try await StatusFixture()
        try await fixture.persistCurrentSegments(forEntryAt: 0)
        try fixture.hideSecondEntry()

        let status = try #require(
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice))

        #expect(status.readyChapterCount == 1)
        #expect(status.totalChapterCount == 1)
        #expect(status.staleSourceChapterKeys.isEmpty)
        #expect(status.isComplete)
    }

    @Test func invalidMatchingReceiptFailsClosed() async throws {
        let fixture = try await StatusFixture()
        try fixture.corruptManifestDigest()

        await #expect(throws: AnthologyNarrationReadinessError.invalidPlan) {
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice)
        }
    }

    @Test func incompleteImportedBlockSetFailsBeforeVisibleReadinessFiltering() async throws {
        let fixture = try await StatusFixture()
        try fixture.removeSecondImportedEntryWithoutRebuilding()

        await #expect(throws: AnthologyNarrationReadinessError.invalidPlan) {
            try await fixture.service.status(
                audiobookID: fixture.audiobookID, preferredVoice: fixture.preferredVoice)
        }
    }

    @Test func ordinaryBookReturnsNil() async throws {
        let database = try DatabaseService(inMemory: ())
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-status-ordinary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let status = try await AnthologyNarrationStatusService(
            db: database.writer, cacheDirectory: cacheDirectory
        ).status(audiobookID: "ordinary", preferredVoice: VoiceCatalog.default.id)

        #expect(status == nil)
    }
}

@MainActor
private final class StatusFixture {
    let database: DatabaseService
    let audiobookID = "status-anthology"
    let preferredVoice = VoiceID("af_heart")
    let entryIDs = [
        UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
    ]
    let cacheDirectory: URL
    private let anthologyID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private var revision = 1
    private var currentOrder = [0, 1]
    private var blocksByEntry: [Int: EPubBlockRecord] = [:]

    init() async throws {
        database = try DatabaseService(inMemory: ())
        cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-anthology-status-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0)",
                arguments: [audiobookID, "Fixture Anthology"])
        }
        try AnthologyDAO(db: database.writer).save(
            AnthologyRecord(
                id: anthologyID.uuidString, title: "Fixture Anthology", subtitle: nil,
                creator: nil, coverPath: nil, nextStableSlot: 2, latestBuildRevision: 0,
                createdAt: "2026-08-02T12:00:00Z", modifiedAt: "2026-08-02T12:00:00Z"))
        try replaceBlocks(order: currentOrder)
        try insertBuild(order: currentOrder)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    var service: AnthologyNarrationStatusService {
        AnthologyNarrationStatusService(db: database.writer, cacheDirectory: cacheDirectory)
    }

    func persistCurrentSegments(forEntryAt entryIndex: Int, sourceText: String? = nil) async throws
    {
        let block = try #require(blocksByEntry[entryIndex])
        let renderBlock: EPubBlockRecord
        if let sourceText {
            var stale = block
            stale.text = sourceText
            renderBlock = stale
        } else {
            renderBlock = block
        }
        let voice = effectiveVoice(forEntryAt: entryIndex)
        let chapter = NarrationChapterRenderPlan(
            chapterIndex: block.chapterIndex!, displayNumber: block.chapterIndex! + 1,
            sourceChapterKey: entryIDs[entryIndex].uuidString,
            title: "Chapter \(entryIndex + 1)", blocks: [renderBlock], voice: voice)
        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: block.chapterIndex == 0)
        let pack = await EnglishPronunciationPack.bundledOrEmpty()
        let overrides = PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
        let occurrenceOverrides = PronunciationOverrideStore.shared.occurrenceOverrides(
            forBookID: audiobookID)
        let fmEnabled =
            UserDefaults.standard.string(forKey: "narrationQAClassifier") ?? "auto" == "auto"

        for segment in segments {
            let signature = NarrationService.contentSignature(
                for: segment.blocks, includeLeadOutPad: false, overrides: overrides,
                occurrenceOverrides: occurrenceOverrides,
                normalizationMode: NarrationService.normalizationMode(fmEnabled: fmEnabled),
                pronunciationPack: pack)
            let fileName = NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID, chapterIndex: segment.chapterIndex,
                sourceChapterKey: segment.sourceChapterKey, segmentIndex: segment.segmentIndex,
                voice: segment.voice, contentSignature: signature)
            let url = cacheDirectory.appendingPathComponent(fileName)
            try Data([0x01]).write(to: url)
            let track = TrackRecord(
                id: NarrationFileNaming.trackID(
                    audiobookID: audiobookID, chapterIndex: segment.chapterIndex,
                    sourceChapterKey: segment.sourceChapterKey, segmentIndex: segment.segmentIndex),
                audiobookID: audiobookID, title: segment.chapterTitle, duration: 1,
                filePath: url.path, isEnabled: true,
                sortOrder: segment.chapterIndex * 1000 + segment.segmentIndex,
                playlistPosition: nil, narrationVoice: segment.voice.rawValue)
            try TrackDAO(db: database.writer).insertAll([track], audiobookID: audiobookID)
        }
    }

    func reorderEntries() throws {
        currentOrder = [1, 0]
        revision += 1
        try replaceBlocks(order: currentOrder)
        try updateTrackSortOrders()
        try insertBuild(order: currentOrder)
    }

    func removeSecondEntry() throws {
        currentOrder = [0]
        revision += 1
        try replaceBlocks(order: currentOrder)
        try updateTrackSortOrders()
        try insertBuild(order: currentOrder)
    }

    func hideSecondEntry() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE epub_block SET is_hidden = 1 WHERE id = ?",
                arguments: ["block-1"])
        }
    }

    func removeSecondImportedEntryWithoutRebuilding() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM epub_block WHERE audiobook_id = ? AND source_chapter_key = ?",
                arguments: [audiobookID, entryIDs[1].uuidString])
        }
    }

    func corruptManifestDigest() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE anthology_build SET manifest_sha256 = ? WHERE audiobook_id = ?",
                arguments: [String(repeating: "0", count: 64), audiobookID])
        }
    }

    private func replaceBlocks(order: [Int]) throws {
        try EPubBlockDAO(db: database.writer).deleteAll(for: audiobookID)
        blocksByEntry = [:]
        let blocks = order.enumerated().map { chapterIndex, entryIndex in
            let block = EPubBlockRecord(
                id: "block-\(entryIndex)", audiobookID: audiobookID,
                spineHref: "chapter-\(entryIndex).xhtml", spineIndex: chapterIndex, blockIndex: 0,
                sequenceIndex: chapterIndex, blockKind: "paragraph",
                text: "Current source text for entry \(entryIndex).", htmlContent: nil,
                cardColor: nil, chapterThemeColor: nil, imagePath: nil,
                chapterIndex: chapterIndex, isHidden: false, hiddenReason: nil,
                isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
                narrationText: nil, sourceChapterKey: entryIDs[entryIndex].uuidString,
                createdAt: nil, modifiedAt: nil)
            blocksByEntry[entryIndex] = block
            return block
        }
        try EPubBlockDAO(db: database.writer).insertAll(blocks)
    }

    private func updateTrackSortOrders() throws {
        try database.writer.write { db in
            for (chapterIndex, entryIndex) in currentOrder.enumerated() {
                let id = NarrationFileNaming.trackID(
                    audiobookID: audiobookID, chapterIndex: chapterIndex,
                    sourceChapterKey: entryIDs[entryIndex].uuidString, segmentIndex: 0)
                try db.execute(
                    sql: "UPDATE track SET sort_order = ? WHERE id = ?",
                    arguments: [chapterIndex * 1000, id])
            }
        }
    }

    private func insertBuild(order: [Int]) throws {
        let chapters = order.enumerated().map { manifestOrder, entryIndex in
            let articleBlocks = [
                ArticleBlock(
                    id: "article-block-\(entryIndex)", stableOrdinal: 0, kind: .paragraph,
                    text: "Current source text for entry \(entryIndex).", sourceURL: nil,
                    imageCandidateURL: nil, caption: nil, codeLanguage: nil)
            ]
            return AnthologyChapterManifest(
                entryID: entryIDs[entryIndex],
                captureID: UUID(
                    uuidString: "00000000-0000-0000-0000-00000000000\(entryIndex + 1)")!,
                articleRevisionID: UUID(
                    uuidString: "11111111-1111-1111-1111-11111111111\(entryIndex + 1)")!,
                stableSlot: entryIndex, order: manifestOrder, title: "Chapter \(entryIndex + 1)",
                author: nil, siteName: nil,
                sourceURL: URL(string: "https://example.test/\(entryIndex)")!,
                capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
                voiceID: entryIndex == 1 ? "bf_emma" : nil, blocks: articleBlocks,
                readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: articleBlocks))
        }
        let manifest = AnthologyBuildManifest(
            schemaVersion: 1, anthologyID: anthologyID, revision: revision,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)", title: "Fixture Anthology",
            subtitle: nil, creator: "Various Authors", language: "en", coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000), chapters: chapters)
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString, anthologyID: anthologyID.uuidString, revision: revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            epubPath: nil, epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID, status: "succeeded", errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try database.writer.write { db in try build.insert(db) }
    }

    private func effectiveVoice(forEntryAt entryIndex: Int) -> VoiceID {
        entryIndex == 1 ? VoiceID("bf_emma") : preferredVoice
    }
}
