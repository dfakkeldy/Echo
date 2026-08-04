// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import MisakiSwift

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

    @Test func completeCurrencyPhrasePreservesDisplaySurfaceAndSemanticSpokenSurface() throws {
        let source = "Revenue was $100 billion."
        let displayText = MisakiPronunciationMarkup.displayText(from: source)
        let result = EnglishG2P(british: false).phonemizeWithMetadata(text: source)
        let semanticToken = try #require(
            result.tokens.first { $0.`_`.currencyExpressionSource != nil }
        )

        #expect(result.tokens.map { $0.text + $0.whitespace }.joined() == displayText)
        #expect(
            result.tokens.map { ($0.`_`.alias ?? $0.text) + $0.whitespace }.joined()
                == "Revenue was one hundred billion dollars."
        )
        #expect(semanticToken.text == "$100 billion")
        #expect(semanticToken.`_`.currencyExpressionSource == "$100 billion")
        #expect(semanticToken.`_`.rating == 4)
        #expect(result.tokens.last?.text == ".")
    }
}
