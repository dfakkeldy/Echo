// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Testing

@testable import Echo

@MainActor
@Suite struct ABSDownloadProgressTests {
    @Test func knownLengthEndsAtOneHundredPercent() async throws {
        let fixture = ABSDownloadFixture(headers: ["Content-Length": "1024"])
        var updates: [ABSDownloadProgress] = []

        try await fixture.service.downloadItemZip(itemID: "i1", to: fixture.destination) {
            updates.append($0)
        }

        #expect(updates.map(\.bytesReceived) == updates.map(\.bytesReceived).sorted())
        #expect(updates.last?.totalBytes == 1_024)
        #expect(updates.last?.bytesReceived == 1_024)
        #expect(updates.last?.fractionCompleted == 1)
    }

    @Test func unknownLengthReportsBytesWithoutInventingFraction() async throws {
        let fixture = ABSDownloadFixture()
        var updates: [ABSDownloadProgress] = []

        try await fixture.service.downloadItemZip(itemID: "i1", to: fixture.destination) {
            updates.append($0)
        }

        #expect(updates.last?.bytesReceived == 1_024)
        #expect(updates.last?.totalBytes == nil)
        #expect(updates.last?.fractionCompleted == nil)
    }

    @Test func refreshedRetryStartsASeparateProgressAttempt() async throws {
        let fixture = ABSDownloadFixture(
            headers: ["Content-Length": "4"], status: 401, suspended: true)
        fixture.stubRefresh(accessToken: "fresh")
        var updates: [ABSDownloadProgress] = []

        let download = Task {
            try await fixture.service.downloadItemZip(itemID: "i1", to: fixture.destination) {
                updates.append($0)
            }
        }
        try await fixture.waitForPendingDownload()

        fixture.stubDownload(status: 200, headers: ["Content-Length": "1024"])
        fixture.resumeDownload()
        try await download.value

        #expect(updates.filter { $0.bytesReceived == 0 }.count >= 2)
        #expect(updates.last?.totalBytes == 1_024)
        #expect(updates.last?.fractionCompleted == 1)
        #expect(
            fixture.requests.last(where: { $0.url?.path.hasSuffix("/download") == true })?
                .value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    /// Regression: the async `URLSession.download(for:delegate:)` convenience never
    /// delivers `didWriteData` over a live connection — URLProtocol stubs synthesize the
    /// callback, so only a real socket can prove incremental progress reaches the caller.
    @Test func liveTransportDeliversIncrementalProgress() async throws {
        let totalBytes = 512 * 1024
        let server = try await ThrottledLoopbackHTTPServer.start(
            totalBytes: totalBytes, chunkBytes: 64 * 1024, chunkGapMilliseconds: 60)
        defer { server.stop() }
        let fixture = ABSDownloadFixture(liveServerPort: server.port)
        var updates: [ABSDownloadProgress] = []

        try await fixture.service.downloadItemZip(itemID: "i1", to: fixture.destination) {
            updates.append($0)
        }

        #expect(
            updates.contains { $0.bytesReceived > 0 && $0.bytesReceived < Int64(totalBytes) },
            "expected an intermediate progress update, got \(updates.map(\.bytesReceived))")
        #expect(updates.last?.bytesReceived == Int64(totalBytes))
        #expect(updates.last?.totalBytes == Int64(totalBytes))
    }

    @Test func cancellationRemovesPartialDestination() async throws {
        let fixture = ABSDownloadFixture(suspended: true)
        var updates: [ABSDownloadProgress] = []
        let download = Task {
            try await fixture.service.downloadItemZip(itemID: "i1", to: fixture.destination) {
                updates.append($0)
            }
        }
        try await fixture.waitForPendingDownload()

        download.cancel()
        await #expect {
            try await download.value
        } throws: { $0 is CancellationError }

        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(fixture.pendingDownloadCount == 0)
        #expect(updates.first?.bytesReceived == 0)
    }
}

@MainActor
private final class ABSDownloadFixture {
    let service: AudiobookshelfService
    let destination: URL
    private let scope: String
    private let tokenStore: ABSTokenStore

