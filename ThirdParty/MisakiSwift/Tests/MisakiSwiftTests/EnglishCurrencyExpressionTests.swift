import Testing
@testable import MisakiSwift

@Suite struct EnglishCurrencyExpressionTests {
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
  func supported(input: String, spoken: String) throws {
    let expression = try #require(EnglishCurrencyExpression.parse(input))
    #expect(expression.spokenForm == spoken)
  }

  @Test(arguments: [
    "$1,23", "$1.2.3", "$1.001", "$2 bn", "$2 quadrillion",
    "¥2", "$", "100 billion people",
  ])
  func unsupportedIsNotConsumed(input: String) {
    #expect(EnglishCurrencyExpression.parse(input) == nil)
  }
}
