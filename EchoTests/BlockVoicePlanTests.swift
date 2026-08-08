// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct BlockVoicePlanTests {
    private nonisolated static let sourceSHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test func resolvesBlocksRangesAndDefaultSpeaker() throws {
        let document = try BlockVoicePlanLoader.decode(data: Self.fixturePlanData)
        let resolved = try BlockVoicePlanLoader.resolve(
            document: document,
            sourceEPUBSHA256: Self.sourceSHA,
            chapters: Self.fixtureChapters)

        #expect(resolved.voice(forBlockID: "s2-b3") == VoiceID("bf_emma"))
        #expect(resolved.voice(forBlockID: "s2-b8") == VoiceID("am_fenrir"))
        #expect(resolved.voice(forBlockID: "s2-b10") == VoiceID("am_fenrir"))
        #expect(resolved.voice(forBlockID: "s0-b0") == VoiceID("am_michael"))
        #expect(resolved.voicePlanID == "plan-" + resolved.voicePlanSHA256.prefix(12))
    }

    @Test func equivalentReorderedPlansHaveTheSameIdentity() throws {
        let first = try BlockVoicePlanLoader.resolve(
            document: BlockVoicePlanLoader.decode(data: Self.fixturePlanData),
            sourceEPUBSHA256: Self.sourceSHA,
            chapters: Self.fixtureChapters)
        let second = try BlockVoicePlanLoader.resolve(
            document: BlockVoicePlanLoader.decode(data: Self.reorderedFixturePlanData),
            sourceEPUBSHA256: Self.sourceSHA,
            chapters: Self.fixtureChapters)

        #expect(first.voicePlanSHA256 == second.voicePlanSHA256)
        #expect(first.voicePlanID == second.voicePlanID)
    }

    @Test(
        "Rejects invalid decoding inputs",
        arguments: [
            ("{\"schemaVersion\":1,\"schemaVersion\":1}", BlockVoicePlanError.duplicateJSONKey("schemaVersion")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[],\"assignments\":[]}", BlockVoicePlanError.duplicateJSONKey("epubSHA256")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[],\"assignments\":[],\"extra\":true}", BlockVoicePlanError.unknownField("extra")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"extra\":true},\"defaultSpeakerID\":\"narrator\",\"speakers\":[],\"assignments\":[]}", BlockVoicePlanError.unknownField("extra")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"id\":\"other\",\"voiceID\":\"am_michael\"}],\"assignments\":[]}", BlockVoicePlanError.duplicateJSONKey("id")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"voiceID\":\"am_michael\",\"extra\":true}],\"assignments\":[]}", BlockVoicePlanError.unknownField("extra")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[],\"assignments\":[{\"speakerID\":\"narrator\",\"range\":{\"start\":\"s0-b0\",\"start\":\"s0-b1\",\"end\":\"s0-b1\"}}]}", BlockVoicePlanError.duplicateJSONKey("start")),
            ("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[],\"assignments\":[{\"speakerID\":\"narrator\",\"range\":{\"start\":\"s0-b0\",\"end\":\"s0-b1\",\"extra\":true}}]}", BlockVoicePlanError.unknownField("extra")),
        ])
    func rejectsInvalidDecodingInputs(json: String, expected: BlockVoicePlanError) {
        #expect(throws: expected) {
            _ = try BlockVoicePlanLoader.decode(data: Data(json.utf8))
        }
    }

    @Test func rejectsMalformedJSON() {
        do {
            _ = try BlockVoicePlanLoader.decode(data: Data("{".utf8))
            Issue.record("Expected malformed JSON to be rejected.")
        } catch BlockVoicePlanError.malformedJSON {
            // Expected.
        } catch {
            Issue.record("Wrong error thrown: \(error)")
        }
    }

    @Test(
        "Rejects invalid resolved plans",
        arguments: [
            (plan(schemaVersion: 2), BlockVoicePlanError.unsupportedSchema(2)),
            (plan(sourceSHA: "ABC"), .invalidSourceSHA256("ABC")),
            (plan(defaultSpeaker: "9narrator"), .invalidSpeakerID("9narrator")),
            (plan(speakers: "[{\"id\":\"9narrator\",\"voiceID\":\"am_michael\"}]"), .invalidSpeakerID("9narrator")),
            (plan(speakers: "[{\"id\":\"narrator\",\"voiceID\":\"am_michael\"},{\"id\":\"narrator\",\"voiceID\":\"bf_emma\"}]"), .duplicateSpeaker("narrator")),
            (plan(defaultSpeaker: "missing"), .missingDefaultSpeaker("missing")),
            (plan(speakers: "[{\"id\":\"narrator\",\"voiceID\":\"not_a_voice\"}]"), .unknownVoice("not_a_voice")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"bad\"]}]"), .invalidBlockID("bad")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"s9-b9\"]}]"), .missingBlock("s9-b9")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"s0-b1\"]}]"), .nonNarratableBlock("s0-b1")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[]}]"), .invalidBlockID("")),
            (plan(assignments: "[{\"speakerID\":\"narrator\"}]"), .malformedJSON("assignment")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"s0-b0\"],\"range\":{\"start\":\"s2-b3\",\"end\":\"s2-b3\"}}]"), .malformedJSON("assignment")),
            (plan(assignments: "[{\"speakerID\":\"9narrator\",\"blocks\":[\"s0-b0\"]}]"), .invalidSpeakerID("9narrator")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"s0-b0\"]},{\"speakerID\":\"narrator\",\"blocks\":[\"s0-b0\"]}]"), .duplicateAssignment("s0-b0")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"blocks\":[\"s0-b0\",\"s0-b0\"]}]"), .duplicateAssignment("s0-b0")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"range\":{\"start\":\"s2-b10\",\"end\":\"s2-b8\"}}]"), .invalidRange(start: "s2-b10", end: "s2-b8")),
            (plan(assignments: "[{\"speakerID\":\"narrator\",\"range\":{\"start\":\"s0-b0\",\"end\":\"s2-b3\"}}]"), .crossChapterRange(start: "s0-b0", end: "s2-b3")),
        ])
    func rejectsInvalidResolvedPlans(json: String, expected: BlockVoicePlanError) throws {
        let document = try BlockVoicePlanLoader.decode(data: Data(json.utf8))
        #expect(throws: expected) {
            _ = try BlockVoicePlanLoader.resolve(
                document: document,
                sourceEPUBSHA256: Self.sourceSHA,
                chapters: Self.fixtureChapters)
        }
    }

    @Test func rejectsSourceMismatch() throws {
        let document = try BlockVoicePlanLoader.decode(data: Self.fixturePlanData)
        #expect(throws: BlockVoicePlanError.sourceMismatch(expected: Self.sourceSHA, actual: "f" + String(repeating: "0", count: 63))) {
            _ = try BlockVoicePlanLoader.resolve(
                document: document,
                sourceEPUBSHA256: "f" + String(repeating: "0", count: 63),
                chapters: Self.fixtureChapters)
        }
    }

    @Test func rejectsUndeclaredAssignmentSpeaker() throws {
        let document = try BlockVoicePlanLoader.decode(data: Data(Self.plan(
            assignments: "[{\"speakerID\":\"mara\",\"blocks\":[\"s0-b0\"]}]"
        ).utf8))

        #expect(throws: BlockVoicePlanError.unknownSpeaker("mara")) {
            _ = try BlockVoicePlanLoader.resolve(
                document: document,
                sourceEPUBSHA256: Self.sourceSHA,
                chapters: Self.fixtureChapters)
        }
    }

    private static var fixturePlanData: Data {
        Data(plan(
            speakers: "[{\"id\":\"narrator\",\"voiceID\":\"am_michael\"},{\"id\":\"mara\",\"voiceID\":\"bf_emma\"},{\"id\":\"jon\",\"voiceID\":\"am_fenrir\"}]",
            assignments: "[{\"speakerID\":\"mara\",\"blocks\":[\"s2-b3\",\"s2-b7\"]},{\"speakerID\":\"jon\",\"range\":{\"start\":\"s2-b8\",\"end\":\"s2-b10\"}}]").utf8)
    }

    private static var reorderedFixturePlanData: Data {
        Data("{\"assignments\":[{\"range\":{\"end\":\"s2-b10\",\"start\":\"s2-b8\"},\"speakerID\":\"jon\"},{\"blocks\":[\"s2-b7\",\"s2-b3\"],\"speakerID\":\"mara\"}],\"speakers\":[{\"voiceID\":\"am_fenrir\",\"id\":\"jon\"},{\"voiceID\":\"am_michael\",\"id\":\"narrator\"},{\"voiceID\":\"bf_emma\",\"id\":\"mara\"}],\"defaultSpeakerID\":\"narrator\",\"source\":{\"epubSHA256\":\"\(sourceSHA)\"},\"schemaVersion\":1}".utf8)
    }

    private nonisolated static func plan(
        schemaVersion: Int = 1,
        sourceSHA: String? = nil,
        defaultSpeaker: String = "narrator",
        speakers: String = "[{\"id\":\"narrator\",\"voiceID\":\"am_michael\"}]",
        assignments: String = "[]"
    ) -> String {
        "{\"schemaVersion\":\(schemaVersion),\"source\":{\"epubSHA256\":\"\(sourceSHA ?? Self.sourceSHA)\"},\"defaultSpeakerID\":\"\(defaultSpeaker)\",\"speakers\":\(speakers),\"assignments\":\(assignments)}"
    }

    private static var fixtureChapters: [NarrationChapterPlanner.PlannedChapter] {
        [
            .init(index: 0, displayNumber: 1, blocks: [block("s0-b0", sequence: 0), block("s0-b1", sequence: 1, hidden: true)]),
            .init(index: 2, displayNumber: 2, blocks: [
                block("s2-b3", sequence: 3), block("s2-b7", sequence: 7), block("s2-b8", sequence: 8),
                block("s2-b9", sequence: 9), block("s2-b10", sequence: 10),
            ]),
        ]
    }

    private static func block(_ suffix: String, sequence: Int, hidden: Bool = false) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-fixture-\(suffix)", audiobookID: "fixture", spineHref: "fixture.xhtml",
            spineIndex: 0, blockIndex: sequence, sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue, text: "Text", htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
            isHidden: hidden, hiddenReason: nil, isFrontMatter: false, wordCount: 1,
            markers: nil, textFormats: nil, narrationText: nil, codeLanguage: nil,
            sourceChapterKey: nil, createdAt: nil, modifiedAt: nil)
    }
}