    var pendingDownloadCount: Int { URLProtocolStub.pendingResponseCount(scope: scope) }
    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }

    init(
        headers: [String: String] = [:], status: Int = 200, suspended: Bool = false
    ) {
        scope = "abs-download-progress-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokenStore = ABSTokenStore(serverID: "abs-download-\(UUID().uuidString)")
        tokenStore.accessToken = "access"
        tokenStore.refreshToken = "refresh"
        service = AudiobookshelfService(
            baseURL: URL(string: "http://abs-progress.test:13378")!, tokens: tokenStore,
            session: URLProtocolStub.makeSession(scope: scope))
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-download-progress-\(UUID().uuidString).zip")
        stubDownload(status: status, headers: headers, suspended: suspended)
    }

    /// Talks to a real loopback server through an unstubbed session, so the transport's
    /// own delegate callbacks (not URLProtocol-synthesized ones) drive progress.
    init(liveServerPort: UInt16) {
        scope = "abs-download-progress-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokenStore = ABSTokenStore(serverID: "abs-download-\(UUID().uuidString)")
        tokenStore.accessToken = "access"
        tokenStore.refreshToken = "refresh"
        service = AudiobookshelfService(
            baseURL: URL(string: "http://127.0.0.1:\(liveServerPort)")!, tokens: tokenStore,
            session: URLSession(configuration: .ephemeral))
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-download-progress-\(UUID().uuidString).zip")
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: destination)
        tokenStore.clear()
        URLProtocolStub.finish(scope: scope)
    }

    func stubDownload(
        status: Int = 200, headers: [String: String] = [:], suspended: Bool = false
    ) {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/download", status: status,
            data: Data(repeating: 0xA5, count: status == 401 ? 4 : 1_024),
            headers: headers, suspended: suspended)
    }

    func stubRefresh(accessToken: String) {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/auth/refresh",
            json:
                "{\"user\":{\"id\":\"u1\",\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"rotated\"}}"
        )
    }

    func resumeDownload() {
        URLProtocolStub.resume(scope: scope, pathSuffix: "/download")
    }

    func waitForPendingDownload() async throws {
        for _ in 0..<50_000 {
            if pendingDownloadCount == 1 { return }
            await Task.yield()
        }
        throw ABSDownloadFixtureTimeoutError()
    }
}

private struct ABSDownloadFixtureTimeoutError: Error {}

/// Minimal loopback HTTP/1.1 server that streams a fixed-size body in throttled chunks,
/// so a test can observe genuine transport-level download progress callbacks.
nonisolated private final class ThrottledLoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(totalBytes: Int, chunkBytes: Int, chunkGapMilliseconds: Int) async throws
        -> ThrottledLoopbackHTTPServer
    {
        let queue = DispatchQueue(label: "abs-live-progress-server")
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            serve(
                connection, on: queue, totalBytes: totalBytes, chunkBytes: chunkBytes,
                chunkGapMilliseconds: chunkGapMilliseconds)
        }
        let ready = OneShotFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard ready.trySet() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard ready.trySet() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard port > 0 else {
            listener.cancel()
            throw ABSDownloadFixtureTimeoutError()
        }
        return ThrottledLoopbackHTTPServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }

    private static func serve(
        _ connection: NWConnection,
        on queue: DispatchQueue,
        totalBytes: Int,
        chunkBytes: Int,
        chunkGapMilliseconds: Int
    ) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            // Any request bytes are enough for a GET; stream the throttled response.
            let header =
                "HTTP/1.1 200 OK\r\nContent-Length: \(totalBytes)\r\n"
                + "Content-Type: application/zip\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(header.utf8),
                completion: .contentProcessed { _ in
                    sendChunks(
                        connection, on: queue, remaining: totalBytes, chunkBytes: chunkBytes,
                        chunkGapMilliseconds: chunkGapMilliseconds)
                })
        }
    }

    private static func sendChunks(
        _ connection: NWConnection,
        on queue: DispatchQueue,
        remaining: Int,
        chunkBytes: Int,
        chunkGapMilliseconds: Int
    ) {
        guard remaining > 0 else {
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let size = min(chunkBytes, remaining)
        connection.send(
            content: Data(repeating: 0xA5, count: size),
            completion: .contentProcessed { error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(chunkGapMilliseconds)) {
                    sendChunks(
                        connection, on: queue, remaining: remaining - size,
                        chunkBytes: chunkBytes, chunkGapMilliseconds: chunkGapMilliseconds)
                }
            })
    }
}

/// Lets a multi-fire callback resume a continuation exactly once.
nonisolated private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns true the first time only.
    func trySet() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}
