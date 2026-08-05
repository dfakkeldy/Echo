// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MiniBARTG2PTokenizerTests {
    private static let tokenizerJSON = #"""
        {
          "version":"1.0",
          "truncation":{"direction":"Right","max_length":128,"strategy":"LongestFirst","stride":0},
          "padding":null,
          "added_tokens":[],
          "normalizer":{"type":"Lowercase"},
          "pre_tokenizer":{"type":"Split","pattern":{"String":""},"behavior":"Removed","invert":false},
          "post_processor":{"type":"RobertaProcessing","sep":["</s>",2],"cls":["<s>",0],"trim_offsets":true,"add_prefix_space":false},
          "decoder":null,
          "model":{"type":"WordLevel","vocab":{"<s>":0,"<pad>":1,"</s>":2,"<unk>":3,"<mask>":4,"e":5,"a":6,"s":7,"i":8,"r":9,"n":10,"AH0":11,"o":12,"N":13,"t":14,"l":15,"L":17,"c":21,"d":22,"u":24,"m":26,"h":29,"p":31,"b":34,"y":40,"k":41,"f":44,"w":46,"'":50,"HH":53,"OW1":56,"-":91,".":102},"unk_token":"<unk>"}
        }
        """#

    private func tokenizer(json: String = Self.tokenizerJSON) throws
        -> MiniBARTG2PTokenizer
    {
        try MiniBARTG2PTokenizer(data: Data(json.utf8))
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

    @Test func decodeOutputStripsControlAndPunctuationTokens() throws {
        #expect(
            try tokenizer().decodeOutput(ids: [0, 53, 11, 17, 56, 102, 2, 1])
                == ["HH", "AH0", "L", "OW1"])
    }

    @Test func decodeOutputRejectsUnknownAndEmptyOutput() throws {
        let value = try tokenizer()

        #expect(throws: MiniBARTG2PTokenizer.Error.unknownOutputID(999)) {
            try value.decodeOutput(ids: [53, 999, 2])
        }
        #expect(throws: MiniBARTG2PTokenizer.Error.emptyOutput) {
            try value.decodeOutput(ids: [0, 1, 2, 102])
        }
    }

    @Test func initializerRejectsDuplicateVocabularyIDs() {
        let duplicate = Self.tokenizerJSON.replacingOccurrences(
            of: #""c":21"#,
            with: #""c":6"#)

        #expect(throws: MiniBARTG2PTokenizer.Error.duplicateVocabularyID(6)) {
            try tokenizer(json: duplicate)
        }
    }

    @Test func initializerRejectsTokenizerContractDrift() {
        let wrongNormalizer = Self.tokenizerJSON.replacingOccurrences(
            of: #""type":"Lowercase""#,
            with: #""type":"NFC""#)

        #expect(throws: MiniBARTG2PTokenizer.Error.invalidConfiguration) {
            try tokenizer(json: wrongNormalizer)
        }
    }

    @Test func vocabularyVersionIsStableAndContentBound() throws {
        let original = try tokenizer()
        let changed = try tokenizer(
            json: Self.tokenizerJSON.replacingOccurrences(
                of: #""c":21"#,
                with: #""c":79"#))

        #expect(original.vocabularyVersion.hasPrefix("sha256:"))
        #expect(original.vocabularyVersion.count == 71)
        #expect(original.vocabularyVersion != changed.vocabularyVersion)
    }
}
