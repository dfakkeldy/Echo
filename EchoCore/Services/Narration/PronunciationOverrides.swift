// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure text rewriter that injects user-supplied pronunciations into Misaki's
/// native `[word](/ipa/)` link syntax before G2P. Misaki parses such links with
/// `rating: 5` (highest confidence), bypassing both the lexicon and the (removed)
/// BART fallback — so an override always wins.
///
/// Case-insensitive whole-word match; substring matches are rejected ("use" must
/// not match inside "user"). Per-book entries override global entries on conflict.
struct PronunciationOverrides {
    let entries: [String: String]

    /// Apply overrides to `text`, wrapping each matched whole word in link syntax.
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }
        // One combined regex alternation, case-insensitive, word-boundary guarded.
        // Escape regex metacharacters in keys and skip empty values.
        let escaped = entries.keys
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .sorted { $0.count > $1.count } // longest-first so "Postgres" beats "Post"
        guard !escaped.isEmpty else { return text }
        let pattern = "\\b(?:" + escaped.joined(separator: "|") + ")\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        // Process matches right-to-left so index offsets stay valid.
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = re.matches(in: text, range: fullRange).reversed()
        var result = text
        for m in matches {
            guard let range = Range(m.range, in: result) else { continue }
            let matched = String(result[range])
            // Lowercased lookup (case-insensitive match).
            guard let ipa = entries.first(where: { $0.key.lowercased() == matched.lowercased() })?.value else {
                continue
            }
            // Skip if this word is already inside a link "[...](/.../)": look back
            // for an unbalanced "[". Cheap heuristic — Misaki links are rare in prose.
            if isInsideLink(result, at: range.lowerBound) { continue }
            result.replaceSubrange(range, with: "[\(matched)](/\(ipa)/)")
        }
        return result
    }

    /// True if `index` falls inside a `[...](/.../)` link's display text.
    private func isInsideLink(_ s: String, at index: String.Index) -> Bool {
        // Walk back to the nearest '[' that has no following ']' before `index`.
        var i = index
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == "]" { return false } // closed before us → not in a link
            if s[i] == "[" { return true } // open bracket → we're inside display text
        }
        return false
    }

    /// Merge two maps; `book` wins on key conflict.
    static func merging(global: [String: String], book: [String: String]) -> PronunciationOverrides {
        PronunciationOverrides(entries: global.merging(book) { _, b in b })
    }
}
