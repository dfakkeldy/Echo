import Testing
@testable import MisakiSwift

@Suite struct EnglishCurrencyExpressionTests {
  private let g2p = EnglishG2P(british: false)

  @Test(arguments: [
    ("$0", "zero dollars"),
    ("$1", "one dollar"),
    ("$2", "two dollars"),
    ("$1.00", "one dollar"),
    ("$1.01", "one dollar and one cent"),
    ("$0.50", "fifty cents"),
    ("£0.01", "one penny"),
    ("£0.02", "two pence"),
    ("€1.01", "one euro and one cent"),
    ("$5.5 million", "five point five million dollars"),
    ("$100 billion", "one hundred billion dollars"),
    ("£1.5 million", "one point five million pounds"),
    ("€2 trillion", "two trillion euros"),
    ("$2 BILLION", "two billion dollars"),
    ("-$2 billion", "minus two billion dollars"),
    ("$-2 billion", "minus two billion dollars"),
    ("$1,234.56", "one thousand, two hundred and thirty-four dollars and fifty-six cents"),
    ("$1,000,000", "one million dollars"),
    ("$1.0 million", "one million dollars"),
    ("$5.50 million", "five point five million dollars"),
    ("$.5 million", "zero point five million dollars"),
  ])
  func supported(input: String, spoken: String) throws {
    let expression = try #require(EnglishCurrencyExpression.parse(input))
    #expect(expression.spokenForm == spoken)
  }

  @Test(arguments: [
    (
      "$9,223,372,036,854,775,808",
      "nine quintillion, two hundred and twenty-three quadrillion, three hundred and seventy-two trillion, thirty-six billion, eight hundred and fifty-four million, seven hundred and seventy-five thousand, eight hundred and eight dollars"
    ),
    (
      "$9,223,372,036,854,775,808.50 million",
      "nine quintillion, two hundred and twenty-three quadrillion, three hundred and seventy-two trillion, thirty-six billion, eight hundred and fifty-four million, seven hundred and seventy-five thousand, eight hundred and eight point five million dollars"
    ),
    (
      "$1,000,000,000,000,000,000,000,000,000,000,000",
      "one decillion dollars"
    ),
  ])
  func valuesBeyondSignedIntRangeUseExactDigitSpeech(input: String, spoken: String) throws {
    let expression = try #require(EnglishCurrencyExpression.parse(input))
    #expect(expression.spokenForm == spoken)
  }

