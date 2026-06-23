// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// `URLSessionDelegate` that applies `ABSServerTrustEvaluator` to TLS server-trust challenges,
/// enabling opt-in self-signed cert pinning for one Audiobookshelf server. The decision is pure
/// (`ABSServerTrustEvaluator`); this class only does the cert I/O and records the last untrusted
/// leaf fingerprint it saw (so the connect flow can offer to pin it).
///
/// `@unchecked Sendable`: the only mutable state is `_lastUntrustedLeafSHA256`, guarded by `lock`.
final class ABSServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let evaluator: ABSServerTrustEvaluator
    private let lock = NSLock()
    private var _lastUntrustedLeafSHA256: String?

    init(evaluator: ABSServerTrustEvaluator) { self.evaluator = evaluator }

    /// The leaf SHA-256 of the most recent UNtrusted cert seen for the expected host, if any.
    var lastUntrustedLeafSHA256: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastUntrustedLeafSHA256
    }

    static func disposition(for decision: ABSServerTrustEvaluator.Decision)
        -> URLSession.AuthChallengeDisposition
    {
        switch decision {
        case .accept: return .useCredential
        // `.reject` falls through to default handling so the system rejects the cert with a
        // deterministic NSURLErrorServerCertificateUntrusted (-1202), not a -999 cancel.
        case .reject, .useDefault: return .performDefaultHandling
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isServerTrust = space.authenticationMethod == NSURLAuthenticationMethodServerTrust
        guard isServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let defaultTrustSucceeded = SecTrustEvaluateWithError(trust, nil)
        let leaf = ABSCertificateFingerprint.leafSHA256(of: trust)

        // Record an untrusted leaf for our host so the probe can surface it (and a later mismatch
        // is observable). Never record for other hosts or for CA-trusted certs.
        if !defaultTrustSucceeded, space.host.lowercased() == evaluator.expectedHost, let leaf {
            lock.lock()
            _lastUntrustedLeafSHA256 = leaf
            lock.unlock()
        }

        let decision = evaluator.decide(
            isServerTrust: true,
            challengeHost: space.host,
            defaultTrustSucceeded: defaultTrustSucceeded,
            leafSHA256: leaf)
        let credential = decision == .accept ? URLCredential(trust: trust) : nil
        completionHandler(Self.disposition(for: decision), credential)
    }
}

/// Builds a delegate-backed `URLSession` for one ABS server. Pass `pinnedSHA256 == nil` for the
/// first-connect probe (any untrusted cert is rejected, but its fingerprint is captured) or for a
/// CA-trusted/`http://` server (the delegate just defers to default handling). Pass a pin to
/// enforce it. The returned delegate must be kept alive for the session's lifetime; the session
/// retains it, so holding the session is enough.
enum ABSURLSession {
    static func make(expectedHost: String, pinnedSHA256: String?)
        -> (session: URLSession, delegate: ABSServerTrustDelegate)
    {
        let evaluator = ABSServerTrustEvaluator(
            expectedHost: expectedHost.lowercased(), pinnedSHA256: pinnedSHA256)
        let delegate = ABSServerTrustDelegate(evaluator: evaluator)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }
}
