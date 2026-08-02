// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct AnthologyNarrationRenderPlanTests {
    private let entryA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let entryB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test func nilOverrideInheritsPreferredVoice() throws {
        let plans = try NarrationChapterRenderPlanner.plan(
            chapters: chapters(keys: [entryA.uuidString]),
            preferredVoice: VoiceID("af_heart"),
            manifest: manifest(entries: [(entryA, nil)]))

        #expect(plans.map(\.voice) == [VoiceID("af_heart")])
    }

    @Test func explicitOverrideWins() throws {
        let plans = try NarrationChapterRenderPlanner.plan(
            chapters: chapters(keys: [entryA.uuidString, entryB.uuidString]),
            preferredVoice: VoiceID("af_heart"),
            manifest: manifest(entries: [(entryA, nil), (entryB, "bf_emma")]))

        #expect(plans.map(\.voice.rawValue) == ["af_heart", "bf_emma"])
    }

    @Test func changingPreferredVoiceChangesInheritedVoice() throws {
        let manifest = manifest(entries: [(entryA, nil)])
        let chapters = chapters(keys: [entryA.uuidString])

        let first = try NarrationChapterRenderPlanner.plan(
            chapters: chapters, preferredVoice: VoiceID("af_heart"), manifest: manifest)
        let second = try NarrationChapterRenderPlanner.plan(
            chapters: chapters, preferredVoice: VoiceID("am_michael"), manifest: manifest)

        #expect(first.map(\.voice) == [VoiceID("af_heart")])
        #expect(second.map(\.voice) == [VoiceID("am_michael")])
    }

    @Test func ordinaryBookIgnoresBlockKeysAndUsesPreferredVoice() throws {
        let plans = try NarrationChapterRenderPlanner.plan(
            chapters: chapters(keys: ["foreign-key"]),
            preferredVoice: VoiceID("bf_emma"),
            manifest: nil)

        #expect(plans.map(\.sourceChapterKey) == [nil])
        #expect(plans.map(\.voice) == [VoiceID("bf_emma")])
    }

    @Test func anthologyRejectsMixedBlockKeysInOneChapter() throws {
        #expect(throws: NarrationChapterRenderPlanError.mixedSourceChapterKeys(chapterIndex: 0)) {
            try NarrationChapterRenderPlanner.plan(
                chapters: [chapter(index: 0, keys: [entryA.uuidString, entryB.uuidString])],
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil), (entryB, nil)]))
        }
    }

    @Test func anthologyRejectsMissingBlockKey() throws {
        #expect(throws: NarrationChapterRenderPlanError.missingSourceChapterKey(chapterIndex: 0)) {
            try NarrationChapterRenderPlanner.plan(
                chapters: [chapter(index: 0, keys: [nil])],
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil)]))
        }
    }

    @Test func anthologyRejectsKeyAbsentFromManifest() throws {
        #expect(throws: NarrationChapterRenderPlanError.unknownSourceChapterKey(entryB.uuidString)) {
            try NarrationChapterRenderPlanner.plan(
                chapters: chapters(keys: [entryB.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil)]))
        }
    }

    @Test func anthologyRejectsNoncanonicalUUIDText() throws {
        let foreignKey = entryA.uuidString.lowercased()

        #expect(throws: NarrationChapterRenderPlanError.unknownSourceChapterKey(foreignKey)) {
            try NarrationChapterRenderPlanner.plan(
                chapters: chapters(keys: [foreignKey]),
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil)]))
        }
    }

    @Test func anthologyRejectsRepeatedVisibleKey() throws {
        #expect(throws: NarrationChapterRenderPlanError.duplicateSourceChapterKey(entryA.uuidString)) {
            try NarrationChapterRenderPlanner.plan(
                chapters: chapters(keys: [entryA.uuidString, entryA.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil)]))
        }
    }

    @Test func anthologyRejectsUnavailableManifestVoice() throws {
        #expect(throws: NarrationChapterRenderPlanError.unavailableVoice("missing-voice")) {
            try NarrationChapterRenderPlanner.plan(
                chapters: chapters(keys: [entryA.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, "missing-voice")]))
        }
    }

    @Test func anthologyRejectsForcedStableTokenCollision() throws {
        #expect(throws: NarrationChapterRenderPlanError.duplicateStableToken("collision")) {
            try NarrationChapterRenderPlanner.plan(
                chapters: chapters(keys: [entryA.uuidString, entryB.uuidString]),
                preferredVoice: VoiceID("af_heart"),
                manifest: manifest(entries: [(entryA, nil), (entryB, nil)]),
                stableToken: { _ in "collision" })
        }
    }

    private func chapters(keys: [String]) -> [NarrationChapterPlanner.PlannedChapter] {
        keys.enumerated().map { index, key in chapter(index: index, keys: [key]) }
    }

    private func chapter(
        index: Int,
        keys: [String?]
    ) -> NarrationChapterPlanner.PlannedChapter {
        NarrationChapterPlanner.PlannedChapter(
            index: index,
            displayNumber: index + 1,
            blocks: keys.enumerated().map { blockIndex, key in
                EPubBlockRecord(
                    id: "block-\(index)-\(blockIndex)", audiobookID: "book",
                    spineHref: "chapter.xhtml", spineIndex: index, blockIndex: blockIndex,
                    sequenceIndex: blockIndex, blockKind: "paragraph", text: "Narratable text",
                    htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
                    chapterIndex: index, isHidden: false, hiddenReason: nil, isFrontMatter: false,
                    wordCount: nil, markers: nil, textFormats: nil, narrationText: nil,
                    sourceChapterKey: key, createdAt: nil, modifiedAt: nil)
            })
    }

    private func manifest(entries: [(UUID, String?)]) -> AnthologyBuildManifest {
        AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            revision: 1,
            epubIdentifier: "urn:uuid:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            title: "Fixture anthology", subtitle: nil, creator: "Various Authors", language: "en",
            coverPath: nil, modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: entries.enumerated().map { order, entry in
                AnthologyChapterManifest(
                    entryID: entry.0,
                    captureID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(order + 1)")!,
                    articleRevisionID: UUID(uuidString: "11111111-1111-1111-1111-11111111111\(order + 1)")!,
                    stableSlot: order, order: order, title: "Chapter \(order + 1)", author: nil,
                    siteName: nil, sourceURL: URL(string: "https://example.test/\(order)")!,
                    capturedAt: Date(timeIntervalSince1970: 1_775_000_000), voiceID: entry.1,
                    blocks: [], readableContentSHA256: String(repeating: "a", count: 64))
            })
    }
}
