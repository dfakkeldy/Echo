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

    func items(libraryID: String, query: ABSLibraryItemsQuery) async throws -> ABSLibraryItemsResponse {
        let request = URLRequest(url: endpoints.items(libraryID: libraryID, query: query))
        return try await authorized(request, decode: ABSLibraryItemsResponse.self)
    }

    func allItems(libraryID: String, query: ABSLibraryItemsQuery) async throws -> [ABSLibraryItem] {
        try await pagedItems(libraryID: libraryID, query: query) { _ in }
    }

    func libraryFilterData(libraryID: String) async throws -> ABSLibraryFilterData {
        let request = URLRequest(url: endpoints.libraryFilterData(libraryID))
        let response = try await authorized(request, decode: ABSLibraryFilterDataResponse.self)
        return response.browseFilterData
    }

    func pagedItems(
        libraryID: String,
        query: ABSLibraryItemsQuery,
        onPage: ([ABSLibraryItem]) async throws -> Void
    ) async throws -> [ABSLibraryItem] {
        var query = query
        query.limit = max(1, query.limit)
        var results: [ABSLibraryItem] = []

        while true {
            let response = try await items(libraryID: libraryID, query: query)
            guard !response.results.isEmpty else { return results }

            let responseLimit = max(1, response.limit ?? query.limit)
            let responsePage = response.page ?? query.page
            results.append(contentsOf: response.results)
            try await onPage(response.results)
            if response.results.count < responseLimit { return results }
            if let total = response.total,
                responsePage * responseLimit + response.results.count >= total
            {
                return results
            }
            if let numPages = response.numPages, responsePage + 1 >= numPages { return results }

            query.page += 1
        }
    }

    func item(id: String) async throws -> ABSLibraryItem {
        let request = URLRequest(url: endpoints.item(id))
        return try await authorized(request, decode: ABSLibraryItem.self)
    }

    /// Server-side search across the library (title/author/series/narrator/...).
    /// Returns item-bearing book, podcast, series, and author matches with stable ID deduplication.
    func search(libraryID: String, query: String, limit: Int = 25) async throws -> ABSSearchResults
    {
        let request = URLRequest(
            url: endpoints.search(libraryID: libraryID, query: query, limit: limit))
        let response = try await authorized(request, decode: ABSSearchResponse.self)
        let authorResults: [ABSLibraryItem]
        if response.authorNames.isEmpty {
            authorResults = []
        } else {
            authorResults = try await authorSearchFallbackItems(
                libraryID: libraryID, authorNames: response.authorNames, limit: limit)
        }
        return ABSSearchResults(
            items: deduplicated(response.libraryItems + authorResults),
            isLimited: response.isPotentiallyLimited(to: limit))
    }

    private func authorSearchFallbackItems(
        libraryID: String,
        authorNames: [String],
        limit: Int
    ) async throws -> [ABSLibraryItem] {
        let items = try await allItems(
            libraryID: libraryID,
            query: ABSLibraryItemsQuery(limit: max(limit, 25), sort: .title))
        var seen = Set<String>()
        let matches = items.filter { item in
            guard let author = item.author else { return false }
            return authorNames.contains { name in
                author.localizedStandardContains(name) || name.localizedStandardContains(author)
            } && seen.insert(item.id).inserted
        }
        return matches
    }

    private func deduplicated(_ items: [ABSLibraryItem]) -> [ABSLibraryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
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
    /// refreshes once and retries.
    func downloadItemZip(itemID: String, to destination: URL) async throws {
        try await downloadItemZip(itemID: itemID, to: destination) { _ in }
    }

    /// Downloads the item's whole-item zip while delivering transport progress on the main
    /// actor. The expected total is nil when the server does not provide a usable length.
    func downloadItemZip(
        itemID: String,
        to destination: URL,
        onProgress: @escaping @MainActor @Sendable (ABSDownloadProgress) -> Void
    ) async throws {
        func request(accessToken: String) -> URLRequest {
            var request = URLRequest(url: endpoints.downloadItem(itemID))
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        guard let access = tokens.accessToken else { throw ABSError.unauthorized }
        var temporaryURL: URL?
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        do {
            var attempt = try await downloadAttempt(
                request(accessToken: access), onProgress: onProgress)
            temporaryURL = attempt.temporaryURL
            if (attempt.response as? HTTPURLResponse)?.statusCode == 401 {
                try? FileManager.default.removeItem(at: attempt.temporaryURL)
                temporaryURL = nil
                let refreshed = try await refreshAccessToken()
                attempt = try await downloadAttempt(
                    request(accessToken: refreshed), onProgress: onProgress)
                temporaryURL = attempt.temporaryURL
            }

            guard let http = attempt.response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw ABSError.http(
                    (attempt.response as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
            }

            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: attempt.temporaryURL, to: destination)
            temporaryURL = nil

            let finalProgress = Self.completedDownloadProgress(
                destination: destination,
                response: attempt.response,
                latestProgress: attempt.latestProgress)
            onProgress(finalProgress)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func downloadAttempt(
        _ request: URLRequest,
        onProgress: @escaping @MainActor @Sendable (ABSDownloadProgress) -> Void
    ) async throws -> ABSDownloadAttempt {
        let delegate = ABSDownloadDelegate()
        onProgress(ABSDownloadProgress(bytesReceived: 0, totalBytes: nil))
        let task = Task { [session] in
            try await session.download(for: request, delegate: delegate)
        }

        return try await withTaskCancellationHandler {
            async let reportProgress: Void = Self.forwardDownloadProgress(
                from: delegate.updates,
                to: onProgress)
            do {
                let (temporaryURL, response) = try await task.value
                delegate.finish()
                await reportProgress
                return ABSDownloadAttempt(
                    temporaryURL: temporaryURL,
                    response: response,
                    latestProgress: delegate.latestProgress)
            } catch {
                task.cancel()
                delegate.finish()
                await reportProgress
                throw error
            }
        } onCancel: {
            task.cancel()
            delegate.finish()
        }
    }

    private nonisolated static func forwardDownloadProgress(
        from updates: AsyncStream<ABSDownloadProgress>,
        to onProgress: @escaping @MainActor @Sendable (ABSDownloadProgress) -> Void
    ) async {
        for await update in updates {
            guard !Task.isCancelled else { return }
            await onProgress(update)
        }
    }

    private nonisolated static func completedDownloadProgress(
        destination: URL,
        response: URLResponse,
        latestProgress: ABSDownloadProgress?
    ) -> ABSDownloadProgress {
        let destinationSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            .map(Int64.init)
        let expectedLength = normalizedDownloadLength(response.expectedContentLength)
        return ABSDownloadProgress(
            bytesReceived: destinationSize ?? latestProgress?.bytesReceived ?? 0,
            totalBytes: latestProgress?.totalBytes ?? expectedLength)
    }

    private nonisolated static func normalizedDownloadLength(_ value: Int64) -> Int64? {
        value > 0 ? value : nil
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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

private struct ABSDownloadAttempt: Sendable {
    let temporaryURL: URL
    let response: URLResponse
    let latestProgress: ABSDownloadProgress?
}

/// The URLSession callback queue is not actor-isolated. This delegate protects its stream
/// continuation and latest value with a lock, then hands immutable progress to the service.
nonisolated private final class ABSDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    let updates: AsyncStream<ABSDownloadProgress>

    private let lock = NSLock()
    private var continuation: AsyncStream<ABSDownloadProgress>.Continuation?
    private var didFinish = false
    private var latest: ABSDownloadProgress?

    override init() {
        let stream = AsyncStream<ABSDownloadProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        updates = stream.stream
        continuation = stream.continuation
        super.init()
    }

    var latestProgress: ABSDownloadProgress? {
        lock.withLock { latest }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `URLSession.download(for:delegate:)` owns this temporary location until it returns
        // it to the caller. Keep the progress stream open for `didCompleteWithError`, which
        // is the single completion point for both success and failure.
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = ABSDownloadProgress(
            bytesReceived: max(0, totalBytesWritten),
            totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        lock.withLock {
            guard !didFinish else { return }
            latest = progress
            continuation?.yield(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        finish()
    }

    func finish() {
        lock.withLock {
            guard !didFinish else { return }
            didFinish = true
            continuation?.finish()
            continuation = nil
        }
    }
}
