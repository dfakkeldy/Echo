import Foundation
import NaturalLanguage

struct NLPProcessor {
    func sentences(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
            String(text[$0]).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    func words(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
            String(text[$0])
        }
    }
}
