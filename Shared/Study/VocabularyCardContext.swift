// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decodes a vocabulary card's stored context sentence from its `mediaJSON`
/// (`{"context": "..."}`, written by `VocabularyCardBuilder`).
enum VocabularyCardContext {
    static func sentence(fromMediaJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let context = obj["context"] as? String, !context.isEmpty
        else { return nil }
        return context
    }
}
