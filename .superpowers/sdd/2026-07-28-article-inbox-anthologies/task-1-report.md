# Task 1 report — trusted capture envelope and vendored Readability

## Implementation

- Added the `ArticleWorkshopLimits` hard bounds, including the 12 MiB URL-response limit.
- Added nonisolated, `Codable`, `Equatable`, `Sendable` capture-domain values: `ArticleCaptureMethod`, `ReadabilityCapturePayload`, and `ArticleCaptureEnvelope`.
- Added shared `JSONEncoder.articleWorkshop` and `JSONDecoder.articleWorkshop` factories. They serialize dates as ISO 8601 internet dates with fractional seconds, so the host and share extension use the same wire representation.
- Added only the contract fields in the brief; no cookie, authorization, credential, form, history, script, frame, or active-embed fields were introduced.
- Vendored the exact `@mozilla/readability` 0.6.0 `Readability.js` and Apache-2.0 license, with the required `PIN.json` values.
- Added an executable vendor verifier that downloads the pinned tarball into a `mktemp -d` directory, validates SHA-512 npm integrity with `openssl dgst -sha512 -binary | openssl base64 -A`, byte-compares the extracted JavaScript and license, and removes the temporary directory with a trap.

## Files changed

- `ThirdParty/Readability/Readability.js`
- `ThirdParty/Readability/LICENSE.md`
- `ThirdParty/Readability/PIN.json`
- `Scripts/verify_readability_vendor.sh`
- `Shared/ArticleCapture/ArticleWorkshopLimits.swift`
- `Shared/ArticleCapture/ArticleCaptureEnvelope.swift`
- `EchoTests/ArticleWorkshop/ArticleCaptureEnvelopeTests.swift`

## TDD evidence

### RED

Commands run before the implementation:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
```

Relevant results:

- `make build-tests` exited 2 / `make` exited 65. `ArticleCaptureEnvelopeTests.swift` could not find `ReadabilityCapturePayload`, `ArticleCaptureEnvelope`, `ArticleWorkshopLimits`, `JSONEncoder.articleWorkshop`, or `JSONDecoder.articleWorkshop`.
- `make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests` was invoked after the failed build and could not provide a built focused suite.
- `bash Scripts/verify_readability_vendor.sh` exited 127: `No such file or directory`.

### GREEN

Commands run after the implementation:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
git diff --check
```

Relevant results:

- `make build-tests` exited 0: `** TEST BUILD SUCCEEDED **`.
- Focused Swift Testing suite passed: `ArticleCaptureEnvelopeTests` ran 2 tests with 0 failures.
- Vendor verifier exited 0: `Readability vendor pin verified: @mozilla/readability 0.6.0`.
- `git diff --check` exited 0.

## Vendor-pin verification

The verifier fetched the tarball pinned in `PIN.json`, confirmed the expected SHA-512 npm integrity value, and byte-compared both committed artifacts to `package/Readability.js` and `package/LICENSE.md` from that tarball.

## Self-review

- Reviewed the diff for scope: it contains only the seven files specified by the brief; the Xcode project file was not changed.
- Confirmed the default-MainActor build accepts the explicitly nonisolated serialized values and factories across the synchronized app, widget, and watch targets.
- Confirmed the test fixture is authored synthetic content only.
- Confirmed no browser-secret-shaped payload property was added.

## Concerns

- The focused test run emitted existing simulator/device connection and app-fixture diagnostic noise, but the relevant Swift Testing suite passed. No new functional failure was observed.
