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

    @Test func everyConsonantMatchesThePackGeneratorMapping() throws {
        let rows = [
            ("B", "b"), ("CH", "ʧ"), ("D", "d"), ("DH", "ð"),
            ("F", "f"), ("G", "ɡ"), ("HH", "h"), ("JH", "ʤ"),
            ("K", "k"), ("L", "l"), ("M", "m"), ("N", "n"),
            ("NG", "ŋ"), ("P", "p"), ("R", "ɹ"), ("S", "s"),
            ("SH", "ʃ"), ("T", "t"), ("TH", "θ"), ("V", "v"),
            ("W", "w"), ("Y", "j"), ("Z", "z"), ("ZH", "ʒ"),
        ]

        for (token, expected) in rows {
            #expect(try ARPAbetToKokoroIPA.convert([token]) == expected)
        }
    }

    @Test func everyVowelAndStressMatchesThePackGeneratorMapping() throws {
        let rows = [
            ("AA0", "ɑ"), ("AA1", "ˈɑ"), ("AA2", "ˌɑ"),
            ("AE0", "æ"), ("AE1", "ˈæ"), ("AE2", "ˌæ"),
            ("AH0", "ə"), ("AH1", "ˈʌ"), ("AH2", "ˌʌ"),
            ("AO0", "ɔ"), ("AO1", "ˈɔ"), ("AO2", "ˌɔ"),
            ("AW0", "aʊ"), ("AW1", "ˈaʊ"), ("AW2", "ˌaʊ"),
            ("AY0", "aɪ"), ("AY1", "ˈaɪ"), ("AY2", "ˌaɪ"),
            ("EH0", "ɛ"), ("EH1", "ˈɛ"), ("EH2", "ˌɛ"),
            ("ER0", "ɚ"), ("ER1", "ˈɜɹ"), ("ER2", "ˌɜɹ"),
            ("EY0", "eɪ"), ("EY1", "ˈeɪ"), ("EY2", "ˌeɪ"),
            ("IH0", "ɪ"), ("IH1", "ˈɪ"), ("IH2", "ˌɪ"),
            ("IY0", "i"), ("IY1", "ˈi"), ("IY2", "ˌi"),
            ("OW0", "oʊ"), ("OW1", "ˈoʊ"), ("OW2", "ˌoʊ"),
            ("OY0", "ɔɪ"), ("OY1", "ˈɔɪ"), ("OY2", "ˌɔɪ"),
            ("UH0", "ʊ"), ("UH1", "ˈʊ"), ("UH2", "ˌʊ"),
            ("UW0", "u"), ("UW1", "ˈu"), ("UW2", "ˌu"),
        ]

        for (token, expected) in rows {
            #expect(try ARPAbetToKokoroIPA.convert([token]) == expected)
        }
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
