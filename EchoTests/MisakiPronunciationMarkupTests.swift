// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct MisakiPronunciationMarkupTests {
    @Test func displayTextRemovesOnlyValidMisakiMarkup() {
        #expect(
            MisakiPronunciationMarkup.displayText(
                from: "The [filesystem](/fˈIl sˌɪstəm/) is [live](/lˈIv/)."
            ) == "The filesystem is live."
        )
    }

    @Test func displayTextLeavesMalformedAndEditorialBracketsUntouched() {
        let source = "Keep [sic], [reference](notes), and [record](/ɹəkˈɔɹd) unchanged."
        #expect(MisakiPronunciationMarkup.displayText(from: source) == source)
    }
}
