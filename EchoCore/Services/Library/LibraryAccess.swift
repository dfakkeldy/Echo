// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Security-scoped bookmark make/resolve for Library roots, plus author-sort
/// normalization. Pure/static so it is testable with plain file URLs and shared
/// by iOS and (later) macOS. Mirrors `Persistence`'s bookmark options.
enum LibraryAccess {
    private static let logger = Logger(category: "LibraryAccess")

    /// Creates a persistent bookmark for `url` (a folder root or standalone book).
    /// Empty options = a full bookmark that survives relaunch, matching
    /// `Persistence.saveBookmark`. Enters the security scope around `bookmarkData`
    /// because iOS requires active access while creating a bookmark from a
    /// document-picker URL.
    static func makeBookmark(for url: URL) -> Data? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
                let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
                let options: URL.BookmarkCreationOptions = []
            #endif
            return try url.bookmarkData(
                options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
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
            #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
                let options: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(
                resolvingBookmarkData: data, options: options, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            return (url, isStale)
        } catch {
            logger.error("Bookmark resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persists a per-book security-scoped bookmark in the Keychain so standalone
    /// books picked directly from the file selector stay reopenable from the
    /// Library page after switching books or rebooting the device.
    @discardableResult
    static func saveBookBookmark(
        for url: URL,
        bookID: String,
        makeBookmark: (URL) -> Data? = { makeBookmark(for: $0) },
        saveData: (Data, String) -> Bool = { data, account in
            KeychainStore.set(
                data, forAccount: account, service: KeychainStore.bookBookmarkService)
        }
    ) -> Bool {
        guard let data = makeBookmark(url) else { return false }
        return saveData(data, bookBookmarkAccount(for: bookID))
    }

    /// Resolves a previously stored per-book security-scoped bookmark from the
    /// Keychain, refreshing it in place when iOS flags the bookmark as stale.
    static func resolveBookBookmark(
        for bookID: String,
        loadData: (String) -> Data? = { account in
            KeychainStore.data(forAccount: account, service: KeychainStore.bookBookmarkService)
        },
        resolveData: (Data) -> (url: URL, isStale: Bool)? = { resolveURL(from: $0) },
        makeBookmark: (URL) -> Data? = { makeBookmark(for: $0) },
        saveData: (Data, String) -> Bool = { data, account in
            KeychainStore.set(
                data, forAccount: account, service: KeychainStore.bookBookmarkService)
        }
    ) -> URL? {
        let account = bookBookmarkAccount(for: bookID)
        guard let data = loadData(account),
            let resolved = resolveData(data)
        else { return nil }
        if resolved.isStale, let refreshed = makeBookmark(resolved.url) {
            _ = saveData(refreshed, account)
        }
        return resolved.url
    }

    /// Stable Keychain account key for a book's security-scoped bookmark.
    static func bookBookmarkAccount(for bookID: String) -> String {
        if let url = URL(string: bookID), url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        return bookID
    }

    /// Computes the relative path from `root` to `child`, or `nil` if `child`
    /// is not equal to or inside `root`. Returns `""` when `child == root`.
    /// Uses resolved standardized path components so `/var` vs `/private/var`
    /// symlinks never break matching and sibling prefixes (`/Books2`) never
    /// falsely match `/Books`.
    nonisolated static func relativePath(of child: URL, from root: URL) -> String? {
        let childComponents = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard childComponents.count >= rootComponents.count else { return nil }
        guard Array(childComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        let remainder = childComponents.dropFirst(rootComponents.count)
        return remainder.joined(separator: "/")
    }

    /// Reconstructs a child URL beneath `resolvedRoot` from a stored relative
    /// path, falling back to `storedURL` only when `relativePath` is nil.
    nonisolated static func resolveChildURL(
        resolvedRoot: URL,
        relativePath: String?,
        fallbackURL: URL? = nil,
        rootDisplayName: String? = nil
    ) -> URL? {
        if let relativePath {
            if relativePath.isEmpty {
                return resolvedRoot
            }
            let components = relativePath.split(separator: "/").map(String.init)
            return components.reduce(resolvedRoot) { acc, part in
                acc.appendingPathComponent(part)
            }
        }
        guard let fallbackURL else { return nil }
        // If the stored URL still sits under the resolved root, preserve it.
        if let rel = Self.relativePath(of: fallbackURL, from: resolvedRoot) {
            return rel.isEmpty
                ? resolvedRoot
                : rel.split(separator: "/").map(String.init).reduce(resolvedRoot) {
                    $0.appendingPathComponent($1)
                }
        }
        // Prefix drifted across a reboot/FileProvider mount change on a legacy
        // row without `source_relative_path`: rebase the tail after the root's
        // folder name onto the live `resolvedRoot`.
        let rootName = rootDisplayName ?? resolvedRoot.lastPathComponent
        if !rootName.isEmpty {
            let parts = fallbackURL.standardizedFileURL.pathComponents
            if let anchorIdx = parts.lastIndex(of: rootName), anchorIdx + 1 < parts.count {
                let tail = parts[(anchorIdx + 1)...]
                return tail.reduce(resolvedRoot) { $0.appendingPathComponent($1) }
            }
        }
        return fallbackURL
    }

    /// Best-effort normalized grouping key for "browse by author": trims, flips a
    /// single "Last, First" into "First Last", lowercases. Display uses the raw
    /// author; this only groups. Returns nil for nil/empty input.
    nonisolated static func authorSort(_ author: String?) -> String? {
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
