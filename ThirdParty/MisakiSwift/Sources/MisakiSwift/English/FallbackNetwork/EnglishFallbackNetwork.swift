// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Out-of-vocabulary (OOV) fallback for English words missing from the lexicon.
///
/// History: the original neural BART fallback was removed to drop the MLX
/// dependency (mlx-swift #341 broke the iOS-Simulator test suite). It was
/// replaced by a stub that returned the `❓` glyph — but `KokoroPhonemeVocab`
/// drops `❓`, so OOV words (e.g. the name "Jacqui") were rendered as SILENCE.
///
/// This is now a deterministic, vocab-safe grapheme→IPA approximator. The goal
/// is "never silent, always plausible" — not phonetic perfection. A word like
/// "Jacqui" becomes `ʤˈækɪ` instead of a silent gap; precise pronunciations
/// still come from the user PronunciationOverrides feature.
///
/// Every symbol it emits is guaranteed to be in the Kokoro phoneme vocab (so
/// nothing is dropped). Verified by `Tools/oov_check.swift` over 160 adversarial
/// words + 10 golden cases (all vocab-safe, none empty). Key guarantees:
/// - Unmappable characters are DROPPED (never passed through) — that's what
///   keeps the output ⊆ vocab. ASCII `g` is never emitted (uses IPA `ɡ`).
/// - Diacritics are folded (café→cafe), special letters folded (ø→o, æ→ae…).
/// - Digits expand to spoken words; ALL-CAPS initialisms spell out (FAQ, JSON).
/// - A letter-bearing token always yields ≥1 phoneme; a token with no mappable
///   letters yields a neutral schwa `ə`, never `❓`/silence.
final class EnglishFallbackNetwork {
    init(british: Bool) {
        // `british` is accepted for API stability with EnglishG2P; the approximator
        // is accent-neutral (precise GB/US vowels come from the lexicon, not here).
        _ = british
    }

