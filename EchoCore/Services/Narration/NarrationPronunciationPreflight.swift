// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if DEBUG
    import Synchronization
#endif

typealias NeuralEvaluator = @Sendable (String) async throws -> NeuralG2PShadowResult

struct NarrationPronunciationCandidate: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case emptyPhonemes
        case acronym
        case fallbackPronunciation
        case properNoun
        case sourceDisagreement
        case multipleTrustedPronunciations
        case contextualFamily
        case unsupportedPhonemes
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
            reasons.sorted {
                $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending
            },
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
    #if DEBUG
        nonisolated static let debugNeuralBatchRanOnMainThread = Mutex<Bool?>(nil)
        nonisolated private static func debugIsMainThread() -> Bool { Thread.isMainThread }
    #endif

    static func scan(
        texts: [String],
        overrides: PronunciationOverrides,
        phonemes: (String) -> String
    ) -> [NarrationPronunciationCandidate] {
        scan(
            texts: texts,
            overrides: overrides,
            pronunciation: { word in (phonemes(word), []) })
    }

    static func scan(
        texts: [String],
        overrides: PronunciationOverrides,
        pronunciation: (String) -> (phonemes: String, fallbackHits: [PronunciationFallbackHit])
    ) -> [NarrationPronunciationCandidate] {
        var buckets:
            [String: (
                display: String,
                reasons: Set<NarrationPronunciationCandidate.Reason>,
                count: Int
            )] = [:]
        let overridden = Set(overrides.entries.keys.map { $0.lowercased() })

        for text in texts {
            let normalized = TextNormalizer.normalize(text)
            for raw in normalized.split(whereSeparator: isWordSeparator) {
                let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
                guard word.count > 1 else { continue }
                let key = word.lowercased()
                guard !overridden.contains(key) else { continue }

                var reasons: Set<NarrationPronunciationCandidate.Reason> = []
                let result = pronunciation(word)
                if result.phonemes.isEmpty { reasons.insert(.emptyPhonemes) }
                if !result.fallbackHits.isEmpty { reasons.insert(.fallbackPronunciation) }
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

    /// Evaluates each genuine deterministic OOV spelling twice, off the caller's
    /// actor, so the live path can preserve observed instability in advisory
    /// evidence. The repetition is deliberately bounded; immutable synthesis
    /// chunks and their selected pronunciation receipts are preserved.
    @concurrent
    nonisolated static func applyingNeuralShadow(
        to plan: NarrationRenderPlan,
        evaluator: NeuralEvaluator
    ) async throws -> NarrationRenderPlan {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugNeuralBatchRanOnMainThread.withLock { $0 = isMainThread }
        #endif

        let words = Set(
            plan.blocks.flatMap(\.pronunciationDecisions).compactMap { decision in
                PronunciationCandidateAnalyzer.isNeuralOOVComparisonCandidate(decision)
                    ? decision.normalizedWord : nil
            }
        ).sorted()
        guard !words.isEmpty else { return plan }

        let repeatCount = 2
        var results: [String: [NeuralG2PShadowResult]] = [:]
        results.reserveCapacity(words.count)
        for word in words {
            var repeatedResults: [NeuralG2PShadowResult] = []
            repeatedResults.reserveCapacity(repeatCount)
            for _ in 0..<repeatCount {
                try Task.checkCancellation()
                let result: NeuralG2PShadowResult
                do {
                    result = try await evaluator(word)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result = .rejected(.inference)
                }
                try Task.checkCancellation()
                if result == .rejected(.cancelled) {
                    throw CancellationError()
                }
                repeatedResults.append(result)
            }
            results[word] = repeatedResults
        }

        return NarrationRenderPlan(
            blocks: plan.blocks.map { block in
                NarrationPlannedBlock(
                    blockID: block.blockID,
                    originalBlock: block.originalBlock,
                    synthesisChunks: block.synthesisChunks,
                    pronunciationDecisions: block.pronunciationDecisions.map { decision in
                        guard let repeatedResults = results[decision.normalizedWord] else {
                            return decision
                        }
                        return repeatedResults.reduce(decision) { partialDecision, result in
                            PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
                                result,
                                to: partialDecision)
                        }
                    },
                    pronunciationDecisionDiagnostics: block.pronunciationDecisionDiagnostics,
                    trailingSilence: block.trailingSilence)
            })
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
                pronunciation: { word in
                    let result = g2p.result(for: word)
                    return (result.phonemes, result.fallbackHits)
                })
        }
    }
#endif
