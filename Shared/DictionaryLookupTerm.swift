// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum DictionaryLookupTerm {
    static func sanitized(_ rawTerm: String) -> String {
        let characters = Array(rawTerm)
        var start = 0
        var end = characters.count

        while start < end, characters[start].isDictionaryBoundaryPunctuation {
            start += 1
        }
        while end > start, characters[end - 1].isDictionaryBoundaryPunctuation {
            end -= 1
        }

        return String(characters[start..<end])
    }
}

private extension Character {
    var isDictionaryBoundaryPunctuation: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }
}
