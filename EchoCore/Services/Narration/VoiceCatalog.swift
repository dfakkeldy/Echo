// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Accent of a Kokoro narration voice (the language Echo's English G2P targets).
nonisolated enum VoiceAccent: String, Sendable {
    case american, british
    var title: String { self == .american ? "American" : "British" }
}

/// Speaker gender, used only for grouping the picker.
nonisolated enum VoiceGender: String, Sendable {
    case female, male
    var title: String { self == .female ? "Female" : "Male" }
}

nonisolated struct NarrationVoice: Identifiable, Hashable, Sendable {
    let id: VoiceID
    let displayName: String
    let descriptor: String  // short quality hint shown under the name
    let accent: VoiceAccent
    let gender: VoiceGender
    let grade: String  // Kokoro "Overall Grade" (VOICES.md); drives best-first ordering
}

/// A grouped run of voices for the picker (e.g. "American · Female").
nonisolated struct VoiceSection: Identifiable, Sendable {
    let id: String
    let title: String
    let voices: [NarrationVoice]
}

nonisolated enum VoiceCatalog {
    /// All 28 English Kokoro voices (American `a*` + British `b*`). Their
    /// `[510,256]` fp32 style packs are bundled in `EchoCore/Resources/<id>.f32`,
    /// fetched verbatim from `onnx-community/Kokoro-82M-v1.0-ONNX` via
    /// `Tools/fetch_kokoro_voices.py` (the `.bin` files are byte-identical to our
    /// `.f32` format — no conversion needed). Non-English Kokoro voices are
    /// intentionally excluded: Echo's G2P (MisakiSwift English) emits English
    /// IPA, so other-language voices would be mis-pronounced.
    ///
    /// Ordered best-first within each accent/gender group by Kokoro's published
    /// Overall Grade (hexgrad/Kokoro-82M VOICES.md); `af_heart` (Ava, grade A)
    /// stays first so it remains the default.
    static let all: [NarrationVoice] = [
        // American · Female
        v("af_heart", "Ava", .american, .female, "A"),
        v("af_bella", "Bella", .american, .female, "A-"),
        v("af_nicole", "Nicole", .american, .female, "B-"),
        v("af_aoede", "Aoede", .american, .female, "C+"),
        v("af_kore", "Kore", .american, .female, "C+"),
        v("af_sarah", "Sarah", .american, .female, "C+"),
        v("af_alloy", "Alloy", .american, .female, "C"),
        v("af_nova", "Nova", .american, .female, "C"),
        v("af_sky", "Sky", .american, .female, "C-"),
        v("af_jessica", "Jessica", .american, .female, "D"),
        v("af_river", "River", .american, .female, "D"),
        // American · Male
        v("am_fenrir", "Fenrir", .american, .male, "C+"),
        v("am_michael", "Michael", .american, .male, "C+"),
        v("am_puck", "Puck", .american, .male, "C+"),
        v("am_echo", "Echo", .american, .male, "D"),
        v("am_eric", "Eric", .american, .male, "D"),
        v("am_liam", "Liam", .american, .male, "D"),
        v("am_onyx", "Onyx", .american, .male, "D"),
        v("am_santa", "Santa", .american, .male, "D-"),
        v("am_adam", "Adam", .american, .male, "F+"),
        // British · Female
        v("bf_emma", "Emma", .british, .female, "B-"),
        v("bf_isabella", "Isabella", .british, .female, "C"),
        v("bf_alice", "Alice", .british, .female, "D"),
        v("bf_lily", "Lily", .british, .female, "D"),
        // British · Male
        v("bm_fable", "Fable", .british, .male, "C"),
        v("bm_george", "George", .british, .male, "C"),
        v("bm_lewis", "Lewis", .british, .male, "D+"),
        v("bm_daniel", "Daniel", .british, .male, "D"),
    ]

    static let `default`: NarrationVoice = all[0]

    static func voice(for id: VoiceID) -> NarrationVoice? {
        all.first { $0.id == id }
    }

    /// Voices grouped into picker sections (American · Female, American · Male,
    /// British · Female, British · Male), preserving the best-first order of
    /// `all`. Empty groups are omitted.
    static var sections: [VoiceSection] {
        let order: [(VoiceAccent, VoiceGender)] = [
            (.american, .female), (.american, .male),
            (.british, .female), (.british, .male),
        ]
        return order.compactMap { accent, gender in
            let voices = all.filter { $0.accent == accent && $0.gender == gender }
            guard !voices.isEmpty else { return nil }
            return VoiceSection(
                id: "\(accent.rawValue)-\(gender.rawValue)",
                title: "\(accent.title) · \(gender.title)",
                voices: voices)
        }
    }

    private static func v(
        _ id: String, _ name: String, _ accent: VoiceAccent, _ gender: VoiceGender,
        _ grade: String
    ) -> NarrationVoice {
        NarrationVoice(
            id: VoiceID(id), displayName: name, descriptor: qualityWord(grade),
            accent: accent, gender: gender, grade: grade)
    }

    /// A non-alarming quality hint derived from the Kokoro grade.
    private static func qualityWord(_ grade: String) -> String {
        switch grade.first {
        case "A": return "Highest quality"
        case "B": return "High quality"
        case "C": return "Good quality"
        default: return "Standard quality"  // D / F tiers
        }
    }
}
