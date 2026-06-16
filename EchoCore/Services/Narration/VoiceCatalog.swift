// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationVoice: Identifiable, Hashable, Sendable {
    let id: VoiceID
    let displayName: String
    let descriptor: String  // e.g. "US · warm"
    let sampleClipName: String  // bundled preview clip (added in Plan 4)
}

enum VoiceCatalog {
    /// Curated set (spec §3.2). Kokoro voicepack keys as raw IDs.
    ///
    /// Only `af_heart` (Ava) is shipped for now: FluidAudio's on-device ANE
    /// Kokoro repo ships only `af_heart.bin` — the other Kokoro voices 404 on
    /// download. Re-add them once their `[510,256]` fp32 `.bin` packs are
    /// converted from `hexgrad/Kokoro-82M/voices/*.pt` and bundled (FluidAudio
    /// loads a local voice file before downloading).
    static let all: [NarrationVoice] = [
        NarrationVoice(
            id: VoiceID("af_heart"), displayName: "Ava", descriptor: "US · warm",
            sampleClipName: "voice_ava")
    ]

    static let `default`: NarrationVoice = all[0]

    static func voice(for id: VoiceID) -> NarrationVoice? {
        all.first { $0.id == id }
    }
}
