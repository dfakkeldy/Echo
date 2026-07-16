// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// A fully valid `formatVersion: 2` portable deck document. Individual
/// failure tests mutate a JSON copy of this fixture (or of `legacyDeckJSON`)
/// via `mutatingTopLevel`/`mutatingFirstCard` rather than hand-writing a new
/// JSON literal per case, so every test exercises exactly one violated rule.
private let portableSourceSignatureValue = "sha256:" + String(repeating: "a", count: 64)

private let portableDeckJSON = """
    {
      "formatVersion": 2,
      "deckID": "com.kinnoki.book.edition.core",
      "deckName": "Core Review",
      "targetBinding": "selectedBook",
      "targetMediaID": "echo-portable:kinnoki:book.edition.core",
      "sourceSignature": {
        "algorithm": "echo-canonical-blocks-v1",
        "value": "\(portableSourceSignatureValue)"
      },
      "cards": [
        {
          "frontText": "What does chapter one establish?",
          "backText": "The founding premise of the book.",
          "triggerTiming": "manualOnly",
          "sourceAnchor": "s1-b2"
        }
      ]
    }
    """

/// Mirrors the shape `StudyDeckFileExporter` currently produces: no v2
/// top-level fields at all.
private let legacyDeckJSON = """
    {
      "deckName": "Chapter 1 Vocabulary",
      "targetMediaID": "my-audiobook.m4b",
      "cards": [
        {
          "frontText": "What does 'ephemeral' mean?",
          "backText": "Lasting for a very short time.",
          "sourceAnchor": "s1-b2",
          "startTime": 45.0,
          "endTime": 52.0,
          "triggerTiming": "beginning"
        }
      ]
    }
    """

private struct FixtureDecodeFailure: Error {}

private func decodedDict(_ json: String) throws -> [String: Any] {
    guard let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else {
        throw FixtureDecodeFailure()
    }
    return dict
}

/// Parses `json`, applies `transform` to the top-level object, and
/// re-serializes. Setting a key to `nil` in `transform` removes it, letting
/// tests express "field absent" directly.
private func mutatingTopLevel(
    _ json: String,
    _ transform: (inout [String: Any]) -> Void
) throws -> Data {
    var dict = try decodedDict(json)
    transform(&dict)
    return try JSONSerialization.data(withJSONObject: dict)
}

/// Same as `mutatingTopLevel` but scoped to `cards[0]`.
private func mutatingFirstCard(
    _ json: String,
    _ transform: (inout [String: Any]) -> Void
) throws -> Data {
    try mutatingTopLevel(json) { dict in
        guard var cards = dict["cards"] as? [[String: Any]], var card = cards.first else {
            return
        }
        transform(&card)
        cards[0] = card
        dict["cards"] = cards
    }
}

@Suite struct PortableDeckImportTests {

    // MARK: - Classification

    @Test func completeV2ClassifiesAsPortable() throws {
        let validated = try ValidatedDeckImport.decode(Data(portableDeckJSON.utf8))
        guard case .portable(let deck) = validated else {
            Issue.record("Expected portable deck")
            return
        }
        #expect(deck.deckID == "com.kinnoki.book.edition.core")
        #expect(deck.cards[0].sourceAnchor == "s1-b2")
    }

    @Test func currentLegacyShapeRemainsLegacy() throws {
        let validated = try ValidatedDeckImport.decode(Data(legacyDeckJSON.utf8))
        guard case .legacy = validated else {
            Issue.record("Expected legacy deck")
            return
        }
    }

    // MARK: - Top-level v2 marker completeness

