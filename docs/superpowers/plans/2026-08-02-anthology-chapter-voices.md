# Anthology Chapter Voices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Echo narrate each generated-anthology chapter with its frozen explicit voice or the user's current preferred voice, while preserving stable cache identity across chapter reordering.

**Architecture:** Validate the matching successful anthology build receipt, join imported chapter blocks to frozen manifest chapters by `sourceChapterKey`, and produce one pure `NarrationChapterRenderPlan` consumed by every narration surface. Ordinary books remain on their existing index-based identity; trusted anthologies use a SHA-256-derived stable chapter token for cache files and track IDs.

**Tech Stack:** Swift 6, SwiftUI, Observation, GRDB, CryptoKit, AVFoundation, Swift Testing, existing Kokoro/ONNX narration stack.

## Global Constraints

- Branch from `nightly`; do not push directly to `nightly`, `weekly`, or `main`.
- Preserve iOS 18, macOS 15, and watchOS 11 deployment floors.
- Add no database migration and no third-party dependency.
- Treat `nil` chapter voice as inheritance: `override ?? preferredVoice`.
- Treat only a locally matched, validated `AnthologyBuildRecord` as anthology authority. A standalone re-imported EPUB without that receipt remains an ordinary book.
- Validate the complete anthology plan before deleting cache files or synthesizing audio.
- Keep generic EPUB/PDF cache names, track IDs, resume behavior, and export fallback unchanged.
- Never log captured prose, source URLs, or raw anthology/entry UUIDs when a bounded digest is sufficient.
- Use the repository's file-system-synchronized Xcode groups; do not edit `project.pbxproj` for new Swift files.
- Run focused tests after each task and `make test` before publication. App builds, real rendering, and human listening are separate proof states.

## File and Responsibility Map

| Area | Files | Responsibility |
|---|---|---|
| Receipt trust | `EchoCore/Services/ArticleWorkshop/AnthologyBuildManifestValidator.swift`, `AnthologyNarrationManifestResolver.swift`, `AnthologyService.swift` | Locate and validate the frozen successful build record before narration uses chapter voice data. |
| Shared plan | `EchoCore/Services/Narration/NarrationChapterRenderPlanner.swift`, `NarrationChapterPlanner.swift`, `NarrationSegmentPlanner.swift` | Join visible EPUB chapters to manifest entry UUIDs and resolve one effective voice per chapter. |
| Stable persistence | `NarrationFileNaming.swift`, `NarrationService.swift` | Generate/parse stable anthology filenames and track IDs while retaining legacy wrappers. |
| iOS/iPadOS runtime | `EchoCore/ViewModels/PlayerModel+Narration.swift`, `EchoCore/State/PlaybackState.swift` | Use the shared plan for cleanup, resume, render, cache reuse, outline, and UI summary state. |
| macOS runtime and repair | `Echo macOS/Services/MacBatchProcessingService.swift`, `NarrationQAReviewModel.swift`, `PronunciationRepairService.swift` | Preserve the resolved voice and identity during batch retry, QA, and repair. |
| Readiness/export | `AnthologyNarrationStatusService.swift`, `NarrationCacheSource.swift`, `ExportSourceResolver.swift` | Prove complete current audio and export only reachable current tracks in current order. |
| Editing UI | `AnthologyBuilderView.swift`, `MacArticleWorkshopView.swift`, `MacAnthologyVoiceEditor.swift`, localization catalog | Expose inherited/explicit choices on iPhone, iPad, and Mac. |
| Verification | Focused files under `EchoTests/ArticleWorkshop` plus existing narration/export suites | Prove identity, invalidation, orchestration, accessibility, and compatibility. |

---

## Task 1: Centralize Frozen Build-Receipt Validation

**Files:**

- Create: `EchoCore/Services/ArticleWorkshop/AnthologyBuildManifestValidator.swift`
- Create: `EchoCore/Services/ArticleWorkshop/AnthologyNarrationManifestResolver.swift`
- Modify: `EchoCore/Services/ArticleWorkshop/AnthologyService.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyNarrationManifestResolverTests.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyServiceTests.swift`

**Interfaces:**

- Consumes: `AnthologyBuildRecord`, `DatabaseWriter`, library `audiobookID`, optional canonical EPUB URL.
- Produces:

```swift
nonisolated enum AnthologyBuildManifestValidationError: Error, Equatable, Sendable {
    case invalidReceipt
    case invalidManifest
}

nonisolated enum AnthologyBuildManifestValidator {
    static func validate(_ build: AnthologyBuildRecord) throws -> AnthologyBuildManifest
}

nonisolated struct AnthologyNarrationManifestResolver: Sendable {
    let db: DatabaseWriter

    func resolve(
        audiobookID: String,
        epubURL: URL? = nil
    ) throws -> AnthologyBuildManifest?
}
```

