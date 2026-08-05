// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ARPAbetToKokoroIPATests {
    @Test func conversionPolicyHasTheApprovedIdentity() {
        #expect(
            ARPAbetToKokoroIPA.policyVersion
                == "mini-bart-arpabet-to-kokoro-v1")
    }

    @Test func convertsConsonantsVowelsAndStressLikeThePackGenerator() throws {
        #expect(
            try ARPAbetToKokoroIPA.convert(["HH", "AH0", "L", "OW1"])
                == "həlˈoʊ")
        #expect(
            try ARPAbetToKokoroIPA.convert(["R", "EH1", "K", "ER0", "D"])
                == "ɹˈɛkɚd")
        #expect(
            try ARPAbetToKokoroIPA.convert(["R", "IH0", "K", "AO1", "R", "D"])
                == "ɹɪkˈɔɹd")
    }

    @Test func secondaryStressAndStressedERUseThePackMapping() throws {
        #expect(try ARPAbetToKokoroIPA.convert(["ER1"]) == "ˈɜɹ")
        #expect(try ARPAbetToKokoroIPA.convert(["ER2"]) == "ˌɜɹ")
        #expect(try ARPAbetToKokoroIPA.convert(["AE2"]) == "ˌæ")
    }

    @Test func convertedIPAIsAcceptedByKokoroProductionVocabulary() throws {
        let ipa = try ARPAbetToKokoroIPA.convert(["JH", "AE1", "K", "W", "IH0"])

        #expect(ipa == "ʤˈækwɪ")
        #expect(try KokoroPhonemeVocab().validatedIDs(forPhonemes: ipa).count > 2)
    }

    @Test func rejectsEmptyTokens() {
        #expect(throws: ARPAbetToKokoroIPA.Error.emptyTokens) {
            try ARPAbetToKokoroIPA.convert([])
        }
        #expect(throws: ARPAbetToKokoroIPA.Error.emptyToken) {
            try ARPAbetToKokoroIPA.convert(["HH", ""])
        }
    }

    @Test func rejectsMissingOrMalformedVowelStress() {
        #expect(throws: ARPAbetToKokoroIPA.Error.malformedStress("AH")) {
            try ARPAbetToKokoroIPA.convert(["AH"])
        }
        #expect(throws: ARPAbetToKokoroIPA.Error.malformedStress("AH3")) {
            try ARPAbetToKokoroIPA.convert(["AH3"])
        }
        #expect(throws: ARPAbetToKokoroIPA.Error.malformedStress("B1")) {
            try ARPAbetToKokoroIPA.convert(["B1"])
        }
    }

    @Test func rejectsUnmappableModelTokens() {
        #expect(throws: ARPAbetToKokoroIPA.Error.unsupportedToken("<unk>")) {
            try ARPAbetToKokoroIPA.convert(["<unk>"])
        }
        #expect(throws: ARPAbetToKokoroIPA.Error.unsupportedToken("a")) {
            try ARPAbetToKokoroIPA.convert(["a"])
        }
    }
}
