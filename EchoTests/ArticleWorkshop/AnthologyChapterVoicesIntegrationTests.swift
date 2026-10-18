// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyChapterVoicesIntegrationTests {
    @Test func threeVoiceWorkflowPreservesStableIdentityAndFailsClosed() async throws {
        let fixture = try await ThreeVoiceAnthologyFixture()
        defer { fixture.remove() }
        let entryA = fixture.baseManifest.chapters[0].entryID.uuidString
        let entryB = fixture.baseManifest.chapters[1].entryID.uuidString
        let entryC = fixture.baseManifest.chapters[2].entryID.uuidString
        var renderCallCounts: [Int] = []

        let initial = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        renderCallCounts.append(initial.renderCallCount)

        #expect(initial.importedSourceChapterKeys == [entryA, entryB, entryC])
        #expect(initial.narrationRender == .complete)
        #expect(initial.persistedVoices == ["af_heart", "bf_emma", "am_michael"])
        #expect(initial.effectiveDefaultVoice == VoiceID("af_heart"))
        #expect(initial.voiceOverrideCount == 2)
        #expect(initial.tracks.map(\.sortOrder) == [0, 1000, 2000])
        #expect(initial.fileURLsBySourceKey.values.allSatisfy { fixture.fileExists(at: $0) })
        #expect(
            initial.fileURLsBySourceKey.values.allSatisfy {
                $0.deletingLastPathComponent() == fixture.cacheDirectory
            })

        let chapterTwoChanged = fixture.manifest(
            from: fixture.baseManifest,
            revision: 2,
            voiceByEntryID: [entryB: "af_nicole"])
        try await fixture.install(chapterTwoChanged)
        let explicitOverride = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        renderCallCounts.append(explicitOverride.renderCallCount)

        #expect(explicitOverride.synthesizedVoices == ["af_nicole"])
        #expect(explicitOverride.fileURLsBySourceKey[entryA] == initial.fileURLsBySourceKey[entryA])
        #expect(explicitOverride.fileURLsBySourceKey[entryC] == initial.fileURLsBySourceKey[entryC])
        #expect(explicitOverride.fileURLsBySourceKey[entryB] != initial.fileURLsBySourceKey[entryB])
        #expect(explicitOverride.persistedVoices == ["af_heart", "af_nicole", "am_michael"])

        let savedEntryBURL = try #require(explicitOverride.fileURLsBySourceKey[entryB])
        fixture.model.persistence.saveLastTrack(
            for: fixture.audiobookID,
            trackId: savedEntryBURL.absoluteString)

        let reordered = fixture.manifest(
            from: chapterTwoChanged,
            revision: 3,
            orderedEntryIDs: [entryC, entryA, entryB])
        try await fixture.install(reordered)
        let reorderedRun = try await fixture.run(preferredVoice: VoiceID("af_heart"))
        renderCallCounts.append(reorderedRun.renderCallCount)

        #expect(reorderedRun.fileURLsBySourceKey == explicitOverride.fileURLsBySourceKey)
        #expect(reorderedRun.tracks.map(\.sortOrder) == [0, 1000, 2000])
        #expect(reorderedRun.persistedSourceKeysInTrackOrder == [entryC, entryA, entryB])
        #expect(reorderedRun.playbackQueueSourceKeys == [entryC, entryA, entryB])
        #expect(reorderedRun.currentIndex == 2)
        #expect(reorderedRun.currentTrackURL == savedEntryBURL)

        let exportItems = try await fixture.exportItems(preferredVoice: VoiceID("af_heart"))
        #expect(exportItems.map(\.emitsChapterMarker) == [true, true, true])
        #expect(
            exportItems.map(\.title) == [
                "ch. 1: Rain on Red Stone",
                "ch. 2: Three Lanterns at Dawn",
                "ch. 3: The Clockmaker’s Finch",
            ])

        let preferredVoiceChanged = try await fixture.run(preferredVoice: VoiceID("af_bella"))
        renderCallCounts.append(preferredVoiceChanged.renderCallCount)

        #expect(preferredVoiceChanged.synthesizedVoices == ["af_bella"])
        #expect(
            preferredVoiceChanged.fileURLsBySourceKey[entryA]
                != reorderedRun.fileURLsBySourceKey[entryA])
        #expect(
            preferredVoiceChanged.fileURLsBySourceKey[entryB]
                == reorderedRun.fileURLsBySourceKey[entryB])
        #expect(
            preferredVoiceChanged.fileURLsBySourceKey[entryC]
                == reorderedRun.fileURLsBySourceKey[entryC])
        #expect(preferredVoiceChanged.persistedVoices == ["am_michael", "af_bella", "af_nicole"])
        #expect(preferredVoiceChanged.effectiveDefaultVoice == VoiceID("af_bella"))

        let provenAudioURLs = Set(preferredVoiceChanged.fileURLsBySourceKey.values)
        let staleSentinel = try fixture.createStaleCacheSentinel()
        #expect(
            fixture.normalCleanupWouldDelete(
                staleSentinel,
                whileKeeping: provenAudioURLs))
        try fixture.corruptLatestReceiptDigest()
        let invalidReceiptRun = try await fixture.run(preferredVoice: VoiceID("af_bella"))
        renderCallCounts.append(invalidReceiptRun.renderCallCount)

        guard case .failed(let message) = invalidReceiptRun.narrationRender else {
            Issue.record("Expected invalid narration plan to leave a visible render failure.")
            return
        }
        #expect(
            message
                == "Rebuild this anthology to refresh its narration plan, then try again.")
        #expect(invalidReceiptRun.narrationPlayback != .completed)
        let failureEvent = try #require(invalidReceiptRun.narrationEvents.last)
        #expect(failureEvent.category == .error)
        #expect(failureEvent.severity == .error)
        #expect(failureEvent.descriptor.developerMessage == "render failed type=plan-validation")
        #expect(failureEvent.descriptor.privateDetail == nil)
        #expect(invalidReceiptRun.rawSynthesisCallCount == 0)
        #expect(fixture.fileExists(at: staleSentinel))
        #expect(provenAudioURLs.allSatisfy { fixture.fileExists(at: $0) })
        #expect(renderCallCounts == [3, 1, 0, 1, 0])
    }
}

