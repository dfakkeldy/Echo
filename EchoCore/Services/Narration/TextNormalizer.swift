// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Converts written prose into a speakable form before phonemization.
/// Pure and deterministic — the unit with the highest naturalness ROI.
enum TextNormalizer {
    static func normalize(_ input: String) -> String {
        var s = input
        s = expandAbbreviations(s)
        s = normalizeOrdinals(s)
        s = expandDollarAmounts(s)
        s = expandProseFriendlyTimes(s)
        s = expandISODates(s)
        s = expandLikelyStandaloneYears(s)
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
        out = out.replacingOccurrences(of: "i.e.", with: "that is")
        out = out.replacingOccurrences(of: "etc.", with: "et cetera")
        out = out.replacingOccurrences(of: "vs.", with: "versus")
        out = out.replacingOccurrences(of: "Dr.", with: "Doctor")
        // "Mrs." before "Mr." so the shorter token can't partially consume it.
        out = out.replacingOccurrences(of: "Mrs.", with: "Missus")
        out = out.replacingOccurrences(of: "Mr.", with: "Mister")
        out = out.replacingOccurrences(of: "Ms.", with: "Miz")
        out = out.replacingOccurrences(of: "Prof.", with: "Professor")
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

    private static func expandDollarAmounts(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern:
                #"(?<![\p{L}\p{N}_])\$([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.([0-9]{2}))?(?![\p{L}\p{N}_]|\.[0-9]|%)"#
        ) { match, text in
            guard let dollarsText = substring(match.range(at: 1), in: text),
                let dollars = Int(dollarsText.replacingOccurrences(of: ",", with: ""))
            else { return nil }

            let centsText = substring(match.range(at: 2), in: text)
            let cents = centsText.flatMap(Int.init) ?? 0
            guard (0...99).contains(cents) else { return nil }

            return dollarWords(dollars: dollars, cents: cents, hasExplicitCents: centsText != nil)
        }
    }

    private static func dollarWords(
        dollars: Int,
        cents: Int,
        hasExplicitCents: Bool
    ) -> String {
        let dollarPart = "\(cardinalWords(dollars)) \(dollars == 1 ? "dollar" : "dollars")"
        guard hasExplicitCents, cents > 0 else { return dollarPart }

        let centPart = "\(cardinalWords(cents)) \(cents == 1 ? "cent" : "cents")"
        return dollars == 0 ? centPart : "\(dollarPart) and \(centPart)"
    }

