// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated enum ContextualCandidateSlot: String, Codable, Equatable, Sendable {
    case a, b, c, d, needsReview
}

nonisolated enum ContextualFamilyState: String, Codable, Equatable, Sendable {
    case disabled, shadow, graduated
}

nonisolated enum DeterministicRuleStrength: String, Codable, Equatable, Sendable {
    case definitive, advisory, abstained
}

nonisolated struct ContextualPronunciationCandidate: Codable, Equatable, Sendable {
    let slot: ContextualCandidateSlot
    let candidateID: String
    let ipa: String
    let senseLabel: String
    let lexicalRole: String
}

nonisolated struct ContextualPronunciationOccurrence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let targetWord: String
    let precedingSentence: String?
    let targetSentence: String
    let followingSentence: String?
    let familyID: String
    let candidates: [ContextualPronunciationCandidate]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
}

nonisolated enum ContextualModelAvailability: String, Codable, Equatable, Sendable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

nonisolated enum ContextualModelFailure: String, Codable, Equatable, Sendable {
    case contextTooLarge
    case guardrail
    case refusal
    case unsupportedLanguageOrLocale
    case timeout
    case rateLimited
    case assetsUnavailable
    case concurrentRequest
    case parsing
    case invalidBatch
    case cancelled
    case unknown
}

nonisolated struct ContextualPronunciationFamily: Codable, Equatable, Sendable {
    let familyID: String
    let normalizedSpelling: String
    let candidates: [ContextualPronunciationCandidate]
    let state: ContextualFamilyState
}

nonisolated struct ContextualDeterministicAnalysis: Equatable, Sendable {
    let candidateID: String?
    let ruleID: String?
    let strength: DeterministicRuleStrength

    static let abstained = Self(
        candidateID: nil,
        ruleID: nil,
        strength: .abstained)
}

nonisolated struct ContextualPronunciationBatchRequest: Equatable, Sendable {
    let occurrences: [ContextualPronunciationOccurrence]
}

nonisolated struct ContextualModelSelection: Equatable, Sendable {
    let occurrenceID: String
    let slot: ContextualCandidateSlot
}

nonisolated struct ContextualModelRuntime: Codable, Equatable, Sendable {
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
}

nonisolated struct ContextualPronunciationBatchResult: Equatable, Sendable {
    let availability: ContextualModelAvailability
    let selections: [ContextualModelSelection]
    let failure: ContextualModelFailure?
    let runtime: ContextualModelRuntime
}

typealias ContextualPronunciationBatchEvaluator =
    @Sendable (ContextualPronunciationBatchRequest) async throws
    -> ContextualPronunciationBatchResult

nonisolated struct ContextualPronunciationEvidence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let familyID: String
    let candidatePackVersion: String
    let submittedCandidateIDs: [String]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
    let modelCandidateID: String?
    let modelAbstained: Bool
    let modelAvailability: ContextualModelAvailability
    let modelFailure: ContextualModelFailure?
    let familyState: ContextualFamilyState
    let acceptanceReason: ContextualAcceptanceReason
    let promptSchemaVersion: String
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
    let humanCandidateID: String?
    let humanCorrectionScope: String?
    let isLimited: Bool
}

nonisolated enum ContextualAcceptanceReason: String, Codable, Equatable, Sendable {
    case shadowObserved
    case shadowNeedsReview
    case shadowModelUnavailable
    case shadowModelFailure
}

nonisolated struct ContextualPronunciationPreflightConfiguration: Equatable, Sendable {
    let maximumBatchCount: Int
    let maximumPromptCharacters: Int

    static let phaseTwo = Self(
        maximumBatchCount: 8,
        maximumPromptCharacters: 8_000)
}
