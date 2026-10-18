// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceProgressTests {
    @Test func getProgressDecodes() async throws {
        let fixture = AudiobookshelfServiceProgressFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/api/me/progress/it1",
            json: """
                {"libraryItemId":"it1","currentTime":123.5,"duration":3600,"progress":0.034,"isFinished":false,"lastUpdate":1700000000000}
                """)
        let p = try await fixture.service.getProgress(itemID: "it1")
        #expect(p?.currentTime == 123.5)
        #expect(p?.lastUpdate == 1_700_000_000_000)
    }

    @Test func getProgress404ReturnsNil() async throws {
        let fixture = AudiobookshelfServiceProgressFixture()
        URLProtocolStub.stub(
            scope: fixture.scope, pathSuffix: "/api/me/progress/itX", status: 404, json: "{}")
        let p = try await fixture.service.getProgress(itemID: "itX")
        #expect(p == nil)
    }

    @Test func patchProgressSendsBody() async throws {
        let fixture = AudiobookshelfServiceProgressFixture()
        URLProtocolStub.stub(
            scope: fixture.scope, pathSuffix: "/api/me/progress/it1", status: 200, json: "{}")
        try await fixture.service.patchProgress(
            itemID: "it1", currentTime: 900, duration: 3600, isFinished: false)
        let patch = fixture.requests.first {
            $0.url?.path.hasSuffix("/api/me/progress/it1") == true
        }
        #expect(patch?.httpMethod == "PATCH")
    }
}

/// Per-test stub isolation: suites and the tests inside them run concurrently in
/// one process, so a shared stub scope lets one test's `reset()` erase another's
/// recorded requests. A unique scope per fixture keeps each test's traffic its own.
@MainActor
private final class AudiobookshelfServiceProgressFixture {
    let scope: String
    let service: AudiobookshelfService
    private let tokenStore: ABSTokenStore

    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }

    init() {
        scope = "abs-progress-service-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokenStore = ABSTokenStore(serverID: "prog-\(UUID().uuidString)")
        tokenStore.accessToken = "acc"
        service = AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!,
            tokens: tokenStore, session: URLProtocolStub.makeSession(scope: scope))
    }

    isolated deinit {
        URLProtocolStub.finish(scope: scope)
    }
}
