// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleRevisionConflictResolution: Equatable, Sendable {
    let revisions: [ArticleRevisionRecord]
    let activeRevisionID: String?
    let requiresReview: Bool
}

nonisolated struct ArticleAnthologyConflictResolution: Equatable, Sendable {
    let active: ArticleCloudAnthologyManifest
    let recovered: ArticleCloudAnthologyManifest
}

/// Pure, deterministic policy for retaining immutable cleanup siblings and
/// preserving both ordered project manifests after concurrent edits.
nonisolated struct ArticleSyncConflictResolver: Sendable {
    func resolveRevision(
        incoming: ArticleRevisionRecord,
        existing: [ArticleRevisionRecord],
        activeRevisionID: String?
    ) -> ArticleRevisionConflictResolution {
        if existing.contains(where: { $0.id == incoming.id }) {
            return ArticleRevisionConflictResolution(
                revisions: existing.sorted(by: Self.revisionOrder),
                activeRevisionID: activeRevisionID,
                requiresReview: false)
        }

        var revisions = existing
        revisions.append(incoming)
        let active = activeRevisionID.flatMap { id in
            existing.first(where: { $0.id == id })
        }
        let isSibling =
            active.map {
                $0.id != incoming.id
                    && $0.parentRevisionID == incoming.parentRevisionID
            } ?? false
        let followsActive = incoming.parentRevisionID == activeRevisionID

        return ArticleRevisionConflictResolution(
            revisions: revisions.sorted(by: Self.revisionOrder),
            activeRevisionID: followsActive && !isSibling ? incoming.id : activeRevisionID,
            requiresReview: isSibling)
    }

    func resolveAnthology(
        incoming: ArticleCloudAnthologyManifest,
        existing: ArticleCloudAnthologyManifest,
        makeRecoveredID: @Sendable () -> UUID
    ) -> ArticleAnthologyConflictResolution {
        let recoveredID = makeRecoveredID()
        let recoveredTitle = Self.recoveredTitle(incoming.anthology.title)
        var recoveredAnthology = incoming.anthology
        recoveredAnthology.id = recoveredID.uuidString
        recoveredAnthology.title = recoveredTitle
        recoveredAnthology.createdAt = incoming.anthology.modifiedAt
        let recoveredEntries = incoming.entries.map { entry in
            var copy = entry
            copy.id =
                ArticleSyncConflictIdentity.recoveredEntryID(
                    recoveredAnthologyID: recoveredID,
                    entryID: entry.id
                ).uuidString
            copy.anthologyID = recoveredID.uuidString
            return copy
        }
        return ArticleAnthologyConflictResolution(
            active: existing,
            recovered: ArticleCloudAnthologyManifest(
                schemaVersion: incoming.schemaVersion,
                anthology: recoveredAnthology,
                entries: recoveredEntries,
                coverContentVersion: incoming.coverContentVersion))
    }

    func recoveredAnthologyID(
        incoming: ArticleCloudAnthologyManifest,
        existing: ArticleCloudAnthologyManifest
    ) -> UUID {
        ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: existing)
    }

    private static func revisionOrder(
        _ lhs: ArticleRevisionRecord,
        _ rhs: ArticleRevisionRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func recoveredTitle(_ title: String) -> String {
        let suffix = " (Recovered)"
        return title.hasSuffix(suffix) ? title : title + suffix
    }

}
