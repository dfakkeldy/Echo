// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct VoiceCatalogTests {
    @Test func shipsAllEnglishVoices() {
        // All 28 English Kokoro voices (American af_*/am_* + British bf_*/bm_*).
        // Their [510,256] fp32 packs are bundled in EchoCore/Resources
        // (fetched verbatim from onnx-community/Kokoro-82M-v1.0-ONNX via
        // Tools/fetch_kokoro_voices.py). Non-English voices are excluded —
        // Echo's G2P is English-only.
        #expect(VoiceCatalog.all.count == 28)
        #expect(VoiceCatalog.all.contains { $0.id == VoiceID("af_heart") })
    }

    @Test func defaultIsHeartUSFemaleAva() {
        #expect(VoiceCatalog.default.id == VoiceID("af_heart"))
        #expect(VoiceCatalog.default.displayName == "Ava")
    }

    @Test func allVoicesAreUnique() {
        let ids = VoiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupByIDReturnsMatch() {
        #expect(VoiceCatalog.voice(for: VoiceID("af_heart"))?.displayName == "Ava")
        #expect(VoiceCatalog.voice(for: VoiceID("nope")) == nil)
    }

    @Test func defaultIsFirstSoItLeadsThePicker() {
        #expect(VoiceCatalog.all.first?.id == VoiceCatalog.default.id)
    }

    @Test func sectionsCoverEveryVoiceExactlyOnce() {
        let sectioned = VoiceCatalog.sections.flatMap(\.voices)
        // Same set, no omissions, no duplicates across the 4 groups.
        #expect(sectioned.count == VoiceCatalog.all.count)
        #expect(Set(sectioned.map(\.id)) == Set(VoiceCatalog.all.map(\.id)))
    }

    @Test func sectionsAreGroupedByAccentAndGender() {
        let sections = VoiceCatalog.sections
        #expect(
            sections.map(\.title) == [
                "American · Female", "American · Male", "British · Female", "British · Male",
            ])
        #expect(sections.map(\.voices.count) == [11, 9, 4, 4])
        // Every voice in a section actually matches that section's accent + gender.
        for section in sections {
            let first = section.voices.first!
            #expect(
                section.voices.allSatisfy {
                    $0.accent == first.accent && $0.gender == first.gender
                })
        }
    }
}
