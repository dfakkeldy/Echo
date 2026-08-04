// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB

nonisolated struct PronunciationFallbackHit: Sendable, Equatable, Hashable, Codable {
    let word: String
    let ipa: String
}

nonisolated struct RenderedPronunciationFallbackHit: Sendable, Equatable {
    let blockID: String
    let audioStartTime: TimeInterval
    let audioEndTime: TimeInterval
    let fallback: PronunciationFallbackHit
}

enum PronunciationFallbackDiscovery {
    private static let confidence = 0.25
    private static let heardText = "G2P fallback"
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
    private static let canonicalLocale = Locale(identifier: "en_US_POSIX")

    static func records(
        audiobookID: String,
        hits: [RenderedPronunciationFallbackHit],
        createdAt: String
    ) -> [NarrationQualityIssueRecord] {
        var seen: Set<String> = []
        return hits.compactMap { hit in
            guard
                let displayWord = displayWord(for: hit.fallback.word),
                let canonical = canonicalKey(displayWord),
                !seen.contains("\(hit.blockID)\u{1F}\(canonical)"),
                !hit.fallback.ipa.isEmpty
            else { return nil }
            seen.insert("\(hit.blockID)\u{1F}\(canonical)")

            let fix = SuggestedFix(spokenForm: displayWord, ipa: hit.fallback.ipa)
            guard
                let fixData = try? JSONEncoder().encode(fix),
                let fixJSON = String(data: fixData, encoding: .utf8)
            else { return nil }

            return NarrationQualityIssueRecord(
                id: issueID(audiobookID: audiobookID, blockID: hit.blockID, canonicalWord: canonical),
                audiobookID: audiobookID,
                sourceBlockID: hit.blockID,
                sourceWordStart: nil,
                sourceWordEnd: nil,
                audioStartTime: hit.audioStartTime,
                audioEndTime: max(hit.audioEndTime, hit.audioStartTime),
                expectedText: displayWord,
                heardText: heardText,
                issueType: NarrationQAIssueType.pronunciation.rawValue,
                confidence: confidence,
                suggestedFixJSON: fixJSON,
                origin: NarrationQualityIssueOrigin.pronunciationPreflight.rawValue,
                status: NarrationQAIssueStatus.open.rawValue,
                createdAt: createdAt,
                resolvedAt: nil)
        }
    }

    static func persist(
        audiobookID: String,
        hits: [RenderedPronunciationFallbackHit],
        createdAt: String,
        db: DatabaseWriter
    ) throws {
        let candidates = records(audiobookID: audiobookID, hits: hits, createdAt: createdAt)
        guard !candidates.isEmpty else { return }

        try db.write { database in
            let existingPronunciationIssues = try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("issue_type") == NarrationQAIssueType.pronunciation.rawValue)
                .filter(Column("origin") == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue)
                .fetchAll(database)
            var existingWords: Set<String> = Set(
                existingPronunciationIssues.compactMap { issue in
                    guard let blockID = issue.sourceBlockID, let word = canonicalKey(issue.expectedText) else {
                        return nil
                    }
                    return "\(blockID)\u{1F}\(word)"
                })

            for var candidate in candidates {
                guard
                    let canonical = canonicalKey(candidate.expectedText),
                    let blockID = candidate.sourceBlockID,
                    !existingWords.contains("\(blockID)\u{1F}\(canonical)")
                else { continue }
                try candidate.insert(database)
                existingWords.insert("\(blockID)\u{1F}\(canonical)")
            }
        }
    }

    private static func displayWord(for raw: String) -> String? {
        let words = WordTokenizer.words(in: raw)
        guard words.count == 1 else { return nil }
        let word = String(words[0]).trimmingCharacters(in: trimCharacters)
        guard !word.isEmpty, word.contains(where: { $0.isLetter }) else { return nil }
        return word
    }

    private static func canonicalKey(_ word: String) -> String? {
        guard let display = displayWord(for: word) else { return nil }
        return display.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: canonicalLocale)
    }

    private static func issueID(audiobookID: String, blockID: String, canonicalWord: String) -> String {
        let payload = "\(audiobookID)\u{1F}\(blockID)\u{1F}\(canonicalWord)"
        let hash = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "pron-fallback-\(hash.prefix(24))"
    }
}