- `nil` means no successful build matches and the caller must use legacy ordinary-book behavior.
- A matching but invalid record throws; callers must stop before cleanup or synthesis.
- Match `audiobook_id = ?` first. Only when `epubURL` is supplied, also compare the standardized file path to `epub_path`. Select the latest successful matching revision deterministically.

### Steps

- [ ] Add failing resolver tests for all three trust outcomes.

```swift
@Test func ordinaryBookReturnsNil() throws {
    let fixture = try ManifestResolverFixture()
    #expect(try fixture.resolver.resolve(audiobookID: "ordinary") == nil)
}

@Test func validAnthologyReturnsFrozenManifestByAudiobookID() throws {
    let fixture = try ManifestResolverFixture()
    let expected = try fixture.insertSuccessfulBuild(audiobookID: "book-1")
    #expect(try fixture.resolver.resolve(audiobookID: "book-1") == expected)
}

@Test func matchingTamperedReceiptThrows() throws {
    let fixture = try ManifestResolverFixture()
    try fixture.insertTamperedBuild(audiobookID: "book-1")
    #expect(throws: AnthologyBuildManifestValidationError.self) {
        try fixture.resolver.resolve(audiobookID: "book-1")
    }
}
```

- [ ] Run the new suite and confirm the missing types fail compilation.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationManifestResolverTests
```

Expected: failure because the validator and resolver do not exist.

- [ ] Move the complete validation currently in `AnthologyService.frozenManifest(from:)` into `AnthologyBuildManifestValidator.validate(_:)`. Preserve all existing checks: record identity/status/date, manifest digest, schema, EPUB identity, chapter order and uniqueness, stable slots, voice availability, readable-content digest, block identity, and safe URLs.

- [ ] Implement the resolver with a parameterized GRDB query. Do not accept a failed build, an arbitrary manifest file, or position-based chapter matching.

```swift
let build = try db.read { database in
    try AnthologyBuildRecord.fetchOne(
        database,
        sql: """
            SELECT * FROM anthology_build
            WHERE status = 'succeeded'
              AND (audiobook_id = ? OR (? IS NOT NULL AND epub_path = ?))
            ORDER BY revision DESC, created_at DESC, id DESC
            LIMIT 1
            """,
        arguments: [audiobookID, epubPath, epubPath]
    )
}
return try build.map(AnthologyBuildManifestValidator.validate)
```

- [ ] Replace `AnthologyService.frozenManifest(from:)` with a call to the shared validator and map validation failure to `AnthologyService.Error.invalidStoredData`. Existing `AnthologyServiceTests` must remain green.

- [ ] Add path-match, unavailable-voice, duplicate-entry, and digest-mismatch cases. Assert that a failed build does not shadow an older successful build.

- [ ] Run focused tests.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationManifestResolverTests
make test-only FILTER=EchoTests/AnthologyServiceTests
```

Expected: both suites pass.

- [ ] Commit.

```bash
git add EchoCore/Services/ArticleWorkshop/AnthologyBuildManifestValidator.swift \
  EchoCore/Services/ArticleWorkshop/AnthologyNarrationManifestResolver.swift \
  EchoCore/Services/ArticleWorkshop/AnthologyService.swift \
  EchoTests/ArticleWorkshop/AnthologyNarrationManifestResolverTests.swift \
  EchoTests/ArticleWorkshop/AnthologyServiceTests.swift
git commit -m "refactor(article-workshop): centralize build receipt validation"
```

---

## Task 2: Build the Shared Chapter and Segment Render Plan

**Files:**

- Create: `EchoCore/Services/Narration/NarrationChapterRenderPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationSegmentPlanner.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyNarrationRenderPlanTests.swift`
- Test: `EchoTests/NarrationSegmentPlannerTests.swift`

**Interfaces:**

- Consumes: existing `[NarrationChapterPlanner.PlannedChapter]`, preferred `VoiceID`, optional validated `AnthologyBuildManifest`.
- Produces:

```swift
nonisolated struct NarrationChapterRenderPlan: Equatable, Sendable {
    let chapterIndex: Int
    let displayNumber: Int
    let sourceChapterKey: String?
    let title: String
    let blocks: [EPubBlockRecord]
    let voice: VoiceID
}

nonisolated enum NarrationChapterRenderPlanError: Error, Equatable, Sendable {
    case missingSourceChapterKey(chapterIndex: Int)
    case mixedSourceChapterKeys(chapterIndex: Int)
    case unknownSourceChapterKey(String)
    case duplicateSourceChapterKey(String)
    case duplicateStableToken(String)
    case unavailableVoice(String)
}

nonisolated enum NarrationChapterRenderPlanner {
    static func plan(
        chapters: [NarrationChapterPlanner.PlannedChapter],
        preferredVoice: VoiceID,
        manifest: AnthologyBuildManifest?
    ) throws -> [NarrationChapterRenderPlan]
}
```

