// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceDownloadTests {
    @Test func downloadsZipBytesToDestination() async throws {
        let fixture = AudiobookshelfServiceDownloadFixture()
        let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03])  // "PK.." zip magic + bytes
        URLProtocolStub.stub(
            scope: fixture.scope, pathSuffix: "/download", status: 200, data: payload,
            headers: ["Content-Type": "application/zip"])
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-dl-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await fixture.service.downloadItemZip(itemID: "it1", to: dest)

        let written = try Data(contentsOf: dest)
        let request = try #require(fixture.requests.last)
        let queryItems = URLComponents(
            url: try #require(request.url), resolvingAgainstBaseURL: false
        )?.queryItems ?? []

        #expect(written == payload)
        #expect(request.url?.path == "/api/items/it1/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
        #expect(!queryItems.contains { $0.name == "token" })
    }

    @Test func httpErrorThrows() async {
        let fixture = AudiobookshelfServiceDownloadFixture()
        URLProtocolStub.stub(scope: fixture.scope, pathSuffix: "/download", status: 500, json: "{}")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-dl-\(UUID().uuidString).zip")
        await #expect {
            try await fixture.service.downloadItemZip(itemID: "it1", to: dest)
        } throws: { error in
            if case ABSError.http(500, _) = error { return true }
            return false
        }
    }

    @Test func progressDownloadRetainsHeaderAuthentication() async throws {
        let fixture = AudiobookshelfServiceDownloadFixture()
        let payload = Data(repeating: 0xA5, count: 1_024)
        URLProtocolStub.stub(
            scope: fixture.scope, pathSuffix: "/download", status: 200, data: payload,
            headers: ["Content-Type": "application/zip", "Content-Length": "1024"])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-progress-auth-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await fixture.service.downloadItemZip(itemID: "it1", to: destination) { _ in }

        let request = try #require(fixture.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
        #expect(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) == false)
    }
}

@MainActor
private final class AudiobookshelfServiceDownloadFixture {
    let scope: String
    let service: AudiobookshelfService
    private let tokenStore: ABSTokenStore

    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }

    init() {
        scope = "abs-download-service-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokenStore = ABSTokenStore(serverID: "dl-\(UUID().uuidString)")
        tokenStore.accessToken = "acc"
        service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!, tokens: tokenStore,
            session: URLProtocolStub.makeSession(scope: scope))
    }

    isolated deinit {
        tokenStore.clear()
        URLProtocolStub.finish(scope: scope)
    }
}
