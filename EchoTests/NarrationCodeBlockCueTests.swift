// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct NarrationCodeBlockCueTests {

    private func block(kind: EPubBlockRecord.Kind, text: String?, cue: String?)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: "b1", audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: 0, sequenceIndex: 0, blockKind: kind.rawValue,
            text: text, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: nil, isHidden: false, hiddenReason: nil,
            wordCount: 1, markers: nil, textFormats: nil,
            narrationText: cue, codeLanguage: nil, createdAt: nil, modifiedAt: nil)
    }

    private func alignmentBlock(
        id: String,
        sequence: Int,
        kind: EPubBlockRecord.Kind,
        text: String
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "alignment-book", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence, blockKind: kind.rawValue,
            text: text, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: 1, markers: nil, textFormats: nil,
            narrationText: kind == .code ? "Code listing." : nil,
            codeLanguage: kind == .code ? "swift" : nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func codeBlockSpeaksItsCue() {
        let b = block(kind: .code, text: "let x = 5", cue: "Listing 4-2. Retry decorator")
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Listing 4-2. Retry decorator")
    }

    @Test func codeBlockWithoutCueSpeaksFallback() {
        let b = block(kind: .code, text: "let x = 5", cue: nil)
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Code listing.")
    }

    @Test func blankCueFallsBack() {
        let b = block(kind: .code, text: "let x = 5", cue: "   ")
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Code listing.")
    }

    @Test func nonCodeBlocksReturnNil() {
        #expect(NarrationCodeBlockCue.spokenText(
            for: block(kind: .paragraph, text: "Prose.", cue: nil)) == nil)
        #expect(NarrationCodeBlockCue.spokenText(
            for: block(kind: .image, text: nil, cue: nil)) == nil)
    }

    @Test func renderPlanChunksOnlyTheCueAndNeverRawCode() async throws {
        let database = try DatabaseService(inMemory: ())
        let service = NarrationService(
            db: database.writer,
            audiobookID: "a1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: .temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })
        let rawCode = "let retry = { attempt() }"

        let plan = try await service.renderPlan(
            for: [block(kind: .code, text: rawCode, cue: "Listing 4-2. Retry decorator")],
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let chunks = try #require(plan.blocks.first?.synthesisChunks)

        #expect(chunks.map(\.displayText).joined(separator: " ") == "Listing 4-2. Retry decorator")
        #expect(chunks.allSatisfy { !$0.displayText.contains(rawCode) })
        #expect(chunks.allSatisfy { !$0.g2pInputText.contains("attempt") })
    }

    @Test func cacheURLChangesWhenCodeCueChangesButRawCodeDoesNot() async throws {
        let database = try DatabaseService(inMemory: ())
        let service = NarrationService(
            db: database.writer,
            audiobookID: "a1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: .temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })
        let first = block(kind: .code, text: "let value = 42", cue: "First listing.")
        let second = block(kind: .code, text: "let value = 42", cue: "Revised listing.")

        let firstURL = await service.chapterCacheURL(
            chapterIndex: 0, blocks: [first], voice: VoiceID("af_heart"))
        let secondURL = await service.chapterCacheURL(
            chapterIndex: 0, blocks: [second], voice: VoiceID("af_heart"))

        #expect(firstURL != secondURL)
    }

    @Test func estimatedSidecarExcludesCodeFromProseAnchors() {
        let code = alignmentBlock(id: "code", sequence: 0, kind: .code, text: "let x = 5")
        let prose = alignmentBlock(id: "prose", sequence: 1, kind: .paragraph, text: "Prose.")

        #expect(
            EstimatedAlignmentSidecar.readableBlocks(from: [code, prose]).map(\.id) == ["prose"])
    }

    @Test func chapterPlannerKeepsCodeOnlyChapters() throws {
        let code = alignmentBlock(id: "code", sequence: 0, kind: .code, text: "let x = 5")

        let chapter = try #require(NarrationChapterPlanner.plan(from: [code]).first)
        #expect(chapter.blocks.map(\.id) == ["code"])
    }

    @Test func twoWordFallbackDoesNotCreateDivergenceWhenHeard() {
        let windows = NarrationQADetector.detect(
            expectedBlocks: [("code", NarrationCodeBlockCue.fallback)],
            heardWords: [
                TranscribedWord(text: "Code", start: 0),
                TranscribedWord(text: "listing", start: 0.4),
            ])

        #expect(windows.isEmpty)
    }

    @Test func timelineInterpolationGivesCodeZeroProseWeight() throws {
        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["alignment-book", "Alignment Book", 100])
        }
        let blocks = [
            alignmentBlock(id: "start", sequence: 0, kind: .paragraph, text: "A"),
            alignmentBlock(
                id: "code", sequence: 1, kind: .code,
                text: String(repeating: "x", count: 100)),
            alignmentBlock(id: "middle", sequence: 2, kind: .paragraph, text: "Middle"),
            alignmentBlock(id: "end", sequence: 3, kind: .paragraph, text: "End"),
        ]
        try EPubBlockDAO(db: database.writer).insertAll(blocks)
        let service = AlignmentService(db: database.writer, audiobookID: "alignment-book")

        try service.moveBlockToCurrentTime(blockID: "start", time: 0)
        try service.moveBlockToCurrentTime(blockID: "end", time: 100)

        let timeline = try TimelineDAO(db: database.writer).items(for: "alignment-book")
        let codeStart = try #require(timeline.first { $0.epubBlockID == "code" }?.audioStartTime)
        let middleStart = try #require(timeline.first { $0.epubBlockID == "middle" }?.audioStartTime)
        #expect(abs(codeStart - middleStart) < 0.001)
        #expect(abs(middleStart - (100.0 / 7.0)) < 0.001)
    }
}