    @Test(arguments: ["formatVersion", "deckID", "targetBinding", "sourceSignature"])
    func singleV2MarkerAloneIsIncomplete(field: String) throws {
        let data = try mutatingTopLevel(legacyDeckJSON) { dict in
            switch field {
            case "formatVersion": dict["formatVersion"] = 2
            case "deckID": dict["deckID"] = "com.kinnoki.book.edition.core"
            case "targetBinding": dict["targetBinding"] = "selectedBook"
            case "sourceSignature":
                dict["sourceSignature"] = [
                    "algorithm": EchoSourceSignature.currentAlgorithm,
                    "value": portableSourceSignatureValue,
                ]
            default: break
            }
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .incompletePortableDeck = thrown else {
            Issue.record("Expected incompletePortableDeck for \(field) alone, got \(thrown)")
            return
        }
        #expect(thrown.errorDescription == "Portable study deck metadata is incomplete.")
    }

    @Test(arguments: ["formatVersion", "deckID", "targetBinding", "sourceSignature"])
    func threeOfFourV2MarkersIsIncomplete(missingField: String) throws {
        let data = try mutatingTopLevel(portableDeckJSON) { dict in
            dict[missingField] = nil
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .incompletePortableDeck = thrown else {
            Issue.record("Expected incompletePortableDeck missing \(missingField), got \(thrown)")
            return
        }
    }

    // MARK: - Top-level value validation

    @Test func unsupportedFormatVersionFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) { $0["formatVersion"] = 3 }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .unsupportedPortableVersion = thrown else {
            Issue.record("Expected unsupportedPortableVersion, got \(thrown)")
            return
        }
        #expect(thrown.errorDescription == "Portable study decks require formatVersion 2.")
    }