- Extend `NarrationSegmentPlanner.PlannedSegment` with `sourceChapterKey: String?` and `voice: VoiceID`.
- Change `NarrationSegmentPlanner.plan` and `segments` to consume `NarrationChapterRenderPlan` values. Resume remains position-independent by adding:

```swift
static func resume(
    _ segments: [PlannedSegment],
    startingAtSourceChapterKey sourceChapterKey: String
) -> [PlannedSegment]

static func beforeResume(
    _ segments: [PlannedSegment],
    startingAtSourceChapterKey sourceChapterKey: String
) -> [PlannedSegment]
```

Keep the existing index-based resume overloads for ordinary books and existing callers until Task 4 switches anthology playback.

### Steps

- [ ] Add failing pure tests covering inheritance, overrides, preferred-voice changes, and ordinary books.

```swift
@Test func nilOverrideInheritsPreferredVoice() throws {
    let plans = try NarrationChapterRenderPlanner.plan(
        chapters: chapters(keys: [entryA]),
        preferredVoice: VoiceID("af_heart"),
        manifest: manifest(voices: [entryA: nil]))
    #expect(plans.map(\.voice) == [VoiceID("af_heart")])
}

@Test func explicitOverrideWins() throws {
    let plans = try NarrationChapterRenderPlanner.plan(
        chapters: chapters(keys: [entryA, entryB]),
        preferredVoice: VoiceID("af_heart"),
        manifest: manifest(voices: [entryA: nil, entryB: "bf_emma"]))
    #expect(plans.map(\.voice.rawValue) == ["af_heart", "bf_emma"])
}
```

- [ ] Add failing adversarial tests: one chapter with mixed keys, missing key in a claimed anthology, key absent from manifest, repeated key in visible chapters, unavailable manifest voice, and two keys forced through an injected token function to the same digest.

- [ ] Run the new suite and confirm it fails.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationRenderPlanTests
```

Expected: failure because the render planner does not exist.

- [ ] Implement `NarrationChapterRenderPlanner.plan`. For `manifest == nil`, return the preferred voice and `nil` key without inspecting block keys. For a manifest, require every narratable block in each planned chapter to have one identical non-nil key that exists in `manifest.chapters`; use `VoiceID(rawVoiceID)` when `voiceID` is non-nil and the catalog contains it, otherwise use `preferredVoice`.

- [ ] Reject duplicate stable tokens before returning the plan. Use the canonical UUID string from `AnthologyChapterManifest.entryID.uuidString`; do not normalize arbitrary foreign strings into a match.

- [ ] Propagate the key and voice unchanged into every segment. Do not resolve a voice again inside segment planning.

```swift
result.append(
    PlannedSegment(
        chapterIndex: chapter.chapterIndex,
        chapterDisplayNumber: chapter.displayNumber,
        sourceChapterKey: chapter.sourceChapterKey,
        voice: chapter.voice,
        segmentIndex: segmentIndex,
        blocks: currentBlocks,
        chapterTitle: chapter.title
    ))
```

- [ ] Update existing segment tests to construct render plans explicitly and add stable-key resume tests after a reordered input plan.

- [ ] Run focused tests.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationSegmentPlannerTests
make test-only FILTER=EchoTests/NarrationChapterPlannerTests
```

Expected: all three suites pass.

- [ ] Commit.

```bash
git add EchoCore/Services/Narration/NarrationChapterRenderPlanner.swift \
  EchoCore/Services/Narration/NarrationSegmentPlanner.swift \
  EchoTests/ArticleWorkshop/AnthologyNarrationRenderPlanTests.swift \
  EchoTests/NarrationSegmentPlannerTests.swift
git commit -m "feat(narration): resolve anthology chapter voice plans"
```

---

## Task 3: Add Stable Anthology Cache and Track Identity

**Files:**

- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Test: `EchoTests/NarrationFileNamingTests.swift`
- Test: `EchoTests/NarrationCacheStoreTests.swift`
- Test: `EchoTests/NarrationServiceTests.swift`

**Interfaces:**

- Consumes: optional stable `sourceChapterKey` alongside existing EPUB chapter index.
- Produces:

```swift
nonisolated struct NarrationCacheLocation: Equatable, Sendable {
    let chapterIndex: Int?
    let stableChapterToken: String?
    let segmentIndex: Int?
}

static func stableChapterToken(for sourceChapterKey: String) -> String
static func location(fromFileName fileName: String) -> NarrationCacheLocation?
static func trackID(
    audiobookID: String,
    chapterIndex: Int,
    sourceChapterKey: String?,
    segmentIndex: Int?
) -> String
```

- Add `sourceChapterKey: String? = nil` to these `NarrationService` methods:
  - `renderChapter`
  - `renderSegment`
  - `renderSegmentFile`
  - `updateCachedNarrationTitle`
  - the private chapter/segment cache URL helpers they call.
- `nil` must produce exactly the current filename and track ID.
- Non-nil names use this format:

