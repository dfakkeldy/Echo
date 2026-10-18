// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Brace-matching scan of `MacSource`-normalized macOS source. Normalization
/// collapses the file to a single line but leaves delimiters intact, so the
/// closure bodies can still be recovered by matching braces.
enum MacSheetScan {

    /// Bodies of every `.sheet(…) { … }` trailing closure, without the outer
    /// braces. A `.sheet` mentioned in prose (no trailing closure) is skipped.
    static func closures(in source: String) -> [String] {
        let characters = Array(source)
        let marker = Array(".sheet(")
        var results: [String] = []
        var index = 0

        while index + marker.count <= characters.count {
            guard Array(characters[index..<(index + marker.count)]) == marker else {
                index += 1
                continue
            }
            // Step over the argument list, then require a trailing closure.
            guard let afterArguments = matchDelimiter(characters, from: index + marker.count - 1),
                let braceStart = nextNonSpace(characters, from: afterArguments + 1),
                characters[braceStart] == "{",
                let braceEnd = matchDelimiter(characters, from: braceStart)
            else {
                index += marker.count
                continue
            }
            results.append(String(characters[(braceStart + 1)..<braceEnd]))
            index = braceEnd + 1
        }
        return results
    }

    /// `Mac…`-prefixed types constructed in a fragment, e.g. the content view of
    /// a sheet closure.
    static func macViewTypes(in fragment: String) -> [String] {
        matches(of: "\\b(Mac[A-Za-z0-9_]*)\\(", in: fragment)
    }

    /// Types a view reads via `@Environment(SomeType.self)`. Built-in key paths
    /// such as `@Environment(\\.dismiss)` are excluded on purpose: they always
    /// carry a default value and so can never trap.
    static func environmentObservables(in source: String) -> [String] {
        matches(of: "@Environment\\(([A-Z][A-Za-z0-9_]*)\\.self\\)", in: source)
    }

    // MARK: - Primitives

    /// Index of the delimiter closing the one at `start`, honouring nesting.
    private static func matchDelimiter(_ characters: [Character], from start: Int) -> Int? {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        guard let closer = pairs[characters[start]] else { return nil }
        var depth = 0

        for index in start..<characters.count {
            let character = characters[index]
            if character == characters[start] {
                depth += 1
            } else if character == closer {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func nextNonSpace(_ characters: [Character], from start: Int) -> Int? {
        (start..<characters.count).first { characters[$0] != " " }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
