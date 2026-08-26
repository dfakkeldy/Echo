// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone, sim-free regression check for the English OOV grapheme→IPA fallback
// (mirror of MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift).
// Run: swift Tools/oov_check.swift   — asserts every output is vocab-safe + non-empty,
// plus exact golden cases (Jacqui → ʤˈækɪ). Exits non-zero on any failure.
import Foundation

// Kokoro phoneme vocab (the ONLY symbols the model accepts). Built from Unicode
// SCALARS so combining marks (e.g. U+0303) don't merge with the adjacent space
// into one grapheme cluster (which would wrongly drop " " from the set).
let VOCAB_STR =
    ";:,.!?—…\"()“” ̃ʣʥʦʨᵝꭧAIOQSTWYᵊabcdefhijklmnopqrstuvwxyzɑɐɒæβɔɕçɖðʤəɚɛɜɟɡɥɨɪʝɯɰŋɳɲɴøɸθœɹɾɻʁɽʂʈʧʊʋʌɣɤχʎʒʔˈˌːʰʲ↓→↗↘ᵻ"
let VOCAB = Set((VOCAB_STR + "ʃ").unicodeScalars.map(Character.init))  // ʃ U+0283 is in vocab (id 131); ensure present

// Ordered grapheme→IPA rules (longest grapheme groups first → greedy longest-match).
let RULES: [(String, String)] = [
    ("augh", "ɔ"), ("ough", "ʌf"), ("eigh", "eɪ"), ("tion", "ʃən"), ("sion", "ʒən"),
    ("cian", "ʃən"),
    ("cqu", "k"), ("igh", "aɪ"), ("tch", "ʧ"), ("sch", "sk"), ("dge", "ʤ"), ("gli", "li"),
    ("gni", "ni"),
    ("ya", "ja"), ("ye", "je"), ("yi", "ji"), ("yo", "jo"), ("yu", "ju"),
    ("bh", "v"), ("mh", "v"), ("dh", "d"), ("fh", "h"), ("gh", "ɡ"), ("ch", "ʧ"), ("sh", "ʃ"),
    ("th", "θ"),
    ("ph", "f"), ("wh", "w"), ("ck", "k"), ("ng", "ŋ"), ("qu", "kw"), ("kn", "n"), ("wr", "ɹ"),
    ("mb", "m"),
    ("gn", "n"), ("cc", "k"), ("ll", "l"), ("tt", "t"), ("nn", "n"), ("ss", "s"), ("ff", "f"),
    ("pp", "p"),
    ("mm", "m"), ("dd", "d"), ("rr", "ɹ"), ("zz", "z"), ("bb", "b"),
    ("aoi", "i"), ("ao", "i"), ("eau", "oʊ"), ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ou", "aʊ"),
    ("ow", "oʊ"),
    ("oa", "oʊ"), ("oi", "ɔɪ"), ("oy", "ɔɪ"), ("ai", "eɪ"), ("ay", "eɪ"), ("au", "ɔ"), ("aw", "ɔ"),
    ("ew", "u"),
    ("ey", "i"), ("ie", "i"), ("ue", "u"), ("oe", "oʊ"), ("ae", "i"),
    ("ce", "s"), ("ci", "si"), ("cy", "si"), ("ge", "ʤ"), ("gi", "ʤi"), ("gy", "ʤi"),
    ("a", "æ"), ("e", "ɛ"), ("i", "ɪ"), ("o", "ɒ"), ("u", "ʌ"), ("y", "i"),
    ("b", "b"), ("c", "k"), ("d", "d"), ("f", "f"), ("g", "ɡ"), ("h", "h"), ("j", "ʤ"), ("k", "k"),
    ("l", "l"),
    ("m", "m"), ("n", "n"), ("p", "p"), ("q", "k"), ("r", "ɹ"), ("s", "s"), ("t", "t"), ("v", "v"),
    ("w", "w"),
    ("x", "ks"), ("z", "z"),
]

