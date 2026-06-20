// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HTTP client for one Audiobookshelf server. Sibling to `CloudKitSyncService`:
/// a concrete `@MainActor final class`, constructor-injected, no protocol.
/// The `session` parameter is the test seam (inject a `URLProtocolStub` session).
@MainActor
final class AudiobookshelfService {
    private let endpoints: ABSEndpoints
    private let tokens: ABSTokenStore
    private let session: URLSession

    /// Serializes refreshes so concurrent 401s don't each rotate the token (ABS #5253).
    private var inFlightRefresh: Task<String, Error>?

    init(baseURL: URL, tokens: ABSTokenStore, session: URLSession = .shared) {
        self.endpoints = ABSEndpoints(baseURL: baseURL)
        self.tokens = tokens
        self.session = session
    }

    // MARK: Auth

    /// POST /login. Sends `x-return-tokens: true` so the rotating refresh token is in the
    /// body (ABS otherwise sets it as an http-only cookie). Returns the server's default
    /// library id, if any.
    @discardableResult
    func login(username: String, password: String) async throws -> String? {
        var request = URLRequest(url: endpoints.login())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONEncoder().encode(
            ABSLoginRequest(username: username, password: password))

        let decoded: ABSLoginResponse = try await send(request, decode: ABSLoginResponse.self)
        guard let access = decoded.access else { throw ABSError.unauthorized }
        tokens.accessToken = access
        if let refresh = decoded.refresh { tokens.refreshToken = refresh }
        return decoded.userDefaultLibraryId
    }

    /// POST /auth/refresh with `x-refresh-token`. Serialized via `inFlightRefresh`, and
    /// persists the rotated refresh token EVERY time a refresh succeeds.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        if let existing = inFlightRefresh { return try await existing.value }
        guard let refresh = tokens.refreshToken else { throw ABSError.unauthorized }

        let task = Task<String, Error> { [endpoints, session, tokens] in
            var request = URLRequest(url: endpoints.refresh())
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            let decoded: ABSLoginResponse =
                try await Self.sendStatic(request, session: session, decode: ABSLoginResponse.self)
            guard let access = decoded.access else { throw ABSError.unauthorized }
            tokens.accessToken = access
            if let rotated = decoded.refresh { tokens.refreshToken = rotated }  // persist EVERY time
            return access
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    func signOut() async {
        if let refresh = tokens.refreshToken {
            var request = URLRequest(url: endpoints.logout())
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            _ = try? await session.data(for: request)
        }
        tokens.clear()
    }

    // MARK: Browse

    func libraries() async throws -> [ABSLibrary] {
        let request = URLRequest(url: endpoints.libraries())
        return try await authorized(request, decode: ABSLibrariesResponse.self).libraries
    }

    func items(libraryID: String, page: Int = 0, limit: Int = 50, filter: String? = nil)
        async throws -> ABSLibraryItemsResponse
    {
        let request = URLRequest(
            url: endpoints.items(libraryID: libraryID, page: page, limit: limit, filter: filter))
        return try await authorized(request, decode: ABSLibraryItemsResponse.self)
    }

    func item(id: String) async throws -> ABSLibraryItem {
        let request = URLRequest(url: endpoints.item(id))
        return try await authorized(request, decode: ABSLibraryItem.self)
    }

    /// Server-side search across the library (title/author/series/narrator/...).
    /// Returns the matched library items (the `book` results).
    func search(libraryID: String, query: String, limit: Int = 25) async throws -> [ABSLibraryItem]
    {
        let request = URLRequest(
            url: endpoints.search(libraryID: libraryID, query: query, limit: limit))
        return try await authorized(request, decode: ABSSearchResponse.self).book.map(\.libraryItem)
    }

    /// Self-contained cover URL for `AsyncImage` (token in query). nil if not logged in.
    func coverURL(itemID: String) -> URL? {
        guard let token = tokens.accessToken else { return nil }
        return endpoints.cover(itemID, token: token)
    }

    // MARK: Authorized request plumbing

    /// Performs `request` with a Bearer access token; on 401 refreshes once and retries.
    func authorized<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        var attempt = request
        if let access = tokens.accessToken {
            attempt.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        do {
            return try await send(attempt, decode: type)
        } catch ABSError.http(401, _) {
            let access = try await refreshAccessToken()
            var retry = request
            retry.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            return try await send(retry, decode: type)
        }
    }

    // MARK: Download

    /// Downloads the item's whole-item zip (audio + any EPUB) to `destination`, replacing
    /// any existing file there. The token is carried in the URL query (ABS-supported) and
    /// also as a Bearer header; on a 401 it refreshes once and retries. The zip has no
    /// Content-Length (streamed), so callers can't show a determinate percentage.
    func downloadItemZip(itemID: String, to destination: URL) async throws {
        func attempt(_ token: String) async throws -> (URL, URLResponse) {
            var request = URLRequest(url: endpoints.downloadItem(itemID, token: token))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await session.download(for: request)
        }
        guard let access = tokens.accessToken else { throw ABSError.unauthorized }
        var (tempURL, response) = try await attempt(access)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let refreshed = try await refreshAccessToken()
            (tempURL, response) = try await attempt(refreshed)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)  // don't leak the temp file on a non-2xx
            throw ABSError.http((response as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: Transport

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        try await Self.sendStatic(request, session: session, decode: type)
    }

    /// Static so the refresh `Task` closure doesn't capture `self`.
    nonisolated private static func sendStatic<T: Decodable>(
        _ request: URLRequest, session: URLSession, decode type: T.Type
    ) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ABSError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ABSError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ABSError.http(http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
