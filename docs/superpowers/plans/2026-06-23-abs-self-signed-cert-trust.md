# Audiobookshelf Self-Signed Certificate Trust (TOFU Pinning) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user connect Echo to an Audiobookshelf server that serves HTTPS with a self-signed certificate, by explicitly trusting (pinning) that certificate's fingerprint on first connect — making the existing `ARCHITECTURE.md` claim true the secure way.

**Architecture:** A pure `ABSServerTrustEvaluator` decides accept/reject/use-default; a thin `URLSessionDelegate` (`ABSServerTrustDelegate`) runs the TLS I/O and feeds the evaluator; an `ABSURLSession` factory builds the delegate-backed session. The pinned leaf-cert SHA-256 is stored per-server in the Keychain (no schema migration). The connect flow probes first, throws `ABSError.untrustedCertificate(host:sha256:)` on a self-signed cert, and the iOS connect view shows a fingerprint-confirmation alert before re-connecting with the pin.

**Tech Stack:** Swift, SwiftUI, Foundation `URLSession`, `Security` (SecTrust), CryptoKit (SHA256), GRDB (unchanged), Swift Testing.

## Global Constraints

- **SPDX header line 1 of every Swift file:** `// SPDX-License-Identifier: GPL-3.0-or-later`. A SwiftFormat PostToolUse hook reflows the whole file on each Edit and can push the SPDX line below an `import`; after each edit verify SPDX is still line 1.
- **Shared code = both targets.** Everything in `EchoCore/Services/Audiobookshelf/` and `Shared/` compiles for **iOS and macOS**. Use only Foundation / Security / CryptoKit there (no UIKit).
- **No schema migration.** The pin lives in the Keychain. Do not add a `Schema_Vxx`.
- **No new third-party dependency.**
- **New `.swift` files are auto-included** (the project uses `PBXFileSystemSynchronizedRootGroup`); do not edit `project.pbxproj`.
- **Build/test commands:** `make build-tests` once after a code change, then `make test-only FILTER=EchoTests/<Suite>` for fast re-runs. Full suite: `make test`. Never run two `xcodebuild`s at once and never enable parallel testing (16 GB machine).
- **Trust-decision fingerprints** are lowercase, unseparated hex of the SHA-256 of the DER leaf cert. Display format is colon-grouped uppercase pairs.
- **PR target:** `nightly`. Conventional Commits.
- Reference spec: `docs/superpowers/specs/2026-06-23-abs-self-signed-cert-trust-design.md`.

---

## File Structure

**Create (EchoCore — shared):**
- `EchoCore/Services/Audiobookshelf/ABSServerTrustEvaluator.swift` — pure trust decision (`Decision` enum + `decide(...)`).
- `EchoCore/Services/Audiobookshelf/ABSCertificateFingerprint.swift` — SHA-256 of a `SecTrust` leaf + hex/display formatting.
- `EchoCore/Services/Audiobookshelf/ABSServerTrust.swift` — `ABSServerTrustDelegate` (URLSessionDelegate) + `ABSURLSession` factory (they change together).

**Modify:**
- `Shared/KeychainStore.swift` — add `Key.absPinnedCertificate`.
- `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift` — `pinnedCertificateSHA256` property; clear it in `clear()`.
- `EchoCore/Services/Audiobookshelf/ABSModels.swift` — `ABSError.untrustedCertificate` case + `mappingTrustFailure(...)` pure helper.
- `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift` — `trustDelegate` init param; map trust failures in `send`; `invalidate()`.
- `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift` — delegate-backed session in connect/reconnect; `trustingCertificate:` overload; invalidate cached session on replace/disconnect.
- `EchoCore/Views/ABSConnectionsSettingsView.swift` — fingerprint-confirmation alert.
- `ARCHITECTURE.md`, `CHANGELOG.md`, (`README.md` if it mentions ABS cert behavior).

**Create (tests):**
- `EchoTests/ABSServerTrustEvaluatorTests.swift`
- `EchoTests/ABSCertificateFingerprintTests.swift`
- `EchoTests/ABSServerTrustDelegateTests.swift`
- `EchoTests/ABSErrorTrustMappingTests.swift`
- (extend) `EchoTests/ABSTokenStoreTests.swift`

