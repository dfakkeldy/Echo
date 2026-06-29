// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits a block of prose into sub-chunks the TTS model can synthesize in one
/// call. The hard ceiling is Kokoro's ~510-phoneme context (the `af_heart` style
/// pack has exactly 510 rows = `MAX_PHONEME_LENGTH`; past it the style row
/// saturates and the model runs beyond its trained length). English phonemizes at
/// ~1.0–1.3 phonemes per character, so the default budget stays well under 510.
///
/// Bigger chunks are better for prosody: each `synthesize` call is an independent
/// utterance whose final word gets sentence-final intonation (a falling pitch and
/// trailing pause), so every chunk seam is an audible "period." Fewer, longer
/// chunks mean fewer seams. (The old 200-char cap was a FluidAudio/CoreML-era
/// guard against an ANE BNNS vocoder trap on long dynamic shapes; that engine was
/// replaced by the ONNX Runtime CPU EP, which has no such trap and runs dynamic
/// shapes natively — so the budget could be relaxed toward the real ceiling.)
///
/// Pure and deterministic so it's unit-testable without the real model.
///
/// Contract:
/// - Every returned piece has `count <= maxChars`.
/// - Splits preferentially at sentence/clause boundaries (`. ! ? ;` and newlines),
///   falls back to word boundaries for an over-long run, and only hard-splits a
///   single word that is itself longer than `maxChars`.
/// - Never loses content: concatenating the pieces reproduces the input modulo
///   collapsed runs of whitespace.
/// - Empty / whitespace-only input → `[]`.
enum NarrationTextChunker {

    /// Default budget: 350 chars ≈ 350–455 phonemes, a comfortable margin under
    /// Kokoro's ~510-phoneme ceiling while roughly halving the synth-call count
    /// (and so the number of audible chunk seams) versus the old 200-char cap.
    static func split(_ text: String, maxChars: Int = 350) -> [String] {
        guard maxChars > 0 else { return [] }

        // Normalize whitespace runs to single spaces so piece lengths are
        // predictable and joining reproduces the text modulo whitespace.
        let normalized = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        var pieces: [String] = []
        for sentence in splitIntoSentences(normalized, maxChars: maxChars) {
            if sentence.count <= maxChars {
                pieces.append(sentence)
            } else {
                pieces.append(contentsOf: wrapByWords(sentence, maxChars: maxChars))
            }
        }
        // Drop chunks that are purely decorative — punctuation, separators,
        // or character sequences with no speakable content. Synthesizing
        // "* * *" produces a stutter or silent audio gap, wasting ANE time
        // and producing audible artifacts in the narration stream.
        pieces = pieces.filter { chunk in
            let speakable = chunk.filter { $0.isLetter || $0.isNumber }
            return !speakable.isEmpty
        }
        return pieces
    }

    /// Greedily groups sentence/clause units so each accumulated piece stays
    /// `<= maxChars`. Sentence terminators (`. ! ? ;`) keep their trailing
    /// punctuation; newlines were already folded to spaces by `split`.
    private static func splitIntoSentences(_ text: String, maxChars: Int) -> [String] {
        var sentences: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }

        // Don't split inside a pronunciation-override link `[word](/ipa/)`: an IPA
        // syllable separator "." is a legitimate terminator-looking character, and
        // splitting there would insert spaces inside the link and corrupt it.
        var inLink = false
        var awaitingLinkTarget = false
        for ch in text {
            current.append(ch)
            if awaitingLinkTarget {
                inLink = ch == "("
                awaitingLinkTarget = false
            }
            if ch == "[" {
                inLink = true
            } else if ch == "]" {
                awaitingLinkTarget = true
            } else if ch == ")" {
                inLink = false
            }
            if !inLink, ch == "." || ch == "!" || ch == "?" || ch == ";" {
                flush()
            }
        }
        flush()

        // Greedily merge adjacent units that still fit under the budget, so a
        // paragraph of short sentences doesn't produce one synth call per
        // sentence (which would over-fragment the audio).
        var merged: [String] = []
        for s in sentences {
            if let last = merged.last, last.count + 1 + s.count <= maxChars {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// Wraps an over-long unit at word boundaries; a single word longer than
    /// `maxChars` is hard-split so no piece ever exceeds the budget.
    private static func wrapByWords(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let w = String(word)
            if w.count > maxChars {
                // Flush what we have, then hard-split the over-long word.
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(contentsOf: hardSplit(w, maxChars: maxChars))
                continue
            }
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= maxChars {
                current += " " + w
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Hard-splits a single token longer than `maxChars` into fixed-size slices.
    private static func hardSplit(_ word: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var idx = word.startIndex
        while idx < word.endIndex {
            let end = word.index(idx, offsetBy: maxChars, limitedBy: word.endIndex) ?? word.endIndex
            pieces.append(String(word[idx..<end]))
            idx = end
        }
        return pieces
    }
}
