// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationPronunciationPreflightTests {
    @Test func flagsAcronymsAndProperNounsNotAlreadyOverridden() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Xcode talks to NASA and Fakkeldy."],
            overrides: PronunciationOverrides(entries: ["Fakkeldy": "fɑkəldi"]),
            phonemes: { word in word == "Xcode" ? "" : "ok" })

        #expect(candidates.map(\.word).contains("Xcode"))
        #expect(candidates.map(\.word).contains("NASA"))
        #expect(!candidates.map(\.word).contains("Fakkeldy"))
    }

    @Test func collapsesRepeatedCandidates() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Kubernetes Kubernetes Kubernetes"],
            overrides: PronunciationOverrides(entries: [:]),
            phonemes: { _ in "" })

        #expect(candidates.count == 1)
        #expect(candidates[0].occurrenceCount == 3)
    }

    @Test func candidatesEncodeAsStableLocalReportJSON() throws {
        let candidates = [
            NarrationPronunciationCandidate(
                word: "Xcode",
                reasons: [.emptyPhonemes, .properNoun],
                occurrenceCount: 4)
        ]

        let data = try NarrationPronunciationPreflight.encodeReport(candidates)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""word" : "Xcode""#))
        #expect(json.contains(#""occurrenceCount" : 4"#))
        #expect(json.contains("emptyPhonemes"))
        #expect(json.contains("properNoun"))
    }
}
