// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Pins the exact stderr strings `echo-cli narrate` emits — overnight agents
/// grep these, so changes here are contract changes.
@Suite struct NarrationRunProgressFormatterTests {

    @Test func messagesAreStableAndTimestampFree() {
        #expect(NarrationRunProgressFormatter.message(for: .importing) == "importing source")
        #expect(
            NarrationRunProgressFormatter.message(for: .preparing(fraction: 0.42))
                == "preparing voice models 42%")
        #expect(
            NarrationRunProgressFormatter.message(
                for: .chapter(index: 2, of: 12, fraction: 0.25))
                == "chapter 3/12 · 25% of batch")
        #expect(NarrationRunProgressFormatter.message(for: .exporting) == "exporting m4b")
        #expect(
            NarrationRunProgressFormatter.message(
                for: .wroteSidecar(anchors: 19, anchorsWithWords: 7))
                == "sidecar written (19 anchors, 7 with word timings)")
    }

    @Test func chapterMessageClampsDisplayIndex() {
        // After the final chapter completes, index == of - 1 with fraction 1.
        #expect(
            NarrationRunProgressFormatter.message(
                for: .chapter(index: 11, of: 12, fraction: 1.0))
                == "chapter 12/12 · 100% of batch")
        // Degenerate empty batch must not crash or show chapter 1/0.
        #expect(
            NarrationRunProgressFormatter.message(
                for: .chapter(index: 0, of: 0, fraction: 0))
                == "chapter 0/0 · 0% of batch")
    }

    @Test func timestampsRollHoursIntoMinutes() {
        #expect(NarrationRunProgressFormatter.timestamp(0) == "0:00")
        #expect(NarrationRunProgressFormatter.timestamp(9.4) == "0:09")
        #expect(NarrationRunProgressFormatter.timestamp(75) == "1:15")
        #expect(NarrationRunProgressFormatter.timestamp(4502) == "75:02")
    }

    @Test func summaryReportsRealtimeFactor() {
        #expect(
            NarrationRunProgressFormatter.summary(audioSeconds: 3600, wallSeconds: 600)
                == "3600s audio in 600s wall (6.0× realtime)")
        // Sub-second walls clamp to 1s so the factor stays finite.
        #expect(
            NarrationRunProgressFormatter.summary(audioSeconds: 12, wallSeconds: 0.2)
                == "12s audio in 1s wall (12.0× realtime)")
    }
}