    private static func expandProseFriendlyTimes(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern:
                #"(?<![\p{L}\p{N}_:/.-])([1-9]|1[0-2]):([0-5][0-9])(?![\p{L}\p{N}_:/-]|\.[\p{L}\p{N}_])"#
        ) { match, text in
            guard isLikelyTime(match.range, in: text),
                let hourText = substring(match.range(at: 1), in: text),
                let minuteText = substring(match.range(at: 2), in: text),
                let hour = Int(hourText),
                let minute = Int(minuteText)
            else { return nil }

            return timeWords(hour: hour, minute: minute)
        }
    }

    private static func isLikelyTime(_ range: NSRange, in s: String) -> Bool {
        if hasTimeSuffix(after: range, in: s) { return true }
        if let word = lowercasedWordBefore(range, in: s) {
            return timeContextWords.contains(word)
        }

        guard let previous = previousNonWhitespaceCharacter(before: range, in: s) else {
            return true
        }
        return standaloneTimePrefixCharacters.contains(previous)
    }

    private static let timeContextWords: Set<String> = [
        "about", "after", "around", "at", "before", "between", "by", "from", "past",
        "till", "to", "until",
    ]

    private static let standaloneTimePrefixCharacters: Set<Character> = [
        "(", "[", "{", "\"", "'", ".", ",", ";", "!", "?",
    ]

    private static func hasTimeSuffix(after range: NSRange, in s: String) -> Bool {
        guard let swiftRange = Range(range, in: s) else { return false }
        let tail = String(s[swiftRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            .lowercased()
        for suffix in ["a.m.", "p.m.", "am", "pm"] {
            guard tail.hasPrefix(suffix) else { continue }
            let suffixEnd = tail.index(tail.startIndex, offsetBy: suffix.count)
            if suffixEnd == tail.endIndex || !tail[suffixEnd].isLetter { return true }
        }
        return false
    }

    private static func timeWords(hour: Int, minute: Int) -> String {
        let hourWords = cardinalWords(hour)
        if minute == 0 { return "\(hourWords) o'clock" }
        if minute < 10 { return "\(hourWords) oh \(cardinalWords(minute))" }
        return "\(hourWords) \(cardinalWords(minute))"
    }

    private static func expandISODates(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern:
                #"(?<![\p{L}\p{N}_/.-])((?:1[6-9]|20)[0-9]{2})-([0-9]{2})-([0-9]{2})(?![\p{L}\p{N}_/-]|\.[\p{L}\p{N}_])"#
        ) { match, text in
            guard let yearText = substring(match.range(at: 1), in: text),
                let monthText = substring(match.range(at: 2), in: text),
                let dayText = substring(match.range(at: 3), in: text),
                let year = Int(yearText),
                let month = Int(monthText),
                let day = Int(dayText),
                isValidDate(year: year, month: month, day: day)
            else { return nil }

            return "\(monthNames[month - 1]) \(ordinalWords(day)), \(yearWords(year))"
        }
    }

    private static func expandLikelyStandaloneYears(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern:
                #"(?<![\p{L}\p{N}_/.-])((?:1[6-9]|20)[0-9]{2})(?![\p{L}\p{N}_/.-]|%)"#
        ) { match, text in
            guard isLikelyStandaloneYear(match.range, in: text),
                let yearText = substring(match.range(at: 1), in: text),
                let year = Int(yearText)
            else { return nil }
            return yearWords(year)
        }
    }

    private static func isLikelyStandaloneYear(_ range: NSRange, in s: String) -> Bool {
        guard let previous = lowercasedWordBefore(range, in: s) else { return false }
        return yearContextWords.contains(previous)
    }

    private static let yearContextWords: Set<String> = [
        "after", "around", "before", "by", "circa", "during", "from", "in", "since",
        "through", "throughout", "until", "year",
    ]

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month) else { return false }
        let daysInMonth = [
            31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
        ]
        return (1...daysInMonth[month - 1]).contains(day)
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December",
    ]

    private static func yearWords(_ year: Int) -> String {
        if (2000...2009).contains(year) {
            let remainder = year - 2000
            return remainder == 0 ? "two thousand" : "two thousand \(cardinalWords(remainder))"
        }
        if (2010...2099).contains(year) {
            return "twenty \(cardinalWords(year - 2000))"
        }
        if (1600...1999).contains(year) {
            let century = year / 100
            let remainder = year % 100
            let prefix = cardinalWords(century)
            if remainder == 0 { return "\(prefix) hundred" }
            if remainder < 10 { return "\(prefix) oh \(cardinalWords(remainder))" }
            return "\(prefix) \(cardinalWords(remainder))"
        }
        return cardinalWords(year)
    }

    private static func expandNumericPercentages(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern: #"(?<![\p{L}\p{N}_$])([0-9][0-9,]*(?:\.[0-9]+)?)\s*%"#
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
            pattern:
                #"(?<![\p{L}\p{N}_])([0-9]{1,3}(?:,[0-9]{3})+)(?:\.([0-9]+))?(?![\p{L}\p{N}_])"#
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

    /// "1st" -> "first", "21st" -> "twenty-first", "100th" -> "one hundredth".
    /// The written suffix is ignored; the digits drive the correct ordinal word.
    private static func normalizeOrdinals(_ s: String) -> String {
        replacingMatches(
            in: s,
            pattern: #"(?<![\p{L}\p{N}_])([0-9]+)(?:st|nd|rd|th)\b"#
        ) { match, text in
            guard let literal = substring(match.range(at: 1), in: text),
                let value = Int(literal)
            else { return nil }
            return ordinalWords(value)
        }
    }

    private static func ordinalWords(_ value: Int) -> String {
        // Ordinalize the final spoken word of the cardinal form: "twenty-one" ->
        // "twenty-first", "one hundred" -> "one hundredth", "forty-five" ->
        // "forty-fifth". Everything before the final word stays cardinal.
        let cardinal = cardinalWords(value)
        guard let lastSpace = cardinal.lastIndex(of: " ") else {
            return ordinalizeFinalToken(cardinal)
        }
        let head = String(cardinal[..<lastSpace])
        let tail = String(cardinal[cardinal.index(after: lastSpace)...])
        return head + " " + ordinalizeFinalToken(tail)
    }

    private static func ordinalizeFinalToken(_ token: String) -> String {
        if let lastHyphen = token.lastIndex(of: "-") {
            let head = String(token[..<lastHyphen])
            let tail = String(token[token.index(after: lastHyphen)...])
            return head + "-" + ordinalizeComponent(tail)
        }
        return ordinalizeComponent(token)
    }

    private static func ordinalizeComponent(_ word: String) -> String {
        ordinalIrregulars[word] ?? (word + "th")
    }

    private static let ordinalIrregulars: [String: String] = [
        "one": "first", "two": "second", "three": "third", "five": "fifth",
        "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
        "twenty": "twentieth", "thirty": "thirtieth", "forty": "fortieth",
        "fifty": "fiftieth", "sixty": "sixtieth", "seventy": "seventieth",
        "eighty": "eightieth", "ninety": "ninetieth",
        "hundred": "hundredth", "thousand": "thousandth",
        "million": "millionth", "billion": "billionth",
    ]

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

    private static func lowercasedWordBefore(_ range: NSRange, in s: String) -> String? {
        guard let swiftRange = Range(range, in: s) else { return nil }
        var cursor = swiftRange.lowerBound
        while cursor > s.startIndex {
            let previous = s.index(before: cursor)
            guard s[previous].isWhitespace else { break }
            cursor = previous
        }

        let end = cursor
        while cursor > s.startIndex {
            let previous = s.index(before: cursor)
            guard s[previous].isLetter else { break }
            cursor = previous
        }

        guard cursor < end else { return nil }
        return String(s[cursor..<end]).lowercased()
    }

    private static func previousNonWhitespaceCharacter(before range: NSRange, in s: String)
        -> Character?
    {
        guard let swiftRange = Range(range, in: s) else { return nil }
        var cursor = swiftRange.lowerBound
        while cursor > s.startIndex {
            cursor = s.index(before: cursor)
            if !s[cursor].isWhitespace { return s[cursor] }
        }
        return nil
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
