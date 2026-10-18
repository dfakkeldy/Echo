// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite(.serialized) struct AudiobookshelfServiceAuthTests {
    @Test func loginStoresAccessAndRefreshTokens() async throws {
        let fixture = AudiobookshelfServiceAuthFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/login",
            json: """
                {"user":{"id":"u1","accessToken":"acc1","refreshToken":"ref1"},"userDefaultLibraryId":"lib1"}
                """)
        let defaultLib = try await fixture.service.login(username: "dan", password: "pw")
        #expect(fixture.tokens.accessToken == "acc1")
        #expect(fixture.tokens.refreshToken == "ref1")
        #expect(defaultLib == "lib1")
        fixture.tokens.clear()
    }

    @Test func loginFallsBackToLegacyPermanentToken() async throws {
        let fixture = AudiobookshelfServiceAuthFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/login",
            json: """
                {"user":{"id":"u1","token":"legacy-tok"},"userDefaultLibraryId":null}
                """)
        _ = try await fixture.service.login(username: "dan", password: "pw")
        #expect(fixture.tokens.accessToken == "legacy-tok")
        fixture.tokens.clear()
    }

    @Test func refreshRotatesAndPersistsTheRefreshToken() async throws {
        let fixture = AudiobookshelfServiceAuthFixture()
        fixture.tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/auth/refresh",
            json: """
                {"user":{"id":"u1","accessToken":"acc2","refreshToken":"ref-new"}}
                """)
        let newAccess = try await fixture.service.refreshAccessToken()
        #expect(newAccess == "acc2")
        #expect(fixture.tokens.accessToken == "acc2")
        #expect(fixture.tokens.refreshToken == "ref-new")  // rotation persisted
        fixture.tokens.clear()
    }

    @Test func concurrentRefreshesCallTheEndpointOnce() async throws {
        let fixture = AudiobookshelfServiceAuthFixture()
        fixture.tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/auth/refresh",
            json: """
                {"user":{"id":"u1","accessToken":"acc3","refreshToken":"ref3"}}
                """)
        async let a = fixture.service.refreshAccessToken()
        async let b = fixture.service.refreshAccessToken()
        async let c = fixture.service.refreshAccessToken()
        _ = try await (a, b, c)
        let refreshCalls = fixture.requests.filter {
            $0.url?.path.hasSuffix("/auth/refresh") == true
        }
        #expect(refreshCalls.count == 1)  // serialized: one network refresh, not three
        fixture.tokens.clear()
    }

    @Test func refreshWithoutTokenThrowsUnauthorized() async {
        let fixture = AudiobookshelfServiceAuthFixture()
        await #expect {
            _ = try await fixture.service.refreshAccessToken()
        } throws: { error in
            guard case ABSError.unauthorized = error else { return false }
            return true
        }
    }

    @Test func signOutRevokesRemoteTokenAndClearsLocalTokens() async {
        let fixture = AudiobookshelfServiceAuthFixture()
        fixture.tokens.accessToken = "acc-old"
        fixture.tokens.refreshToken = "ref-old"
        fixture.tokens.pinnedCertificateSHA256 = "deadbeef"
        URLProtocolStub.stub(scope: fixture.scope, pathSuffix: "/logout", json: "{}")

        let result = await fixture.service.signOut()

        guard case .remoteRevoked = result else {
            Issue.record("Expected remoteRevoked sign-out result")
            return
        }
        #expect(!result.didRemoteRevokeFail)
        #expect(fixture.tokens.accessToken == nil)
        #expect(fixture.tokens.refreshToken == nil)
        #expect(fixture.tokens.pinnedCertificateSHA256 == nil)
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests.first?.url?.path.hasSuffix("/logout") == true)
        #expect(fixture.requests.first?.value(forHTTPHeaderField: "x-refresh-token") == "ref-old")
    }

    @Test func signOutClearsLocalTokensWhenRemoteRevokeFails() async {
        let fixture = AudiobookshelfServiceAuthFixture()
        fixture.tokens.accessToken = "acc-old"
        fixture.tokens.refreshToken = "ref-old"
        fixture.tokens.pinnedCertificateSHA256 = "deadbeef"
        URLProtocolStub.stub(
            scope: fixture.scope, pathSuffix: "/logout", status: 500, json: "{}")

        let result = await fixture.service.signOut()

        guard case .remoteRevokeFailed(let error) = result else {
            Issue.record("Expected remoteRevokeFailed sign-out result")
            return
        }
        guard case .http(500, _) = error else {
            Issue.record("Expected HTTP 500 revoke failure")
            return
        }
        #expect(result.didRemoteRevokeFail)
        #expect(fixture.tokens.accessToken == nil)
        #expect(fixture.tokens.refreshToken == nil)
        #expect(fixture.tokens.pinnedCertificateSHA256 == nil)
    }

    @Test func signOutWithoutRefreshTokenStillClearsLocalState() async {
        let fixture = AudiobookshelfServiceAuthFixture()
        fixture.tokens.accessToken = "acc-old"
        fixture.tokens.pinnedCertificateSHA256 = "deadbeef"

        let result = await fixture.service.signOut()

        guard case .noRemoteToken = result else {
            Issue.record("Expected noRemoteToken sign-out result")
            return
        }
        #expect(!result.didRemoteRevokeFail)
        #expect(fixture.tokens.accessToken == nil)
        #expect(fixture.tokens.refreshToken == nil)
        #expect(fixture.tokens.pinnedCertificateSHA256 == nil)
        #expect(fixture.requests.isEmpty)
    }
}

/// Per-test stub isolation: suites and the tests inside them run concurrently in
/// one process, so a shared stub scope lets one test's `reset()` erase another's
/// recorded requests. `.serialized` orders this suite's own tests but does not
/// hold back the other ABS suites, so the scope — not the trait — is the isolation.
@MainActor
private final class AudiobookshelfServiceAuthFixture {
    let scope: String
    let service: AudiobookshelfService
    let tokens: ABSTokenStore

    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }

    init() {
        scope = "abs-auth-service-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokens = ABSTokenStore(serverID: "auth-\(UUID().uuidString)")
        service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens,
            session: URLProtocolStub.makeSession(scope: scope))
    }

    isolated deinit {
        URLProtocolStub.finish(scope: scope)
    }
}
