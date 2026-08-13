// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import Testing

    @testable import Echo

    @MainActor @Suite struct TranscribeProgressViewTests {
        @Test func progressFractionZeroChaptersIsZero() {
            let state = StandaloneProgressState()
            #expect(TranscribeProgressView.fraction(for: state) == 0.0)
        }

        @Test func progressFractionHalfway() {
            let state = StandaloneProgressState()
            state.chaptersTotal = 4
            state.chaptersComplete = 2
            #expect(TranscribeProgressView.fraction(for: state) == 0.5)
        }

        @Test func progressFractionCapsAtOne() {
            let state = StandaloneProgressState()
            state.chaptersTotal = 2
            state.chaptersComplete = 5
            #expect(TranscribeProgressView.fraction(for: state) == 1.0)
        }
    }
#endif
