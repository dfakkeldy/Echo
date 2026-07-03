import Testing
@testable import MisakiSwift

let texts: [(originalText: String, requiredPhonemes: [String])] = [
  (
    "[Misaki](/misˈɑki/) is a G2P engine designed for [Kokoro](/kˈOkəɹO/) models.",
    ["misˈɑki", "kˈOkəɹO"]
  ),
  (
    "“To James Mortimer, M.R.C.S., from his friends of the C.C.H.,” was engraved upon it, with the date “1884.”",
    []
  )
]

@Test func testStrings_BritishPhonetization() async throws {
  let englishG2P = EnglishG2P(british: true)
  
  for pair in texts {
    let result = englishG2P.phonemize(text: pair.originalText).0
    #expect(!result.isEmpty)
    #expect(!result.contains("❓"))
    for phoneme in pair.requiredPhonemes {
      #expect(result.contains(phoneme))
    }
  }
}

@Test func testStrings_AmericanPhonetization() async throws {
  let englishG2P = EnglishG2P(british: false)

  for pair in texts {
    let result = englishG2P.phonemize(text: pair.originalText).0
    #expect(!result.isEmpty)
    #expect(!result.contains("❓"))
    for phoneme in pair.requiredPhonemes {
      #expect(result.contains(phoneme))
    }
  }
}

// Retokenize Currency Index Fix Tests
@Test func testRetokenize_CurrencyWithFollowingTokens() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "$50 is the price for this item")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹ"))  // "dollar" phoneme should be present
}

// Currency appearing mid-sentence with multiple tokens before and after
@Test func testRetokenize_CurrencyInMiddleOfSentence() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "The total cost was $100 and we paid it yesterday")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹz"))  // American "dollar" phoneme
}

// Multiple currency symbols trigger the currency code path multiple times
@Test func testRetokenize_MultipleCurrenciesInText() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "I exchanged $200 for €150 at the bank today")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹ"))  // "dollar" phoneme
  #expect(result.contains("jˈʊɹOz"))  // "euro" phoneme
}

@Test func testPastTense_IedVerbsUseKnownYStem() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "verified")

  #expect(result.phonemes == "vˈɛɹəfˌId")
  #expect(result.fallbackHits.isEmpty)
}

@Test func testCamelCaseCompoundsPreserveKnownWordBreaks() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "CarPlay")

  #expect(result.phonemes == "kˈɑɹ plˈA")
  #expect(result.fallbackHits.isEmpty)
}

@Test func testCamelCaseDoesNotSplitMcSurnamePrefix() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "McDonald")

  #expect(!result.phonemes.contains(" "))
}

@Test func testArithmeticKeepsNounAndTechnicalAdjectiveStress() async throws {
  let englishG2P = EnglishG2P(british: false)
  let noun = englishG2P.phonemizeWithMetadata(text: "Arithmetic is hard.")
  let adjective = englishG2P.phonemizeWithMetadata(text: "The arithmetic mean is useful.")

  #expect(noun.phonemes.hasPrefix("əɹˈɪθmətˌɪk "))
  #expect(adjective.phonemes.contains("ˌɛɹɪθmˈɛTɪk mˈin"))
  #expect(noun.fallbackHits.isEmpty)
  #expect(adjective.fallbackHits.isEmpty)
}
