// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite(.serialized) struct AudiobookshelfServiceAuthTests {
    private func makeService() -> (AudiobookshelfService, ABSTokenStore) {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "auth-\(UUID().uuidString)")
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens,
            session: URLProtocolStub.makeSession())
        return (service, tokens)
    }

    @Test func loginStoresAccessAndRefreshTokens() async throws {
        let (service, tokens) = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/login",
            json: """
                {"user":{"id":"u1","accessToken":"acc1","refreshToken":"ref1"},"userDefaultLibraryId":"lib1"}
                """)
        let defaultLib = try await service.login(username: "dan", password: "pw")
        #expect(tokens.accessToken == "acc1")
        #expect(tokens.refreshToken == "ref1")
        #expect(defaultLib == "lib1")
        tokens.clear()
    }

    @Test func loginFallsBackToLegacyPermanentToken() async throws {
        let (service, tokens) = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/login",
            json: """
                {"user":{"id":"u1","token":"legacy-tok"},"userDefaultLibraryId":null}
                """)
        _ = try await service.login(username: "dan", password: "pw")
        #expect(tokens.accessToken == "legacy-tok")
        tokens.clear()
    }

    @Test func refreshRotatesAndPersistsTheRefreshToken() async throws {
        let (service, tokens) = makeService()
        tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(
            pathSuffix: "/auth/refresh",
            json: """
                {"user":{"id":"u1","accessToken":"acc2","refreshToken":"ref-new"}}
                """)
        let newAccess = try await service.refreshAccessToken()
        #expect(newAccess == "acc2")
        #expect(tokens.accessToken == "acc2")
        #expect(tokens.refreshToken == "ref-new")  // rotation persisted
        tokens.clear()
    }

    @Test func concurrentRefreshesCallTheEndpointOnce() async throws {
        let (service, tokens) = makeService()
        tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(
            pathSuffix: "/auth/refresh",
            json: """
                {"user":{"id":"u1","accessToken":"acc3","refreshToken":"ref3"}}
                """)
        async let a = service.refreshAccessToken()
        async let b = service.refreshAccessToken()
        async let c = service.refreshAccessToken()
        _ = try await (a, b, c)
        let refreshCalls = URLProtocolStub.requests.filter {
            $0.url?.path.hasSuffix("/auth/refresh") == true
        }
        #expect(refreshCalls.count == 1)  // serialized: one network refresh, not three
        tokens.clear()
    }

    @Test func refreshWithoutTokenThrowsUnauthorized() async {
        let (service, _) = makeService()
        await #expect {
            _ = try await service.refreshAccessToken()
        } throws: { error in
            guard case ABSError.unauthorized = error else { return false }
            return true
        }
    }

    @Test func signOutRevokesRemoteTokenAndClearsLocalTokens() async {
        let (service, tokens) = makeService()
        tokens.accessToken = "acc-old"
        tokens.refreshToken = "ref-old"
        tokens.pinnedCertificateSHA256 = "deadbeef"
        URLProtocolStub.stub(pathSuffix: "/logout", json: "{}")

        let result = await service.signOut()

        guard case .remoteRevoked = result else {
            Issue.record("Expected remoteRevoked sign-out result")
            return
        }
        #expect(!result.didRemoteRevokeFail)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        #expect(tokens.pinnedCertificateSHA256 == nil)
        #expect(URLProtocolStub.requests.count == 1)
        #expect(URLProtocolStub.requests.first?.url?.path.hasSuffix("/logout") == true)
        #expect(URLProtocolStub.requests.first?.value(forHTTPHeaderField: "x-refresh-token") == "ref-old")
    }

    @Test func signOutClearsLocalTokensWhenRemoteRevokeFails() async {
        let (service, tokens) = makeService()
        tokens.accessToken = "acc-old"
        tokens.refreshToken = "ref-old"
        tokens.pinnedCertificateSHA256 = "deadbeef"
        URLProtocolStub.stub(pathSuffix: "/logout", status: 500, json: "{}")

        let result = await service.signOut()

        guard case .remoteRevokeFailed(let error) = result else {
            Issue.record("Expected remoteRevokeFailed sign-out result")
            return
        }
        guard case .http(500, _) = error else {
            Issue.record("Expected HTTP 500 revoke failure")
            return
        }
        #expect(result.didRemoteRevokeFail)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        #expect(tokens.pinnedCertificateSHA256 == nil)
    }

    @Test func signOutWithoutRefreshTokenStillClearsLocalState() async {
        let (service, tokens) = makeService()
        tokens.accessToken = "acc-old"
        tokens.pinnedCertificateSHA256 = "deadbeef"

        let result = await service.signOut()

        guard case .noRemoteToken = result else {
            Issue.record("Expected noRemoteToken sign-out result")
            return
        }
        #expect(!result.didRemoteRevokeFail)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        #expect(tokens.pinnedCertificateSHA256 == nil)
        #expect(URLProtocolStub.requests.isEmpty)
    }
}
