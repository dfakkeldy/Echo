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
        var words =
            folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        if let first = words.first, ["a", "an", "the"].contains(first) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    nonisolated static func groups(for identities: [Identity]) -> [String: String] {
        // Bucket by title first: separately imported epubs carry no author, so an
        // author-less edition can only join a title bucket whose authorship is
        // unambiguous (zero or one distinct author key).
        var byTitle: [String: [Identity]] = [:]
        for identity in identities {
            let titleKey = normalizedKey(title: identity.title)
            guard !titleKey.isEmpty else { continue }
            byTitle[titleKey, default: []].append(identity)
        }

        var result: [String: String] = [:]
        for titleKey in byTitle.keys.sorted() {
            guard let bucket = byTitle[titleKey] else { continue }
            let authorKeys = Set(bucket.map { normalizedKey(title: $0.author ?? "") })
                .subtracting([""])

            if authorKeys.count <= 1 {
                // 0 or 1 distinct author: author-less members join the group.
                guard bucket.count > 1 else { continue }
                let groupID = "edition:\(authorKeys.first ?? "")|\(titleKey)"
                for identity in bucket {
                    result[identity.id] = groupID
                }
            } else {
                // >= 2 distinct authors: group per author as before; author-less
                // members stay ungrouped (ambiguous — never guess an author).
                var byAuthor: [String: [Identity]] = [:]
                for identity in bucket {
                    let authorKey = normalizedKey(title: identity.author ?? "")
                    guard !authorKey.isEmpty else { continue }
                    byAuthor[authorKey, default: []].append(identity)
                }
                for authorKey in byAuthor.keys.sorted() {
                    guard let members = byAuthor[authorKey], members.count > 1 else { continue }
                    let groupID = "edition:\(authorKey)|\(titleKey)"
                    for identity in members {
                        result[identity.id] = groupID
                    }
                }
            }
        }
        return result
    }
}
