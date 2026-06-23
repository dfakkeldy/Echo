// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSServerTrustDelegateTests {
    @Test func dispositionMapsDecisions() {
        #expect(ABSServerTrustDelegate.disposition(for: .accept) == .useCredential)
        #expect(ABSServerTrustDelegate.disposition(for: .reject) == .performDefaultHandling)
        #expect(ABSServerTrustDelegate.disposition(for: .useDefault) == .performDefaultHandling)
    }

    @Test func factoryBuildsDelegateWithNoCapturedFingerprintInitially() {
        let (session, delegate) = ABSURLSession.make(
            expectedHost: "homelab.local", pinnedSHA256: nil)
        #expect(delegate.lastUntrustedLeafSHA256 == nil)
        session.finishTasksAndInvalidate()
    }
}
