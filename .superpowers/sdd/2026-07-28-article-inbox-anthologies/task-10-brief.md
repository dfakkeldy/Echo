# Task 10: Anthology projects, stable slots, manifests, and builder UI

Implement Task 10 from:

`docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base:

`3855c662`

## Coordination and scope

- Do not modify `Echo.xcodeproj/project.pbxproj`, `ARCHITECTURE.md`, narration files, the share extension, or the Global Pronunciation sibling worktree.
- Task 5/8 remain dependency-waiting; Task 6 remains review-blocked. Do not modify or claim them.
- No physical-device/iPhone Mirroring work. The user has explicitly said physical iPhone/iPad acceptance is unavailable and must remain pending.
- Task 10 authors projects and freezes immutable manifests. Do not build ZIP/EPUB files (Task 11), orchestrate published build receipts/exports (Task 12), import editions (Task 13), synthesize narration (Task 14), or export M4B (Task 15).
- No third-party dependencies or generalized repository/protocol hierarchy.

## Test-first requirements

Add the planned `AnthologyServiceTests` and `AnthologyBuilderViewModelTests` before production code. Cover:

1. project creation preserves the caller's selection order;
2. reorder changes display order but never `stableSlot`;
3. remove plus later add never reuses stable slots, and display order remains dense/deterministic;
4. manifest freezes exact current article revision IDs, clean blocks, hashes, entry voice IDs, stable slots, and current order;
5. a later article cleanup marks Changes Available without mutating the prior successful build manifest/record;
6. explicit creator is preserved; missing/blank creator becomes `Various Authors` only in the manifest and is not written back to the project;
7. per-entry voice override survives reorder and reload;
8. failed build receipts do not consume the next published manifest revision; derive it from latest successful build only;
9. chapter title override, project metadata, cover choice, and every structural change persist immediately;
10. malformed UUID/date/URL/revision JSON, mismatched revision hash/capture, missing package, missing entry capture, or invalid stored order fails closed with user-safe errors;
11. an article with no current cleanup revision receives one atomic empty baseline revision before freezing, without arbitrary cleanup or prose mutation; a concurrent real cleanup wins safely;
12. a coherent database snapshot is used for all entry/current-revision inputs so concurrent edits cannot produce a half-old/half-new manifest.

Add accessibility/policy tests for Move Up/Down parity, stable slot labels, explicit build action, and the in-context Clean Up route.

## Shared manifest models

Add the exact planned Codable/Equatable/Sendable models:

```swift
struct AnthologyBuildManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let anthologyID: UUID
    let revision: Int
    let epubIdentifier: String
    let title: String
    let subtitle: String?
    let creator: String
    let language: String
    let coverPath: String?
    let modifiedAt: Date
    let chapters: [AnthologyChapterManifest]
}

struct AnthologyChapterManifest: Codable, Equatable, Sendable {
    let entryID: UUID
    let captureID: UUID
    let articleRevisionID: UUID
    let stableSlot: Int
    let order: Int
    let title: String
    let author: String?
    let siteName: String?
    let sourceURL: URL
    let capturedAt: Date
    let voiceID: String?
    let blocks: [ArticleBlock]
    let readableContentSHA256: String
}
```

- `schemaVersion = 1`.
- `epubIdentifier = urn:uuid:<anthology UUID>` and remains stable across builds/reorders.
- Published revision is latest successful build revision + 1; failed attempts do not consume it.
- Normalize blank optional metadata/voice/title overrides to `nil`.
- Creator fallback is exactly `Various Authors`, manifest-only.
- Use the single common nonempty article language only when all chapters agree; otherwise use BCP-47 `und`.
- `order` is dense `0...n-1`; filenames later use `stableSlot`, never order.
- Validate every source URL as absolute HTTP(S), every stored UUID, every timestamp, and all current revision material.

## Coherent persistence and revision materialization

Extend the existing DAOs with cohesive atomic operations rather than service-level check/write races:

- load one anthology, its ordered entries, capture records, exact current revisions, and latest successful build in one GRDB read snapshot;
- update project metadata/cover without changing managed counters;
- update chapter title/voice only for an entry owned by the anthology;
- replace order atomically and update project `modifiedAt`;
- remove an owned entry, compact display order, preserve all stable slots, and update `modifiedAt`;
- allocate additions from `nextStableSlot` without reuse.

For captures with no current revision:

- locally load/sanitize the immutable managed snapshot;
- construct an empty canonical recipe revision with the correct readable hash;
- publish it conditionally with expected current `nil`;
- if a concurrent revision wins, use that current revision instead;
- reload one coherent project snapshot before manifest materialization.

Use or extract one shared revision-materialization helper now that cleanup and anthology building both need it. It must validate:

- revision belongs to capture;
- canonical recipe/metadata decode and agreement;
- recipe applies to immutable snapshot;
- recomputed readable hash equals the stored revision hash.

Do not rewrite existing revisions or silently repair malformed ones.

## Service and Changes Available

Implement `AnthologyService` with deterministic injected clock/UUID seams for tests.

- Project creation is atomic.
- Manifest creation loads/sanitizes locally only: no network, WebKit, image download, CloudKit, narration, or credentials.
- A prior `AnthologyBuildRecord.manifestJSON` is immutable evidence.
- `changesAvailable` compares current project/build content (metadata, cover, entry membership/order/stable slots, exact revision IDs, title/voice overrides) to the latest successful frozen manifest while ignoring only the next-attempt revision number.
- Never mutate a prior build record/manifest to clear the flag.
- Empty anthologies cannot produce a manifest.

## Builder/list view models and iOS UI

Create the planned list and builder view models plus:

- `AnthologyListView`
- `AnthologyDetailView`
- `AnthologyBuilderView`

Replace the Task 7 Anthologies placeholder with the real list and navigation.

Builder behavior:

- edits title/subtitle/creator and generated/user cover choice;
- persists each structural/metadata change immediately and reports a user-safe retryable error on failure;
- reorders by drag and Move Up/Down accessibility actions;
- removes entries from the project without deleting reusable captures;
- supports per-article voice override using the existing voice catalog plus “Project Default”;
- shows a table-of-contents preview with order and stable slot;
- offers in-context **Clean Up** using the accepted Task 9 cleanup context;
- exposes **Build** explicitly by freezing/preparing a manifest only; do not create an EPUB in Task 10;
- visibly distinguishes saved project state, Changes Available, and prepared manifest revision without relying on color.

For user cover choice, use the smallest native iOS image picker/file flow and copy accepted data into the exact managed anthology directory. Bound bytes and decoded dimensions, reject unsafe/non-image data, write atomically, and never persist a security-scoped external path. Generated cover remains the default; Task 11 owns rendering it.

Preserve Dynamic Type, VoiceOver/keyboard-equivalent move actions, 44-point targets, native lists/forms/confirmation, user-safe errors, and Task 7 Books/Inbox toolbar isolation.

## Verification

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyServiceTests
make test-only FILTER=EchoTests/AnthologyBuilderViewModelTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
make test-only FILTER=EchoTests/ArticleCleanupViewModelTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/ArticleInboxPresentationPolicyTests
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
git diff --check
```

Run any new anthology accessibility/policy/cover suite. Record only executable tests.

## Commit and report

Commit:

`feat: author article anthology projects`

Write ignored report:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-10-report.md`

Include RED/GREEN receipts, exact files, transaction/concurrency/failure evidence, security/accessibility checks, and remaining proof boundaries. Return only when committed and clean, or with an exact blocker.