---

## Task 1: `ABSServerTrustEvaluator` (pure trust decision)

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSServerTrustEvaluator.swift`
- Test: `EchoTests/ABSServerTrustEvaluatorTests.swift`

**Interfaces:**
- Produces: `struct ABSServerTrustEvaluator { enum Decision: Equatable { case useDefault, accept, reject }; let expectedHost: String; let pinnedSHA256: String?; func decide(isServerTrust: Bool, challengeHost: String, defaultTrustSucceeded: Bool, leafSHA256: String?) -> Decision }`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/ABSServerTrustEvaluatorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ABSServerTrustEvaluatorTests {
    private func evaluator(pinned: String?) -> ABSServerTrustEvaluator {
        ABSServerTrustEvaluator(expectedHost: "homelab.local", pinnedSHA256: pinned)
    }

    @Test func caTrustedOnOurHostUsesDefault() {
        let d = evaluator(pinned: nil).decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: true, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func untrustedOurHostNoPinRejects() {
        let d = evaluator(pinned: nil).decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .reject)
    }

    @Test func untrustedOurHostMatchingPinAccepts() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .accept)
    }

    @Test func untrustedOurHostMismatchedPinRejects() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "different")
        #expect(d == .reject)
    }

    @Test func differentHostUsesDefaultEvenWithPin() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "cdn.example.com",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func nonServerTrustMethodUsesDefault() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: false, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func hostComparisonIsCaseInsensitive() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "Homelab.LOCAL",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .accept)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (type not defined)**

Run: `make build-tests`
Expected: BUILD FAILS — `cannot find 'ABSServerTrustEvaluator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `EchoCore/Services/Audiobookshelf/ABSServerTrustEvaluator.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, testable trust decision for an Audiobookshelf TLS server-trust challenge.
/// No `Security`/`Foundation` cert I/O here — the caller (`ABSServerTrustDelegate`) extracts the
/// inputs and applies the result. This is the unit-tested heart of self-signed cert pinning.
struct ABSServerTrustEvaluator: Sendable {
    enum Decision: Equatable, Sendable { case useDefault, accept, reject }

    /// Lowercased host of the server's configured base URL.
    let expectedHost: String
    /// Trusted leaf-cert SHA-256 (lowercase hex) for this server, or nil if nothing is pinned yet.
    let pinnedSHA256: String?

