// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct DockStatusFeedbackTests {
    @Test func savedUsesSuccessPresentation() {
        let feedback = DockStatusFeedback(result: .saved)

        #expect(feedback.message == "Passage marked")
        #expect(feedback.systemImage == "checkmark.circle.fill")
        #expect(feedback.isSuccess)
    }

    @Test func unavailableAndFailedUseFailurePresentation() {
        for result in [MarkPassageResult.unavailable, .failed] {
            let feedback = DockStatusFeedback(result: result)

            #expect(feedback.message == "Couldn't mark passage")
            #expect(feedback.systemImage == "exclamationmark.circle.fill")
            #expect(feedback.isSuccess == false)
        }
    }
}
