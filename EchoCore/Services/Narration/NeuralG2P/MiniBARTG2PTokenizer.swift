// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Deterministic character tokenizer for the locked Mini-BART English G2P model.
nonisolated struct MiniBARTG2PTokenizer: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidConfiguration
        case duplicateVocabularyID(Int64)
        case emptyInput
        case sentenceInput
        case unsupportedCharacters(String)
        case invalidWord
        case unknownInputToken(String)
        case unknownOutputID(Int64)
        case emptyOutput
    }

    let vocabularyVersion: String

    private let tokenToID: [String: Int64]
    private let idToToken: [Int64: String]
    private let maximumLength: Int

    init(data: Data) throws {
        let configuration: Configuration
        do {
            configuration = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw Error.invalidConfiguration
        }

        guard
            configuration.version == "1.0",
            configuration.normalizer.type == "Lowercase",
            configuration.preTokenizer.type == "Split",
            configuration.preTokenizer.pattern.string == "",
            configuration.preTokenizer.behavior == "Removed",
            configuration.preTokenizer.invert == false,
            configuration.postProcessor.type == "RobertaProcessing",
            configuration.postProcessor.cls == TokenPair(token: "<s>", id: 0),
            configuration.postProcessor.sep == TokenPair(token: "</s>", id: 2),
            configuration.truncation.direction == "Right",
            configuration.truncation.maxLength == 128,
            configuration.truncation.strategy == "LongestFirst",
            configuration.model.type == "WordLevel",
            configuration.model.unknownToken == "<unk>",
            configuration.model.vocabulary["<s>"] == 0,
            configuration.model.vocabulary["<pad>"] == 1,
            configuration.model.vocabulary["</s>"] == 2,
            configuration.model.vocabulary["<unk>"] == 3,
            configuration.model.vocabulary["<mask>"] == 4
        else {
            throw Error.invalidConfiguration
        }

        var reverse: [Int64: String] = [:]
        for (token, id) in configuration.model.vocabulary {
            if reverse.updateValue(token, forKey: id) != nil {
                throw Error.duplicateVocabularyID(id)
            }
        }

        self.tokenToID = configuration.model.vocabulary
        self.idToToken = reverse
        self.maximumLength = configuration.truncation.maxLength
        self.vocabularyVersion =
            "sha256:"
            + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func encode(word: String) throws -> [Int64] {
        if word.contains(where: \Character.isWhitespace) {
            throw Error.sentenceInput
        }

        let normalized =
            word
            .trimmingCharacters(in: Self.outerSentencePunctuation)
            .lowercased()
        guard !normalized.isEmpty else { throw Error.emptyInput }

        var unsupported = ""
        for character in normalized where !Self.isAcceptedWordCharacter(character) {
            unsupported.append(character)
        }
        guard unsupported.isEmpty else {
            throw Error.unsupportedCharacters(unsupported)
        }
        guard Self.hasValidWordShape(normalized) else { throw Error.invalidWord }

        let maximumCharacters = maximumLength - 2
        var ids: [Int64] = [0]
        ids.reserveCapacity(min(normalized.count, maximumCharacters) + 2)
        for character in normalized.prefix(maximumCharacters) {
            let token = String(character)
            guard let id = tokenToID[token] else {
                throw Error.unknownInputToken(token)
            }
            ids.append(id)
        }
        ids.append(2)
        return ids
    }

    func decodeOutput(ids: [Int64]) throws -> [String] {
        var output: [String] = []
        output.reserveCapacity(ids.count)
        for id in ids {
            guard let token = idToToken[id] else { throw Error.unknownOutputID(id) }
            if id == 0 || id == 1 || id == 2 || token == "." {
                continue
            }
            output.append(token)
        }
        guard !output.isEmpty else { throw Error.emptyOutput }
        return output
    }

    private static let outerSentencePunctuation = CharacterSet(
        charactersIn: ".,!?;:\"()[]{}")

    private static func isAcceptedWordCharacter(_ character: Character) -> Bool {
        character == "'" || character == "-"
            || (character.isASCII && character.isLetter)
    }

    private static func hasValidWordShape(_ word: String) -> Bool {
        guard let first = word.first, let last = word.last,
            first.isLetter, last.isLetter
        else { return false }

        var previousWasSeparator = false
        for character in word {
            let isSeparator = character == "'" || character == "-"
            if isSeparator && previousWasSeparator { return false }
            previousWasSeparator = isSeparator
        }
        return true
    }
}

extension MiniBARTG2PTokenizer {
    fileprivate nonisolated struct Configuration: Decodable {
        let version: String
        let truncation: Truncation
        let normalizer: Normalizer
        let preTokenizer: PreTokenizer
        let postProcessor: PostProcessor
        let model: Model

        enum CodingKeys: String, CodingKey {
            case version, truncation, normalizer, model
            case preTokenizer = "pre_tokenizer"
            case postProcessor = "post_processor"
        }
    }

    fileprivate nonisolated struct Truncation: Decodable {
        let direction: String
        let maxLength: Int
        let strategy: String

        enum CodingKeys: String, CodingKey {
            case direction, strategy
            case maxLength = "max_length"
        }
    }

    fileprivate nonisolated struct Normalizer: Decodable {
        let type: String
    }

    fileprivate nonisolated struct PreTokenizer: Decodable {
        let type: String
        let pattern: SplitPattern
        let behavior: String
        let invert: Bool
    }

    fileprivate nonisolated struct SplitPattern: Decodable {
        let string: String

        enum CodingKeys: String, CodingKey {
            case string = "String"
        }
    }

    fileprivate nonisolated struct PostProcessor: Decodable {
        let type: String
        let sep: TokenPair
        let cls: TokenPair
    }

    fileprivate nonisolated struct TokenPair: Decodable, Equatable {
        let token: String
        let id: Int64

        init(token: String, id: Int64) {
            self.token = token
            self.id = id
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            token = try container.decode(String.self)
            id = try container.decode(Int64.self)
            guard container.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a two-value tokenizer pair")
            }
        }
    }

    fileprivate nonisolated struct Model: Decodable {
        let type: String
        let vocabulary: [String: Int64]
        let unknownToken: String

        enum CodingKeys: String, CodingKey {
            case type
            case vocabulary = "vocab"
            case unknownToken = "unk_token"
        }
    }
}
