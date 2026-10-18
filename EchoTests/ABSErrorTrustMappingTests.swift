// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSErrorTrustMappingTests {
    @Test func mapsServerCertUntrustedWithFingerprint() {
        let mapped = ABSError.mappingTrustFailure(
            .network(URLError(.serverCertificateUntrusted)),
            capturedFingerprint: "deadbeef", host: "homelab.local")
        guard case .untrustedCertificate(let host, let sha) = mapped else {
            Issue.record("expected .untrustedCertificate, got \(mapped)")
            return
        }
        #expect(host == "homelab.local")
        #expect(sha == "deadbeef")
    }

    @Test func leavesUntrustedAloneWithoutFingerprint() {
        let mapped = ABSError.mappingTrustFailure(
            .network(URLError(.serverCertificateUntrusted)),
            capturedFingerprint: nil, host: "homelab.local")
        guard case .network = mapped else {
            Issue.record("expected .network, got \(mapped)")
            return
        }
    }

    @Test func leavesNonTrustNetworkErrorsAlone() {
        let mapped = ABSError.mappingTrustFailure(
            .network(URLError(.timedOut)), capturedFingerprint: "x", host: "homelab.local")
        guard case .network = mapped else {
            Issue.record("expected .network, got \(mapped)")
            return
        }
    }

    @Test func leavesHTTPErrorsAlone() {
        let mapped = ABSError.mappingTrustFailure(
            .http(500, body: nil), capturedFingerprint: "x", host: "homelab.local")
        guard case .http(500, _) = mapped else {
            Issue.record("expected .http(500), got \(mapped)")
            return
        }
    }

    @Test func describesATSBlocksClearly() {
        let error = ABSError.network(
            URLError(.appTransportSecurityRequiresSecureConnection))
        #expect(
            error.errorDescription
                == "App Transport Security blocked plain HTTP. Reinstall the latest app build, or use an HTTPS Audiobookshelf URL.")
    }
}
