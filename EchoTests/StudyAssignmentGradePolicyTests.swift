// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct StudyAssignmentGradePolicyTests {
    @Test func chapterListeningAssignmentsUseAgainAndGoodOnly() {
        #expect(
            StudyAssignmentGradePolicy.choices(for: StudyFlashcardType.listeningAssignment)
                == [.again, .good])
    }

    @Test func imageAssignmentsKeepFullFSRSScale() {
        #expect(
            StudyAssignmentGradePolicy.choices(for: StudyFlashcardType.imageAssignment)
                == ReviewGrade.allCases)
    }

    @Test func normalCardsKeepFullFSRSScale() {
        #expect(
            StudyAssignmentGradePolicy.choices(for: StudyFlashcardType.normal)
                == ReviewGrade.allCases)
    }
}