```text
{bookToken}-ck{32-lowercase-hex}[-s{segmentIndex}][-h{contentSignature}]-{voice}-v20.m4a
```

- Stable track IDs use `syn-{audiobookID}-ck{token}` plus optional `-s{segmentIndex}`.

### Steps

- [ ] Add characterization tests that freeze every existing legacy filename, parser result, and track ID before adding the new path.

- [ ] Add failing stable-name tests.

```swift
@Test func stableNameDoesNotChangeWhenChapterIndexChanges() {
    let first = NarrationFileNaming.segmentFileName(
        audiobookID: "book", chapterIndex: 1, sourceChapterKey: entryKey,
        segmentIndex: 0, voice: VoiceID("af_heart"), contentSignature: "abc")
    let reordered = NarrationFileNaming.segmentFileName(
        audiobookID: "book", chapterIndex: 9, sourceChapterKey: entryKey,
        segmentIndex: 0, voice: VoiceID("af_heart"), contentSignature: "abc")
    #expect(first == reordered)
    #expect(NarrationFileNaming.location(fromFileName: first)?.stableChapterToken?.count == 32)
}
```

- [ ] Run naming tests and confirm the new overloads fail compilation.

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationFileNamingTests
```

- [ ] Implement SHA-256 token generation with `CryptoKit`. Lowercase the hex encoding and take exactly 32 characters. Parse only the owned `-ck{32 hex}` and optional `-s{digits}` grammar; reject malformed or ambiguous names.

- [ ] Implement filename and track-ID helpers, retaining existing index-based methods as wrappers. Do not bump `renderVersion`: the stable filename namespace already prevents adopting legacy anthology files, while generic book bytes are unchanged.

- [ ] Thread `sourceChapterKey` through `NarrationService`. Use stable track IDs for anthology units, but keep `sortOrder = chapterIndex * 1000 + segmentIndex` as mutable presentation order. On cache reuse, update both title and `sort_order` for the stable track:

```swift
try await db.write { database in
    try database.execute(
        sql: """
            UPDATE track
            SET title = ?, sort_order = ?
            WHERE id = ? AND audiobook_id = ?
            """,
        arguments: [savedTitle, sortOrder, trackID, audiobookID])
}
```

- [ ] Replace `NarrationCacheStore.staleVoiceFiles` with plan-aware deletion:

```swift
static func staleFiles(
    _ fileNames: [String],
    bookPrefix: String,
    expectedDurableFileNames: Set<String>
) -> [String]
```

It returns only active-book files absent from the complete expected set. Require callers to skip cleanup when the expected set is empty because plan construction failed.

- [ ] Add tests proving mixed current voices are preserved, stale voice/content/version variants are removed, another book is untouched, partial files are bounded to the active book, and legacy index-named anthology audio is not adopted.

- [ ] Add service tests with a fake TTS engine: a reorder updates `sort_order` without a synthesis call; changing one chapter voice creates only that chapter's new stable file; ordinary calls still produce their previous path and track ID.

- [ ] Run focused tests.

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationFileNamingTests
make test-only FILTER=EchoTests/NarrationCacheStoreTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: all suites pass.

- [ ] Commit.

```bash
git add EchoCore/Services/Narration/NarrationFileNaming.swift \
  EchoCore/Services/Narration/NarrationService.swift \
  EchoTests/NarrationFileNamingTests.swift \
  EchoTests/NarrationCacheStoreTests.swift \
  EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): add stable anthology cache identity"
```

---

## Task 4: Integrate the Plan into iOS and iPadOS Playback

**Files:**

- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/State/PlaybackState.swift`
- Create: `EchoCore/Services/Narration/NarrationResumeResolver.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyNarrationPlaybackPlanTests.swift`
- Test: `EchoTests/PlayerModelTests.swift`
- Test: `EchoTests/NarrationOutlineBuilderTests.swift`

**Interfaces:**

- Consumes: active `audiobookID`, visible/all EPUB blocks, preferred voice, validated optional manifest.
- Produces:

```swift
nonisolated enum NarrationResumeResolver {
    static func sourceChapterKey(
        fromLastTrackURL url: URL?,
        plans: [NarrationChapterRenderPlan]
    ) -> String?
}
```

- Add presentation state:

```swift
var narrationDefaultVoice: VoiceID? = nil
var narrationVoiceOverrideCount = 0
```

Reset both when the active book changes or narration state is cleared.

### Steps

- [ ] Extract a pure playback-plan fixture test that loads a three-chapter generated anthology: inherited `af_heart`, explicit `bf_emma`, explicit third voice. Assert every planned segment keeps the chapter voice and source key.

- [ ] Add a failing stable-resume test where the last track belongs to entry B, then reorder B from position 2 to position 1. Assert resume starts at B's new position, not at the old numeric index.

- [ ] Add a cleanup-order test with an invalid claimed anthology. Inject a cleanup spy and assert it is not called when receipt or block-to-manifest validation fails.

