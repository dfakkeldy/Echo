// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationProgressTextTests {
    @Test func formatsChapterAndPercent() {
        #expect(
            NarrationProgressText.subtitle(chapterDisplayNumber: 1, fraction: 0.0)
                == "Preparing chapter 1…")
        #expect(
            NarrationProgressText.subtitle(chapterDisplayNumber: 1, fraction: 0.4)
                == "Preparing chapter 1… 40%")
        #expect(
            NarrationProgressText.subtitle(chapterDisplayNumber: 3, fraction: 1.0)
                == "Preparing chapter 3… 100%")
    }

    @Test func clampsOutOfRangeFraction() {
        #expect(
            NarrationProgressText.subtitle(chapterDisplayNumber: 2, fraction: -0.5)
                == "Preparing chapter 2…")
        #expect(
            NarrationProgressText.subtitle(chapterDisplayNumber: 2, fraction: 1.5)
                == "Preparing chapter 2… 100%")
    }
}
