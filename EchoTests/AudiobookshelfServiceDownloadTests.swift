// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceDownloadTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "dl-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func downloadsZipBytesToDestination() async throws {
        let service = makeService()
        let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03])  // "PK.." zip magic + bytes
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: payload,
            headers: ["Content-Type": "application/zip"])
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-dl-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await service.downloadItemZip(itemID: "it1", to: dest)

        let written = try Data(contentsOf: dest)
        let request = try #require(URLProtocolStub.requests.last)
        let queryItems = URLComponents(
            url: try #require(request.url), resolvingAgainstBaseURL: false
        )?.queryItems ?? []

        #expect(written == payload)
        #expect(request.url?.path == "/api/items/it1/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
        #expect(!queryItems.contains { $0.name == "token" })
    }

    @Test func httpErrorThrows() async {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/download", status: 500, json: "{}")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-dl-\(UUID().uuidString).zip")
        await #expect {
            try await service.downloadItemZip(itemID: "it1", to: dest)
        } throws: { error in
            if case ABSError.http(500, _) = error { return true }
            return false
        }
    }
}