@MainActor
private final class ThreeVoiceAnthologyFixture {
    struct RunResult {
        let renderCallCount: Int
        let rawSynthesisCallCount: Int
        let synthesizedVoices: [String]
        let importedSourceChapterKeys: [String]
        let tracks: [TrackRecord]
        let persistedVoices: [String]
        let fileURLsBySourceKey: [String: URL]
        let persistedSourceKeysInTrackOrder: [String]
        let playbackQueueSourceKeys: [String]
        let currentIndex: Int
        let currentTrackURL: URL?
        let effectiveDefaultVoice: VoiceID?
        let voiceOverrideCount: Int
        let narrationRender: NarrationRenderActivity
        let narrationPlayback: NarrationPlaybackActivity
        let narrationEvents: [NarrationEvent]
    }

    let database: DatabaseService
    let baseManifest: AnthologyBuildManifest
    let cacheDirectory: URL
    let audiobookID: String
    let model = PlayerModel()
    private let root: URL
    private let workshopRoot: URL
    private let bookDirectory: URL
    private let tts = MockTTSEngine(secondsPerChar: 0.1)
    private let audioWriter = FixtureAudioWriter()

    init() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/three-voice-anthology-manifest.json")
        let data = try Data(contentsOf: fixtureURL)
        baseManifest = try JSONDecoder.articleWorkshop.decode(
            AnthologyBuildManifest.self,
            from: data)
        database = try DatabaseService(inMemory: ())
        root = URL(
            fileURLWithPath: "/tmp/echo-3v-\(UUID().uuidString)",
            isDirectory: true)
        workshopRoot = root.appending(path: "Workshop", directoryHint: .isDirectory)
        bookDirectory = root.appending(path: "Book", directoryHint: .isDirectory)
        cacheDirectory = root.appending(path: "Narration", directoryHint: .isDirectory)
        for directory in [workshopRoot, bookDirectory, cacheDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        audiobookID = bookDirectory.absoluteString
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
        model.databaseService = database
        model.folderURL = bookDirectory
        model.narrationTTS = tts
        model.narrationAudioWriter = audioWriter
        model.narrationCacheDirectoryProvider = { [cacheDirectory] in cacheDirectory }
        try await install(baseManifest)
    }