let DIGITS: [Character: String] = [
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
    "7": "seven", "8": "eight", "9": "nine",
]

// Pre-stressed letter names for ALL-CAPS initialisms (each is its own stressed word).
let LETTER_NAMES: [Character: String] = [
    "a": "ˈeɪ", "b": "bˈi", "c": "sˈi", "d": "dˈi", "e": "ˈi", "f": "ˈɛf", "g": "ʤˈi", "h": "ˈeɪʧ",
    "i": "ˈaɪ",
    "j": "ʤˈeɪ", "k": "kˈeɪ", "l": "ˈɛl", "m": "ˈɛm", "n": "ˈɛn", "o": "ˈoʊ", "p": "pˈi",
    "q": "kjˈu", "r": "ˈɑɹ",
    "s": "ˈɛs", "t": "tˈi", "u": "jˈu", "v": "vˈi", "w": "dˈʌbəlju", "x": "ˈɛks", "y": "wˈaɪ",
    "z": "zˈi",
]

let VOWELS = Set("aeiouæɛɪɒʌɔəʊɚɜɐɑɨɯɤøœ")
let SPECIAL_FOLDS: [(String, String)] = [
    ("Ø", "o"), ("ø", "o"), ("Ł", "l"), ("ł", "l"), ("Þ", "th"), ("þ", "th"), ("Ð", "d"),
    ("ð", "d"),
    ("Æ", "ae"), ("æ", "ae"), ("Œ", "oe"), ("œ", "oe"), ("ß", "ss"),
]

func insertStress(_ s: String) -> String {
    guard let first = s.firstIndex(where: { VOWELS.contains($0) }) else { return s }
    return String(s[..<first]) + "ˈ" + String(s[first...])
}

func tablePhonemize(_ token: String) -> String {
    var t = token
    for (k, v) in SPECIAL_FOLDS { t = t.replacingOccurrences(of: k, with: v) }
    t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
    t = t.lowercased()
    if t.hasPrefix("x") { t = "z" + t.dropFirst() }
    var out = ""
    var idx = t.startIndex
    outer: while idx < t.endIndex {
        for (g, ipa) in RULES where t[idx...].hasPrefix(g) {
            out += ipa
            idx = t.index(idx, offsetBy: g.count)
            continue outer
        }
        idx = t.index(after: idx)  // drop unmappable char (never pass through)
    }
    return insertStress(out)
}

func phonemes(for raw: String) -> String {
    var s = raw
    for ch in ["-", "'", "’", "\u{2010}"] { s = s.replacingOccurrences(of: ch, with: " ") }
    var s2 = ""
    for c in s {
        if let w = DIGITS[c] { s2 += " " + w + " " } else { s2.append(c) }
    }
    var words: [String] = []
    for tok in s2.split(separator: " ").map(String.init) {
        let alpha = tok.filter { $0.isLetter }
        if alpha.count >= 2 && alpha.allSatisfy({ $0.isUppercase }) {
            for c in tok where c.isLetter {
                if let name = LETTER_NAMES[Character(c.lowercased())] { words.append(name) }
            }
            continue
        }
        let ph = tablePhonemize(tok)
        if !ph.isEmpty { words.append(ph) }
    }
    let joined = words.joined(separator: " ")
    return joined.isEmpty ? "ə" : joined  // last resort: schwa, never silent
}