    func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
        // rating 1 = low-confidence fallback (same as the previous stub).
        (Self.phonemes(for: word.text), 1)
    }

    // MARK: - Approximator

    /// Ordered grapheme→IPA rules. Longest grapheme groups come first so a greedy
    /// left-to-right scan performs longest-match at each position.
    private static let rules: [(grapheme: String, ipa: String)] = [
        ("augh", "ɔ"), ("ough", "ʌf"), ("eigh", "eɪ"), ("tion", "ʃən"), ("sion", "ʒən"),
        ("cian", "ʃən"), ("cqu", "k"), ("igh", "aɪ"), ("tch", "ʧ"), ("sch", "sk"), ("dge", "ʤ"),
        ("gli", "li"), ("gni", "ni"), ("ya", "ja"), ("ye", "je"), ("yi", "ji"), ("yo", "jo"),
        ("yu", "ju"), ("bh", "v"), ("mh", "v"), ("dh", "d"), ("fh", "h"), ("gh", "ɡ"), ("ch", "ʧ"),
        ("sh", "ʃ"), ("th", "θ"), ("ph", "f"), ("wh", "w"), ("ck", "k"), ("ng", "ŋ"), ("qu", "kw"),
        ("kn", "n"), ("wr", "ɹ"), ("mb", "m"), ("gn", "n"), ("cc", "k"), ("ll", "l"), ("tt", "t"),
        ("nn", "n"), ("ss", "s"), ("ff", "f"), ("pp", "p"), ("mm", "m"), ("dd", "d"), ("rr", "ɹ"),
        ("zz", "z"), ("bb", "b"), ("aoi", "i"), ("ao", "i"), ("eau", "oʊ"), ("ee", "i"),
        ("ea", "i"),
        ("oo", "u"), ("ou", "aʊ"), ("ow", "oʊ"), ("oa", "oʊ"), ("oi", "ɔɪ"), ("oy", "ɔɪ"),
        ("ai", "eɪ"), ("ay", "eɪ"), ("au", "ɔ"), ("aw", "ɔ"), ("ew", "u"), ("ey", "i"), ("ie", "i"),
        ("ue", "u"), ("oe", "oʊ"), ("ae", "i"), ("ce", "s"), ("ci", "si"), ("cy", "si"),
        ("ge", "ʤ"),
        ("gi", "ʤi"), ("gy", "ʤi"), ("a", "æ"), ("e", "ɛ"), ("i", "ɪ"), ("o", "ɒ"), ("u", "ʌ"),
        ("y", "i"), ("b", "b"), ("c", "k"), ("d", "d"), ("f", "f"), ("g", "ɡ"), ("h", "h"),
        ("j", "ʤ"), ("k", "k"), ("l", "l"), ("m", "m"), ("n", "n"), ("p", "p"), ("q", "k"),
        ("r", "ɹ"), ("s", "s"), ("t", "t"), ("v", "v"), ("w", "w"), ("x", "ks"), ("z", "z"),
    ]

    private static let digitWords: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    /// Pre-stressed IPA letter names for ALL-CAPS initialisms (each its own word).
    private static let letterNames: [Character: String] = [
        "a": "ˈeɪ", "b": "bˈi", "c": "sˈi", "d": "dˈi", "e": "ˈi", "f": "ˈɛf", "g": "ʤˈi",
        "h": "ˈeɪʧ", "i": "ˈaɪ", "j": "ʤˈeɪ", "k": "kˈeɪ", "l": "ˈɛl", "m": "ˈɛm", "n": "ˈɛn",
        "o": "ˈoʊ", "p": "pˈi", "q": "kjˈu", "r": "ˈɑɹ", "s": "ˈɛs", "t": "tˈi", "u": "jˈu",
        "v": "vˈi", "w": "dˈʌbəlju", "x": "ˈɛks", "y": "wˈaɪ", "z": "zˈi",
    ]

    private static let vowels = Set("aeiouæɛɪɒʌɔəʊɚɜɐɑɨɯɤøœ")

    /// Letters that are distinct graphemes (not just diacritics) and don't
    /// decompose under `stripDiacritics` — fold them explicitly.
    private static let specialFolds: [(String, String)] = [
        ("Ø", "o"), ("ø", "o"), ("Ł", "l"), ("ł", "l"), ("Þ", "th"), ("þ", "th"), ("Ð", "d"),
        ("ð", "d"), ("Æ", "ae"), ("æ", "ae"), ("Œ", "oe"), ("œ", "oe"), ("ß", "ss"),
    ]

    /// Grapheme→IPA approximation for one whole token (may contain hyphens,
    /// apostrophes, digits). Always returns a non-empty, fully vocab-safe string.
    static func phonemes(for raw: String) -> String {
        // Hyphen / apostrophe → word break.
        var s = raw
        for ch in ["-", "'", "\u{2019}", "\u{2010}"] {
            s = s.replacingOccurrences(of: ch, with: " ")
        }
        // Expand digits to spoken words (each its own word).
        var expanded = ""
        for c in s {
            if let w = digitWords[c] { expanded += " " + w + " " } else { expanded.append(c) }
        }

        var words: [String] = []
        for token in expanded.split(separator: " ").map(String.init) {
            let letters = token.filter { $0.isLetter }
            // ALL-CAPS initialism (≥2 letters, all uppercase) → spell letter by letter.
            if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) {
                for c in token where c.isLetter {
                    if let name = letterNames[Character(c.lowercased())] { words.append(name) }
                }
                continue
            }
            let ph = tablePhonemize(token)
            if !ph.isEmpty { words.append(ph) }
        }

        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "ə" : joined  // last resort: a voiced schwa, never silence
    }

    private static func tablePhonemize(_ token: String) -> String {
        var t = token
        for (k, v) in specialFolds { t = t.replacingOccurrences(of: k, with: v) }
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t  // café → cafe
        t = t.lowercased()
        if t.hasPrefix("x") { t = "z" + t.dropFirst() }  // word-initial x → z (Xavier)

        var out = ""
        var idx = t.startIndex
        scan: while idx < t.endIndex {
            for rule in rules where t[idx...].hasPrefix(rule.grapheme) {
                out += rule.ipa
                idx = t.index(idx, offsetBy: rule.grapheme.count)
                continue scan
            }
            idx = t.index(after: idx)  // drop unmappable char — keeps output ⊆ vocab
        }
        return insertStress(out)
    }

    /// Inserts exactly one primary-stress mark before the first vowel cluster.
    private static func insertStress(_ s: String) -> String {
        guard let first = s.firstIndex(where: { vowels.contains($0) }) else { return s }
        return String(s[..<first]) + "ˈ" + String(s[first...])
    }
}