- [ ] Run focused tests and confirm failure.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationPlaybackPlanTests
```

- [ ] In `PlayerModel+Narration`, replace the single global-voice chapter loop with this sequence:

  1. load all and visible blocks;
  2. resolve the matching manifest;
  3. build chapter render plans and segment plans;
  4. compute every expected cache filename from each segment's identity, content, and voice;
  5. perform plan-aware cleanup;
  6. resolve resume by stable key for anthologies or legacy chapter index for ordinary books;
  7. render/cache/update/queue each segment with its own key and voice;
  8. backfill earlier segments using the same resolved values.

- [ ] Pass `sourceChapterKey` and `voice` into cache lookup, entitlement checks, `renderSegment`, `renderSegmentFile`, cached-title/order update, queue insertion, and backfill. Delete any inner-loop fallback to `narrationVoiceForFiles`.

- [ ] Compute outline readiness from the exact expected filenames for the resolved plans. Continue using the existing outline builder for excluded-chapter presentation; supply a rendered-index set derived from exact plan matches rather than a global voice suffix.

- [ ] Set `state.narrationDefaultVoice` to the chosen preferred voice. Set override count from manifest chapters represented by current narration plans whose frozen `voiceID` is non-nil.

- [ ] Map matching invalid receipts and plan mismatches to a rebuild-oriented user error. Confirm this happens before file deletion and before invoking the TTS engine.

- [ ] Update source-level `PlayerModelTests` assertions so a regression to one loop-wide voice fails. Keep all existing streaming, cancellation, book-switch, and render-ahead tests green.

- [ ] Run focused and adjacent tests.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationPlaybackPlanTests
make test-only FILTER=EchoTests/PlayerModelTests
make test-only FILTER=EchoTests/NarrationOutlineBuilderTests
make test-only FILTER=EchoTests/NarrationSegmentPlannerTests
```

Expected: all suites pass.

- [ ] Commit.

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift \
  EchoCore/State/PlaybackState.swift \
  EchoCore/Services/Narration/NarrationResumeResolver.swift \
  EchoTests/ArticleWorkshop/AnthologyNarrationPlaybackPlanTests.swift \
  EchoTests/PlayerModelTests.swift \
  EchoTests/NarrationOutlineBuilderTests.swift
git commit -m "feat(ios): honor anthology chapter voices in playback"
```

---

## Task 5: Integrate macOS Batch Narration, QA, and Repair

**Files:**

- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify: `EchoCore/Services/Narration/PronunciationRepairService.swift`
- Test: `EchoTests/MacReaderParityTests.swift`
- Test: `EchoTests/NarrationQAReviewModelTests.swift`
- Test: `EchoTests/PronunciationRepairServiceTests.swift`

**Interfaces:**

- Add `sourceChapterKey: String? = nil` to `PronunciationRepairService.init` and store it with the existing chapter index and voice.
- Add injectable plan resolution to `NarrationQAReviewModel.Dependencies`:

```swift
let narrationPlan:
    @Sendable (_ audiobookID: String, _ preferredVoice: VoiceID)
        async throws -> [NarrationChapterRenderPlan]
```

The live dependency loads blocks, resolves the validated manifest, and calls the shared planner. Tests provide a deterministic plan without loading a TTS model.

### Steps

- [ ] Add failing batch tests or parity assertions proving the Mac loop takes `chapter.voice` and `chapter.sourceChapterKey`, including the fresh-engine retry path.

- [ ] Add a QA test where the global preference is `af_heart` but the issue's chapter plan uses `bf_emma`. Assert full QA and `acceptFix` pass `bf_emma` to the fake render/repair dependency.

- [ ] Add a repair test that creates two stable files for the same book and different chapter keys. Repair entry B and assert only entry B's matching durable/partial files are cleared and regenerated.

- [ ] Run focused tests and confirm the new expectations fail.

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationQAReviewModelTests
make test-only FILTER=EchoTests/PronunciationRepairServiceTests
make test-only FILTER=EchoTests/MacReaderParityTests
```

- [ ] In `MacBatchProcessingService`, resolve the manifest by temporary `audiobookID` plus canonical EPUB path, build the same render plans as iOS, and use each chapter's key/voice for cache lookup, render, retry, persistence, and sidecar ordering.

- [ ] Ensure the retry captures the failed chapter plan value before replacing the engine. It must not re-read the preferred voice and lose an explicit override.

- [ ] In `NarrationQAReviewModel`, resolve the current plan once per QA/repair operation and find the target by current chapter index. Reject a claimed anthology whose target cannot be joined to a stable key.

- [ ] Pass the target key and effective voice to `PronunciationRepairService`. Use stable naming helpers when clearing files and invoking `NarrationService`; preserve the legacy index path when the key is nil.