  @Test func valuesAboveNamedScaleCeilingFailClosed() {
    #expect(
      EnglishCurrencyExpression.parse(
        "$1,000,000,000,000,000,000,000,000,000,000,000,000"
      ) == nil
    )
  }

  @Test(arguments: [
    "$1,23", "$1.2.3", "$1.001", "$2 bn", "$2 quadrillion",
    "¥2", "$", "100 billion people",
  ])
  func unsupportedIsNotConsumed(input: String) {
    #expect(EnglishCurrencyExpression.parse(input) == nil)
  }

  @Test func multiScalarDigitGraphemeFailsClosed() {
    #expect(EnglishCurrencyExpression.parse("$1.1️⃣ million") == nil)
  }

  @Test(arguments: ["$1.", "$1,"])
  func sentencePunctuationIsNotPartOfTheAmount(input: String) {
    #expect(EnglishCurrencyExpression.parse(input) == nil)
  }

  @Test(arguments: [
    ("$0", "zero dollars"),
    ("$1", "one dollar"),
    ("$2", "two dollars"),
    ("$1.00", "one dollar"),
    ("$1.01", "one dollar and one cent"),
    ("$0.50", "fifty cents"),
    ("£0.01", "one penny"),
    ("£0.02", "two pence"),
    ("€1.01", "one euro and one cent"),
    ("$5.5 million", "five point five million dollars"),
    ("$100 billion", "one hundred billion dollars"),
    ("£1.5 million", "one point five million pounds"),
    ("€2 trillion", "two trillion euros"),
    ("$2 BILLION", "two billion dollars"),
    ("-$2 billion", "minus two billion dollars"),
    ("$-2 billion", "minus two billion dollars"),
    ("$1,234.56", "one thousand, two hundred and thirty-four dollars and fifty-six cents"),
    ("$1.0 million", "one million dollars"),
    ("$5.50 million", "five point five million dollars"),
    ("$.5 million", "zero point five million dollars"),
  ])
  func supportedExpressionBecomesOneSemanticToken(source: String, spoken: String) throws {
    let result = g2p.phonemizeWithMetadata(text: source)
    let semanticToken = try #require(result.tokens.first)

    #expect(result.tokens.count == 1)
    #expect(reconstructedSource(from: result.tokens) == source)
    #expect(reconstructedSpokenSurface(from: result.tokens) == spoken)
    #expect(semanticToken.text == source)
    #expect(semanticToken.`_`.alias == spoken)
    #expect(semanticToken.`_`.currencyExpressionSource == source)
    #expect(semanticToken.`_`.rating == 4)
  }

  @Test func semanticCurrencySpanStopsBeforeFollowingPunctuation() throws {
    let source = "Revenue was $100 billion."
    let result = g2p.phonemizeWithMetadata(text: source)
    let semanticToken = try #require(
      result.tokens.first { $0.`_`.currencyExpressionSource != nil }
    )

    #expect(reconstructedSource(from: result.tokens) == source)
    #expect(
      reconstructedSpokenSurface(from: result.tokens)
        == "Revenue was one hundred billion dollars."
    )
    #expect(semanticToken.text == "$100 billion")
    #expect(semanticToken.`_`.currencyExpressionSource == "$100 billion")
    #expect(String(source[semanticToken.tokenRange]) == "$100 billion")
    #expect(semanticToken.whitespace.isEmpty)
    #expect(result.tokens.last?.text == ".")
  }

  @Test func semanticCurrencySpanCarriesTrailingBoundaryWhitespace() throws {
    let source = "It cost $2 today."
    let result = g2p.phonemizeWithMetadata(text: source)
    let semanticToken = try #require(
      result.tokens.first { $0.`_`.currencyExpressionSource != nil }
    )

    #expect(reconstructedSource(from: result.tokens) == source)
    #expect(reconstructedSpokenSurface(from: result.tokens) == "It cost two dollars today.")
    #expect(String(source[semanticToken.tokenRange]) == "$2")
    #expect(semanticToken.whitespace == " ")
  }

  @Test(arguments: [
    ("$1,23", ["$1,23"]),
    ("$1.2.3", ["$1.2.3"]),
    ("$1.001", ["$1.001"]),
    ("$2 bn", ["$2 ", "bn"]),
    ("$2 quadrillion", ["$2 ", "quadrillion"]),
    ("$2bn", ["$2bn"]),
    ("$2million", ["$2million"]),
    ("$", ["$"]),
  ])
  func malformedSupportedSymbolCandidateRemainsIntact(
    source: String,
    expectedTokenSurfaces: [String]
  ) {
    let result = g2p.phonemizeWithMetadata(text: source)

    #expect(reconstructedSource(from: result.tokens) == source)
    #expect(reconstructedSpokenSurface(from: result.tokens) == source)
    #expect(result.tokens.map { $0.text + $0.whitespace } == expectedTokenSurfaces)
    #expect(result.tokens.allSatisfy { !$0.text.isEmpty })
    #expect(result.tokens.allSatisfy {
      !$0.text.contains(where: \.isLetter) || !($0.phonemes ?? "").isEmpty
    })
    #expect(result.tokens.allSatisfy { $0.`_`.currencyExpressionSource == nil })
  }

  @Test func nonCurrencyMagnitudeProseHasNoCurrencyMetadata() {
    let source = "100 billion people"
    let result = g2p.phonemizeWithMetadata(text: source)

    #expect(reconstructedSource(from: result.tokens) == source)
    #expect(result.tokens.allSatisfy { $0.`_`.currencyExpressionSource == nil })
  }

  private func reconstructedSource(from tokens: [MToken]) -> String {
    tokens.map { $0.text + $0.whitespace }.joined()
  }

  private func reconstructedSpokenSurface(from tokens: [MToken]) -> String {
    tokens.map { ($0.`_`.alias ?? $0.text) + $0.whitespace }.joined()
  }
}
