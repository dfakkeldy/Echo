# Audiobookshelf — Opt-in Self-Signed Certificate Trust (TOFU Pinning)

- **Date:** 2026-06-23
- **Status:** Approved design — ready for implementation plan
- **Area:** `EchoCore/Services/Audiobookshelf/`, iOS connect UI, docs
- **PR target:** `nightly` (promotion-ladder convention)

## 1. Problem

`ARCHITECTURE.md` (Audiobookshelf section) claims:

> Self-signed certs, LAN `http://`, and non-standard ports are all tolerated (homelab reality).

Two of those three are true; one is **false in code**:

- ✅ **LAN `http://`** and ✅ **non-standard ports** are tolerated — the recent ATS fix added
  `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` to the iOS and macOS `Info.plist`s,
  which permits plaintext HTTP and arbitrary ports.
- ❌ **Self-signed HTTPS is NOT tolerated.** `AudiobookshelfService` uses `URLSession.shared`
  (no `URLSessionDelegate`, no server-trust handling anywhere in `EchoCore` — verified by grep:
  zero matches for `URLSessionDelegate`, `didReceive challenge`, `serverTrust`). A homelab user
  running ABS over `https://` with a self-signed cert hits `NSURLErrorServerCertificateUntrusted`
  (`-1202`) and cannot connect.

**Key correction to a common misconception:** `NSAllowsArbitraryLoads` governs ATS *transport
policy* (is plaintext / weak TLS permitted?). It does **not** alter X.509 *chain validation* —
the TLS stack still rejects an untrusted/self-signed cert. The only override point is a
`URLSessionDelegate` server-trust challenge. They are two independent gates.

## 2. Decision

Make the claim true the secure way: **opt-in, trust-on-first-use (TOFU) certificate pinning**,
scoped per-server to the host the user entered. This was chosen over (a) a blanket
"allow self-signed" toggle that accepts *any* cert for the host (weaker — a LAN attacker can MITM
with their own self-signed cert) and (b) simply correcting the docs to drop the promise.

### Trust model (why TOFU pinning is correct here)

- Self-signed homelab certs have no CA to validate against, so the user is the trust anchor —
  exactly like SSH's `known_hosts`. On first connect we show the user the certificate's SHA-256
  fingerprint and let them **explicitly** accept it. We then pin **that exact leaf certificate**.
- Pinning the specific leaf (not "any cert for this host") closes the active-MITM window: only
  the certificate the user actually saw and approved is ever accepted afterward.
- Scoping to the **user-entered host** means we never apply the pin to some other host (e.g. a
  redirect to a CDN) — those still validate normally against the system trust store.
- A homelab user who *later* installs a proper CA-trusted cert keeps working with no action: the
  default chain validation succeeds and the pin is simply not consulted.

## 3. Goals / Non-goals

**Goals**
- Let a user connect to an ABS server with a self-signed HTTPS cert, after an explicit one-time
  trust confirmation showing the fingerprint.
- Persist the trust decision per-server so reconnect/relaunch/background all work.
- Keep CA-trusted HTTPS and plaintext `http://` behavior exactly as today.
- Pure, fully unit-tested trust-decision logic.
- No regression to the existing `AudiobookshelfService` auth/download/progress tests.

**Non-goals (YAGNI / deferred, documented)**
- SPKI / public-key pinning (leaf-cert pinning is right for static self-signed homelab certs).
- A "trust any certificate, no questions" global escape hatch.
- A dedicated "the certificate changed!" warning UI (mismatch fails closed → normal connect error;
  recovery is sign-out + reconnect). Future nicety.
- macOS ABS **UI** (still the documented fast-follow). The shared service layer *does* gain the
  pinning capability so macOS reuses it when its UI lands.
- Honoring the pin for `AsyncImage` cover loads — see §8 Known Limitations.

## 4. Components

All new types live in `EchoCore/Services/Audiobookshelf/` (compiled by **both** iOS and macOS
targets; Foundation + Security + CryptoKit only).

### 4.1 `ABSServerTrustEvaluator` — the pure, testable core

```swift
struct ABSServerTrustEvaluator {
    enum Decision: Equatable { case useDefault, accept, reject }

    /// - expectedHost: the host of the server's configured baseURL (lowercased).
    /// - pinnedSHA256: the trusted leaf fingerprint for this server, or nil if none pinned yet.
    let expectedHost: String
    let pinnedSHA256: String?

    func decide(
        isServerTrust: Bool,
        challengeHost: String,
        defaultTrustSucceeded: Bool,
        leafSHA256: String?
    ) -> Decision {
        // Not a server-trust challenge, or a host we didn't configure → let the system decide.
        guard isServerTrust, challengeHost.lowercased() == expectedHost else { return .useDefault }
        // CA-trusted already → no pin needed (homelab user installed a real cert later).
        if defaultTrustSucceeded { return .useDefault }
        // Untrusted + our host: accept iff we have a pin and the leaf matches it.
        if let pinnedSHA256, let leafSHA256, leafSHA256 == pinnedSHA256 { return .accept }
        return .reject
    }
}
```

