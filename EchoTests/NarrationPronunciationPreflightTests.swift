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

    @Test func flagsFallbackPronunciationsBeforeRender() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["verified verified inclusive"],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciation: { word in
                if word == "verified" {
                    return ("vˈɛɹɪfid", [PronunciationFallbackHit(word: word, ipa: "vˈɛɹɪfid")])
                }
                return ("ok", [])
            })

        #expect(candidates.count == 1)
        #expect(candidates[0].word == "verified")
        #expect(candidates[0].reasons == [.fallbackPronunciation])
        #expect(candidates[0].occurrenceCount == 2)
    }

    @Test func candidatesEncodeAsStableLocalReportJSON() throws {
        let candidates = [
            NarrationPronunciationCandidate(
                word: "Xcode",
                reasons: [.emptyPhonemes, .fallbackPronunciation, .properNoun],
                occurrenceCount: 4)
        ]

        let data = try NarrationPronunciationPreflight.encodeReport(candidates)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""word" : "Xcode""#))
        #expect(json.contains(#""occurrenceCount" : 4"#))
        #expect(json.contains("emptyPhonemes"))
        #expect(json.contains("fallbackPronunciation"))
        #expect(json.contains("properNoun"))
    }
}
