// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Converts written prose into a speakable form before phonemization.
/// Pure and deterministic — the unit with the highest naturalness ROI.
enum TextNormalizer {
    static func normalize(_ input: String) -> String {
        var s = input
        s = expandAbbreviations(s)
        s = stripThousandsSeparators(s)
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

    private static func stripThousandsSeparators(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: "(?<=\\d),(?=\\d{3}\\b)")
        let r = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: r, withTemplate: "")
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
        // Em dash used as a pause → comma.
        s.replacingOccurrences(of: " — ", with: ", ")
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
}