Fingerprints are compared as lowercase hex strings of the SHA-256 of the DER leaf cert.

### 4.2 `ABSServerTrustDelegate: NSObject, URLSessionDelegate` — the I/O shell

Implements `urlSession(_:didReceive:completionHandler:)`:

1. If `challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust`
   and a `serverTrust` exists:
   - `defaultTrustSucceeded = SecTrustEvaluateWithError(serverTrust, nil)`.
   - `leafSHA256 =` SHA-256 of the leaf cert via `SecTrustCopyCertificateChain(serverTrust)` →
     first element → `SecCertificateCopyData` → CryptoKit `SHA256.hash`, hex-encoded.
     (`SecTrustCopyCertificateChain` is the iOS-15+/macOS-12+ replacement for the deprecated
     `SecTrustGetCertificateAtIndex`.)
   - Record the captured untrusted fingerprint when `defaultTrustSucceeded == false` and the host
     matches (thread-safe; see §9), so the service can surface it.
   - Ask `evaluator.decide(...)` and map:
     - `.useDefault` → `completionHandler(.performDefaultHandling, nil)`
     - `.accept`     → `completionHandler(.useCredential, URLCredential(trust: serverTrust))`
     - `.reject`     → `completionHandler(.performDefaultHandling, nil)` *(let the system reject so
       the error is deterministically `-1202`, rather than a `-999` cancel)*
2. Any non-server-trust method → `.performDefaultHandling`.

Holds `var lastUntrustedLeafSHA256: String?` (lock-guarded). Does **not** retain the service.

### 4.3 `ABSURLSession` — session factory

```swift
enum ABSURLSession {
    /// Returns a session whose delegate enforces (or probes for) the pin, plus the delegate
    /// so the caller can read the captured fingerprint. `pinnedSHA256 == nil` = probe mode.
    static func make(expectedHost: String, pinnedSHA256: String?)
        -> (session: URLSession, delegate: ABSServerTrustDelegate)
}
```

Callers that need no trust override keep passing `.shared` (CA path / `http://` unchanged).

### 4.4 `ABSError.untrustedCertificate(host:sha256:)` — new case

Added to `ABSError` in `ABSModels.swift`, with a `LocalizedError` description. Surfaced only on the
connect probe.

### 4.5 Storage — Keychain, no schema migration

`ABSTokenStore` already stores per-server creds in Keychain, namespaced by `serverID`
(`service = "com.echo.abs.<serverID>"`). Add:

- `KeychainStore.Key.absPinnedCertificate` (new enum case in `Shared/KeychainStore.swift`).
- `ABSTokenStore.pinnedCertificateSHA256: String?` — computed, backed by that key; cleared in
  `clear()` (so sign-out un-pins).

Rationale: the fingerprint is not secret, but reusing the existing per-server Keychain namespace
avoids a `Schema_V25` migration (latest is `v24_feed_note_position_voice_memo`) and the
cross-branch version-collision risk this project has repeatedly hit. It also keeps the trust
artifact paired with the refresh token it secures.

## 5. Data flow

Host is derived from the normalized base URL (`ABSEndpoints.normalizedBaseURL`) via
`url.host?.lowercased()`.

### 5.1 Connect — CA-trusted cert or `http://` (unchanged)
`connectAudiobookshelf` builds the service with `session: .shared`, logs in, saves the
`ABSServerRecord`. The delegate is never involved.

### 5.2 Connect — self-signed cert (new)
1. **Probe.** `connectAudiobookshelf(baseURL:username:password:)` builds the service with a
   **probe** session (`ABSURLSession.make(expectedHost:host, pinnedSHA256:nil)`). `login()` fails
   the TLS handshake. The transport maps `URLError.serverCertificateUntrusted` + the delegate's
   captured fingerprint → throws `ABSError.untrustedCertificate(host:, sha256:)`.
2. **Confirm.** `ABSConnectionsSettingsView` catches *that specific case* and presents an `.alert`:
   the colon-grouped SHA-256 + "This server uses a self-signed certificate. Trust it?" with
   **Trust** / **Cancel**.
3. **Trust + retry.** On Trust, the view calls
   `connectAudiobookshelf(baseURL:username:password:trustingCertificate: sha256)`, which:
   generates a `serverID`, persists the pin to that server's Keychain, builds an **enforcing**
   session (`ABSURLSession.make(expectedHost:host, pinnedSHA256: sha256)`), logs in, and saves the
   `ABSServerRecord` exactly as today. Cancel writes nothing.

