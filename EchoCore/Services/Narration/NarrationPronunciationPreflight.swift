// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationPronunciationCandidate: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case emptyPhonemes
        case acronym
        case properNoun
    }

    let word: String
    let reasons: Set<Reason>
    let occurrenceCount: Int

    init(word: String, reasons: Set<Reason>, occurrenceCount: Int) {
        self.word = word
        self.reasons = reasons
        self.occurrenceCount = occurrenceCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.word = try container.decode(String.self, forKey: .word)
        self.reasons = Set(try container.decode([Reason].self, forKey: .reasons))
        self.occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word, forKey: .word)
        try container.encode(
            reasons.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending },
            forKey: .reasons)
        try container.encode(occurrenceCount, forKey: .occurrenceCount)
    }

    private enum CodingKeys: CodingKey {
        case word
        case reasons
        case occurrenceCount
    }
}

enum NarrationPronunciationPreflight {
    static func scan(
        texts: [String],
        overrides: PronunciationOverrides,
        phonemes: (String) -> String
    ) -> [NarrationPronunciationCandidate] {
        var buckets: [
            String: (
                display: String,
                reasons: Set<NarrationPronunciationCandidate.Reason>,
                count: Int
            )
        ] = [:]
        let overridden = Set(overrides.entries.keys.map { $0.lowercased() })

        for text in texts {
            let normalized = TextNormalizer.normalize(text)
            for raw in normalized.split(whereSeparator: isWordSeparator) {
                let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
                guard word.count > 1 else { continue }
                let key = word.lowercased()
                guard !overridden.contains(key) else { continue }

                var reasons: Set<NarrationPronunciationCandidate.Reason> = []
                if phonemes(word).isEmpty { reasons.insert(.emptyPhonemes) }
                if word.allSatisfy(\.isUppercase), word.count >= 2 { reasons.insert(.acronym) }
                if word.first?.isUppercase == true, !word.allSatisfy(\.isUppercase) {
                    reasons.insert(.properNoun)
                }
                guard !reasons.isEmpty else { continue }

                var bucket = buckets[key] ?? (word, [], 0)
                bucket.reasons.formUnion(reasons)
                bucket.count += 1
                buckets[key] = bucket
            }
        }

        return buckets.values
            .map {
                NarrationPronunciationCandidate(
                    word: $0.display,
                    reasons: $0.reasons,
                    occurrenceCount: $0.count)
            }
            .sorted { lhs, rhs in
                if lhs.occurrenceCount != rhs.occurrenceCount {
                    return lhs.occurrenceCount > rhs.occurrenceCount
                }
                return lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
            }
    }

    private static func isWordSeparator(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && character != "'"
    }

    static func encodeReport(_ candidates: [NarrationPronunciationCandidate]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(candidates)
    }
}

#if os(iOS) || os(macOS)
    extension NarrationPronunciationPreflight {
        static func scan(
            blocks: [EPubBlockRecord],
            overrides: PronunciationOverrides,
            g2p: KokoroG2P = KokoroG2P()
        ) -> [NarrationPronunciationCandidate] {
            scan(
                texts: blocks.compactMap(\.text),
                overrides: overrides,
                phonemes: g2p.phonemes(for:))
        }
    }
#endif
