// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Extracts inline Markdown emphasis from a single run of prose.
///
/// Hand-rolled block parsing (headings, paragraphs) lives in
/// `TextDocumentParser`; this handles only *inline* emphasis, delegating to
/// Foundation's inline-only Markdown parser so nested `***both***`, links, and
/// escapes are handled correctly without a third-party CommonMark dependency.
/// Links collapse to their visible label (the URL is dropped from narration and
/// the reader text alike).
enum MarkdownInlineFormatter {

    /// - Returns: the plain text with all inline markup removed, plus the
    ///   bold/italic/strikethrough spans as character ranges into that plain text.
    static func format(_ markdown: String) -> (plain: String, formats: [TextFormat]) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return (markdown, [])
        }

        let plain = String(attributed.characters)
        var formats: [TextFormat] = []

        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let lower = attributed.characters.distance(
                from: attributed.startIndex, to: run.range.lowerBound)
            let upper = attributed.characters.distance(
                from: attributed.startIndex, to: run.range.upperBound)
            guard upper > lower else { continue }
            let range = lower...(upper - 1)

            if intent.contains(.stronglyEmphasized) {
                formats.append(TextFormat(type: .bold, range: range))
            }
            if intent.contains(.emphasized) {
                formats.append(TextFormat(type: .italic, range: range))
            }
            if intent.contains(.strikethrough) {
                formats.append(TextFormat(type: .strikethrough, range: range))
            }
        }
        return (plain, formats)
    }
}
