// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Fixture-driven cover for the closed-compound fallback: an OOV closed compound
/// must be voiced from its known lexical components, while a derived or
/// accidentally-splittable word must keep falling through to the whole-token
/// guess, and a listed word must keep coming from the lexicon.
@Suite struct ClosedCompoundPronunciationTests {

    private struct CompoundFixture: Decodable {
        let caseID: String
        let word: String
        /// `compound`, `whole-token-fallback`, or `lexicon`.
        let expectedOutcome: String
        let expectedLeft: String?
        let expectedRight: String?
        let expectedLeftIPA: String?
        let expectedRightIPA: String?
        let expectedIPA: String
        let evidence: String
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureURL: URL {
        repositoryURL
            .appendingPathComponent("EchoTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Pronunciation")
            .appendingPathComponent("closed_compound_v1.jsonl")
    }

    private var goldURL: URL {
        repositoryURL
            .appendingPathComponent("EchoCore")
            .appendingPathComponent("Services")
            .appendingPathComponent("Narration")
            .appendingPathComponent("MisakiResources")
            .appendingPathComponent("us_gold.json")
    }

    private func fixtures() throws -> [CompoundFixture] {
        let data = try Data(contentsOf: fixtureURL)
        return try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(CompoundFixture.self, from: Data($0.utf8)) }
    }

    /// Stress markers are repositioned when components are joined, and the
    /// lexicon's flap `ɾ` is mapped to the vocab-safe `T`, so component evidence
    /// is compared on the segment sequence alone.
    private func segments(_ ipa: String) -> String {
        String(
            ipa
                .replacingOccurrences(of: "ɾ", with: "T")
                .replacingOccurrences(of: "ʔ", with: "t")
                .filter { $0 != "ˈ" && $0 != "ˌ" })
    }

