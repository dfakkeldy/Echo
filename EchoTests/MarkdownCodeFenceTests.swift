// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct MarkdownCodeFenceTests {

    private func parse(_ md: String) -> EPUBBlockParse {
        parseMarkdown(
            audiobookID: "md-test", content: md,
            sourceURL: URL(fileURLWithPath: "/tmp/test.md"))
    }

    @Test func fencedCodeBecomesCodeBlockWithIndentationPreserved() {
        let parsed = parse("""
            # Chapter One

            Some prose.

            ```python
            def f():
                return 1
            ```

            More prose.
            """)
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code != nil)
        #expect(code?.text == "def f():\n    return 1")
        #expect(code?.codeLanguage == "python")
        #expect(code?.narrationText == "Code listing.")
        // Prose neighbors intact.
        #expect(parsed.blocks.contains { $0.text == "Some prose." })
        #expect(parsed.blocks.contains { $0.text == "More prose." })
    }

    @Test func fenceWithoutInfoStringHasNilLanguage() {
        let parsed = parse("```\nx = 1\n```")
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code?.codeLanguage == nil)
        #expect(code?.text == "x = 1")
    }

    @Test func unterminatedFenceAtEOFStillEmits() {
        let parsed = parse("Prose.\n\n```swift\nlet x = 5")
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code?.text == "let x = 5")
        #expect(code?.codeLanguage == "swift")
    }

    @Test func emptyFenceIsDropped() {
        let parsed = parse("```\n\n```\n\nProse.")
        #expect(!parsed.blocks.contains {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        })
    }

    @Test func longerBacktickFencePreservesShorterBackticksInsideCode() {
        let parsed = parse("""
            ````markdown
            before
            ```
            after
            ````

            Tail prose.
            """)
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }

        #expect(code?.text == "before\n```\nafter")
        #expect(code?.codeLanguage == "markdown")
        #expect(parsed.blocks.contains { $0.text == "Tail prose." })
    }

    @Test func fenceOnlyClosesWithMatchingDelimiterCharacter() {
        let parsed = parse("""
            ```text
            alpha
            ~~~
            omega
            ```
            """)
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }

        #expect(code?.text == "alpha\n~~~\nomega")
        #expect(code?.codeLanguage == "text")
    }

    @Test func fourSpaceIndentedMatchingFenceRemainsCodeContent() {
        let parsed = parse("""
            ```text
            before
                ```
            after
            ```
            """)
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }

        #expect(code?.text == "before\n    ```\nafter")
        #expect(code?.codeLanguage == "text")
    }
}
