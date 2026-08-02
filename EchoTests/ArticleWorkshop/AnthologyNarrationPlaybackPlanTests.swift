// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AnthologyNarrationPlaybackPlanTests {
    private let entryA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let entryB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let entryC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    @Test func generatedAnthologyPreservesEveryChapterVoiceAndSourceKeyInPlaybackSegments()
        async throws
    {
        let fixture = generatedAnthology(
            entries: [
                (entryA, nil),
                (entryB, "bf_emma"),
                (entryC, "am_michael"),
            ])

        let prepared = try await NarrationPlaybackPlanPreparation.prepare(
            chapters: fixture.chapters,
            allChapters: fixture.chapters,
            preferredVoice: VoiceID("af_heart"),
            resolveManifest: { fixture.manifest },
            existingDurableFileNames: [],
            expectedFileName: { segment in
                "\(segment.sourceChapterKey!)-s\(segment.segmentIndex)-\(segment.voice.rawValue).m4a"
            },
            cleanup: { _ in })

        #expect(
            prepared.segments.map(\.sourceChapterKey)
                == [entryA.uuidString, entryB.uuidString, entryC.uuidString])
        #expect(
            prepared.segments.map(\.voice.rawValue)
                == ["af_heart", "bf_emma", "am_michael"])
    }

    @Test func stableResumeFollowsEntryBAfterItMovesFromSecondToFirst() throws {
        let original = try NarrationChapterRenderPlanner.plan(
            chapters: chapters(keys: [entryA.uuidString, entryB.uuidString]),
            preferredVoice: VoiceID("af_heart"),
            manifest: manifest(entries: [(entryA, nil), (entryB, "bf_emma")]))
        let savedURL = URL(fileURLWithPath: "/cache/")
            .appendingPathComponent(
                NarrationFileNaming.segmentFileName(
                    audiobookID: "book",
                    chapterIndex: original[1].chapterIndex,
                    sourceChapterKey: entryB.uuidString,
                    segmentIndex: 0,
                    voice: original[1].voice,
                    contentSignature: "fixture"))

        let reordered = try NarrationChapterRenderPlanner.plan(
            chapters: chapters(keys: [entryB.uuidString, entryA.uuidString]),
            preferredVoice: VoiceID("af_heart"),
            manifest: manifest(entries: [(entryA, nil), (entryB, "bf_emma")]))

        let sourceKey = NarrationResumeResolver.sourceChapterKey(
            fromLastTrackURL: savedURL,
            plans: reordered)

        #expect(sourceKey == entryB.uuidString)
        #expect(reordered.first?.sourceChapterKey == sourceKey)
        #expect(reordered.first?.chapterIndex == 0)
    }

    @Test func invalidReceiptDoesNotComputeExpectedFilesOrRunCleanup() async {
        var expectedFileNameCalls = 0
        var cleanupCalls = 0

        await #expect(throws: FixtureError.invalidReceipt) {
            try await NarrationPlaybackPlanPreparation.prepare(
                chapters: chapters(keys: [entryA.uuidString]),
                allChapters: chapters(keys: [entryA.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                resolveManifest: { throw FixtureError.invalidReceipt },
                existingDurableFileNames: [],
                expectedFileName: { _ in
                    expectedFileNameCalls += 1
                    return "unexpected.m4a"
                },
                cleanup: { _ in cleanupCalls += 1 })
        }

        #expect(expectedFileNameCalls == 0)
        #expect(cleanupCalls == 0)
    }

    @Test func blockToManifestMismatchDoesNotComputeExpectedFilesOrRunCleanup() async {
        var expectedFileNameCalls = 0
        var cleanupCalls = 0

        await #expect(
            throws: NarrationChapterRenderPlanError.unknownSourceChapterKey(entryB.uuidString)
        ) {
            try await NarrationPlaybackPlanPreparation.prepare(
                chapters: chapters(keys: [entryB.uuidString]),
                allChapters: chapters(keys: [entryB.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                resolveManifest: { manifest(entries: [(entryA, nil)]) },
                existingDurableFileNames: [],
                expectedFileName: { _ in
                    expectedFileNameCalls += 1
                    return "unexpected.m4a"
                },
                cleanup: { _ in cleanupCalls += 1 })
        }

        #expect(expectedFileNameCalls == 0)
        #expect(cleanupCalls == 0)
    }

    @Test func cleanupPreservesCurrentCacheForExcludedChapter() async throws {
        let excludedFileName = NarrationFileNaming.segmentFileName(
            audiobookID: "book",
            chapterIndex: 1,
            sourceChapterKey: entryB.uuidString,
            segmentIndex: 0,
            voice: VoiceID("bf_emma"),
            contentSignature: "excluded")
        var cleanupExpectedFileNames = Set<String>()

        _ = try await NarrationPlaybackPlanPreparation.prepare(
            chapters: chapters(keys: [entryA.uuidString]),
            allChapters: chapters(keys: [entryA.uuidString, entryB.uuidString]),
            preferredVoice: VoiceID("af_heart"),
            resolveManifest: { manifest(entries: [(entryA, nil), (entryB, "bf_emma")]) },
            existingDurableFileNames: [excludedFileName],
            expectedFileName: { segment in
                "active-\(segment.chapterIndex)-\(segment.segmentIndex).m4a"
            },
            cleanup: { cleanupExpectedFileNames = $0 })

        #expect(cleanupExpectedFileNames.contains(excludedFileName))
    }

    private enum FixtureError: Error {
        case invalidReceipt
    }

    private func generatedAnthology(
        entries: [(UUID, String?)]
    ) -> (chapters: [NarrationChapterPlanner.PlannedChapter], manifest: AnthologyBuildManifest) {
        (
            chapters: chapters(keys: entries.map { $0.0.uuidString }),
            manifest: manifest(entries: entries)
        )
    }

    private func chapters(keys: [String]) -> [NarrationChapterPlanner.PlannedChapter] {
        keys.enumerated().map { index, key in
            NarrationChapterPlanner.PlannedChapter(
                index: index,
                displayNumber: index + 1,
                blocks: [block(index: index, sourceChapterKey: key)])
        }
    }

    private func block(index: Int, sourceChapterKey: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "block-\(index)", audiobookID: "book", spineHref: "chapter-\(index).xhtml",
            spineIndex: index, blockIndex: 0, sequenceIndex: index, blockKind: "paragraph",
            text: "Narratable chapter \(index + 1).", htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: index, isHidden: false,
            hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, narrationText: nil, sourceChapterKey: sourceChapterKey,
            createdAt: nil, modifiedAt: nil)
    }

    private func manifest(entries: [(UUID, String?)]) -> AnthologyBuildManifest {
        AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            revision: 1,
            epubIdentifier: "urn:uuid:DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            title: "Generated anthology", subtitle: nil, creator: "Various Authors", language: "en",
            coverPath: nil, modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: entries.enumerated().map { order, entry in
                AnthologyChapterManifest(
                    entryID: entry.0,
                    captureID: UUID(
                        uuidString: "00000000-0000-0000-0000-00000000000\(order + 1)")!,
                    articleRevisionID: UUID(
                        uuidString: "11111111-1111-1111-1111-11111111111\(order + 1)")!,
                    stableSlot: order, order: order, title: "Chapter \(order + 1)", author: nil,
                    siteName: nil, sourceURL: URL(string: "https://example.test/\(order)")!,
                    capturedAt: Date(timeIntervalSince1970: 1_775_000_000), voiceID: entry.1,
                    blocks: [], readableContentSHA256: String(repeating: "a", count: 64))
            })
    }
}
