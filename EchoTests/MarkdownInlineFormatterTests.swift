// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MarkdownInlineFormatterTests {

    @Test func boldSpanIsCapturedAndMarkersStripped() {
        let (plain, formats) = MarkdownInlineFormatter.format("a **bold** end")
        #expect(plain == "a bold end")
        #expect(formats.contains { $0.type == .bold && $0.range == 2...5 })  // "bold"
    }

    @Test func italicSpanIsCaptured() {
        let (plain, formats) = MarkdownInlineFormatter.format("an *italic* word")
        #expect(plain == "an italic word")
        #expect(formats.contains { $0.type == .italic && $0.range == 3...8 })
    }

    @Test func strikethroughSpanIsCaptured() {
        let (plain, formats) = MarkdownInlineFormatter.format("x ~~gone~~ y")
        #expect(plain == "x gone y")
        #expect(formats.contains { $0.type == .strikethrough })
    }

    @Test func nestedBoldItalicYieldsBothSpans() {
        let (plain, formats) = MarkdownInlineFormatter.format("***both***")
        #expect(plain == "both")
        #expect(formats.contains { $0.type == .bold })
        #expect(formats.contains { $0.type == .italic })
    }

    @Test func linkCollapsesToLabel() {
        let (plain, _) = MarkdownInlineFormatter.format("see [the docs](https://example.com) now")
        #expect(plain == "see the docs now")
    }

    @Test func plainTextHasNoFormats() {
        let (plain, formats) = MarkdownInlineFormatter.format("just words")
        #expect(plain == "just words")
        #expect(formats.isEmpty)
    }
}
