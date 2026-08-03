import Foundation

struct EnglishCurrencyUnitForms: Equatable, Sendable {
  let majorSingular: String
  let majorPlural: String
  let minorSingular: String
  let minorPlural: String
}

struct EnglishCurrencyExpression: Equatable, Sendable {
  enum Magnitude: String, CaseIterable, Sendable {
    case thousand, million, billion, trillion
  }

  let source: String
  let symbol: Character
  let isNegative: Bool
  let integerDigits: String
  let fractionalDigits: String?
  let magnitude: Magnitude?
  let spokenForm: String

  static func parse(_ source: String) -> Self? {
    var remainder = source[...]
    var isNegative = false

    if remainder.first == "-" {
      isNegative = true
      remainder.removeFirst()
    }

    guard let symbol = remainder.first,
          let unitForms = Lexicon.currencies[String(symbol)] else {
      return nil
    }
    remainder.removeFirst()

    if remainder.first == "-" {
      guard !isNegative else { return nil }
      isNegative = true
      remainder.removeFirst()
    }

    let amountAndMagnitude = remainder.split(separator: " ", omittingEmptySubsequences: false)
    guard amountAndMagnitude.count == 1 || amountAndMagnitude.count == 2,
          !amountAndMagnitude[0].isEmpty else {
      return nil
    }

    let magnitude: Magnitude?
    if amountAndMagnitude.count == 2 {
      guard !amountAndMagnitude[1].isEmpty,
            let parsedMagnitude = Magnitude(rawValue: amountAndMagnitude[1].lowercased()) else {
        return nil
      }
      magnitude = parsedMagnitude
    } else {
      magnitude = nil
    }

    guard let digits = parseDigits(String(amountAndMagnitude[0])),
          magnitude != nil || (digits.fractional?.count ?? 0) <= 2,
          let integerValue = Int(digits.integer) else {
      return nil
    }

    let numberWords = EnglishNum2Word()
    let unsignedSpokenForm: String
    if let magnitude {
      var amountWords = numberWords.convert(Decimal(integerValue))
      if let fractionalDigits = digits.fractional {
        var normalizedFraction = fractionalDigits
        while normalizedFraction.last == "0" {
          normalizedFraction.removeLast()
        }
        if !normalizedFraction.isEmpty {
          var fractionWords: [String] = []
          for digit in normalizedFraction {
            guard let digitValue = asciiDigitValue(digit) else { return nil }
            fractionWords.append(numberWords.convert(Decimal(digitValue)))
          }
          amountWords += " point " + fractionWords.joined(separator: " ")
        }
      }
      unsignedSpokenForm = "\(amountWords) \(magnitude.rawValue) \(unitForms.majorPlural)"
    } else {
      let fractionalDigits = digits.fractional ?? ""
      let minorDigits = fractionalDigits.count == 1 ? fractionalDigits + "0" : fractionalDigits
      guard let minorValue = Int(minorDigits.isEmpty ? "0" : minorDigits) else { return nil }

      var components: [String] = []
      if integerValue != 0 || minorValue == 0 {
        let unit = integerValue == 1 ? unitForms.majorSingular : unitForms.majorPlural
        components.append("\(numberWords.convert(Decimal(integerValue))) \(unit)")
      }
      if minorValue != 0 {
        let unit = minorValue == 1 ? unitForms.minorSingular : unitForms.minorPlural
        components.append("\(numberWords.convert(Decimal(minorValue))) \(unit)")
      }
      unsignedSpokenForm = components.joined(separator: " and ")
    }

    let spokenForm = isNegative ? "minus \(unsignedSpokenForm)" : unsignedSpokenForm
    return Self(
      source: source,
      symbol: symbol,
      isNegative: isNegative,
      integerDigits: digits.integer,
      fractionalDigits: digits.fractional,
      magnitude: magnitude,
      spokenForm: spokenForm
    )
  }

  private static func parseDigits(_ amount: String) -> (integer: String, fractional: String?)? {
    let decimalParts = amount.split(separator: ".", omittingEmptySubsequences: false)
    guard decimalParts.count == 1 || decimalParts.count == 2 else { return nil }

    let integerPart = String(decimalParts[0])
    let fractionalPart = decimalParts.count == 2 ? String(decimalParts[1]) : nil
    guard fractionalPart == nil || !(fractionalPart?.isEmpty ?? true),
          fractionalPart?.allSatisfy(isASCIIDigit) != false else {
      return nil
    }

    let integerDigits: String
    if integerPart.isEmpty {
      guard fractionalPart != nil else { return nil }
      integerDigits = "0"
    } else if integerPart.contains(",") {
      let groups = integerPart.split(separator: ",", omittingEmptySubsequences: false)
      guard let leadingGroup = groups.first,
            (1...3).contains(leadingGroup.count),
            leadingGroup.allSatisfy(isASCIIDigit),
            groups.dropFirst().allSatisfy({
              $0.count == 3 && $0.allSatisfy(isASCIIDigit)
            }) else {
        return nil
      }
      integerDigits = groups.joined()
    } else {
      guard integerPart.allSatisfy(isASCIIDigit) else { return nil }
      integerDigits = integerPart
    }

    return (integerDigits, fractionalPart)
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    asciiDigitValue(character) != nil
  }

  private static func asciiDigitValue(_ character: Character) -> Int? {
    guard character.unicodeScalars.count == 1,
          let scalar = character.unicodeScalars.first,
          (48...57).contains(scalar.value) else {
      return nil
    }
    return Int(scalar.value - 48)
  }
}
