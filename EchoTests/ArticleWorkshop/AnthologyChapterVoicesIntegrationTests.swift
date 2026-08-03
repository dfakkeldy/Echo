// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyChapterVoicesIntegrationTests {
    @Test func threeVoiceWorkflowPreservesStableIdentityAndFailsClosed() async throws {
        let fixture = try await ThreeVoiceAnthologyFixture()
        let entryA = fixture.baseManifest.chapters[0].entryID.uuidString
        let entryB = fixture.baseManifest.chapters[1].entryID.uuidString
        let entryC = fixture.baseManifest.chapters[2].entryID.uuidString
        var synthesisCallCounts: [Int] = []

        let initial = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        synthesisCallCounts.append(initial.synthesisCallCount)

        #expect(initial.segments.map(\.sourceChapterKey) == [entryA, entryB, entryC])
        #expect(initial.segments.map(\.voice.rawValue) == ["af_heart", "bf_emma", "am_michael"])
        #expect(initial.tracks.map(\.narrationVoice) == ["af_heart", "bf_emma", "am_michael"])
        #expect(initial.tracks.map(\.sortOrder) == [0, 1000, 2000])
        #expect(initial.fileURLsBySourceKey.values.allSatisfy { fixture.fileExists(at: $0) })

        let chapterTwoChanged = fixture.manifest(
            from: fixture.baseManifest,
            revision: 2,
            voiceByEntryID: [entryB: "af_nicole"])
        try fixture.install(chapterTwoChanged)
        let explicitOverride = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        synthesisCallCounts.append(explicitOverride.synthesisCallCount)

        #expect(explicitOverride.synthesizedVoices == ["af_nicole"])
        #expect(explicitOverride.fileURLsBySourceKey[entryA] == initial.fileURLsBySourceKey[entryA])
        #expect(explicitOverride.fileURLsBySourceKey[entryC] == initial.fileURLsBySourceKey[entryC])
        #expect(explicitOverride.fileURLsBySourceKey[entryB] != initial.fileURLsBySourceKey[entryB])
        #expect(explicitOverride.tracks.map(\.narrationVoice) == ["af_heart", "af_nicole", "am_michael"])

        let reordered = fixture.manifest(
            from: chapterTwoChanged,
            revision: 3,
            orderedEntryIDs: [entryC, entryA, entryB])
        try fixture.install(reordered)
        let reorderedRun = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        synthesisCallCounts.append(reorderedRun.synthesisCallCount)

        #expect(reorderedRun.fileURLsBySourceKey == explicitOverride.fileURLsBySourceKey)
        #expect(reorderedRun.tracks.map(\.sortOrder) == [0, 1000, 2000])
        #expect(reorderedRun.sourceKeysInTrackOrder == [entryC, entryA, entryB])
        let savedEntryBURL = try #require(explicitOverride.fileURLsBySourceKey[entryB])
        #expect(
            NarrationResumeResolver.target(
                fromLastTrackURL: savedEntryBURL,
                plans: reorderedRun.chapters,
                isAnthology: true) == .sourceChapterKey(entryB))
        #expect(
            NarrationSegmentPlanner.resume(
                reorderedRun.segments,
                startingAtSourceChapterKey: entryB
            ).first?.sourceChapterKey == entryB)

        let exportItems = try await fixture.exportItems(preferredVoice: VoiceID("af_heart"))
        #expect(exportItems.map(\.emitsChapterMarker) == [true, true, true])
        #expect(
            exportItems.map(\.title) == [
                "ch. 1: Rain on Red Stone",
                "ch. 2: Three Lanterns at Dawn",
                "ch. 3: The Clockmaker’s Finch",
            ])

        let preferredVoiceChanged = try await fixture.run(preferredVoice: VoiceID("af_bella"))
        synthesisCallCounts.append(preferredVoiceChanged.synthesisCallCount)

        #expect(preferredVoiceChanged.synthesizedVoices == ["af_bella"])
        #expect(preferredVoiceChanged.fileURLsBySourceKey[entryA] != reorderedRun.fileURLsBySourceKey[entryA])
        #expect(preferredVoiceChanged.fileURLsBySourceKey[entryB] == reorderedRun.fileURLsBySourceKey[entryB])
        #expect(preferredVoiceChanged.fileURLsBySourceKey[entryC] == reorderedRun.fileURLsBySourceKey[entryC])
        #expect(preferredVoiceChanged.tracks.map(\.narrationVoice) == ["am_michael", "af_bella", "af_nicole"])

        let provenAudioURLs = Set(preferredVoiceChanged.fileURLsBySourceKey.values)
        try fixture.corruptLatestReceiptDigest()
        let callsBeforeInvalidReceipt = fixture.totalSynthesisCallCount
        await #expect(throws: AnthologyBuildManifestValidationError.invalidReceipt) {
            try await fixture.run(preferredVoice: VoiceID("af_bella"))
        }
        synthesisCallCounts.append(fixture.totalSynthesisCallCount - callsBeforeInvalidReceipt)

        #expect(provenAudioURLs.allSatisfy { fixture.fileExists(at: $0) })
        #expect(synthesisCallCounts == [3, 1, 0, 1, 0])
    }
}