    private func evidence(
        for word: String,
        in result: KokoroG2P.Result
    ) throws -> PronunciationTokenEvidence {
        try #require(
            result.tokenEvidence.first { $0.text.lowercased() == word.lowercased() },
            Comment(rawValue: "no token evidence for \(word)"))
    }

    @Test func committedCorpusCoversEveryOutcome() throws {
        let rows = try fixtures()
        let counts = Dictionary(grouping: rows, by: \.expectedOutcome).mapValues(\.count)

        #expect(rows.count == 21)
        #expect(counts["compound"] == 6)
        #expect(counts["whole-token-fallback"] == 8)
        #expect(counts["lexicon"] == 7)
        #expect(Set(rows.map(\.caseID)).count == rows.count)
    }

    /// The reported defect: `fogline`, `tidewatcher`, and `boatlight` resolved
    /// through the generic G2P fallback (`fogline` lost its `g` outright) because
    /// the split gate only ever consulted the modifier. Each must now be built
    /// from its `us_gold` component pronunciations.
    @Test func closedCompoundsAreBuiltFromGoldComponents() throws {
        let gold = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: goldURL))
                as? [String: Any])

        for row in try fixtures() where row.expectedOutcome == "compound" {
            let comment = Comment(rawValue: "\(row.caseID) (\(row.evidence))")
            let left = try #require(row.expectedLeft, comment)
            let right = try #require(row.expectedRight, comment)
            let leftIPA = try #require(row.expectedLeftIPA, comment)
            let rightIPA = try #require(row.expectedRightIPA, comment)

            // The components must really be the lexicon's own entries, otherwise
            // the fixture would be asserting an invented pronunciation.
            #expect(gold[left] as? String == leftIPA, comment)
            #expect(gold[right] as? String == rightIPA, comment)

            let result = KokoroG2P().result(for: row.word, displayText: row.word)
            #expect(result.pronunciationEvidenceValidation == .matched, comment)
            let token = try evidence(for: row.word, in: result)
            #expect(token.selectedPhonemes == row.expectedIPA, comment)
            // Built from the components, not a coincidental match.
            #expect(
                segments(row.expectedIPA) == segments(leftIPA) + segments(rightIPA),
                comment)
        }
    }

    /// Too eager is worse than too shy: a word that merely *can* be cut into two
    /// lexicon entries (`cancel` + `late`, `adhere` + `scent`), a suffix
    /// derivation, or a word with more than one qualifying split must keep the
    /// whole-token pronunciation.
    @Test func derivedAndAccidentallySplittableWordsKeepTheWholeTokenGuess() throws {
        for row in try fixtures() where row.expectedOutcome == "whole-token-fallback" {
            let comment = Comment(rawValue: "\(row.caseID) (\(row.evidence))")
            let result = KokoroG2P().result(for: row.word, displayText: row.word)
            let token = try evidence(for: row.word, in: result)

            #expect(token.selectedPhonemes == row.expectedIPA, comment)
            #expect(token.usedFallback, comment)
        }
    }

    /// A word the lexicon knows must never be re-derived, including the
    /// `UniversalPronunciationResolver.exceptionWords` and the `-able` family.
    @Test func listedWordsStillComeFromTheLexicon() throws {
        for row in try fixtures() where row.expectedOutcome == "lexicon" {
            let comment = Comment(rawValue: "\(row.caseID) (\(row.evidence))")
            let result = KokoroG2P().result(for: row.word, displayText: row.word)
            let token = try evidence(for: row.word, in: result)

            #expect(token.selectedPhonemes == row.expectedIPA, comment)
            #expect(!token.usedFallback, comment)
        }
    }

    /// A component-built pronunciation and a blind whole-token guess share the
    /// same OOV rating, so before compound provenance the audit reported both as
    /// `g2p.fallback.<word>` and a reviewer could not tell a working compound
    /// from a fallback that happened to sound plausible. The rule ID must now
    /// name the path, and the rationale must cite the components.
    @MainActor @Test func auditDistinguishesTheCompoundPathFromTheFallback() throws {
        let text = "The fogline hid the boatlight from the tidewatcher."
        let result = KokoroG2P().result(for: text, displayText: text)
        #expect(result.pronunciationEvidenceValidation == .matched)

        let expectedComponents = [
            "fogline": "fog+line",
            "boatlight": "boat+light",
            "tidewatcher": "tide+watcher",
        ]
        for (word, components) in expectedComponents {
            let comment = Comment(rawValue: word)
            let token = try evidence(for: word, in: result)
            #expect(token.compoundComponents == components, comment)

            let seed = try #require(
                PronunciationAuditContext.decisionSeed(
                    for: token,
                    blockID: "block-1",
                    chunkDisplayText: text,
                    blockDisplayText: text,
                    wordBase: 0),
                comment)
            #expect(seed.ruleID == "g2p.compound.\(word)", comment)
            #expect(seed.rationale.contains(components), comment)
            #expect(seed.selectedIPA == token.selectedPhonemes, comment)
        }

        // An ordinary OOV word keeps the whole-token fallback rule ID.
        let guessed = try evidence(for: "fogline", in: result)
        #expect(guessed.usedFallback)
        let plain = KokoroG2P().result(for: "Jacqui", displayText: "Jacqui")
        let plainToken = try evidence(for: "Jacqui", in: plain)
        #expect(plainToken.compoundComponents == nil)
        let plainSeed = try #require(
            PronunciationAuditContext.decisionSeed(
                for: plainToken,
                blockID: "block-1",
                chunkDisplayText: "Jacqui",
                blockDisplayText: "Jacqui",
                wordBase: 0))
        #expect(plainSeed.ruleID == "g2p.fallback.jacqui")
    }

    /// Every exception word must stay a lexicon resolution — the compound gate
    /// runs only after whole-word lookup fails, and these must never reach it.
    @Test func exceptionWordsNeverReachTheCompoundGate() throws {
        for word in UniversalPronunciationResolver.exceptionWords.sorted() {
            let result = KokoroG2P().result(for: word, displayText: word)
            let token = try evidence(for: word, in: result)
            #expect(!token.usedFallback, Comment(rawValue: "exception word \(word)"))
        }
    }
}
