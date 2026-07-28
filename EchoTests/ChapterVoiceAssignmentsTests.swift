// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct ChapterVoiceAssignmentsTests {
    @Test func parsesRepeatedAssignments() throws {
        let assignments = try ChapterVoiceAssignments(
            arguments: ["1=af_heart", "28=bm_daniel"])

        #expect(assignments.byDisplayNumber[1] == VoiceID("af_heart"))
        #expect(assignments.byDisplayNumber[28] == VoiceID("bm_daniel"))
    }

    @Test(
        "Rejects invalid chapter voice assignments",
        arguments: [
            (["missing-equals"], ChapterVoiceAssignments.AssignmentError.malformed("missing-equals")),
            (["0=af_heart"], .invalidChapterNumber("0")),
            (["1=not_a_voice"], .unknownVoice("not_a_voice")),
            (["1=af_heart", "1=bf_emma"], .duplicateChapter(1)),
        ])
    func rejectsInvalidAssignments(
        arguments: [String],
        expected: ChapterVoiceAssignments.AssignmentError
    ) {
        #expect(throws: expected) {
            _ = try ChapterVoiceAssignments(arguments: arguments)
        }
    }
}
