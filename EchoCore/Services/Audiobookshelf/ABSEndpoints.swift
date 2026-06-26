// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// All Audiobookshelf URL/path construction in one place.
/// `baseURL` may include a reverse-proxy subpath (e.g. https://host:13378/audiobookshelf);
/// every endpoint appends RELATIVELY so the prefix is preserved. No force-unwraps.
struct ABSEndpoints {
    let baseURL: URL

    /// Normalize raw user input into a base URL: trims whitespace, strips a trailing
    /// slash, defaults a missing scheme to HTTPS, validates via URLComponents.
    /// Returns nil if unparseable. Users must type `http://` explicitly for plaintext
    /// LAN/tailnet servers so the connect UI can ask before sending credentials.
    static func normalizedBaseURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s), comps.host != nil else { return nil }
        return comps.url
    }

    static func requiresPlainHTTPConfirmation(_ url: URL) -> Bool {
        url.scheme?.localizedCaseInsensitiveCompare("http") == .orderedSame
    }

    func login() -> URL { baseURL.appending(path: "login") }
    func refresh() -> URL { baseURL.appending(path: "auth/refresh") }
    func logout() -> URL { baseURL.appending(path: "logout") }
    func libraries() -> URL { baseURL.appending(path: "api/libraries") }

    func items(libraryID: String, page: Int, limit: Int, filter: String?) -> URL {
        var url = baseURL.appending(path: "api/libraries/\(libraryID)/items")
        var q = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "media.metadata.title"),
            URLQueryItem(name: "minified", value: "0"),
        ]
        if let filter, !filter.isEmpty { q.append(URLQueryItem(name: "filter", value: filter)) }
        url.append(queryItems: q)
        return url
    }

    func item(_ id: String) -> URL {
        baseURL.appending(path: "api/items/\(id)")
            .appending(queryItems: [.init(name: "expanded", value: "1")])
    }

    /// Cover and file downloads authenticate via `?token=` so the URL is self-contained
    /// for AsyncImage / background downloads.
    func cover(_ id: String, token: String) -> URL {
        baseURL.appending(path: "api/items/\(id)/cover")
            .appending(queryItems: [.init(name: "token", value: token)])
    }

    func fileDownload(itemID: String, ino: String, token: String) -> URL {
        baseURL.appending(path: "api/items/\(itemID)/file/\(ino)/download")
            .appending(queryItems: [.init(name: "token", value: token)])
    }

    /// Whole-item single-file download (used later by the foreground download path).
    func downloadItem(_ itemID: String, token: String) -> URL {
        baseURL.appending(path: "api/items/\(itemID)/download")
            .appending(queryItems: [.init(name: "token", value: token)])
    }

    func search(libraryID: String, query: String, limit: Int) -> URL {
        var url = baseURL.appending(path: "api/libraries/\(libraryID)/search")
        url.append(queryItems: [
            .init(name: "q", value: query),
            .init(name: "limit", value: String(limit)),
        ])
        return url
    }

    func progress(_ itemID: String) -> URL { baseURL.appending(path: "api/me/progress/\(itemID)") }
    func localSessionsSync() -> URL { baseURL.appending(path: "api/session/local-all") }
}
