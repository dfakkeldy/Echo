# Task 3 report: atomic article capture staging and ingestion

## Implementation

- Added Article Workshop storage locations under Application Support and Caches.
- Added an extension-safe, `nonisolated` staging writer. It encodes and bounds
  the envelope before writing it to `.<UUID>.partial`, applies iOS
  complete-until-first-user-authentication protection to that directory, moves
  it atomically, and writes `complete` only after `envelope.json` is present.
- Added a durable Application Support file store. It requires the completion
  marker, validates package/envelope UUID agreement and schema version 1,
  bounds the source bytes, calculates SHA-256 with CryptoKit before publishing,
  and verifies the durable snapshot digest after publication.
- Added an ingestion service which persists the durable snapshot first, inserts
  the database row second, and removes staging last. A retry following a crash
  after file import either creates the missing row or, when the matching row
  already exists, removes the leftover staged package. Mismatched existing rows
  and snapshots fail closed and retain the staged package.

## Files changed

- `Shared/FileLocations.swift`
- `Shared/ArticleCapture/ArticleCaptureStagingWriter.swift`
- `Shared/ArticleWorkshop/ArticleWorkshopFileStore.swift`
- `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift`
- `EchoTests/ArticleWorkshop/ArticleWorkshopFileStoreTests.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxIngestionServiceTests.swift`

## TDD evidence

RED:

```text
make build-tests
... ArticleWorkshopFileStoreTests.swift:13:27: error: cannot find
'ArticleCaptureStagingWriter' in scope
** TEST BUILD FAILED **
```

The two requested pre-build commands were also run serially:

```text
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

Their existing test product predated the new files and selected zero tests, so
the compile failure above is the meaningful RED proof.

GREEN:

```text
make build-tests
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

All three commands completed successfully in serial order. The focused test
commands returned success but emitted only package-resolution output; their
result-bundle directories contain staging data without a final `Info.plist`, so
they do not provide a normal per-test execution receipt. The build did compile
and link both new test files.

## Self-review

- Marker is written last and incomplete packages are skipped by the importer.
- Durable snapshot write precedes database insertion; staging is removed only
  after both succeed.
- The durable-file-before-row and row-before-staging-deletion crash windows are
  retried idempotently.
- Both staging and import boundaries validate UUID, schema, byte size, and
  SHA-256; mismatches retain the complete staged package.
- The staged directory receives the required iOS data-protection class while
  macOS and watchOS builds stay conditional.
- Only the narrow capture envelope is written; no browser credentials, history,
  scripts, frames, embeds, form data, or cookies are added.

## Concerns

- The focused `test-without-building` process did not yield normal test-count
  output or a complete xcresult bundle in this environment despite zero exits.
  Treat the focused runtime receipt as environment-limited; `make build-tests`
  is the confirmed gate. The repository-wide baseline remains intentionally
  unrun because the dispatch says it is independently unstable.

## Fix round 1

### Addressed findings

1. **Shared staging location — addressed.** Capture staging now lives below
   the configured App Group container; accepted captures remain in host
   Application Support.
2. **Recovery-row comparison — addressed.** Recovery now requires the complete
   deterministic `ArticleCaptureRecord` derived from the staged envelope and
   durable import result, rather than matching only the digest.
3. **Writer recovery — addressed.** The writer has a narrow deterministic
   failure seam, cleans owned partial directories on ordinary failure, removes
   safe stale partial/incomplete packages on retry, and never overwrites a
   valid complete package. Staged JSON is canonicalized with sorted keys so a
   logical retry has a stable digest.
4. **Bounded untrusted reads — addressed.** File-store validation requires
   regular non-symlink files, checks declared size before opening, reads at
   most the configured limit plus one byte, and revalidates file type/size after
   reading and again before publication.
5. **Traversal and symlinks — addressed.** Draining enumerates only direct
   UUID-named children of a standardized, non-symlink staging root. Package,
   marker, and envelope are all revalidated as non-symlink types; the exact
   package is revalidated before deletion.

