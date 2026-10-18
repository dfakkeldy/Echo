// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MiniBARTG2PTokenizerTests {
    private static let lockedTokenizerBase64 = #"""
        ewogICJ2ZXJzaW9uIjogIjEuMCIsCiAgInRydW5jYXRpb24iOiB7CiAgICAiZGlyZWN0aW9uIjogIlJpZ2h0IiwKICAgICJtYXhf
        bGVuZ3RoIjogMTI4LAogICAgInN0cmF0ZWd5IjogIkxvbmdlc3RGaXJzdCIsCiAgICAic3RyaWRlIjogMAogIH0sCiAgInBhZGRp
        bmciOiBudWxsLAogICJhZGRlZF90b2tlbnMiOiBbCiAgICB7CiAgICAgICJpZCI6IDAsCiAgICAgICJjb250ZW50IjogIjxzPiIs
        CiAgICAgICJzaW5nbGVfd29yZCI6IGZhbHNlLAogICAgICAibHN0cmlwIjogZmFsc2UsCiAgICAgICJyc3RyaXAiOiBmYWxzZSwK
        ICAgICAgIm5vcm1hbGl6ZWQiOiBmYWxzZSwKICAgICAgInNwZWNpYWwiOiB0cnVlCiAgICB9LAogICAgewogICAgICAiaWQiOiAx
        LAogICAgICAiY29udGVudCI6ICI8cGFkPiIsCiAgICAgICJzaW5nbGVfd29yZCI6IGZhbHNlLAogICAgICAibHN0cmlwIjogZmFs
        c2UsCiAgICAgICJyc3RyaXAiOiBmYWxzZSwKICAgICAgIm5vcm1hbGl6ZWQiOiBmYWxzZSwKICAgICAgInNwZWNpYWwiOiB0cnVl
        CiAgICB9LAogICAgewogICAgICAiaWQiOiAyLAogICAgICAiY29udGVudCI6ICI8L3M+IiwKICAgICAgInNpbmdsZV93b3JkIjog
        ZmFsc2UsCiAgICAgICJsc3RyaXAiOiBmYWxzZSwKICAgICAgInJzdHJpcCI6IGZhbHNlLAogICAgICAibm9ybWFsaXplZCI6IGZh
        bHNlLAogICAgICAic3BlY2lhbCI6IHRydWUKICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDMsCiAgICAgICJjb250ZW50IjogIjx1
        bms+IiwKICAgICAgInNpbmdsZV93b3JkIjogZmFsc2UsCiAgICAgICJsc3RyaXAiOiBmYWxzZSwKICAgICAgInJzdHJpcCI6IGZh
        bHNlLAogICAgICAibm9ybWFsaXplZCI6IGZhbHNlLAogICAgICAic3BlY2lhbCI6IHRydWUKICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDQsCiAgICAgICJjb250ZW50IjogIjxt
        YXNrPiIsCiAgICAgICJzaW5nbGVfd29yZCI6IGZhbHNlLAogICAgICAibHN0cmlwIjogdHJ1ZSwKICAgICAgInJzdHJpcCI6IGZh
        bHNlLAogICAgICAibm9ybWFsaXplZCI6IGZhbHNlLAogICAgICAic3BlY2lhbCI6IHRydWUKICAgIH0KICBdLAogICJub3JtYWxp
        emVyIjogewogICAgInR5cGUiOiAiTG93ZXJjYXNlIgogIH0sCiAgInByZV90b2tlbml6ZXIiOiB7CiAgICAidHlwZSI6ICJTcGxp
        dCIsCiAgICAicGF0dGVybiI6IHsKICAgICAgIlN0cmluZyI6ICIiCiAgICB9LAogICAgImJlaGF2aW9yIjogIlJlbW92ZWQiLAog
        ICAgImludmVydCI6IGZhbHNlCiAgfSwKICAicG9zdF9wcm9jZXNzb3IiOiB7CiAgICAidHlwZSI6ICJSb2JlcnRhUHJvY2Vzc2lu
        ZyIsCiAgICAic2VwIjogWwogICAgICAiPC9zPiIsCiAgICAgIDIKICAgIF0sCiAgICAiY2xzIjogWwogICAgICAiPHM+IiwKICAg
        ICAgMAogICAgXSwKICAgICJ0cmltX29mZnNldHMiOiB0cnVlLAogICAgImFkZF9wcmVmaXhfc3BhY2UiOiBmYWxzZQogIH0sCiAg
        ImRlY29kZXIiOiBudWxsLAogICJtb2RlbCI6IHsKICAgICJ0eXBlIjogIldvcmRMZXZlbCIsCiAgICAidm9jYWIiOiB7CiAgICAg
        ICI8cz4iOiAwLAogICAgICAiPHBhZD4iOiAxLAogICAgICAiPC9zPiI6IDIsCiAgICAgICI8dW5rPiI6IDMsCiAgICAgICI8bWFz
        az4iOiA0LAogICAgICAiZSI6IDUsCiAgICAgICJhIjogNiwKICAgICAgInMiOiA3LAogICAgICAiaSI6IDgsCiAgICAgICJyIjog
        OSwKICAgICAgIm4iOiAxMCwKICAgICAgIkFIMCI6IDExLAogICAgICAibyI6IDEyLAogICAgICAiTiI6IDEzLAogICAgICAidCI6
        IDE0LAogICAgICAibCI6IDE1LAogICAgICAiUyI6IDE2LAogICAgICAiTCI6IDE3LAogICAgICAiVCI6IDE4LAogICAgICAiUiI6
        IDE5LAogICAgICAiSyI6IDIwLAogICAgICAiYyI6IDIxLAogICAgICAiZCI6IDIyLAogICAgICAiRCI6IDIzLAogICAgICAidSI6
        IDI0LAogICAgICAiSUgwIjogMjUsCiAgICAgICJtIjogMjYsCiAgICAgICJNIjogMjcsCiAgICAgICJaIjogMjgsCiAgICAgICJo
        IjogMjksCiAgICAgICJnIjogMzAsCiAgICAgICJwIjogMzEsCiAgICAgICJFUjAiOiAzMiwKICAgICAgIklZMCI6IDMzLAogICAg
        ICAiYiI6IDM0LAogICAgICAiQiI6IDM1LAogICAgICAiUCI6IDM2LAogICAgICAiRUgxIjogMzcsCiAgICAgICJBRTEiOiAzOCwK
        ICAgICAgIkFBMSI6IDM5LAogICAgICAieSI6IDQwLAogICAgICAiayI6IDQxLAogICAgICAiSUgxIjogNDIsCiAgICAgICJGIjog
        NDMsCiAgICAgICJmIjogNDQsCiAgICAgICJHIjogNDUsCiAgICAgICJ3IjogNDYsCiAgICAgICJWIjogNDcsCiAgICAgICJ2Ijog
        NDgsCiAgICAgICJORyI6IDQ5LAogICAgICAiJyI6IDUwLAogICAgICAiSVkxIjogNTEsCiAgICAgICJFWTEiOiA1MiwKICAgICAg
        IkhIIjogNTMsCiAgICAgICJXIjogNTQsCiAgICAgICJTSCI6IDU1LAogICAgICAiT1cxIjogNTYsCiAgICAgICJBTzEiOiA1NywK
        ICAgICAgIk9XMCI6IDU4LAogICAgICAiQUgxIjogNTksCiAgICAgICJVVzEiOiA2MCwKICAgICAgIkFZMSI6IDYxLAogICAgICAi
        SkgiOiA2MiwKICAgICAgInoiOiA2MywKICAgICAgIkNIIjogNjQsCiAgICAgICJZIjogNjUsCiAgICAgICJBQTAiOiA2NiwKICAg
        ICAgIkVSMSI6IDY3LAogICAgICAiRUgyIjogNjgsCiAgICAgICJJSDIiOiA2OSwKICAgICAgIlRIIjogNzAsCiAgICAgICJBWTIi
        OiA3MSwKICAgICAgIkFFMiI6IDcyLAogICAgICAiRVkyIjogNzMsCiAgICAgICJBQTIiOiA3NCwKICAgICAgIkVIMCI6IDc1LAog
        ICAgICAiaiI6IDc2LAogICAgICAiQVcxIjogNzcsCiAgICAgICJPVzIiOiA3OCwKICAgICAgIngiOiA3OSwKICAgICAgIklZMiI6
        IDgwLAogICAgICAiVVcwIjogODEsCiAgICAgICJBTzIiOiA4MiwKICAgICAgIlVIMSI6IDgzLAogICAgICAiQUUwIjogODQsCiAg
        ICAgICJxIjogODUsCiAgICAgICJBTzAiOiA4NiwKICAgICAgIkFIMiI6IDg3LAogICAgICAiVVcyIjogODgsCiAgICAgICJBWTAi
        OiA4OSwKICAgICAgIk9ZMSI6IDkwLAogICAgICAiLSI6IDkxLAogICAgICAiRVkwIjogOTIsCiAgICAgICJESCI6IDkzLAogICAg
        ICAiQVcyIjogOTQsCiAgICAgICJFUjIiOiA5NSwKICAgICAgIlpIIjogOTYsCiAgICAgICJVSDIiOiA5NywKICAgICAgIkFXMCI6
        IDk4LAogICAgICAiVUgwIjogOTksCiAgICAgICJPWTIiOiAxMDAsCiAgICAgICJPWTAiOiAxMDEsCiAgICAgICIuIjogMTAyCiAg
        ICB9LAogICAgInVua190b2tlbiI6ICI8dW5rPiIKICB9Cn0=
        """#

    private static let lockedTokenizerData = Data(
        base64Encoded: lockedTokenizerBase64,
        options: .ignoreUnknownCharacters)!

    private func tokenizer() throws -> MiniBARTG2PTokenizer {
        try MiniBARTG2PTokenizer(data: Self.lockedTokenizerData)
    }

    private func mutatedTokenizerData(
        _ replacements: [(original: String, replacement: String)]
    ) throws -> Data {
        var text = String(decoding: Self.lockedTokenizerData, as: UTF8.self)
        for replacement in replacements {
            let range = try #require(text.range(of: replacement.original))
            text.replaceSubrange(range, with: replacement.replacement)
        }
        return Data(text.utf8)
    }

    @Test func initializerAcceptsOnlyTheLockedArtifactIdentity() throws {
        let value = try tokenizer()

        #expect(
            value.vocabularyVersion
                == "sha256:40193885f8093d3bf59dfc199db502cfa8618b24bfcb2d08aa5f8d538bc34495")
    }

    @Test func initializerRejectsAUniquelyRemappedVocabulary() throws {
        let data = try mutatedTokenizerData([
            (#""c": 21"#, #""c": 22"#),
            (#""d": 22"#, #""d": 21"#),
        ])

        #expect(throws: MiniBARTG2PTokenizer.Error.invalidConfiguration) {
            try MiniBARTG2PTokenizer(data: data)
        }
    }

    @Test func initializerRejectsIgnoredConfigurationDrift() throws {
        let attacks = [
            (#""padding": null"#, #""padding": {}"#),
            (#""content": "<s>""#, #""content": "<start>""#),
            (#""decoder": null"#, #""decoder": {"type":"Fuse"}"#),
            (#""stride": 0"#, #""stride": 1"#),
            (#""trim_offsets": true"#, #""trim_offsets": false"#),
        ]

        for attack in attacks {
            let data = try mutatedTokenizerData([attack])
            #expect(throws: MiniBARTG2PTokenizer.Error.invalidConfiguration) {
                try MiniBARTG2PTokenizer(data: data)
            }
        }
    }

    @Test func encodeLowercasesAndWrapsCharacterIDs() throws {
        #expect(try tokenizer().encode(word: "Cat") == [0, 21, 6, 14, 2])
    }

    @Test func encodePreservesSupportedApostrophesAndHyphens() throws {
        let value = try tokenizer()

        #expect(try value.encode(word: "don't") == [0, 22, 12, 10, 50, 14, 2])
        #expect(
            try value.encode(word: "cat-like")
                == [0, 21, 6, 14, 91, 15, 8, 41, 5, 2])
    }

    @Test func encodeStripsOuterSentencePunctuation() throws {
        #expect(try tokenizer().encode(word: "(Cat!).") == [0, 21, 6, 14, 2])
    }

    @Test func encodeRejectsEmptySentenceAndUnsupportedInput() throws {
        let value = try tokenizer()

        #expect(throws: MiniBARTG2PTokenizer.Error.emptyInput) {
            try value.encode(word: "...")
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.sentenceInput) {
            try value.encode(word: "cat nap")
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.unsupportedCharacters("é")) {
            try value.encode(word: "café")
        }
    }

    @Test func encodeUsesLockedRightTruncationEnvelope() throws {
        let input = String(repeating: "a", count: 130)
        let encoded = try tokenizer().encode(word: input)

        #expect(encoded.count == 128)
        #expect(encoded.first == 0)
        #expect(encoded.last == 2)
        #expect(encoded.dropFirst().dropLast().allSatisfy { $0 == 6 })
    }

    @Test func decodeOutputConsumesACompleteNormalizedBeamSequence() throws {
        #expect(
            try tokenizer().decodeOutput(ids: [2, 53, 11, 17, 56, 102, 2])
                == ["HH", "AH0", "L", "OW1"])
    }

    @Test func decodeOutputRejectsAnInvalidDecoderStart() throws {
        #expect(throws: MiniBARTG2PTokenizer.Error.invalidDecoderStart(0)) {
            try tokenizer().decodeOutput(ids: [0, 53, 11, 2, 56, 1])
        }
    }

    @Test func decodeOutputRejectsBosAndPadInsideLexicalContent() throws {
        let value = try tokenizer()

        #expect(throws: MiniBARTG2PTokenizer.Error.invalidControlToken(id: 0, index: 2)) {
            try value.decodeOutput(ids: [2, 53, 0, 11, 2])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.invalidControlToken(id: 1, index: 2)) {
            try value.decodeOutput(ids: [2, 53, 1, 11, 2])
        }
    }

    @Test func decodeOutputRequiresExactlyOneFinalTermination() throws {
        let value = try tokenizer()

        #expect(throws: MiniBARTG2PTokenizer.Error.missingTermination) {
            try value.decodeOutput(ids: [2, 53, 11])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.contentAfterTermination(index: 3)) {
            try value.decodeOutput(ids: [2, 53, 2, 56])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.contentAfterTermination(index: 3)) {
            try value.decodeOutput(ids: [2, 53, 2, 2])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.contentAfterTermination(index: 3)) {
            try value.decodeOutput(ids: [2, 53, 2, 1])
        }
    }

    @Test func decodeOutputRejectsUnknownAndEmptyOutput() throws {
        let value = try tokenizer()

        #expect(throws: MiniBARTG2PTokenizer.Error.unknownOutputID(999)) {
            try value.decodeOutput(ids: [2, 53, 999, 2])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.emptyOutput) {
            try value.decodeOutput(ids: [2, 102, 2])
        }
    }
}