- [ ] Run focused tests.

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationQAReviewModelTests
make test-only FILTER=EchoTests/PronunciationRepairServiceTests
make test-only FILTER=EchoTests/MacReaderParityTests
```

Expected: all suites pass.

- [ ] Commit.

```bash
git add 'Echo macOS/Services/MacBatchProcessingService.swift' \
  EchoCore/ViewModels/NarrationQAReviewModel.swift \
  EchoCore/Services/Narration/PronunciationRepairService.swift \
  EchoTests/MacReaderParityTests.swift \
  EchoTests/NarrationQAReviewModelTests.swift \
  EchoTests/PronunciationRepairServiceTests.swift
git commit -m "feat(macos): honor anthology voices in narration and repair"
```

---

## Task 6: Make Readiness and Export Plan-Aware

**Files:**

- Create: `EchoCore/Services/Narration/AnthologyNarrationStatusService.swift`
- Modify: `EchoCore/Services/Export/NarrationCacheSource.swift`
- Modify: `EchoCore/Services/Export/ExportSourceResolver.swift`
- Modify: `EchoCore/Views/ExportProgressView.swift`
- Modify: `EchoCore/Views/VideoExportProgressView.swift`
- Modify: `EchoCore/Services/Export/VideoExportService.swift`
- Modify: `Echo macOS/Views/MacAudioExportView.swift`
- Modify: `Echo macOS/Views/MacVideoExportView.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyNarrationStatusServiceTests.swift`
- Test: `EchoTests/NarrationExportOrderingTests.swift`
- Test: `EchoTests/VideoExportServiceTests.swift`

**Interfaces:**

```swift
nonisolated struct AnthologyNarrationStatus: Equatable, Sendable {
    let readyChapterCount: Int
    let totalChapterCount: Int
    let staleSourceChapterKeys: [String]

    var isComplete: Bool {
        totalChapterCount > 0 && readyChapterCount == totalChapterCount
    }
}

nonisolated enum AnthologyNarrationReadinessError: Error, Equatable, Sendable {
    case invalidPlan
    case incomplete(chapterDisplayNumbers: [Int])
}

struct AnthologyNarrationStatusService: Sendable {
    let db: DatabaseWriter
    let cacheDirectory: URL

    func status(
        audiobookID: String,
        preferredVoice: VoiceID
    ) async throws -> AnthologyNarrationStatus?
}
```

- `nil` status means an ordinary book.
- Existing excluded/hidden narration chapters remain excluded from the denominator and export, matching current Echo behavior.
- Extend `NarrationCacheSource` and `ExportSourceResolver.resolve` with `preferredVoice: VoiceID`. `NarrationCacheSource` loads visible blocks through `EPubBlockDAO`; callers must pass the same resolved preference used by narration. Imported-book resolution ignores the value.

### Steps

- [ ] Add status tests for `0/M`, partial, stale, complete, reorder, removed chapter, and ordinary-book nil. A current chapter requires the exact stable track ID, exact current file path, effective voice, current render version, and on-disk durable file.

- [ ] Add export tests that persist stable tracks in old order, then change their `sort_order`. Assert export follows current `sort_order`, emits one chapter marker for the first segment of each chapter, and does not synthesize or require renamed files.

- [ ] Add failing tests proving anthology export rejects one missing chapter and ignores orphaned legacy/old-voice files instead of selecting a glob fallback.

- [ ] Run focused tests and confirm failure.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationStatusServiceTests
make test-only FILTER=EchoTests/NarrationExportOrderingTests
```

- [ ] Implement status by resolving the validated manifest and shared render plan, then comparing the plan to reachable `TrackRecord` rows and disk files. Return only bounded stable keys in internal status; presentation uses display numbers.

- [ ] Change `NarrationCacheSource.items()` so a valid anthology uses persisted current tracks as the primary inventory. Order by current `sort_order`, group segments by stable chapter token, and derive marker titles from current render plans. If any chapter is incomplete, throw `.incomplete(chapterDisplayNumbers:)`.

- [ ] Keep the existing filename-glob/dedup path unchanged when there is no matching anthology receipt. Do not silently fall back to it after an anthology match fails validation or readiness.

- [ ] Thread the preferred voice through audio and video export entry points on iOS and macOS. Resolve an empty settings value to `VoiceCatalog.default.id` once at each UI boundary; do not let export independently guess a different default.

- [ ] Ensure reorder causes M4B recomposition and recomputation of absolute offsets even though all source audio files are reused.

- [ ] Run focused and adjacent tests.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationStatusServiceTests
make test-only FILTER=EchoTests/NarrationExportOrderingTests
make test-only FILTER=EchoTests/VideoExportServiceTests
```

Expected: all suites pass.

- [ ] Commit.

```bash
git add EchoCore/Services/Narration/AnthologyNarrationStatusService.swift \
  EchoCore/Services/Export/NarrationCacheSource.swift \
  EchoCore/Services/Export/ExportSourceResolver.swift \
  EchoCore/Views/ExportProgressView.swift \
  EchoCore/Views/VideoExportProgressView.swift \
  EchoCore/Services/Export/VideoExportService.swift \
  'Echo macOS/Views/MacAudioExportView.swift' \
  'Echo macOS/Views/MacVideoExportView.swift' \
  EchoTests/ArticleWorkshop/AnthologyNarrationStatusServiceTests.swift \
  EchoTests/NarrationExportOrderingTests.swift \
  EchoTests/VideoExportServiceTests.swift
