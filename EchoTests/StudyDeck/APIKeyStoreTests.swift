// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

// @MainActor: APIKeyStore is MainActor-isolated; Swift Testing @Suite struct inherits
// actor isolation from the attribute, so all test methods run on the main actor without
// the XCTestCase init-override conflict that arises under -default-isolation MainActor.
@MainActor
@Suite struct APIKeyStoreTests {
    @Test func roundTripAndClear() {
        // Per-test service namespace avoids cross-test bleed; DEBUG volatile fallback
        // covers unsigned-sim Keychain denial (KeychainStore already handles this).
        let store = APIKeyStore(service: "com.echo.test.\(UUID().uuidString)")
        #expect(!store.hasKey)
        store.anthropicKey = "sk-ant-test"
        #expect(store.anthropicKey == "sk-ant-test")
        #expect(store.hasKey)
        store.clear()
        #expect(store.anthropicKey == nil)
        #expect(!store.hasKey)
    }
}
