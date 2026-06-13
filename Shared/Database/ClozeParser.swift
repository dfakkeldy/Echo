import Foundation

/// Parses Anki-style cloze deletions (`{{cN::answer}}`) from flashcard text.
///
/// Cloze deletions identify segments of text that should be blanked
/// during review. Each deletion carries a numeric index so a single
/// note can produce multiple cards, each revealing one answer.
///
/// Example:
/// ```
/// "{{c1::mitosis}} is the process of {{c2::cell division}}"
/// // → c1 hides "mitosis", c2 hides "cell division"
/// ```
enum ClozeParser {
    /// A single cloze deletion found in source text.
    struct ClozeDeletion: Equatable {
        let index: Int
        let answer: String
        let range: Range<String.Index>
    }

    /// Returns `true` when the text contains at least one Anki cloze
    /// marker (`{{c`).
    static func hasClozeDeletions(_ text: String) -> Bool {
        text.contains("{{c")
    }

    /// Extracts all cloze deletions from the given text.
    ///
    /// The regex matches `{{c(\d+)::([^}]+)}}` — a numeric index followed
    /// by `::` and the answer text. Malformed markers that don't match
    /// the pattern are silently skipped.
    static func parseDeletions(_ text: String) -> [ClozeDeletion] {
        var results: [ClozeDeletion] = []
        var searchRange = text.startIndex..<text.endIndex

        while let match = text.range(
            of: #"\{\{c(\d+)::([^}]+)\}\}"#,
            options: .regularExpression,
            range: searchRange
        ) {
            let matched = text[match]
            guard let indexStr = matched.split(separator: "::").first?.dropFirst(3),
                  let index = Int(indexStr) else {
                searchRange = match.upperBound..<text.endIndex
                continue
            }
            let afterDelimiter = matched.drop { $0 != ":" }
            let answer = String(afterDelimiter.dropFirst(2).dropLast(2))
            results.append(ClozeDeletion(index: index, answer: answer, range: match))
            searchRange = match.upperBound..<text.endIndex
        }
        return results
    }

    /// Replaces the cloze deletion in `text` with a `[...]` placeholder
    /// to form the card's **front** (question) side.
    static func makeFront(text: String, deletion: ClozeDeletion) -> String {
        var front = text
        front.replaceSubrange(deletion.range, with: "[...]")
        return front
    }

    /// Replaces the cloze deletion in `text` with a `[answer]` highlight
    /// to form the card's **back** (answer) side.
    static func makeBack(text: String, deletion: ClozeDeletion) -> String {
        var back = text
        back.replaceSubrange(deletion.range, with: "[\(deletion.answer)]")
        return back
    }
}
