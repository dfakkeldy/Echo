// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
