// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceProgressTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "prog-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func getProgressDecodes() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/api/me/progress/it1",
            json: """
                {"libraryItemId":"it1","currentTime":123.5,"duration":3600,"progress":0.034,"isFinished":false,"lastUpdate":1700000000000}
                """)
        let p = try await service.getProgress(itemID: "it1")
        #expect(p?.currentTime == 123.5)
        #expect(p?.lastUpdate == 1_700_000_000_000)
    }

    @Test func getProgress404ReturnsNil() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/me/progress/itX", status: 404, json: "{}")
        let p = try await service.getProgress(itemID: "itX")
        #expect(p == nil)
    }

    @Test func patchProgressSendsBody() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/me/progress/it1", status: 200, json: "{}")
        try await service.patchProgress(
            itemID: "it1", currentTime: 900, duration: 3600, isFinished: false)
        let patch = URLProtocolStub.requests.first {
            $0.url?.path.hasSuffix("/api/me/progress/it1") == true
        }
        #expect(patch?.httpMethod == "PATCH")
    }
}
