// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionPayloadFilterTests {
    private func issue(
        expectedText: String,
        issueType: NarrationQAIssueType,
        status: NarrationQAIssueStatus,
        suggestedIPA: String?
    ) -> NarrationQualityIssueRecord {
        let fix = SuggestedFix(spokenForm: nil, ipa: suggestedIPA)
        let fixJSON = String(
            data: try! JSONEncoder().encode(fix), encoding: .utf8)
        return NarrationQualityIssueRecord(
            id: "issue-1",
            audiobookID: "file:///book/",
            sourceBlockID: "epub-file:///book/-s0-b0",
            sourceWordStart: 3,
            sourceWordEnd: 4,
            audioStartTime: 10.0,
            audioEndTime: 11.0,
            expectedText: expectedText,
            heardText: "chumly",
            issueType: issueType.rawValue,
            confidence: 0.9,
            suggestedFixJSON: fixJSON,
            status: status.rawValue,
            createdAt: "2026-06-29T00:00:00Z",
            resolvedAt: "2026-06-29T01:00:00Z")
    }

    @Test func emitsTermLevelPayloadForResolvedPronunciationFix() throws {
        let rec = issue(
            expectedText: "Cholmondeley",
            issueType: .pronunciation,
            status: .resolved,
            suggestedIPA: "\u{2C8}t\u{0283}\u{028C}mli")
        let payload = ContributionPayloadFilter.payload(
            from: rec, language: "en", voiceModelVersion: "kokoro-v1.0")
        let p = try #require(payload)
        #expect(p.term == "Cholmondeley")
        #expect(p.ipa == "\u{2C8}t\u{0283}\u{028C}mli")
        #expect(p.language == "en")
        #expect(p.voiceModelVersion == "kokoro-v1.0")
        #expect(p.confidence == 0.9)
    }

    @Test func dropsUnresolvedIssues() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .pronunciation,
            status: .open, suggestedIPA: "\u{2C8}t\u{0283}\u{028C}mli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsNonPronunciationIssues() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .omission,
            status: .resolved, suggestedIPA: "\u{2C8}t\u{0283}\u{028C}mli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsMissingIPA() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .pronunciation,
            status: .resolved, suggestedIPA: nil)
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsMultiWordExpectedTextToAvoidProseLeak() {
        let rec = issue(
            expectedText: "the dread pirate",
            issueType: .pronunciation,
            status: .resolved,
            suggestedIPA: "\u{2C8}t\u{0283}\u{028C}mli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }
}