    @Test func emptyDeckNameFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) { $0["deckName"] = "   " }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .emptyDeckName = thrown else {
            Issue.record("Expected emptyDeckName, got \(thrown)")
            return
        }
    }

    @Test func missingSelectedBindingFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) { $0["targetBinding"] = "activeBook" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableBinding = thrown else {
            Issue.record("Expected invalidPortableBinding, got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription == "Portable study decks require targetBinding selectedBook.")
    }

    @Test func deckIDTooLongFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) {
            $0["deckID"] = String(repeating: "a", count: 129)
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableDeckID = thrown else {
            Issue.record("Expected invalidPortableDeckID, got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "deckID must be 1-128 ASCII letters, numbers, dots, underscores, or hyphens.")
    }

    @Test func deckIDOutsidePatternFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) { $0["deckID"] = "-leading-hyphen" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableDeckID = thrown else {
            Issue.record("Expected invalidPortableDeckID, got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "deckID must be 1-128 ASCII letters, numbers, dots, underscores, or hyphens.")
    }

    @Test func targetSentinelOutsidePatternFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) {
            $0["targetMediaID"] = "not-a-portable-sentinel"
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableTarget = thrown else {
            Issue.record("Expected invalidPortableTarget, got \(thrown)")
            return
        }
        #expect(thrown.errorDescription == "The portable targetMediaID sentinel is invalid.")
    }

    @Test func sourceSignatureAlgorithmMismatchFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) {
            $0["sourceSignature"] = [
                "algorithm": "some-other-algorithm",
                "value": portableSourceSignatureValue,
            ]
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidSourceSignature = thrown else {
            Issue.record("Expected invalidSourceSignature, got \(thrown)")
            return
        }
        #expect(thrown.errorDescription == "The source signature is missing or malformed.")
    }

    @Test func sourceSignatureValueMalformedFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) {
            $0["sourceSignature"] = [
                "algorithm": EchoSourceSignature.currentAlgorithm,
                "value": "not-a-hash",
            ]
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidSourceSignature = thrown else {
            Issue.record("Expected invalidSourceSignature, got \(thrown)")
            return
        }
    }

    // MARK: - Card-level validation

    @Test func emptyCardsFails() throws {
        let data = try mutatingTopLevel(portableDeckJSON) { $0["cards"] = [[String: Any]]() }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .emptyDeck = thrown else {
            Issue.record("Expected emptyDeck, got \(thrown)")
            return
        }
        #expect(thrown.errorDescription == "The deck contains no cards.")
    }

    @Test func whitespaceOnlyTextFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["frontText"] = "   " }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .emptyCardText(cardIndex: 0) = thrown else {
            Issue.record("Expected emptyCardText(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription == "Card 1: frontText and backText must not be empty.")
    }

    @Test func frontTextOverLimitFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["frontText"] = String(repeating: "a", count: 161)
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .portableTextTooLong(cardIndex: 0) = thrown else {
            Issue.record("Expected portableTextTooLong(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: frontText must be at most 160 Unicode scalars and backText at most 240 Unicode scalars."
        )
    }

    @Test func backTextOverLimitFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["backText"] = String(repeating: "a", count: 241)
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .portableTextTooLong(cardIndex: 0) = thrown else {
            Issue.record("Expected portableTextTooLong(cardIndex: 0), got \(thrown)")
            return
        }
    }

    /// The limits count Unicode scalars, not Characters, so the Swift and
    /// Python validators agree. 81 decomposed "é" is 81 Characters but 162
    /// scalars, and must be rejected.
    @Test func frontTextOverScalarLimitButUnderCharacterCountFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["frontText"] = String(repeating: "e\u{0301}", count: 81)
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .portableTextTooLong(cardIndex: 0) = thrown else {
            Issue.record("Expected portableTextTooLong(cardIndex: 0), got \(thrown)")
            return
        }
    }

    @Test func textExactlyAtScalarLimitsIsAccepted() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["frontText"] = String(repeating: "a", count: 160)
            $0["backText"] = String(repeating: "b", count: 240)
        }
        guard case .portable = try ValidatedDeckImport.decode(data) else {
            Issue.record("Expected portable deck at the exact scalar limits")
            return
        }
    }

    @Test func missingSourceAnchorFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["sourceAnchor"] = nil }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableSourceAnchor(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableSourceAnchor(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: sourceAnchor must match the pattern s<section>-b<block>.")
    }

    @Test func malformedSourceAnchorFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["sourceAnchor"] = "chapter-two" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableSourceAnchor(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableSourceAnchor(cardIndex: 0), got \(thrown)")
            return
        }
    }

    @Test func timestampsPresentFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["startTime"] = 10.0
            $0["endTime"] = 20.0
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .portableTimestampsForbidden(cardIndex: 0) = thrown else {
            Issue.record("Expected portableTimestampsForbidden(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: startTime and endTime are not allowed for portable decks.")
    }

    @Test func timingNotManualOnlyFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["triggerTiming"] = "beginning" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .portableTimingMustBeManualOnly(cardIndex: 0) = thrown else {
            Issue.record("Expected portableTimingMustBeManualOnly(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: triggerTiming must be manualOnly for portable decks.")
    }

    @Test func malformedImageAnchorFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["imageAnchor"] = "not-an-anchor" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableImageAnchor(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableImageAnchor(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: imageAnchor must match the pattern s<section>-b<block>.")
    }

    @Test func bothImageFieldsPresentFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["imageAnchor"] = "s2-b0"
            $0["imageFile"] = "deck-images/mnemonic.png"
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .conflictingImageFields(cardIndex: 0) = thrown else {
            Issue.record("Expected conflictingImageFields(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: imageAnchor and imageFile are mutually exclusive; set at most one.")
    }

    @Test func unsafeImageFileTraversalFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["imageFile"] = "deck-images/../../etc/passwd"
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableImageFile(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableImageFile(cardIndex: 0), got \(thrown)")
            return
        }
        #expect(
            thrown.errorDescription
                == "Card 1: imageFile must be a safe relative path under deck-images/.")
    }

    @Test func absoluteImageFileFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["imageFile"] = "/deck-images/cue.png"
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableImageFile(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableImageFile(cardIndex: 0), got \(thrown)")
            return
        }
    }

    @Test func backslashImageFileFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["imageFile"] = "deck-images\\cue.png"
        }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableImageFile(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableImageFile(cardIndex: 0), got \(thrown)")
            return
        }
    }

    @Test func unsafeImageFileOutsideDeckImagesFails() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["imageFile"] = "mnemonic.png" }
        let thrown = try #require(throws: DeckImportError.self) {
            try ValidatedDeckImport.decode(data)
        }
        guard case .invalidPortableImageFile(cardIndex: 0) = thrown else {
            Issue.record("Expected invalidPortableImageFile(cardIndex: 0), got \(thrown)")
            return
        }
    }

    // MARK: - Valid image fields do not regress

    @Test func validImageAnchorClassifiesAsPortable() throws {
        let data = try mutatingFirstCard(portableDeckJSON) { $0["imageAnchor"] = "s2-b0" }
        let validated = try ValidatedDeckImport.decode(data)
        guard case .portable(let deck) = validated else {
            Issue.record("Expected portable deck")
            return
        }
        #expect(deck.cards[0].imageAnchor == "s2-b0")
    }

    @Test func validImageFileClassifiesAsPortable() throws {
        let data = try mutatingFirstCard(portableDeckJSON) {
            $0["imageFile"] = "deck-images/mnemonic.png"
        }
        let validated = try ValidatedDeckImport.decode(data)
        guard case .portable(let deck) = validated else {
            Issue.record("Expected portable deck")
            return
        }
        #expect(deck.cards[0].imageFile == "deck-images/mnemonic.png")
    }
}