@MainActor
private final class ThreeVoiceAnthologyFixture {
    struct RunResult {
        let synthesisCallCount: Int
        let synthesizedVoices: [String]
        let chapters: [NarrationChapterRenderPlan]
        let segments: [NarrationSegmentPlanner.PlannedSegment]
        let tracks: [TrackRecord]
        let fileURLsBySourceKey: [String: URL]
        let sourceKeysInTrackOrder: [String]
    }

    let database: DatabaseService
    let baseManifest: AnthologyBuildManifest
    let cacheDirectory: URL
    private let audiobookID = "three-voice-anthology-\(UUID().uuidString)"
    private let tts = MockTTSEngine(secondsPerChar: 0.1)
    private let audioWriter = DurableFixtureAudioWriter()
    private let pronunciationPack: EnglishPronunciationPack

    init() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/three-voice-anthology-manifest.json")
        let data = try Data(contentsOf: fixtureURL)
        baseManifest = try JSONDecoder.articleWorkshop.decode(
            AnthologyBuildManifest.self,
            from: data)
        database = try DatabaseService(inMemory: ())
        pronunciationPack = await EnglishPronunciationPack.bundledOrEmpty()
        cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-three-voice-anthology-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true)
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0)",
                arguments: [audiobookID, baseManifest.title])
        }
        try AnthologyDAO(db: database.writer).save(
            AnthologyRecord(
                id: baseManifest.anthologyID.uuidString,
                title: baseManifest.title,
                subtitle: baseManifest.subtitle,
                creator: baseManifest.creator,
                coverPath: nil,
                nextStableSlot: baseManifest.chapters.count,
                latestBuildRevision: 0,
                createdAt: "2026-08-02T12:00:00.000Z",
                modifiedAt: "2026-08-02T12:00:00.000Z"))
        try install(baseManifest)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    var totalSynthesisCallCount: Int { tts.calls.count }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func run(preferredVoice: VoiceID) async throws -> RunResult {
        let callsBeforeRun = tts.calls.count
        let blocks = try EPubBlockDAO(db: database.writer).visibleBlocks(for: audiobookID)
        let plannedChapters = NarrationChapterPlanner.plan(from: blocks)
        let service = NarrationService(
            db: database.writer,
            audiobookID: audiobookID,
            tts: tts,
            audioWriter: audioWriter,
            cacheDirectory: cacheDirectory,
            state: NarrationState(),
            pronunciationPack: pronunciationPack)
        let existingFileNames = Set(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))
        let preparation = try await NarrationPlaybackPlanPreparation.prepare(
            chapters: plannedChapters,
            allChapters: plannedChapters,
            preferredVoice: preferredVoice,
            resolveManifest: {
                try AnthologyNarrationManifestResolver(db: self.database.writer).resolve(
                    audiobookID: self.audiobookID)
            },
            existingDurableFileNames: existingFileNames,
            expectedFileName: { segment in
                await service.segmentCacheURL(
                    chapterIndex: segment.chapterIndex,
                    sourceChapterKey: segment.sourceChapterKey,
                    segmentIndex: segment.segmentIndex,
                    blocks: segment.blocks,
                    voice: segment.voice).lastPathComponent
            },
            cleanup: { expectedFileNames in
                let bookPrefix = "\(NarrationFileNaming.safeToken(self.audiobookID))-"
                for stale in NarrationCacheStore.staleFiles(
                    Array(existingFileNames),
                    bookPrefix: bookPrefix,
                    expectedDurableFileNames: expectedFileNames)
                {
                    try FileManager.default.removeItem(
                        at: self.cacheDirectory.appendingPathComponent(stale))
                }
            })

        var fileURLsBySourceKey: [String: URL] = [:]
        for segment in preparation.segments {
            let fileURL = await service.segmentCacheURL(
                chapterIndex: segment.chapterIndex,
                sourceChapterKey: segment.sourceChapterKey,
                segmentIndex: segment.segmentIndex,
                blocks: segment.blocks,
                voice: segment.voice)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try await service.updateCachedNarrationTitle(
                    chapterIndex: segment.chapterIndex,
                    sourceChapterKey: segment.sourceChapterKey,
                    chapterDisplayNumber: segment.chapterDisplayNumber,
                    segmentIndex: segment.segmentIndex,
                    blocks: segment.blocks,
                    voice: segment.voice,
                    chapterTitle: segment.chapterTitle)
            } else {
                try await service.renderSegment(
                    chapterIndex: segment.chapterIndex,
                    sourceChapterKey: segment.sourceChapterKey,
                    chapterDisplayNumber: segment.chapterDisplayNumber,
                    segmentIndex: segment.segmentIndex,
                    blocks: segment.blocks,
                    voice: segment.voice,
                    chapterTitle: segment.chapterTitle)
            }
            fileURLsBySourceKey[try #require(segment.sourceChapterKey)] = fileURL
        }

        let tracks = try TrackDAO(db: database.writer).tracks(for: audiobookID)
        let keyByTrackID = Dictionary(
            uniqueKeysWithValues: preparation.segments.compactMap { segment in
                segment.sourceChapterKey.map {
                    (
                        NarrationFileNaming.trackID(
                            audiobookID: audiobookID,
                            chapterIndex: segment.chapterIndex,
                            sourceChapterKey: $0,
                            segmentIndex: segment.segmentIndex),
                        $0
                    )
                }
            })
        let newCalls = Array(tts.calls[callsBeforeRun...])
        return RunResult(
            synthesisCallCount: newCalls.count,
            synthesizedVoices: newCalls.map(\.voice.rawValue),
            chapters: preparation.chapters,
            segments: preparation.segments,
            tracks: tracks,
            fileURLsBySourceKey: fileURLsBySourceKey,
            sourceKeysInTrackOrder: tracks.compactMap { keyByTrackID[$0.id] })
    }

    func exportItems(preferredVoice: VoiceID) async throws -> [ExportItem] {
        try await NarrationCacheSource(
            audiobookID: audiobookID,
            cacheDirectory: cacheDirectory,
            databaseWriter: database.writer,
            preferredVoice: preferredVoice
        ).items()
    }

    func install(_ manifest: AnthologyBuildManifest) throws {
        try EPubBlockDAO(db: database.writer).deleteAll(for: audiobookID)
        let blocks = manifest.chapters.flatMap { chapter in
            chapter.blocks.enumerated().map { blockIndex, block in
                EPubBlockRecord(
                    id: "\(audiobookID)-\(block.id)",
                    audiobookID: audiobookID,
                    spineHref: "chapter-\(chapter.stableSlot).xhtml",
                    spineIndex: chapter.order,
                    blockIndex: blockIndex,
                    sequenceIndex: chapter.order * 100 + blockIndex,
                    blockKind: block.kind.rawValue,
                    text: block.text,
                    htmlContent: nil,
                    cardColor: nil,
                    chapterThemeColor: nil,
                    imagePath: nil,
                    chapterIndex: chapter.order,
                    isHidden: false,
                    hiddenReason: nil,
                    isFrontMatter: false,
                    wordCount: nil,
                    markers: nil,
                    textFormats: nil,
                    narrationText: nil,
                    sourceChapterKey: chapter.entryID.uuidString,
                    createdAt: nil,
                    modifiedAt: nil)
            }
        }
        try EPubBlockDAO(db: database.writer).insertAll(blocks)

        let manifestData = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString,
            anthologyID: manifest.anthologyID.uuidString,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: manifestData, as: UTF8.self),
            manifestSHA256: sha256(manifestData),
            epubPath: nil,
            epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID,
            status: "succeeded",
            errorCode: nil,
            createdAt: "2026-08-02T12:00:0\(manifest.revision).000Z")
        try database.writer.write { db in try build.insert(db) }
    }

    func corruptLatestReceiptDigest() throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE anthology_build
                    SET manifest_sha256 = ?
                    WHERE audiobook_id = ?
                      AND revision = (
                          SELECT MAX(revision) FROM anthology_build WHERE audiobook_id = ?
                      )
                    """,
                arguments: [String(repeating: "0", count: 64), audiobookID, audiobookID])
        }
    }

    func manifest(
        from source: AnthologyBuildManifest,
        revision: Int,
        voiceByEntryID: [String: String?] = [:],
        orderedEntryIDs: [String]? = nil
    ) -> AnthologyBuildManifest {
        let chaptersByID = Dictionary(
            uniqueKeysWithValues: source.chapters.map { ($0.entryID.uuidString, $0) })
        let ids = orderedEntryIDs ?? source.chapters.map(\.entryID.uuidString)
        let chapters = ids.enumerated().compactMap { order, entryID -> AnthologyChapterManifest? in
            guard let chapter = chaptersByID[entryID] else { return nil }
            let selectedVoice = voiceByEntryID.keys.contains(entryID)
                ? voiceByEntryID[entryID]!
                : chapter.voiceID
            return AnthologyChapterManifest(
                entryID: chapter.entryID,
                captureID: chapter.captureID,
                articleRevisionID: chapter.articleRevisionID,
                stableSlot: chapter.stableSlot,
                order: order,
                title: chapter.title,
                author: chapter.author,
                siteName: chapter.siteName,
                sourceURL: chapter.sourceURL,
                capturedAt: chapter.capturedAt,
                voiceID: selectedVoice,
                blocks: chapter.blocks,
                readableContentSHA256: chapter.readableContentSHA256)
        }
        return AnthologyBuildManifest(
            schemaVersion: source.schemaVersion,
            anthologyID: source.anthologyID,
            revision: revision,
            epubIdentifier: source.epubIdentifier,
            title: source.title,
            subtitle: source.subtitle,
            creator: source.creator,
            language: source.language,
            coverPath: source.coverPath,
            modifiedAt: source.modifiedAt,
            chapters: chapters)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class DurableFixtureAudioWriter: AudioFileWriting, @unchecked Sendable {
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        let stream = try makeStream(to: url, sampleRate: chunks.first?.sampleRate ?? 24_000)
        for chunk in chunks {
            try await stream.append(chunk)
        }
        return try await stream.finalize()
    }

    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("synthetic-audio".utf8).write(to: url)
        return DurableFixtureAudioStream()
    }
}

private final class DurableFixtureAudioStream: AudioFileStream, @unchecked Sendable {
    private var duration: TimeInterval = 0

    func append(_ chunk: TTSChunk) async throws {
        duration += chunk.duration
    }

    func finalize() async throws -> TimeInterval {
        duration
    }
}
