import Foundation

struct NarrationVoice: Identifiable, Hashable, Sendable {
    let id: VoiceID
    let displayName: String
    let descriptor: String  // e.g. "US · warm"
    let sampleClipName: String  // bundled preview clip (added in Plan 4)
}

enum VoiceCatalog {
    /// Curated set (spec §3.2). Kokoro voicepack keys as raw IDs.
    static let all: [NarrationVoice] = [
        NarrationVoice(
            id: VoiceID("af_heart"), displayName: "Ava", descriptor: "US · warm",
            sampleClipName: "voice_ava"),
        NarrationVoice(
            id: VoiceID("am_michael"), displayName: "Michael", descriptor: "US · steady",
            sampleClipName: "voice_michael"),
        NarrationVoice(
            id: VoiceID("bf_emma"), displayName: "Emma", descriptor: "UK · bright",
            sampleClipName: "voice_emma"),
        NarrationVoice(
            id: VoiceID("bm_george"), displayName: "George", descriptor: "UK · deep",
            sampleClipName: "voice_george"),
    ]

    static let `default`: NarrationVoice = all[0]

    static func voice(for id: VoiceID) -> NarrationVoice? {
        all.first { $0.id == id }
    }
}