git commit -m "feat(export): require current anthology narration plans"
```

---

## Task 7: Finish iPhone/iPad and macOS Voice Editing UI

**Files:**

- Modify: `EchoCore/Views/ArticleWorkshop/AnthologyBuilderView.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift`
- Create: `Echo macOS/Views/MacAnthologyVoiceEditor.swift`
- Modify: `Echo macOS/Views/MacArticleWorkshopView.swift`
- Modify: `EchoCore/Localizable.xcstrings`
- Test: `EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift`
- Test: `EchoTests/MacReaderParityTests.swift`

**Interfaces:**

- iPhone/iPad continues saving through `AnthologyBuilderViewModel.updateEntry(id:chapterTitleOverride:narrationVoiceID:)`.
- Mac editor consumes `AnthologyProject`, `AnthologyService`, and preferred `VoiceID`; it uses the existing `AnthologyBuilderViewModel` rather than a second persistence model.
- Add this focused view contract:

```swift
struct MacAnthologyVoiceEditor: View {
    @State var viewModel: AnthologyBuilderViewModel
    let preferredVoice: VoiceID
}
```

### Steps

- [ ] Update source/UI policy tests to require the inherited label **Echo Preferred Voice**, explanatory help text, and a localized accessible value that distinguishes inheritance from an explicit selection.

- [ ] Add Mac parity assertions for an **Edit Voices** action, a chapter row picker, and use of `AnthologyBuilderViewModel.updateEntry`.

- [ ] Run focused tests and confirm failure.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyBuilderViewModelTests
make test-only FILTER=EchoTests/MacReaderParityTests
```

- [ ] Rename the existing iPhone/iPad **Project Default** option to **Echo Preferred Voice**. Add the approved help copy:

```text
Uses your current Echo narration voice. Changing that preference updates inherited chapters the next time they are narrated.
```

- [ ] Show `Default voice: {display name} · {N} chapter overrides` in the existing narration summary area when `narrationVoiceOverrideCount > 0`; omit the suffix when the count is zero. Use `PlaybackState.narrationDefaultVoice` and `narrationVoiceOverrideCount`, not a second manifest query in the view.

- [ ] Store the existing `AnthologyService` in `MacArticleWorkshopView`. Add **Edit Voices** beside each anthology, asynchronously load its project, and present `MacAnthologyVoiceEditor` in a sheet.

- [ ] In the Mac sheet, show each chapter title, current effective voice, and a picker whose first choice stores nil. Invoke `viewModel.updateEntry` immediately, retain keyboard focus, disable only the row being saved through existing view-model state, and display `userMessage` without dismissing the sheet.

- [ ] Add accessibility identifiers and localized strings for the inherited choice, help, override summary, Mac edit action, readiness labels, and rebuild-oriented errors. Verify the inherited choice has a text value and does not rely on color.

- [ ] Run focused tests.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyBuilderViewModelTests
make test-only FILTER=EchoTests/MacReaderParityTests
```

Expected: both suites pass.

- [ ] Commit.

```bash
git add EchoCore/Views/ArticleWorkshop/AnthologyBuilderView.swift \
  EchoCore/Views/NowPlayingTab.swift \
  'Echo macOS/Views/MacAnthologyVoiceEditor.swift' \
  'Echo macOS/Views/MacArticleWorkshopView.swift' \
  EchoCore/Localizable.xcstrings \
  EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift \
  EchoTests/MacReaderParityTests.swift
git commit -m "feat(article-workshop): edit anthology chapter voices on all platforms"
```

---

## Task 8: Add the Three-Voice Integration Fixture and Regression Gate

**Files:**

- Create: `EchoTests/ArticleWorkshop/AnthologyChapterVoicesIntegrationTests.swift`
- Create: `EchoTests/ArticleWorkshop/Fixtures/three-voice-anthology-manifest.json`
- Modify: `CHANGELOG.md`

**Fixture contract:**

- Chapter 1 has `voiceID: nil` and inherits the test preferred voice.
- Chapter 2 explicitly uses `bf_emma`.
- Chapter 3 explicitly uses a third existing `VoiceCatalog` voice.
- Text is synthetic, short, and non-private.
- Every imported block carries its matching manifest entry UUID as `sourceChapterKey`.

### Steps

- [ ] Add an integration test using the existing fake TTS engine and temporary database/cache. Render all three chapters and assert persisted `TrackRecord.narrationVoice` values match the effective plan.

- [ ] Re-run with only chapter 2's voice changed. Assert the fake engine receives calls only for chapter 2 and the other two stable file URLs remain unchanged.

- [ ] Reorder chapters 3, 1, 2. Assert the fake engine receives zero calls, stable file URLs remain unchanged, track `sort_order` values change, resume follows the stable last track, and export emits markers in 3, 1, 2 order.

- [ ] Change only chapter 1's preferred voice. Assert chapter 1 re-renders and explicit chapters 2 and 3 remain current.

- [ ] Corrupt the receipt digest. Assert the operation throws before cleanup, all proven audio remains on disk, and the fake TTS engine receives zero calls.

- [ ] Run the integration suite.

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyChapterVoicesIntegrationTests
```

