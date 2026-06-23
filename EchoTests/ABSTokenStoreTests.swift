// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ABSTokenStoreTests {
    private func makeStore() -> ABSTokenStore {
        ABSTokenStore(serverID: "test-\(UUID().uuidString)")
    }

    @Test func persistsAndReadsRefreshToken() {
        let store = makeStore()
        store.refreshToken = "refresh-abc"
        #expect(store.refreshToken == "refresh-abc")
        store.clear()
        #expect(store.refreshToken == nil)
    }

    @Test func accessTokenIsMemoryOnly() {
        let store = makeStore()
        store.accessToken = "access-xyz"
        #expect(store.accessToken == "access-xyz")
        let reopened = ABSTokenStore(serverID: store.serverID)
        #expect(reopened.accessToken == nil)
        store.clear()
    }

    @Test func persistsAndClearsPinnedCertificate() {
        let store = makeStore()
        #expect(store.pinnedCertificateSHA256 == nil)
        store.pinnedCertificateSHA256 = "deadbeef"
        #expect(store.pinnedCertificateSHA256 == "deadbeef")

        // A second store for the same server reads the same pin (persisted, not memory-only).
        let reopened = ABSTokenStore(serverID: store.serverID)
        #expect(reopened.pinnedCertificateSHA256 == "deadbeef")

        store.clear()
        #expect(store.pinnedCertificateSHA256 == nil)
    }
}