    func decide(
        isServerTrust: Bool,
        challengeHost: String,
        defaultTrustSucceeded: Bool,
        leafSHA256: String?
    ) -> Decision {
        // Only ever special-case server-trust challenges for the exact host the user configured.
        // A redirect/CDN host (or a non-server-trust method) validates normally.
        guard isServerTrust, challengeHost.lowercased() == expectedHost else { return .useDefault }
        // Cert already chains to a system-trusted CA → no pin needed (user installed a real cert).
        if defaultTrustSucceeded { return .useDefault }
        // Untrusted cert on our host: accept iff we hold a pin and the leaf matches it exactly.
        if let pinnedSHA256, let leafSHA256, leafSHA256 == pinnedSHA256 { return .accept }
        return .reject
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSServerTrustEvaluatorTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSServerTrustEvaluator.swift EchoTests/ABSServerTrustEvaluatorTests.swift
git commit -m "feat(abs): pure server-trust evaluator for self-signed cert pinning"
```

---

## Task 2: `ABSCertificateFingerprint` (SHA-256 + formatting)

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSCertificateFingerprint.swift`
- Test: `EchoTests/ABSCertificateFingerprintTests.swift`

**Interfaces:**
- Produces: `enum ABSCertificateFingerprint { static func hex(_ digest: SHA256.Digest) -> String; static func display(_ hex: String) -> String; static func leafSHA256(of trust: SecTrust) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/ABSCertificateFingerprintTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite struct ABSCertificateFingerprintTests {
    @Test func hexIsLowercase64Chars() {
        let digest = SHA256.hash(data: Data([0x00, 0x01, 0xab, 0xff]))
        let hex = ABSCertificateFingerprint.hex(digest)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(!hex.contains(":"))
    }

    @Test func displayGroupsIntoUppercaseColonPairs() {
        #expect(ABSCertificateFingerprint.display("ab12cd") == "AB:12:CD")
    }

    @Test func displayHandlesOddTrailingNibbleWithoutCrashing() {
        // Defensive: never crash on malformed input; last group may be a single char.
        #expect(ABSCertificateFingerprint.display("abc") == "AB:C")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make build-tests`
Expected: BUILD FAILS — `cannot find 'ABSCertificateFingerprint' in scope`.

- [ ] **Step 3: Write the implementation**

Create `EchoCore/Services/Audiobookshelf/ABSCertificateFingerprint.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Security

/// SHA-256 fingerprints of TLS leaf certificates, plus display formatting.
/// The decision logic lives in `ABSServerTrustEvaluator`; this is the thin cert-I/O + string layer.
enum ABSCertificateFingerprint {
    /// Lowercase, unseparated hex of a SHA-256 digest (the canonical stored/compared form).
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Colon-grouped uppercase pairs for human display, e.g. "AB:12:CD".
    static func display(_ hex: String) -> String {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count, by: 2).map { i -> String in
            String(chars[i..<min(i + 2, chars.count)]).uppercased()
        }.joined(separator: ":")
    }

    /// SHA-256 (lowercase hex) of the DER-encoded leaf certificate in `trust`, or nil if the chain
    /// is empty. Uses `SecTrustCopyCertificateChain` (the iOS 15+/macOS 12+ replacement for the
    /// deprecated `SecTrustGetCertificateAtIndex`).
    static func leafSHA256(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return hex(SHA256.hash(data: der))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSCertificateFingerprintTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSCertificateFingerprint.swift EchoTests/ABSCertificateFingerprintTests.swift
git commit -m "feat(abs): SHA-256 leaf-cert fingerprint + display formatting"
```

---

## Task 3: `ABSServerTrustDelegate` + `ABSURLSession` factory

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSServerTrust.swift`
- Test: `EchoTests/ABSServerTrustDelegateTests.swift`

**Interfaces:**
- Consumes: `ABSServerTrustEvaluator` (Task 1), `ABSCertificateFingerprint` (Task 2).
- Produces:
  - `final class ABSServerTrustDelegate: NSObject, URLSessionDelegate { init(evaluator: ABSServerTrustEvaluator); var lastUntrustedLeafSHA256: String? { get }; static func disposition(for: ABSServerTrustEvaluator.Decision) -> URLSession.AuthChallengeDisposition }`
  - `enum ABSURLSession { static func make(expectedHost: String, pinnedSHA256: String?) -> (session: URLSession, delegate: ABSServerTrustDelegate) }`

- [ ] **Step 1: Write the failing test (pure disposition mapping)**

Create `EchoTests/ABSServerTrustDelegateTests.swift`:

```swift
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
        let (session, delegate) = ABSURLSession.make(expectedHost: "homelab.local", pinnedSHA256: nil)
        #expect(delegate.lastUntrustedLeafSHA256 == nil)
        session.finishTasksAndInvalidate()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: BUILD FAILS — `cannot find 'ABSServerTrustDelegate'` / `'ABSURLSession'`.

- [ ] **Step 3: Write the implementation**

Create `EchoCore/Services/Audiobookshelf/ABSServerTrust.swift`:

```swift
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
        lock.lock(); defer { lock.unlock() }
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
            lock.lock(); _lastUntrustedLeafSHA256 = leaf; lock.unlock()
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSServerTrustDelegateTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSServerTrust.swift EchoTests/ABSServerTrustDelegateTests.swift
git commit -m "feat(abs): URLSession trust delegate + session factory for cert pinning"
```

---

## Task 4: Keychain-backed per-server pin storage

**Files:**
- Modify: `Shared/KeychainStore.swift:16-20` (the `Key` enum)
- Modify: `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift` (add property + clear)
- Test: `EchoTests/ABSTokenStoreTests.swift` (add a case)

**Interfaces:**
- Consumes: existing `KeychainStore` API.
- Produces: `ABSTokenStore.pinnedCertificateSHA256: String?` (get/set, Keychain-backed, per-server; cleared by `clear()`).

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/ABSTokenStoreTests.swift` (inside the suite):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: BUILD FAILS — `value of type 'ABSTokenStore' has no member 'pinnedCertificateSHA256'`.

- [ ] **Step 3a: Add the Keychain key**

In `Shared/KeychainStore.swift`, extend the `Key` enum (currently `securityScopedBookmark`, `bookmarkNotes`, `absRefreshToken`):

```swift
    enum Key: String {
        case securityScopedBookmark
        case bookmarkNotes
        case absRefreshToken
        case absPinnedCertificate
    }
```

- [ ] **Step 3b: Add the property and clear it**

In `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift`, add after the `refreshToken` property:

```swift
    /// Pinned self-signed leaf-cert SHA-256 (lowercase hex) for this server, or nil when the server
    /// uses a CA-trusted cert or plaintext http. Not secret, but stored in this server's Keychain
    /// namespace so trust survives relaunch without a DB schema migration. Cleared on sign-out.
    var pinnedCertificateSHA256: String? {
        get {
            KeychainStore.data(for: .absPinnedCertificate, service: service)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            if let value = newValue, let data = value.data(using: .utf8) {
                KeychainStore.set(data, for: .absPinnedCertificate, service: service)
            } else {
                KeychainStore.remove(.absPinnedCertificate, service: service)
            }
        }
    }
```

And in `func clear()`, add the pin removal alongside the existing token removal:

```swift
    func clear() {
        accessToken = nil
        KeychainStore.remove(.absRefreshToken, service: service)
        KeychainStore.remove(.absPinnedCertificate, service: service)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSTokenStoreTests`
Expected: PASS (3 tests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add Shared/KeychainStore.swift EchoCore/Services/Audiobookshelf/ABSTokenStore.swift EchoTests/ABSTokenStoreTests.swift
git commit -m "feat(abs): persist pinned self-signed cert per server in Keychain"
```

---

## Task 5: `ABSError.untrustedCertificate` + transport mapping in the service

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSModels.swift:6-24` (error case + description) and add the pure mapper.
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift` (init param + `send` mapping + `invalidate()`).
- Test: `EchoTests/ABSErrorTrustMappingTests.swift`

**Interfaces:**
- Consumes: `ABSServerTrustDelegate` (Task 3).
- Produces:
  - `ABSError.untrustedCertificate(host: String, sha256: String)`
  - `static func ABSError.mappingTrustFailure(_ error: ABSError, capturedFingerprint: String?, host: String) -> ABSError`
  - `AudiobookshelfService.init(baseURL:tokens:session:trustDelegate:)` (new optional `trustDelegate` param, default nil)
  - `AudiobookshelfService.invalidate()`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/ABSErrorTrustMappingTests.swift`:

```swift
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
            Issue.record("expected .untrustedCertificate, got \(mapped)"); return
        }
        #expect(host == "homelab.local")
        #expect(sha == "deadbeef")
    }