    func remove() {
        model.narrationRenderTask?.cancel()
        model.playbackController.stop()
        UserDefaults.standard.removeObject(
            forKey: "EchoAudiobooks.lastTrack.\(audiobookID)")
        removeBookFiles(from: PlayerModel.narrationCacheDirectory())
        try? FileManager.default.removeItem(at: root)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func run(preferredVoice: VoiceID) async throws -> RunResult {
        let renderCallsBeforeRun = audioWriter.writeCallCount
        let synthesisCallsBeforeRun = tts.calls.count
        let voice = try #require(VoiceCatalog.voice(for: preferredVoice))
        model.startNarrationPlayback(voice: voice)
        await model.narrationRenderTask?.value

        let blocks = try EPubBlockDAO(db: database.writer).visibleBlocks(for: audiobookID)
        let tracks = try TrackDAO(db: database.writer).tracks(for: audiobookID)
        let fileURLsBySourceKey = fileURLsBySourceKey(from: tracks)
        let newCalls = Array(tts.calls[synthesisCallsBeforeRun...])
        return RunResult(
            renderCallCount: audioWriter.writeCallCount - renderCallsBeforeRun,
            rawSynthesisCallCount: newCalls.count,
            synthesizedVoices: orderedDistinct(newCalls.map(\.voice.rawValue)),
            importedSourceChapterKeys: orderedDistinct(blocks.compactMap(\.sourceChapterKey)),
            tracks: tracks,
            persistedVoices: tracks.compactMap(\.narrationVoice),
            fileURLsBySourceKey: fileURLsBySourceKey,
            persistedSourceKeysInTrackOrder: tracks.compactMap {
                sourceChapterKey(for: URL(fileURLWithPath: $0.filePath))
            },
            playbackQueueSourceKeys: model.tracks.compactMap { sourceChapterKey(for: $0.url) },
            currentIndex: model.currentIndex,
            currentTrackURL: model.tracks.indices.contains(model.currentIndex)
                ? model.tracks[model.currentIndex].url : nil,
            effectiveDefaultVoice: model.state.narrationDefaultVoice,
            voiceOverrideCount: model.state.narrationVoiceOverrideCount,
            narrationRender: model.narrationPlaybackState.snapshot.render,
            narrationPlayback: model.narrationPlaybackState.snapshot.playback,
            narrationEvents: model.narrationPlaybackState.events)
    }

    func exportItems(preferredVoice: VoiceID) async throws -> [ExportItem] {
        try await NarrationCacheSource(
            audiobookID: audiobookID,
            cacheDirectory: cacheDirectory,
            databaseWriter: database.writer,
            preferredVoice: preferredVoice
        ).items()
    }

    func install(_ manifest: AnthologyBuildManifest) async throws {
        let destination = root.appending(path: "revision-\(manifest.revision).epub")
        let result = try AnthologyEPUBBuilder(workshopRoot: workshopRoot)
            .build(manifest: manifest, to: destination)
        _ = try await GeneratedAnthologyImportReconciler.importArchive(
            at: destination,
            audiobookID: audiobookID,
            identity: try GeneratedAnthologyImportIdentity(manifest: manifest),
            databaseService: database)
        let manifestEncoder = JSONEncoder.articleWorkshop
        manifestEncoder.outputFormatting = [.sortedKeys]
        let manifestData = try manifestEncoder.encode(manifest)
        try AnthologyDAO(db: database.writer).saveBuild(
            AnthologyBuildRecord(
                id: UUID().uuidString,
                anthologyID: manifest.anthologyID.uuidString,
                revision: manifest.revision,
                epubIdentifier: manifest.epubIdentifier,
                manifestJSON: String(decoding: manifestData, as: UTF8.self),
                manifestSHA256: result.manifestSHA256,
                epubPath: destination.standardizedFileURL.path,
                epubSHA256: result.epubSHA256,
                audiobookID: audiobookID,
                status: "succeeded",
                errorCode: nil,
                createdAt: "2026-08-02T12:00:0\(manifest.revision).000Z"))
    }

    func createStaleCacheSentinel() throws -> URL {
        let name = "\(NarrationFileNaming.safeToken(audiobookID))-stale-sentinel.m4a"
        let url = cacheDirectory.appendingPathComponent(name)
        try Data("stale".utf8).write(to: url)
        return url
    }

    func normalCleanupWouldDelete(_ sentinel: URL, whileKeeping audioURLs: Set<URL>) -> Bool {
        NarrationCacheStore.staleFiles(
            [sentinel.lastPathComponent],
            bookPrefix: "\(NarrationFileNaming.safeToken(audiobookID))-",
            expectedDurableFileNames: Set(audioURLs.map(\.lastPathComponent))
        ) == [sentinel.lastPathComponent]
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
            let selectedVoice =
                voiceByEntryID.keys.contains(entryID)
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

    private func fileURLsBySourceKey(from tracks: [TrackRecord]) -> [String: URL] {
        Dictionary(
            uniqueKeysWithValues: tracks.compactMap { track in
                let url = URL(fileURLWithPath: track.filePath)
                return sourceChapterKey(for: url).map { ($0, url) }
            })
    }

    private func sourceChapterKey(for url: URL) -> String? {
        let name = url.lastPathComponent
        return baseManifest.chapters.first { chapter in
            name.contains(
                "-ck\(NarrationFileNaming.stableChapterToken(for: chapter.entryID.uuidString))")
        }?.entryID.uuidString
    }

    private func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func removeBookFiles(from directory: URL) {
        let prefix = NarrationFileNaming.safeToken(audiobookID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) || name.hasPrefix(".\(prefix)") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

private final class FixtureAudioWriter: AudioFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let writer = AVFoundationAudioWriter()
    private var writes = 0

    var writeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        recordWrite()
        return try await writer.write(chunks, to: url)
    }

    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
        recordWrite()
        return try writer.makeStream(to: url, sampleRate: sampleRate)
    }

    private func recordWrite() {
        lock.lock()
        writes += 1
        lock.unlock()
    }
}
