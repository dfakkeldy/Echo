// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Security-scoped bookmark make/resolve for Library roots, plus author-sort
/// normalization. Pure/static so it is testable with plain file URLs and shared
/// by iOS and (later) macOS. Mirrors `Persistence`'s bookmark options.
enum LibraryAccess {
    private static let logger = Logger(category: "LibraryAccess")

    /// Creates a persistent bookmark for `url` (a folder root). Empty options =
    /// a full bookmark that survives relaunch, matching `Persistence.saveBookmark`.
    static func makeBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            logger.error("Bookmark create failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves bookmark `data` back to a URL, reporting staleness. Returns nil if
    /// the bookmark can no longer be resolved (the root is unavailable).
    static func resolveURL(from data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: [], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            return (url, isStale)
        } catch {
            logger.error("Bookmark resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Best-effort normalized grouping key for "browse by author": trims, flips a
    /// single "Last, First" into "First Last", lowercases. Display uses the raw
    /// author; this only groups. Returns nil for nil/empty input.
    static func authorSort(_ author: String?) -> String? {
        guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }

        let parts = trimmed.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let canonical = parts.count == 2 ? "\(parts[1]) \(parts[0])" : trimmed
        return canonical.lowercased()
    }
}