    @Test func leavesUntrustedAloneWithoutFingerprint() {
        let mapped = ABSError.mappingTrustFailure(
            .network(URLError(.serverCertificateUntrusted)),
            capturedFingerprint: nil, host: "homelab.local")
        guard case .network = mapped else { Issue.record("expected .network, got \(mapped)"); return }
    }

    @Test func leavesNonTrustNetworkErrorsAlone() {
        let mapped = ABSError.mappingTrustFailure(
            .network(URLError(.timedOut)), capturedFingerprint: "x", host: "homelab.local")
        guard case .network = mapped else { Issue.record("expected .network, got \(mapped)"); return }
    }

    @Test func leavesHTTPErrorsAlone() {
        let mapped = ABSError.mappingTrustFailure(
            .http(500, body: nil), capturedFingerprint: "x", host: "homelab.local")
        guard case .http(500, _) = mapped else { Issue.record("expected .http(500), got \(mapped)"); return }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make build-tests`
Expected: BUILD FAILS — no `untrustedCertificate` / no `mappingTrustFailure`.

- [ ] **Step 3a: Add the error case + description**

In `EchoCore/Services/Audiobookshelf/ABSModels.swift`, add the case to `ABSError`:

```swift
    case serverMessage(String)
    case missingField(String)
    case untrustedCertificate(host: String, sha256: String)
```

And in `errorDescription`:

```swift
        case .missingField(let f): return "Response missing required field: \(f)."
        case .untrustedCertificate(let host, _):
            return "“\(host)” is using a self-signed certificate that isn’t trusted yet."
```

- [ ] **Step 3b: Add the pure mapper**

Append to `ABSModels.swift` (after the `ABSError` enum’s closing brace):

```swift
extension ABSError {
    /// If `error` is a TLS server-trust failure (`URLError.serverCertificateUntrusted`) and the
    /// trust delegate captured a leaf fingerprint, surface it as `.untrustedCertificate` so the UI
    /// can offer to pin it. Every other error passes through unchanged. Pure — unit-tested.
    static func mappingTrustFailure(
        _ error: ABSError, capturedFingerprint: String?, host: String
    ) -> ABSError {
        guard case .network(let underlying) = error,
            (underlying as? URLError)?.code == .serverCertificateUntrusted,
            let fingerprint = capturedFingerprint
        else { return error }
        return .untrustedCertificate(host: host, sha256: fingerprint)
    }
}
```

- [ ] **Step 4a: Run the mapper tests (green before wiring the service)**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSErrorTrustMappingTests`
Expected: PASS (4 tests).

- [ ] **Step 4b: Wire the delegate into the service**

In `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`:

Add a stored property next to `session`:

```swift
    private let session: URLSession
    /// Trust delegate backing `session`, when this service owns a custom (non-`.shared`) session.
    /// nil for `.shared`/stub sessions (tests, CA-trusted/http servers reuse the legacy default).
    private let trustDelegate: ABSServerTrustDelegate?
```

Change the initializer to accept and store it (keep both defaults so existing call sites compile):

```swift
    init(
        baseURL: URL, tokens: ABSTokenStore,
        session: URLSession = .shared, trustDelegate: ABSServerTrustDelegate? = nil
    ) {
        self.endpoints = ABSEndpoints(baseURL: baseURL)
        self.tokens = tokens
        self.session = session
        self.trustDelegate = trustDelegate
    }
```

Replace the instance `send` (currently a one-line forward to `sendStatic`) so it maps trust failures:

```swift
    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        do {
            return try await Self.sendStatic(request, session: session, decode: type)
        } catch let error as ABSError {
            // A self-signed cert surfaces here on first connect; turn it into `.untrustedCertificate`
            // (carrying the fingerprint the delegate captured) so the UI can offer to pin it.
            throw ABSError.mappingTrustFailure(
                error,
                capturedFingerprint: trustDelegate?.lastUntrustedLeafSHA256,
                host: endpoints.baseURL.host ?? "")
        }
    }
```

Add an `invalidate()` method (near the bottom of the class) so the owner can release the delegate-backed session without touching `.shared`:

```swift
    /// Releases the custom delegate-backed session (and its retained delegate). No-op for the
    /// `.shared`/stub path — never invalidate `URLSession.shared`.
    func invalidate() {
        if trustDelegate != nil { session.finishTasksAndInvalidate() }
    }
```

> Note: `endpoints` is `private let`; `ABSEndpoints.baseURL` is accessible from within the type. The static `sendStatic` and the refresh `Task` path are unchanged — the probe only fails through the instance `send`/`login` path, and post-connect requests use the enforcing session.

- [ ] **Step 4c: Verify no regression to existing ABS service tests**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceAuthTests`
Expected: PASS (5 tests) — they inject a stub session with `trustDelegate: nil`, so `mappingTrustFailure` returns errors unchanged.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSModels.swift EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/ABSErrorTrustMappingTests.swift
git commit -m "feat(abs): surface self-signed cert as ABSError.untrustedCertificate"
```

---

## Task 6: `PlayerModel` two-phase connect wiring

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift` (`connectAudiobookshelf`, `makeAudiobookshelfService`, `disconnectAudiobookshelf`)

**Interfaces:**
- Consumes: `ABSURLSession.make` (Task 3), `ABSTokenStore.pinnedCertificateSHA256` (Task 4), `AudiobookshelfService.init(...:trustDelegate:)` + `invalidate()` (Task 5).
- Produces: `func connectAudiobookshelf(baseURL:username:password:trustingCertificate:) async throws -> ABSServerRecord` (the `trustingCertificate:` param is new, defaults nil).

This task is integration code (`@MainActor`, DB + network); it is verified by build + the existing pure-unit coverage of the pieces it composes, plus an on-device check in Task 9. There is no new unit test here — the testable logic was extracted into Tasks 1–5.

- [ ] **Step 1: Replace `connectAudiobookshelf` with the unified, trust-aware version**

In `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`, replace the existing `connectAudiobookshelf(baseURL:username:password:)` with:

```swift
    /// Connect + persist the server (non-secret) and tokens (Keychain). Always uses a delegate-backed
    /// session so self-signed certs can be pinned. On first connect to a self-signed host (no pin
    /// yet) `login()` throws `ABSError.untrustedCertificate` — the connect UI shows the fingerprint
    /// and, on approval, calls this again with `trustingCertificate:` set. CA-trusted and `http://`
    /// servers succeed on the first call with `pinnedSHA256 == nil` (the delegate just defers to
    /// default handling).
    @discardableResult
    func connectAudiobookshelf(
        baseURL: URL, username: String, password: String, trustingCertificate pinnedSHA256: String? = nil
    ) async throws -> ABSServerRecord {
        guard let dao = absServerDAO else { throw ABSError.notConnected }
        let serverID = UUID().uuidString
        let host = baseURL.host?.lowercased() ?? ""
        let tokens = ABSTokenStore(serverID: serverID)
        if let pinnedSHA256 { tokens.pinnedCertificateSHA256 = pinnedSHA256 }
        let (session, delegate) = ABSURLSession.make(expectedHost: host, pinnedSHA256: pinnedSHA256)
        let service = AudiobookshelfService(
            baseURL: baseURL, tokens: tokens, session: session, trustDelegate: delegate)

        let defaultLib: String?
        do {
            defaultLib = try await service.login(username: username, password: password)
        } catch {
            service.invalidate()
            // Roll back the pin we optimistically wrote if a *trust* connect failed for some other
            // reason (wrong password, etc.), so a stale pin can't linger for an unsaved server.
            if pinnedSHA256 != nil { tokens.clear() }
            throw error
        }

        let record = ABSServerRecord(
            id: serverID, baseURL: baseURL.absoluteString, username: username,
            defaultLibraryId: defaultLib,
            addedAt: ISO8601DateFormatter().string(from: Date()))
        try dao.save(record)
        absService?.invalidate()  // release any previously-cached delegate session
        absService = service      // cache the warm instance (access token + refresh serialization)
        absServiceServerID = serverID
        return record
    }
```

- [ ] **Step 2: Update `makeAudiobookshelfService` to rebuild a pinned/enforcing session**

Replace the body’s service construction (currently `session: .shared`) so it reads the pin and builds a delegate session:

```swift
    func makeAudiobookshelfService() -> AudiobookshelfService? {
        if let cached = absService { return cached }
        guard let dao = absServerDAO,
            let server = try? dao.current(),
            let url = URL(string: server.baseURL)
        else { return nil }
        let tokens = ABSTokenStore(serverID: server.id)
        let host = url.host?.lowercased() ?? ""
        let (session, delegate) = ABSURLSession.make(
            expectedHost: host, pinnedSHA256: tokens.pinnedCertificateSHA256)
        let service = AudiobookshelfService(
            baseURL: url, tokens: tokens, session: session, trustDelegate: delegate)
        absService = service
        absServiceServerID = server.id
        return service
    }
```

- [ ] **Step 3: Invalidate the session on disconnect**

In `disconnectAudiobookshelf`, invalidate after sign-out (sign-out already clears tokens incl. the pin):

```swift
    func disconnectAudiobookshelf(_ server: ABSServerRecord) async {
        let service = makeAudiobookshelfService()  // reuse cached instance if present
        await service?.signOut()                   // clears access/refresh + the pinned cert
        service?.invalidate()                       // release the delegate-backed session
        try? absServerDAO?.delete(server.id)
        absService = nil
        absServiceServerID = nil
    }
```

- [ ] **Step 4: Build and run the full ABS suite (no regressions)**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceAuthTests && make test-only FILTER=EchoTests/ABSImportServiceTests`
Expected: PASS. (These don’t touch `PlayerModel`, but they confirm the service API change compiles and behaves.)

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift
git commit -m "feat(abs): two-phase trust-aware connect with per-server pinned session"
```

---

## Task 7: iOS connect-flow fingerprint confirmation

**Files:**
- Modify: `EchoCore/Views/ABSConnectionsSettingsView.swift`

**Interfaces:**
- Consumes: `ABSError.untrustedCertificate` (Task 5), `connectAudiobookshelf(...:trustingCertificate:)` (Task 6), `ABSCertificateFingerprint.display` (Task 2).

UI integration; verified by build + on-device check in Task 9.

- [ ] **Step 1: Add trust state + the pending-trust model**

In `ABSConnectionsSettingsView`, add to the `@State` block:

```swift
    @State private var pendingTrust: PendingTrust?

    private struct PendingTrust: Identifiable {
        let id = UUID()
        let host: String
        let sha256: String
    }
```

- [ ] **Step 2: Catch the untrusted-cert error in `connect()`**

Replace the `do/catch` in `connect()` so the self-signed case opens the confirmation instead of showing a raw error:

```swift
        do {
            let server = try await model.connectAudiobookshelf(
                baseURL: url, username: username, password: password)
            connected = server
            password = ""
        } catch let error as ABSError {
            if case .untrustedCertificate(let host, let sha256) = error {
                pendingTrust = PendingTrust(host: host, sha256: sha256)  // password kept for retry
            } else {
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
```

- [ ] **Step 3: Add the confirmation alert + the trusting retry**

Add the `.alert` modifier after the existing `.sheet(isPresented: $showingBrowse)` line:

```swift
        .alert(
            "Self-Signed Certificate",
            isPresented: Binding(
                get: { pendingTrust != nil },
                set: { if !$0 { pendingTrust = nil } }),
            presenting: pendingTrust
        ) { trust in
            Button("Trust and Connect") { Task { await trustAndConnect(trust) } }
            Button("Cancel", role: .cancel) { pendingTrust = nil }
        } message: { trust in
            Text(
                """
                “\(trust.host)” presented a self-signed certificate.

                SHA-256:
                \(ABSCertificateFingerprint.display(trust.sha256))

                Only trust it if you recognize this fingerprint.
                """)
        }
```

And add the retry method next to `connect()`:

```swift
    private func trustAndConnect(_ trust: PendingTrust) async {
        pendingTrust = nil
        guard let url = ABSEndpoints.normalizedBaseURL(from: baseURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let server = try await model.connectAudiobookshelf(
                baseURL: url, username: username, password: password,
                trustingCertificate: trust.sha256)
            connected = server
            password = ""
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 4: Build the app (iOS) to verify the view compiles**

Run: `make build-tests`
Expected: BUILD SUCCEEDS (test build compiles the app target).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/ABSConnectionsSettingsView.swift
git commit -m "feat(abs): show self-signed cert fingerprint and let user trust it"
```

---

## Task 8: Documentation sync

**Files:**
- Modify: `ARCHITECTURE.md` (ABS section, ~line 283)
- Modify: `CHANGELOG.md`
- Check: `README.md`

- [ ] **Step 1: Fix the false ARCHITECTURE claim**

In `ARCHITECTURE.md`, find the `AudiobookshelfService` bullet containing “Self-signed certs, LAN `http://`, and non-standard ports are all tolerated (homelab reality).” Replace that sentence with:

```markdown
Plaintext LAN `http://` and non-standard ports are tolerated out of the box (the `NSAllowsArbitraryLoads` ATS exception). **Self-signed HTTPS** is supported via opt-in, per-server **trust-on-first-use certificate pinning**: on first connect the user is shown the cert's SHA-256 fingerprint and, on approval, Echo pins that exact leaf certificate (stored in the server's Keychain namespace — no schema migration) and accepts it only for the configured host. CA-trusted HTTPS validates normally with no prompt. A pinned cert that later changes fails closed (sign out and reconnect to re-trust). *Known limitation:* cover thumbnails on a self-signed server don't load, because `AsyncImage` fetches via `URLSession.shared` (which can't use the pinning delegate); connect, browse, search, download, and progress all work.
```

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the current unreleased/nightly section, add:

```markdown
- Audiobookshelf: connect to servers using a self-signed HTTPS certificate. On first connect Echo shows the certificate's SHA-256 fingerprint; once you trust it, that exact certificate is pinned per-server (stored in the Keychain). CA-trusted HTTPS and plaintext `http://` are unchanged. Note: cover thumbnails don't load on self-signed servers yet.
```

- [ ] **Step 3: Check README**

Run: `grep -n "self-signed\|Audiobookshelf\|certificate" README.md`
If a sentence describes ABS cert/HTTPS behavior, update it to match Step 1’s wording. If there’s no such sentence, make no change.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md CHANGELOG.md README.md
git commit -m "docs(abs): document opt-in self-signed cert trust + cover limitation"
```

---

## Task 9: Cross-platform parity + final verification

**Files:** none (verification only)

- [ ] **Step 1: Cross-platform parity review of the shared change**

Dispatch the `cross-platform-parity-reviewer` agent on the diff (shared `EchoCore`/`Shared` files changed). Confirm the new trust types compile for the macOS target and that no iOS-only API leaked into shared code (the trust stack is Foundation/Security/CryptoKit only; the UI lives in the iOS view).

- [ ] **Step 2: Full unit-test suite (iOS sim, RAM-friendly)**

Run: `make test`
Expected: PASS — including the four new suites and the extended `ABSTokenStoreTests`; zero new failures vs. the pre-existing baseline.

- [ ] **Step 3: macOS build**

Build the macOS target (shared service must compile there):
Run: `xcodebuild -scheme Echo -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` (single invocation; do not parallelize)
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: On-device manual check (owner-driven; record result)**

Against a real ABS server with a self-signed cert:
1. Settings ▸ Library Sources ▸ add `https://<host>:<port>`, username/password, Connect.
2. Confirm the fingerprint alert appears with a SHA-256; tap **Trust and Connect**.
3. Confirm login succeeds, Browse lists items, and a download imports and plays.
4. Force-quit and relaunch; confirm browse/progress still work (pin persisted).
5. Sign Out; reconnect; confirm the fingerprint prompt appears again (pin cleared).
Note that cover thumbnails will be blank on the self-signed server (documented limitation).

- [ ] **Step 5: Open the PR against `nightly`**

```bash
git push -u origin HEAD
gh pr create --base nightly --title "feat(abs): opt-in self-signed certificate trust (TOFU pinning)" --body "<summary + spec/plan links + the cover-image limitation + on-device verification status>"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** §4.1 Evaluator → Task 1; §4.2 Delegate + §4.3 factory → Task 3; §4.4 error → Task 5; §4.5 storage → Task 4; §5 data flow → Tasks 6–7; §6 session lifecycle (invalidate) → Tasks 5–6; §7 error handling → Task 5; §8 limitations → Task 8 docs; §9 concurrency (NSLock, Sendable) → Task 3; §10 testing → Tasks 1–5; §11 parity → Task 9; §12 docs → Task 8. All covered.
- **Placeholder scan:** none — every code step shows full code; the only conditional is the README check (Task 8 Step 3), which is a real grep-then-decide, not a deferred unknown.
- **Type consistency:** `ABSServerTrustEvaluator.Decision`, `decide(isServerTrust:challengeHost:defaultTrustSucceeded:leafSHA256:)`, `ABSServerTrustDelegate.disposition(for:)` / `lastUntrustedLeafSHA256`, `ABSURLSession.make(expectedHost:pinnedSHA256:)`, `ABSTokenStore.pinnedCertificateSHA256`, `ABSError.untrustedCertificate(host:sha256:)` / `mappingTrustFailure(_:capturedFingerprint:host:)`, `AudiobookshelfService.init(baseURL:tokens:session:trustDelegate:)` / `invalidate()`, and `connectAudiobookshelf(baseURL:username:password:trustingCertificate:)` are used identically across tasks.
