// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The ONLY shape allowed to leave the device for community pronunciation
/// improvement. Term-level by construction: it carries a single mispronounced
/// term, its corrected IPA, the language, the voice/model version the fix was
/// validated against, and a confidence. It deliberately has NO field that can
/// hold surrounding prose, block text, audio, file paths, or the book id —
/// those never leave the device (design doc Section 8 / Decision D7). `Codable` is the
/// wire shape; encoding produces exactly these five keys.
struct PronunciationContributionPayload: Codable, Equatable, Sendable {
    /// The single term being corrected (e.g. a proper noun or acronym). One word
    /// only — never a phrase that could reconstruct private source text.
    let term: String
    /// Corrected pronunciation in IPA (the Misaki override value).
    let ipa: String
    /// BCP-47-ish language tag (English-only v1 -> "en").
    let language: String
    /// The narration voice/model version the fix was validated against, so a
    /// contribution can be scoped to the engine that produced the mispronunciation.
    let voiceModelVersion: String
    /// 0...1 confidence in the fix (from the resolved QA issue).
    let confidence: Double
}
