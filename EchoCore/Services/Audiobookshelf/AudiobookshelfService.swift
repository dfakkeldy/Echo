// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OSLog

/// HTTP client for one Audiobookshelf server. Sibling to `CloudKitSyncService`:
/// a concrete `@MainActor final class`, constructor-injected, no protocol.
/// The `session` parameter is the test seam (inject a `URLProtocolStub` session).
@MainActor
final class AudiobookshelfService {
    private let logger = Logger(category: "AudiobookshelfAuth")
    private let endpoints: ABSEndpoints
    private let tokens: ABSTokenStore
    private let session: URLSession
    /// Trust delegate backing `session`, when this service owns a custom (non-`.shared`) session.
    /// nil for `.shared`/stub sessions (tests, CA-trusted/http servers reuse the legacy default).
    private let trustDelegate: ABSServerTrustDelegate?

    /// Serializes refreshes so concurrent 401s don't each rotate the token (ABS #5253).
    private var inFlightRefresh: Task<String, Error>?

    init(
        baseURL: URL, tokens: ABSTokenStore,
        session: URLSession = .shared, trustDelegate: ABSServerTrustDelegate? = nil
    ) {
        self.endpoints = ABSEndpoints(baseURL: baseURL)
        self.tokens = tokens
        self.session = session
        self.trustDelegate = trustDelegate
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

    func signOut() async -> ABSSignOutResult {
        guard let refresh = tokens.refreshToken else {
            tokens.clear()
            logger.info("ABS sign-out cleared local credentials; no remote refresh token was present.")
            return .noRemoteToken
        }

        var request = URLRequest(url: endpoints.logout())
        request.httpMethod = "POST"
        request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")

        do {
            _ = try await Self.sendDataStatic(request, session: session)
            tokens.clear()
            logger.info("ABS sign-out revoked the remote refresh token and cleared local credentials.")
            return .remoteRevoked
        } catch let error as ABSError {
            tokens.clear()
            logger.warning(
                "ABS remote sign-out failed; local credentials were cleared: \(error.privacySafeLogDescription, privacy: .public)"
            )
            return .remoteRevokeFailed(error)
        } catch {
            tokens.clear()
            let mapped = ABSError.network(error)
            logger.warning(
                "ABS remote sign-out failed; local credentials were cleared: \(mapped.privacySafeLogDescription, privacy: .public)"
            )
            return .remoteRevokeFailed(mapped)
        }
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

    func allItems(libraryID: String, pageSize: Int = 100, filter: String? = nil)
        async throws -> [ABSLibraryItem]
    {
        let limit = max(1, pageSize)
        var page = 0
        var results: [ABSLibraryItem] = []

        while true {
            let response = try await items(
                libraryID: libraryID, page: page, limit: limit, filter: filter)
            guard !response.results.isEmpty else { return results }

            results.append(contentsOf: response.results)
            if let total = response.total, results.count >= total { return results }
            if let numPages = response.numPages, page + 1 >= numPages { return results }
            if response.total == nil, response.numPages == nil, response.results.count < limit {
                return results
            }

            page += 1
        }
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
        return try await authorized(request, decode: ABSSearchResponse.self).libraryItems
    }

    /// Loads cover bytes using header auth. The request deliberately bypasses URL caches because
    /// cover responses are account-scoped and should not be reused outside this authorized request.
    func coverImageData(itemID: String) async throws -> Data {
        var request = URLRequest(url: endpoints.cover(itemID))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return try await authorizedData(request)
    }

    // MARK: Progress

    /// Current ABS-side progress for an item, or nil if none recorded yet (404).
    func getProgress(itemID: String) async throws -> ABSMediaProgressResponse? {
        let request = URLRequest(url: endpoints.progress(itemID))
        do {
            return try await authorized(request, decode: ABSMediaProgressResponse.self)
        } catch ABSError.http(404, _) {
            return nil
        }
    }

    /// Push local progress to ABS (PATCH /api/me/progress/<id>).
    func patchProgress(itemID: String, currentTime: Double, duration: Double, isFinished: Bool)
        async throws
    {
        var request = URLRequest(url: endpoints.progress(itemID))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fraction = duration > 0 ? min(1.0, max(0.0, currentTime / duration)) : 0
        request.httpBody = try JSONEncoder().encode(
            ABSMediaProgressPatch(
                currentTime: currentTime, duration: duration,
                progress: fraction, isFinished: isFinished))
        try await authorizedNoContent(request)
    }

    /// Like `authorized` but for requests whose response body we don't decode (PATCH/POST).
    /// Same Bearer + single 401-refresh-retry behavior.
    func authorizedNoContent(_ request: URLRequest) async throws {
        func run(_ r: URLRequest) async throws {
            let (_, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else {
                throw ABSError.network(URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ABSError.http(http.statusCode, body: nil)
            }
        }
        var attempt = request
        if let access = tokens.accessToken {
            attempt.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        do {
            try await run(attempt)
        } catch ABSError.http(401, _) {
            let access = try await refreshAccessToken()
            var retry = request
            retry.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            try await run(retry)
        }
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

    /// Performs `request` with Bearer auth and returns the raw response body.
    /// Used for authenticated binary payloads such as cover images.
    func authorizedData(_ request: URLRequest) async throws -> Data {
        var attempt = request
        if let access = tokens.accessToken {
            attempt.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        do {
            return try await sendData(attempt)
        } catch ABSError.http(401, _) {
            let access = try await refreshAccessToken()
            var retry = request
            retry.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            return try await sendData(retry)
        }
    }

    // MARK: Download

    /// Downloads the item's whole-item zip (audio + any EPUB) to `destination`, replacing
    /// any existing file there. The token is carried only in the Bearer header; on a 401 it
    /// refreshes once and retries. The zip has no
    /// Content-Length (streamed), so callers can't show a determinate percentage.
    func downloadItemZip(itemID: String, to destination: URL) async throws {
        func attempt(_ token: String) async throws -> (URL, URLResponse) {
            var request = URLRequest(url: endpoints.downloadItem(itemID))
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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
        do {
            return try await Self.sendStatic(request, session: session, decode: type)
        } catch let error as ABSError {
            // A self-signed cert surfaces here on first connect; turn it into `.untrustedCertificate`
            // (carrying the fingerprint the delegate captured) so the UI can offer to pin it.
            throw ABSError.mappingTrustFailure(
                error,
                capturedFingerprint: trustDelegate?.lastUntrustedLeafSHA256,
                host: endpoints.baseURL.host ?? "")
        }
    }

    private func sendData(_ request: URLRequest) async throws -> Data {
        do {
            return try await Self.sendDataStatic(request, session: session)
        } catch let error as ABSError {
            throw ABSError.mappingTrustFailure(
                error,
                capturedFingerprint: trustDelegate?.lastUntrustedLeafSHA256,
                host: endpoints.baseURL.host ?? "")
        }
    }

    /// Releases the custom delegate-backed session (and its retained delegate). No-op for the
    /// `.shared`/stub path — never invalidate `URLSession.shared`.
    func invalidate() {
        if trustDelegate != nil { session.finishTasksAndInvalidate() }
    }

    /// Static so the refresh `Task` closure doesn't capture `self`.
    nonisolated private static func sendStatic<T: Decodable>(
        _ request: URLRequest, session: URLSession, decode type: T.Type
    ) async throws -> T {
        let data = try await sendDataStatic(request, session: session)
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func sendDataStatic(
        _ request: URLRequest, session: URLSession
    ) async throws -> Data {
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
        return data
    }
}
