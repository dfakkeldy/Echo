// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EditionMatcher {
    struct Identity: Sendable {
        let id: String
        let title: String
        let author: String?
        /// The row's persisted audio-file count. Only consulted by the
        /// path-identity pass: a directly opened audio file may join its
        /// parent-folder row only when that folder row holds exactly one
        /// audio file, so sibling books in a shared folder never merge.
        var fileCount: Int? = nil
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
        var result = titleGroups(for: identities)

        // Path-identity pass: rows whose ids point at the same on-disk book
        // are the same book no matter what their titles say. The library
        // scanner keys a book by its standardized folder URL while a direct
        // open persists the picker's raw URL ("/private/var" vs "/var", or
        // the lone .m4b's file URL), so one book can accrue several rows.
        // Path groups override title groups; any full title group that shares
        // a member with a path cluster is absorbed into it, so an epub
        // edition already paired with the audio row stays on the same card.
        for cluster in pathClusters(for: identities) {
            var members = cluster.memberIDs
            let absorbedTitleGroups = Set(members.compactMap { result[$0] })
            if !absorbedTitleGroups.isEmpty {
                for identity in identities {
                    if let assigned = result[identity.id], absorbedTitleGroups.contains(assigned) {
                        members.insert(identity.id)
                    }
                }
            }
            for id in members {
                result[id] = cluster.groupID
            }
        }
        return result
    }

    // MARK: - Title grouping

    private nonisolated static func titleGroups(for identities: [Identity]) -> [String: String] {
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

    // MARK: - Path-identity grouping

    private struct PathCluster {
        let groupID: String
        let memberIDs: Set<String>
    }

    /// Clusters of rows that resolve to the same on-disk book:
    /// - folder rows whose standardized URLs are equal, and
    /// - a directly opened audio file joined to its parent-folder row when
    ///   that folder row claims exactly one audio file (a multi-book folder
    ///   must keep its per-file rows separate).
    /// Sorted by group id so repeated runs assign identical group ids.
    private nonisolated static func pathClusters(for identities: [Identity]) -> [PathCluster] {
        var folderMembers: [String: [Identity]] = [:]
        var audioFileMembers: [String: [Identity]] = [:]
        var audioFileParentKey: [String: String] = [:]

        for identity in identities {
            guard let url = URL(string: identity.id), url.isFileURL else { continue }
            let standardized = url.standardizedFileURL
            let key = canonicalPathKey(standardized)
            if LibraryScanner.audioExtensions.contains(standardized.pathExtension.lowercased()) {
                audioFileMembers[key, default: []].append(identity)
                audioFileParentKey[key] = canonicalPathKey(
                    standardized.deletingLastPathComponent())
            } else {
                folderMembers[key, default: []].append(identity)
            }
        }

        var clusters: [PathCluster] = []
        var claimedFileKeys: Set<String> = []

        for (folderKey, members) in folderMembers {
            var ids = Set(members.map(\.id))
            let folderHoldsSingleAudioFile = members.contains { $0.fileCount == 1 }
            if folderHoldsSingleAudioFile {
                for (fileKey, fileIdentities) in audioFileMembers
                where audioFileParentKey[fileKey] == folderKey {
                    ids.formUnion(fileIdentities.map(\.id))
                    claimedFileKeys.insert(fileKey)
                }
            }
            guard ids.count > 1 else { continue }
            clusters.append(PathCluster(groupID: "path:\(folderKey)", memberIDs: ids))
        }

        for (fileKey, fileIdentities) in audioFileMembers where !claimedFileKeys.contains(fileKey) {
            guard fileIdentities.count > 1 else { continue }
            clusters.append(
                PathCluster(groupID: "path:\(fileKey)", memberIDs: Set(fileIdentities.map(\.id))))
        }

        return clusters.sorted { $0.groupID < $1.groupID }
    }

    /// One comparison key per on-disk location: standardized (symlinks like
    /// "/private/var" resolved) and slash-insensitive, so a picker URL and the
    /// scanner's standardized folder URL compare equal.
    private nonisolated static func canonicalPathKey(_ url: URL) -> String {
        var key = url.absoluteString
        while key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }
}