### 5.3 Reconnect / `makeAudiobookshelfService()`
Reads the pin for `server.id` from Keychain. If a pin exists → build an enforcing session;
otherwise → `.shared`. So pinned servers keep working across launches, background, and the
per-row cover/browse accessor.

### 5.4 Certificate later changes (rotation / MITM)
Enforcing session sees a leaf whose fingerprint ≠ pin → `.reject` → request fails closed with the
normal connection error. Recovery: Sign Out (clears the pin) and reconnect (re-pins the new cert
after a fresh confirmation).

## 6. Session lifecycle

A `URLSession` created with a delegate **strongly retains that delegate** until invalidated. The
service caches one session for the app lifetime; when it is replaced (disconnect, or reconnect with
a different trust posture) the **previous custom session must be invalidated**
(`finishTasksAndInvalidate()`) to release its delegate. `signOut()` / `disconnectAudiobookshelf`
invalidate the enforcing session. (`.shared` is never invalidated.) This keeps the change clean
under the memory-auditor.

## 7. Error handling

- New `ABSError.untrustedCertificate(host:sha256:)`, surfaced only on the probe.
- Transport mapping: in the instance-level send path, catch the underlying error; if it is
  `URLError.serverCertificateUntrusted` (or a cancel) **and** the delegate captured a fingerprint
  for the expected host, throw `.untrustedCertificate`. All other errors keep their current
  `ABSError.network` / `ABSError.http` mapping.
- The connect view shows the trust alert only for `.untrustedCertificate`; every other error keeps
  today's inline "Could not connect: …" message.

## 8. Known limitations (documented honestly)

- **Cover thumbnails on a self-signed server will not load.** Covers are rendered with `AsyncImage`
  using self-contained `?token=` URLs; `AsyncImage` fetches via `URLSession.shared`, which cannot
  be handed our pinning delegate. Connect, browse (list/metadata), search, **download**, and
  progress sync all work because they go through the service's pinned session; only the inline
  cover images fail (broken-image placeholder). A pinned-session async image loader is a future
  enhancement. This limitation does **not** apply to CA-trusted or `http://` servers.
- Single leaf-cert pin per server; no chain/intermediate pinning, no SPKI.

## 9. Concurrency / thread-safety

- The delegate callback runs on the session's delegate queue (background). The service reads the
  captured fingerprint on `@MainActor`. `lastUntrustedLeafSHA256` is guarded by an `NSLock` (or
  `os_unfair_lock`); the evaluator is a `let`-only value type (inherently safe).
- `ABSServerTrustDelegate` and `ABSServerTrustEvaluator` are `Sendable` (value type / lock-guarded
  reference) to satisfy Swift 6 strict concurrency in the shared module.

## 10. Testing

- **`ABSServerTrustEvaluatorTests`** (Swift Testing, pure — no real certs):
  1. CA-trusted, our host → `.useDefault`
  2. Untrusted, our host, no pin → `.reject` (probe path)
  3. Untrusted, our host, matching pin → `.accept`
  4. Untrusted, our host, mismatched pin → `.reject`
  5. Untrusted, **different** host → `.useDefault`
  6. Non-server-trust method → `.useDefault`
  7. Host comparison is case-insensitive.
- **Fingerprint formatting test:** raw 32-byte digest → lowercase hex and → colon-grouped display.
- **Optional** (nice-to-have): a `SecCertificate` fixture (bundled `.cer`) to test the leaf-SHA-256
  extraction end-to-end. Marked optional because it adds a test resource; the decision logic is the
  risk surface and is fully covered above.
- Existing `AudiobookshelfService*Tests` keep injecting `URLProtocolStub` with no delegate →
  untouched.

## 11. Platform & parity

- Evaluator / delegate / factory / store / error are shared EchoCore → compile on iOS **and**
  macOS. Run the **cross-platform-parity-reviewer** on the shared change.
- The trust-prompt **UI** lands in iOS `ABSConnectionsSettingsView` (where the connect flow lives).
  macOS reuses the same `PlayerModel` API + `ABSError` case when its ABS UI ships.

## 12. Documentation to update (doc-sync)

- **`ARCHITECTURE.md`** ABS section line ~283: replace the misleading sentence with an accurate
  description — CA-trusted HTTPS and plaintext `http://`/arbitrary ports work out of the box;
  self-signed HTTPS requires an explicit per-server TOFU pin (fingerprint shown, leaf cert pinned in
  Keychain). Add a short "Trust model" note and the cover-image limitation.
- **`CHANGELOG.md`** entry under the ABS integration.
- **`README.md`** only if it mentions ABS cert behavior (check during implementation).

## 13. Out of scope / follow-ups (file as chips, not this PR)

- Pinned-session `AsyncImage` replacement so covers load on self-signed servers.
- "Certificate changed" explicit warning + re-trust flow.
- macOS ABS connect UI (already a tracked fast-follow).
