// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct VoiceCatalogTests {
    @Test func hasFourCuratedVoices() {
        #expect(VoiceCatalog.all.count == 4)
    }

    @Test func defaultIsWarmUSFemaleAva() {
        #expect(VoiceCatalog.default.id == VoiceID("af_warm"))
        #expect(VoiceCatalog.default.displayName == "Ava")
    }

    @Test func allVoicesAreUnique() {
        let ids = VoiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupByIDReturnsMatch() {
        #expect(VoiceCatalog.voice(for: VoiceID("af_warm"))?.displayName == "Ava")
        #expect(VoiceCatalog.voice(for: VoiceID("nope")) == nil)
    }
}
