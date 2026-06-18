// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct VoiceCatalogTests {
    @Test func hasCuratedVoice() {
        // Only af_heart (Ava) ships for now — the other Kokoro voices need
        // their [510,256] fp32 packs converted from hexgrad/Kokoro-82M first
        // (see VoiceCatalog.all comment). Updated from the old 4-voice set
        // when the catalog was slimmed for the fixed-shape Kokoro swap.
        #expect(VoiceCatalog.all.count == 1)
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
}
