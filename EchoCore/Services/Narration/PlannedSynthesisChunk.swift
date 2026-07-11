// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated struct PlannedSynthesisChunk: Equatable, Sendable {
    let displayText: String
    let g2pInputText: String
    let phonemes: String
    let phonemeIDs: [Int32]
    let wordCount: Int
    let pronunciationFallbackHits: [PronunciationFallbackHit]
}
