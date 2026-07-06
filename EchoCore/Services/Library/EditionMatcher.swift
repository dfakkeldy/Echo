// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EditionMatcher {
    struct Identity: Sendable {
        let id: String
        let title: String
        let author: String?
    }

    nonisolated static func normalizedKey(title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        if let first = words.first, ["a", "an", "the"].contains(first) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    nonisolated static func groups(for identities: [Identity]) -> [String: String] {
        var byKey: [String: [Identity]] = [:]
        for identity in identities {
            let titleKey = normalizedKey(title: identity.title)
            guard !titleKey.isEmpty else { continue }
            let authorKey = normalizedKey(title: identity.author ?? "")
            byKey["\(authorKey)|\(titleKey)", default: []].append(identity)
        }

        var result: [String: String] = [:]
        for key in byKey.keys.sorted() {
            guard let identities = byKey[key], identities.count > 1 else { continue }
            let groupID = "edition:\(key)"
            for identity in identities {
                result[identity.id] = groupID
            }
        }
        return result
    }
}
