// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Converts Mini-BART's ARPAbet output using the pronunciation-pack policy.
nonisolated enum ARPAbetToKokoroIPA {
    enum Error: Swift.Error, Equatable, Sendable {
        case emptyTokens
        case emptyToken
        case malformedStress(String)
        case unsupportedToken(String)
        case unsupportedIPA(String)
    }

    static let policyVersion = NeuralG2PGovernedIdentity.conversionPolicyVersion

    static func convert(_ tokens: [String]) throws -> String {
        guard !tokens.isEmpty else { throw Error.emptyTokens }

        var output = ""
        for token in tokens {
            guard !token.isEmpty else { throw Error.emptyToken }
            if let consonant = consonants[token] {
                output += consonant
                continue
            }

            guard let final = token.last else { throw Error.emptyToken }
            if final.isNumber {
                let base = String(token.dropLast())
                guard
                    let vowel = vowels[base],
                    let stress = stresses[final]
                else {
                    throw Error.malformedStress(token)
                }
                output += stress
                output += final == "0" ? vowel.unstressed : vowel.stressed
                continue
            }

            if vowels[token] != nil || token.contains(where: \Character.isNumber) {
                throw Error.malformedStress(token)
            }
            throw Error.unsupportedToken(token)
        }

        let vocabulary = try KokoroPhonemeVocab()
        do {
            _ = try vocabulary.validatedIDs(forPhonemes: output)
        } catch let error as KokoroPhonemeVocab.EncodingError {
            switch error {
            case .unsupportedCharacters(let characters):
                throw Error.unsupportedIPA(characters)
            }
        }
        return output
    }

    private static let vowels: [String: (unstressed: String, stressed: String)] = [
        "AA": ("ɑ", "ɑ"),
        "AE": ("æ", "æ"),
        "AH": ("ə", "ʌ"),
        "AO": ("ɔ", "ɔ"),
        "AW": ("aʊ", "aʊ"),
        "AY": ("aɪ", "aɪ"),
        "EH": ("ɛ", "ɛ"),
        "ER": ("ɚ", "ɜɹ"),
        "EY": ("eɪ", "eɪ"),
        "IH": ("ɪ", "ɪ"),
        "IY": ("i", "i"),
        "OW": ("oʊ", "oʊ"),
        "OY": ("ɔɪ", "ɔɪ"),
        "UH": ("ʊ", "ʊ"),
        "UW": ("u", "u"),
    ]

    private static let consonants: [String: String] = [
        "B": "b",
        "CH": "ʧ",
        "D": "d",
        "DH": "ð",
        "F": "f",
        "G": "ɡ",
        "HH": "h",
        "JH": "ʤ",
        "K": "k",
        "L": "l",
        "M": "m",
        "N": "n",
        "NG": "ŋ",
        "P": "p",
        "R": "ɹ",
        "S": "s",
        "SH": "ʃ",
        "T": "t",
        "TH": "θ",
        "V": "v",
        "W": "w",
        "Y": "j",
        "Z": "z",
        "ZH": "ʒ",
    ]

    private static let stresses: [Character: String] = [
        "0": "",
        "1": "ˈ",
        "2": "ˌ",
    ]
}
