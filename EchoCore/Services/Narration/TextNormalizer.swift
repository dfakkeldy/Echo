// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Converts written prose into a speakable form before phonemization.
/// Pure and deterministic — the unit with the highest naturalness ROI.
enum TextNormalizer {
    static func normalize(_ input: String) -> String {
        var s = input
        s = expandAbbreviations(s)
        s = expandNumericPercentages(s)
        s = expandThousandsSeparatedNumbers(s)
        s = replacePercentSymbols(s)
        s = normalizeRomanNumeralChapters(s)
        s = normalizeDashes(s)
        return s
    }

    private static func expandAbbreviations(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "e.g.", with: "for example")
        out = out.replacingOccurrences(of: "Dr.", with: "Doctor")
        // "St." → Saint before a capitalized word, else Street.
        out = replaceStreetVsSaint(out)
        return out
    }

    private static func replaceStreetVsSaint(_ s: String) -> String {
        // "St." followed by whitespace + uppercase letter → "Saint" (dot consumed by abbreviation).
        // All other "St." → "Street." (dot is restored — it may be a sentence-ending period).
        let saint = try! NSRegularExpression(pattern: "St\\.(?=\\s+[A-Z])")
        let street = try! NSRegularExpression(pattern: "St\\.")
        let r1 = NSRange(s.startIndex..., in: s)
        var out = saint.stringByReplacingMatches(in: s, range: r1, withTemplate: "Saint")
        let r2 = NSRange(out.startIndex..., in: out)
        out = street.stringByReplacingMatches(in: out, range: r2, withTemplate: "Street.")
        return out
    }

    private static func expandNumericPercentages(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern: #"(?<![\p{L}\p{N}_])([0-9][0-9,]*(?:\.[0-9]+)?)\s*%"#
        ) { match, text in
            guard let literal = substring(match.range(at: 1), in: text),
                let words = numberWords(from: literal)
            else { return nil }
            return "\(words) percent"
        }
    }

    private static func expandThousandsSeparatedNumbers(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern: #"(?<![\p{L}\p{N}_])([0-9]{1,3}(?:,[0-9]{3})+)(?:\.([0-9]+))?(?![\p{L}\p{N}_])"#
        ) { match, text in
            guard let integer = substring(match.range(at: 1), in: text) else { return nil }
            let fraction = substring(match.range(at: 2), in: text)
            let literal = fraction.map { "\(integer).\($0)" } ?? integer
            return numberWords(from: literal)
        }
    }

    private static func replacePercentSymbols(_ s: String) -> String {
        let out = s.replacingOccurrences(of: "%", with: " percent")
        let re = try! NSRegularExpression(pattern: "\\s+percent")
        let r = NSRange(out.startIndex..., in: out)
        return re.stringByReplacingMatches(in: out, range: r, withTemplate: " percent")
    }

    private static func normalizeRomanNumeralChapters(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: "\\bChapter ([IVXLC]+)\\b")
        let r = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, range: r).reversed()
        var out = s
        for m in matches {
            guard let whole = Range(m.range, in: out),
                let num = Range(m.range(at: 1), in: out),
                let value = romanToInt(String(out[num]))
            else { continue }
            out.replaceSubrange(whole, with: "Chapter \(value)")
        }
        return out
    }

    private static func normalizeDashes(_ s: String) -> String {
        // A *spaced* dash used as a sentence-level pause → comma, so it reads as a
        // real pause. Covers em (—), en (–), and a spaced ASCII hyphen (common in
        // plain-text/Markdown imports). Intra-word hyphens (no surrounding spaces,
        // e.g. "rough-and-ready") are left for the G2P to read as a word break.
        var out = s.replacingOccurrences(of: " — ", with: ", ")
        out = out.replacingOccurrences(of: " – ", with: ", ")
        out = out.replacingOccurrences(of: " - ", with: ", ")
        return out
    }

    private static func romanToInt(_ roman: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        var total = 0
        var prev = 0
        for ch in roman.reversed() {
            guard let v = values[ch] else { return nil }
            total += v < prev ? -v : v
            prev = v
        }
        return total > 0 ? total : nil
    }

    private static func replacingMatches(
        in s: String,
        pattern: String,
        transform: (NSTextCheckingResult, String) -> String?
    ) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let r = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, range: r).reversed()
        var out = s
        for match in matches {
            guard let whole = Range(match.range, in: out),
                let replacement = transform(match, out)
            else { continue }
            out.replaceSubrange(whole, with: replacement)
        }
        return out
    }

    private static func substring(_ range: NSRange, in s: String) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: s) else {
            return nil
        }
        return String(s[swiftRange])
    }

    private static func numberWords(from literal: String) -> String? {
        let clean = literal.replacingOccurrences(of: ",", with: "")
        let parts = clean.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard let integerText = parts.first, let integer = Int(integerText) else { return nil }

        var words = cardinalWords(integer)
        if parts.count == 2, !parts[1].isEmpty {
            let fraction = parts[1].compactMap { digitWord($0) }.joined(separator: " ")
            guard !fraction.isEmpty else { return nil }
            words += " point \(fraction)"
        }
        return words
    }

    private static func cardinalWords(_ value: Int) -> String {
        if value < 20 { return smallNumberWords[value] }
        if value < 100 {
            let tens = value / 10
            let ones = value % 10
            let tensWord = tensNumberWords[tens] ?? ""
            return ones == 0 ? tensWord : "\(tensWord)-\(smallNumberWords[ones])"
        }
        if value < 1000 {
            let hundreds = value / 100
            let remainder = value % 100
            let prefix = "\(smallNumberWords[hundreds]) hundred"
            return remainder == 0 ? prefix : "\(prefix) and \(cardinalWords(remainder))"
        }

        for (scale, name) in scaleNumberWords {
            guard value >= scale else { continue }
            let major = value / scale
            let remainder = value % scale
            let prefix = "\(cardinalWords(major)) \(name)"
            if remainder == 0 { return prefix }
            if remainder < 100 { return "\(prefix) and \(cardinalWords(remainder))" }
            if scale == 1_000 && value < 10_000 {
                return "\(prefix) \(cardinalWords(remainder))"
            }
            return "\(prefix), \(cardinalWords(remainder))"
        }

        return String(value)
    }

    private static func digitWord(_ ch: Character) -> String? {
        guard let value = ch.wholeNumberValue, (0...9).contains(value) else { return nil }
        return smallNumberWords[value]
    }

    private static let smallNumberWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    ]

    private static let tensNumberWords = [
        2: "twenty",
        3: "thirty",
        4: "forty",
        5: "fifty",
        6: "sixty",
        7: "seventy",
        8: "eighty",
        9: "ninety",
    ]

    private static let scaleNumberWords = [
        (1_000_000_000, "billion"),
        (1_000_000, "million"),
        (1_000, "thousand"),
    ]
}
