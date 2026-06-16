// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct SecurityScopeManagerTests {

    /// The parent scope must be balanced and crash-free in every call order —
    /// the whole point of routing it through the manager is that a start is
    /// always paired with a stop (and a stop with nothing held is a safe no-op),
    /// so opening N single-file books no longer leaks N grants.
    ///
    /// A plain temporary-file URL is not security-scoped, so no grant is actually
    /// held; this exercises the guard/balance logic, not the kernel grant.
    @Test func parentScopeStartStopIsBalancedAndSafe() {
        let manager = SecurityScopeManager()
        let url = URL(fileURLWithPath: "/tmp/echo-scope-\(UUID().uuidString)")

        // Stop with nothing held is a safe no-op.
        manager.stopParent()

        // Start grants nothing for a non-scoped URL, but must not crash…
        _ = manager.startParent(url: url)
        // …and the matching stop, a redundant second stop, and stopAll are safe.
        manager.stopParent()
        manager.stopParent()
        manager.stopAll()
    }
}
