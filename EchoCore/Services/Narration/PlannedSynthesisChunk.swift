// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated struct PlannedSynthesisChunk: Equatable, Sendable {
    let displayText: String
    let g2pInputText: String
    let phonemes: String
    let phonemeIDs: [Int32]
    let wordCount: Int
    let pronunciationFallbackHits: [PronunciationFallbackHit]
    let pronunciationTokenEvidence: [PronunciationTokenEvidence]
    let pronunciationEvidenceValidation: PronunciationEvidenceValidation

    init(
        displayText: String,
        g2pInputText: String,
        phonemes: String,
        phonemeIDs: [Int32],
        wordCount: Int,
        pronunciationFallbackHits: [PronunciationFallbackHit],
        pronunciationTokenEvidence: [PronunciationTokenEvidence] = [],
        pronunciationEvidenceValidation: PronunciationEvidenceValidation
    ) {
        self.displayText = displayText
        self.g2pInputText = g2pInputText
        self.phonemes = phonemes
        self.phonemeIDs = phonemeIDs
        self.wordCount = wordCount
        self.pronunciationFallbackHits = pronunciationFallbackHits
        self.pronunciationTokenEvidence = pronunciationTokenEvidence
        self.pronunciationEvidenceValidation = pronunciationEvidenceValidation
    }
}
