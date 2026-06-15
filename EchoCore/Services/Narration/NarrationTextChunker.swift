import Foundation

/// Splits a block of prose into small sub-chunks the TTS model can synthesize
/// safely. FluidAudio's Kokoro path does **no** internal chunking and caps IPA
/// input at ~510 phonemes ("chunk longer prompts upstream"); feeding a whole
/// 400+ char EPUB block in one call drives the palettized vocoder into a dynamic
/// BNNS tensor shape that traps (uncatchable SIGTRAP). We bound the input here,
/// well under the cap, so every `synthesize` call gets a short, predictable run.
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

    /// Conservative default budget: ~200 chars sits comfortably under the
    /// ~510-phoneme cap even when a character expands to multiple phonemes.
    static func split(_ text: String, maxChars: Int = 200) -> [String] {
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

        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == ";" {
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