// ---- Verification ----
let golden: [(String, String)] = [
    ("Jacqui", "ʤˈækɪ"), ("FAQ", "ˈɛf ˈeɪ kjˈu"), ("JSON", "ʤˈeɪ ˈɛs ˈoʊ ˈɛn"),
    ("mother-in-law", "mˈɒθɛɹ ˈɪn lˈɔ"), ("Niamh", "nˈɪæv"), ("Xavier", "zˈæviɹ"),
    ("yes", "jˈes"), ("café", "kˈæfɛ"), ("Siobhan", "sˈɪɒvæn"), ("ice", "ˈɪs"),
]
let corpus = [
    "Jacqui", "Niamh", "Siobhan", "Caoimhe", "Aoife", "Saoirse", "Mhairi", "Sadhbh", "Eoghan",
    "Aodhán", "Sinéad", "Éire", "Oisín", "Tadhg", "Éilís", "Maoilíosa", "Hermione", "Phoebe",
    "Xavier", "Giancarlo", "Callaghan", "Monaghan", "Greenhalgh", "Hugh", "Vaughn", "Llywelyn",
    "O'Brien", "O'Sullivan", "D'Angelo", "N'Golo", "Zoë", "Chloë", "Renée", "José", "Núñez",
    "François", "Müller", "Søren", "Cthulhu", "Yog-Sothoth", "Nyarlathotep", "Drizzt", "Tsujihara",
    "Xi", "Xu", "Ng", "Mbeki", "Nguyen", "Tchaikovsky", "Wojciech", "Grzegorz", "Eyjafjallajökull",
    "Þór", "Beyoncé", "Daenerys", "Khaleesi", "Ysolde", "Beaujolais", "Worcestershire", "Bjork",
    "Bjørk", "Brontë", "Llewellyn", "Jürgen", "Dvořák", "Łódź", "Antonín", "Xochitl", "Qatar",
    "Iqbal", "Yannick", "Yves", "Hieronymus", "Giuseppe", "Gnocchi", "Bruschetta", "Cinzano",
    "Mbappé", "Ngozi", "Pho", "Schwarzenegger", "Csárdás", "Hawai'i", "smörgåsbord", "jalapeño",
    "naïve", "café", "SQLite", "GIF", "JPEG", "kubectl", "nginx", "PostgreSQL", "Xcode", "README",
    "FAQ", "GPU", "JSON", "XML", "HTTP", "SSH", "URL", "API", "OAuth", "JWT", "UUID", "ASCII",
    "regex", "grep", "cron", "tmux", "GitHub", "ngrok", "Wi-Fi", "i18n", "k8s", "ARM64", "x86",
    "Node.js", "TypeScript", "Kubernetes", "don't", "we'll", "y'all", "rock'n'roll",
    "mother-in-law", "ex-wife", "T-shirt", "x-ray", "tsk", "nth", "hmm", "brrr", "cwm", "shhh",
    "zzz", "yacht", "yes", "Yiddish", "xylophone", "schwa", "schnitzel", "ocean", "ice", "who",
    "whole", "thumb", "number", "though", "borough", "thoroughfare", "book", "flood", "mp3",
    "COVID19", "B2B", "3D", "Qatar", "pneumonia", "ungodly",
]

var fails = 0
print("== GOLDEN ==")
for (w, exp) in golden {
    let got = phonemes(for: w)
    let ok = got == exp
    if !ok { fails += 1 }
    print("\(ok ? "✔" : "✘") \(w) -> \(got)\(ok ? "" : "   EXPECTED \(exp)")")
}
print("\n== CORPUS (non-empty + vocab-safe) ==")
var vocabViolations = 0
var empties = 0
for w in corpus {
    let got = phonemes(for: w)
    let bad = got.filter { !VOCAB.contains($0) }
    if got.isEmpty {
        empties += 1
        print("✘ EMPTY: \(w)")
    }
    if !bad.isEmpty {
        vocabViolations += 1
        print("✘ NON-VOCAB \(Array(Set(bad))) in \(w) -> \(got)")
    }
}
print("\nCorpus: \(corpus.count) words, empties=\(empties), vocabViolations=\(vocabViolations)")
print("Golden failures: \(fails)")
if fails == 0 && empties == 0 && vocabViolations == 0 {
    print("\nALL GREEN ✅")
} else {
    print("\nFAILURES ❌")
    exit(1)
}