Expected: pass with synthesis-call counts `3`, `1`, `0`, `1`, `0` across the five scenarios.

- [ ] Add a concise changelog entry describing inherited chapter voices, explicit overrides, Mac editing, and stable reorder reuse. Do not claim real-device or human listening acceptance.

- [ ] Run the complete unit-test gate.

```bash
make test
```

Expected: exit 0 with all non-UI Echo tests passing.

- [ ] Build the affected app targets without signing.

```bash
xcodebuild build -project Echo.xcodeproj -scheme Echo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Echo.xcodeproj -scheme 'Echo macOS' \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: both commands exit 0. Record failures separately from unit-test state.

- [ ] Commit.

```bash
git add EchoTests/ArticleWorkshop/AnthologyChapterVoicesIntegrationTests.swift \
  EchoTests/ArticleWorkshop/Fixtures/three-voice-anthology-manifest.json \
  CHANGELOG.md
git commit -m "test(narration): cover three-voice anthology workflow"
```

---

## Task 9: Real Render Acceptance and Publication

**Files:**

- No committed private audio, EPUB, transcript, or captured article content.
- Update only task-owned test documentation if a verified command or fixture path changed during implementation.

### Steps

- [ ] In a disposable local test directory, build/import a synthetic three-chapter anthology using the fixture's public text. Set chapter 1 to inherit, chapter 2 to `bf_emma`, and chapter 3 to the fixture's third voice.

- [ ] Produce one real render through the app path. Record mechanical evidence separately:
  - the three persisted track voice IDs;
  - durable file existence and current render version;
  - no partial files after completion;
  - current sort order and chapter marker order;
  - read-along anchors joined to each stable chapter.

- [ ] Change only chapter 2's override and rebuild. Verify only chapter 2 obtains a new file/track voice and synthesis activity.

- [ ] Reorder all chapters and rebuild. Verify zero synthesis activity, unchanged stable audio file URLs, updated track order, recomposed M4B marker order, and recomputed absolute sidecar offsets.

- [ ] Listen to all three chapter openings and transitions. Report this as human acceptance only if actually heard; mechanical voice IDs and waveforms are not a listening verdict.

- [ ] Remove the disposable local fixture output. Do not commit generated audio or private workshop state.

- [ ] Inspect the final branch and changes.

```bash
git status --short --branch
git diff --check origin/nightly...HEAD
git log --oneline origin/nightly..HEAD
```

Expected: clean task worktree, no whitespace errors, coherent task-only commits.

- [ ] Push the feature branch and open a ready PR to `nightly`.

```bash
git push -u origin codex/anthology-chapter-voices-design
gh pr create --base nightly --head codex/anthology-chapter-voices-design \
  --title "feat: narrate anthology chapters with selected voices" \
  --body-file .github/pull_request_template.md
```

If the repository template requires filled sections rather than direct reuse, prepare a task-owned temporary PR body outside the repository, populate its required fields with the actual test/build/acceptance states, and pass that path to `--body-file`.

- [ ] Report hosted CI as passing, failing, pending, or blocked. Report PR creation, CI, merge, installation, device acceptance, and human listening acceptance as separate states.

## Final Acceptance Checklist

- [ ] Clearing a chapter choice stores nil and follows Echo's current preferred voice.
- [ ] Explicit chapter choices survive preferred-voice changes.
- [ ] iOS/iPadOS playback and macOS batch narration use the same effective plan.
- [ ] QA and pronunciation repair retain the target chapter's effective voice.
- [ ] Reorder causes zero synthesis calls for unchanged chapters.
- [ ] One voice/text/title/policy change invalidates only the affected chapter.
- [ ] Mixed-voice cleanup preserves every expected current file.
- [ ] Resume maps stable identity to current position.
- [ ] Readiness and export reject missing or stale anthology chapters.
- [ ] M4B order and absolute offsets are recomputed after reorder.
- [ ] Ordinary EPUB/PDF narration remains on legacy identity and behavior.
- [ ] No database migration, third-party dependency, private content, or generated audio was committed.
- [ ] Focused tests, `make test`, iOS build, macOS build, real render, and human listening each have truthful recorded states.