### Fix-round regression tests

- stale partial package reconciliation before retry;
- published-but-incomplete package retry through the marker failure seam;
- oversized envelope rejection before durable publication;
- symlinked envelope rejection and nonempty completion-marker rejection;
- same-digest metadata conflict retaining staging;
- symlinked direct staging package rejection.

### Fix-round verification

```text
RED: make build-tests
ArticleWorkshopFileStoreTests.swift:37:73: error: extra trailing closure
passed to call (the deterministic writer failure seam was absent).

GREEN: make build-tests
** TEST BUILD SUCCEEDED **

Focused commands run serially:
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

One intermediate runtime invocation exposed and named a real canonicalization
defect: seven ingestion tests ran, five passed, and the two retry/conflict tests
failed with `destinationDigestMismatch`. The writer now uses sorted JSON keys.
After that correction the final focused invocations returned success but again
did not yield a complete Swift Testing receipt in this environment, so runtime
success after the last correction remains unproven. `git diff --check` passed.

## Fix round 2

### Addressed finding

Cleanup is now identity-bound to the bytes that were imported. Before its
final validation and deletion, a direct UUID-named staging package is atomically
moved into a unique hidden `.cleanup-*` directory below the same staging root.
The quarantined package is rechecked as a non-symlink directory, validated
again, and deleted only when its SHA-256 equals the digest returned by the
original import. Any error after the move leaves the full quarantined package
in its recoverable location. A newly staged package at the original UUID path
after quarantine is never deleted by this cleanup attempt.

### Fix-round regression tests

- replacing the original direct-child package with another valid package of
  the same UUID immediately before cleanup retains the replacement in
  quarantine and fails the drain on digest mismatch;
- staging a new original package after the accepted package has been
  quarantined leaves that new package in place while the quarantined original
  is cleaned up.

### Fix-round verification

```text
RED: make build-tests
ArticleInboxIngestionServiceTests.swift:126:63: error: type
'ArticleInboxIngestionService' has no member 'CleanupPoint'
(the test seam and quarantine behavior did not yet exist).

GREEN: make build-tests
** TEST BUILD SUCCEEDED **

Focused commands run serially:
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

Both focused commands exited successfully after package resolution but again
produced no XCTest execution/count receipt in this Xcode environment. They are
therefore recorded as environment-limited, not as confirmed runtime passes.
`git diff --check` passed.

## Fix round 3

### Addressed finding

Startup now reconciles direct-child `.cleanup-*` residues before it considers
ordinary staging packages. A cleanup root must have the exact canonical
capture-ID-and-nonce name and be a real, non-symlink directory. It is either a
safe empty post-delete residue or contains exactly one real, non-symlink
UUID-named package matching the name's capture ID. A nonempty quarantine is
removed only after its validated envelope digest agrees with the pre-existing
durable snapshot and the complete deterministic capture row. Missing,
malformed, mismatched, or unvalidated state throws and retains the quarantine.
A current direct package with an ID reconciled from quarantine is deferred for
the current drain, so recovery cannot touch a newly staged package at that
original path.

### Fix-round regression tests

- a post-quarantine failure leaves residue which a new service reconciles on
  the next drain;
- a replacement quarantined package with a different digest is retained and
  causes recovery to fail;
- a safe empty cleanup root is removed;
- a new direct package remains while the prior quarantine for the same UUID is
  reconciled.

### Fix-round verification

```text
GREEN: make build-tests
completed successfully (the captured output was truncated before the final
banner).

make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
exited successfully after package resolution but emitted no XCTest receipt.

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
13 tests passed; ** TEST EXECUTE SUCCEEDED **

git diff --check
passed
```

The FileStore focused command remains environment-limited: its zero exit is
not treated as a confirmed runtime receipt. The new ingestion recovery tests
have a complete runtime receipt.
