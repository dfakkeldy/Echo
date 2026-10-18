# Character-Level Multi-Voice Narration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit source-bound block voice plans to `echo-cli narrate` while preserving one chaptered M4B, the normal alignment sidecar, exact timing, resumability, pronunciation evidence, and legacy uniform/chapter narration.

**Architecture:** Decode a strict authored JSON document, resolve it against imported planned EPUB chapters into a canonical complete block map, and pass a block-to-voice closure through the existing chapter renderer. Plan runs use capture schema 2 and pronunciation-audit schema 7; legacy runs retain their existing identity and schemas.

**Tech Stack:** Swift 6, Foundation, ArgumentParser, Swift Testing, CryptoKit, AVFoundation, existing Echo narration services.

## Global Constraints

- Preserve deployment floors: iOS 18, macOS 15, watchOS 11.
- Keep expensive media, database, and transcript work off the UI actor.
- Introduce no third-party dependency.
- Validate the complete voice plan before fresh-run artifact cleanup.
- Select one voice per original EPUB block and use it for all synthesis chunks in that block.
- Create no per-speaker or per-block audio files.
- Preserve the normal alignment-sidecar and word-timing schemas.
- Preserve current uniform and `--chapter-voice` behavior.
- Run every Apple build/test command through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh --`.

## File Map

- Create `EchoCore/Services/Narration/BlockVoicePlan.swift`: strict document decoding, resolution, canonical identity, lookup, and chapter digest.
- Create `EchoTests/BlockVoicePlanTests.swift`: contract and validation tests.
- Modify `Tools/echo-cli/NarrateCommand.swift`: optional `--voice`, new `--voice-plan`, and option compatibility checks.
- Create `Tools/echo-cli/ResolveVoicePlanCommand.swift`: read-only canonical plan resolution for governed preflight.
- Modify `Tools/echo-cli/EchoCLI.swift`: register `resolve-voice-plan`.
- Create `EchoTests/ResolveVoicePlanCommandTests.swift`: resolver stdout,
  failure, and write-containment tests.
- Modify `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`: resolve plans, derive default/block voices, schema-2 capture identity, filename token, resume validation, and audit inputs.
- Modify `EchoCore/Services/Narration/NarrationService.swift`: accept and apply a block voice closure.
- Modify `EchoCore/Services/Narration/NarrationFileNaming.swift`: allow a stable voice-or-plan cache token.
- Modify `EchoCore/Services/Narration/PronunciationAudit.swift`: schema-7 plan provenance while retaining schema 6 for legacy calls.
- Modify `EchoCore/Services/Narration/PronunciationListeningReel.swift`: forward plan audit provenance.
- Modify `EchoTests/HeadlessNarrationRunnerTests.swift`: plan resolution, capture invalidation/resume, sidecar, and end-to-end assertions.
- Modify `EchoTests/HeadlessNarrationRunnerParallelTests.swift`: mixed block voices under parallel rendering.
- Modify `EchoTests/PronunciationAuditTests.swift`: schema-7 encoding and validation.
- Modify `EchoTests/NarrationServiceTests.swift`: per-block synthesis voice and timing assertions.

---

### Task 1: Strict Voice-Plan Decoding and Resolution

**Files:**
- Create: `EchoCore/Services/Narration/BlockVoicePlan.swift`
- Create: `EchoTests/BlockVoicePlanTests.swift`

**Interfaces:**
- Consumes: `VoiceID`, `VoiceCatalog.voice(for:)`, `PlannedNarrationChapter.blocks`, `EPubBlockRecord.id`, `EPubBlockRecord.sequenceIndex`, and `AlignmentSidecar.portableSuffix(from:)`.
- Produces: `BlockVoicePlanDocument`, `ResolvedBlockVoice`, `ResolvedBlockVoicePlan`, `BlockVoicePlanError`, `BlockVoicePlanLoader.decode(data:)`, and `BlockVoicePlanLoader.resolve(document:sourceEPUBSHA256:chapters:)` with the exact signatures in the approved design spec.

- [ ] **Step 1: Write decoding and happy-path resolution tests**

Add tests that decode the design-spec example, resolve explicit blocks plus an inclusive range, prove unassigned blocks use `narrator`, and prove equivalent reordered JSON resolves to the same `voicePlanSHA256` and `voicePlanID`.

```swift
@Test func resolvesBlocksRangesAndDefaultSpeaker() throws {
    let document = try BlockVoicePlanLoader.decode(data: fixturePlanData)
    let resolved = try BlockVoicePlanLoader.resolve(
        document: document,
        sourceEPUBSHA256: fixtureSourceSHA,
        chapters: fixtureChapters)
    #expect(resolved.voice(forBlockID: "s2-b3") == VoiceID("bf_emma"))
    #expect(resolved.voice(forBlockID: "s2-b8") == VoiceID("am_fenrir"))
    #expect(resolved.voice(forBlockID: "s2-b10") == VoiceID("am_fenrir"))
    #expect(resolved.voice(forBlockID: "s0-b0") == VoiceID("am_michael"))
    #expect(resolved.voicePlanID == "plan-" + resolved.voicePlanSHA256.prefix(12))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/BlockVoicePlanTests
```

Expected: compile failure because `BlockVoicePlanLoader` and related types do not exist.

- [ ] **Step 3: Implement strict decoding and canonical resolution**

Implement the approved schema with explicit `CodingKeys`, a duplicate-key JSON preflight, and these exact errors:

```swift
nonisolated enum BlockVoicePlanError: LocalizedError, Equatable {
    case malformedJSON(String)
    case duplicateJSONKey(String)
    case unsupportedSchema(Int)
    case unknownField(String)
    case invalidSourceSHA256(String)
    case sourceMismatch(expected: String, actual: String)
    case invalidSpeakerID(String)
    case duplicateSpeaker(String)
    case missingDefaultSpeaker(String)
    case unknownVoice(String)
    case invalidBlockID(String)
    case missingBlock(String)
    case nonNarratableBlock(String)
    case duplicateAssignment(String)
    case invalidRange(start: String, end: String)
    case crossChapterRange(start: String, end: String)
}
```

Canonicalize the fully expanded `[ResolvedBlockVoice]` in imported chapter/block order with sorted-key compact JSON and hash it with CryptoKit SHA-256. Retain dictionaries for total voice/speaker lookup. Lookup must precondition that resolution included the requested speakable block rather than inventing a fallback after validation.

- [ ] **Step 4: Add every rejection test from the contract**

Use parameterized tests for unsupported schema, unknown/duplicate keys, malformed SHA, source mismatch, invalid/duplicate/missing-default speakers, unknown voice, malformed/missing/non-narratable block, empty `blocks`, both assignment forms, duplicate/overlapping assignment, reversed range, and cross-chapter range. Assert the exact `BlockVoicePlanError` case.

- [ ] **Step 5: Run the focused tests and verify GREEN**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/BlockVoicePlanTests
```

Expected: `BlockVoicePlanTests` passes with no warnings.

- [ ] **Step 6: Commit the resolved plan model**

```sh
git add EchoCore/Services/Narration/BlockVoicePlan.swift EchoTests/BlockVoicePlanTests.swift
git commit -m "feat(narration): add block voice plan contract"
```

### Task 2: CLI Contract and Fail-Closed Configuration

**Files:**
- Modify: `Tools/echo-cli/NarrateCommand.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Test: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Test: `EchoTests/ResolveVoicePlanCommandTests.swift`

**Interfaces:**
- Consumes: Task 1's `BlockVoicePlanLoader` and plan types.
- Produces: `NarrationRunConfig.voice: VoiceID?`, `NarrationRunConfig.voicePlanURL: URL?`, and `NarrateCommand` option validation for `--voice-plan`.
- Produces: `ResolveVoicePlanCommand`, whose stdout is the exact compact sorted-key identity object in the design spec.

- [ ] **Step 1: Write configuration and validation tests**

Add runner tests proving a plan URL is accepted with `voice == nil`, no-plan `voice == nil` resolves to `VoiceCatalog.defaultVoice`, plan plus chapter overrides fails, plan plus a conflicting explicit voice fails, and plan with PDF/directory source fails before `clearExistingCapturesBeforeRun` removes a seeded marker.

```swift
let config = NarrationRunConfig(
    epubURL: fixtureEPUB,
    outM4BURL: output,
    sidecarURL: sidecar,
    workDir: work,
    voice: nil,
    voicePlanURL: planURL,
    chapterVoicesByDisplayNumber: [:],
    title: "Fixture",
    author: "Echo")
```

- [ ] **Step 2: Run the runner suite and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Expected: compile failure because `voicePlanURL` is not a configuration member and `voice` is not optional.

- [ ] **Step 3: Add CLI options without command-layer destructive cleanup**

```swift
@Option(help: "Kokoro voice id. Defaults to af_heart unless --voice-plan supplies the default.")
var voice: String?

@Option(name: .customLong("voice-plan"), help: "Source-bound block voice-plan JSON file.")
var voicePlan: String?
```

Pass `voice.map(VoiceID.init)` and `voicePlan.map { URL(fileURLWithPath: $0) }` into the config. Move fresh-render deletion out of `NarrateCommand`; the runner's post-validation cleanup owns deletion. Reject plan/chapter coexistence, plan/PDF-or-directory input, and explicit-default mismatch through `NarrationRunError.voicePlan(String)`.

- [ ] **Step 4: Resolve plans before cleanup**

For a plan-backed EPUB file, compute the exact raw SHA-256, decode the plan, import and plan chapters, resolve it, then execute fresh cleanup. For no-plan runs derive:

```swift
let legacyDefaultVoice = config.voice ?? VoiceCatalog.defaultVoice
```

Keep current chapter-assignment validation unchanged on the legacy branch.
Before cleanup, resolve every distinct planned voice with
`NarrationResources.url(forResource: voice.rawValue, withExtension: "f32")`
and the corresponding `"rows"` resource; report a missing resource through
`NarrationRunError.voicePlan(String)`.

- [ ] **Step 5: Add the read-only resolver command**

Add `ResolveVoicePlanCommand` with required `--epub` and `--voice-plan` options.
It must call a shared runner helper that imports EPUB blocks and invokes Task
1's resolver without opening a database or creating a work directory. Register
it in `EchoCLI.configuration.subcommands`. Add command-level tests for valid
JSON stdout, invalid source/plan exit status, and absence of created files.

- [ ] **Step 6: Run focused tests and build the CLI**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

Expected: runner tests pass, `echo-cli narrate --help` includes `--voice-plan`,
and `echo-cli resolve-voice-plan --help` includes the two required file options.

- [ ] **Step 7: Commit CLI and configuration wiring**

```sh
git add Tools/echo-cli/NarrateCommand.swift Tools/echo-cli/ResolveVoicePlanCommand.swift Tools/echo-cli/EchoCLI.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/HeadlessNarrationRunnerTests.swift EchoTests/ResolveVoicePlanCommandTests.swift
git commit -m "feat(cli): accept source-bound voice plans"
```

### Task 3: Render One Voice Per Original Block

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Test: `EchoTests/NarrationServiceTests.swift`
- Test: `EchoTests/HeadlessNarrationRunnerParallelTests.swift`

**Interfaces:**
- Consumes: resolved plan lookup from Task 1 and run resolution from Task 2.
- Produces: an added `blockVoice: @escaping @Sendable (String) -> VoiceID`
  parameter on both existing `NarrationService.renderChapter` overloads; every
  other existing parameter and return type remains unchanged.

- [ ] **Step 1: Write a synthesis-call ordering test**

Extend the recording TTS test engine to append `(text, voice)` values. Render a chapter where `s0-b0` expands to two chunks with `am_michael` and `s0-b1` uses `bf_emma`; assert both first-block chunks use `am_michael`, the next uses `bf_emma`, one anchor is emitted per original block, and words remain monotonic.

```swift
#expect(engine.calls.map(\.voice) == [
    VoiceID("am_michael"), VoiceID("am_michael"), VoiceID("bf_emma")
])
#expect(rendered.anchors.map(\.blockID) == ["s0-b0", "s0-b1"])
```

- [ ] **Step 2: Run the service test and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: compile failure because `renderChapter` does not accept `blockVoice`.

- [ ] **Step 3: Thread the closure through the render path**

Resolve once outside the synthesis-chunk loop:

```swift
let voice = blockVoice(plannedBlock.blockID)
for chunk in plannedBlock.synthesisChunks {
    let pcm = try await engine.synthesize(chunk.text, voice: voice)
    // retain the existing sample append, evidence, and word-timing operations
}
```

Legacy runner calls pass `{ _ in chapterVoice }`; plan calls pass `{ resolvedPlan.voice(forBlockID: $0) }`. Do not create another audio segment or protocol layer.

- [ ] **Step 4: Add a parallel mixed-voice runner test**

Render two chapters with the existing parallel recording factory and assert collected `(blockID, voiceID)` pairs match the resolved plan regardless of worker completion order. Assert `workDir` contains only chapter M4As and markers, with no per-speaker filename.

- [ ] **Step 5: Run service and parallel suites**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerParallelTests
```

Expected: both suites pass; anchor count and timing assertions are unchanged by voice switches.

- [ ] **Step 6: Commit block-level rendering**

```sh
git add EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/NarrationServiceTests.swift EchoTests/HeadlessNarrationRunnerParallelTests.swift
git commit -m "feat(narration): select Kokoro voice per EPUB block"
```

### Task 4: Plan-Aware Cache and Capture Identity

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Test: `EchoTests/HeadlessNarrationRunnerTests.swift`

**Interfaces:**
- Consumes: `ResolvedBlockVoicePlan.voicePlanID`, `.voicePlanSHA256`, and `.chapterDigest(blockIDs:)`.
- Produces: capture identity schema 2 fields `voicePlanSHA256: String?` and `chapterVoicePlanSHA256: String?`; legacy schema 1 encodes both as absent.

- [ ] **Step 1: Write resume identity tests**

Cover: identical interrupted plan resumes; reordered equivalent JSON resumes; changed speaker voice, default voice, explicit block, or range invalidates; plan capture cannot resume as legacy and legacy cannot resume as plan.

```swift
#expect(identity.schemaVersion == 2)
#expect(identity.voicePlanSHA256 == resolved.voicePlanSHA256)
#expect(identity.chapterVoicePlanSHA256 == resolved.chapterDigest(blockIDs: chapterBlockIDs))
#expect(identity.audioFileName.contains(resolved.voicePlanID))
```

- [ ] **Step 2: Run resume tests and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Expected: plan marker assertions fail because capture identity remains schema 1.

- [ ] **Step 3: Generalize filename identity token**

Change chapter naming to accept `renderIdentityToken: String`, supplied as the legacy voice raw value or resolved `voicePlanID`. Sanitize with current voice-token rules. No-plan filenames must remain unchanged.

- [ ] **Step 4: Materialize and validate schema-2 captures**

Make both new fields optional for backward decoding and enforce:

```swift
switch identity.schemaVersion {
case 1:
    guard expectedPlan == nil,
          identity.voicePlanSHA256 == nil,
          identity.chapterVoicePlanSHA256 == nil else { reject() }
case 2:
    guard let expectedPlan,
          identity.voicePlanSHA256 == expectedPlan.voicePlanSHA256,
          identity.chapterVoicePlanSHA256 == expectedChapterDigest else { reject() }
default:
    reject()
}
```

Include full plan hash and ordered chapter digests in `captureSetID`. Retain source, renderer, content, audio-byte/hash, marker-hash, and pronunciation-evidence checks.

- [ ] **Step 5: Run focused and legacy resume tests**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Expected: all plan and pre-existing chapter-plan resume cases pass.

- [ ] **Step 6: Commit capture identity**

```sh
git add EchoCore/Services/Narration/NarrationFileNaming.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/HeadlessNarrationRunnerTests.swift
git commit -m "feat(narration): bind captures to block voice plans"
```

### Task 5: Plan-Aware Pronunciation Audit

**Files:**
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Test: `EchoTests/PronunciationAuditTests.swift`

**Interfaces:**
- Consumes: resolved plan hash and ordered block map.
- Produces: schema-7 fields `voicePlanSHA256: String?` and `blockVoices: [String: String]?`; legacy manifests keep schema 6 with both absent.

- [ ] **Step 1: Write schema-7 construction and validation tests**

Assert schema 7, `voice == "mixed"`, empty `chapterVoices`, exact plan hash, sorted complete block map, and unchanged audiobook/reel hashes. Add rejection tests for missing/extra block entries, unknown voices, invalid plan hash, and a decision whose block ID is absent.

```swift
#expect(manifest.schemaVersion == 7)
#expect(manifest.voicePlanSHA256 == resolved.voicePlanSHA256)
#expect(manifest.blockVoices == ["s0-b0": "am_michael", "s0-b1": "bf_emma"])
```

- [ ] **Step 2: Run audit tests and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAuditTests
```

Expected: compile failure because plan audit fields do not exist.

- [ ] **Step 3: Add schema-dependent audit encoding**

```swift
nonisolated struct PronunciationBlockVoiceProvenance: Equatable, Sendable {
    let voicePlanSHA256: String
    let blockVoices: [String: VoiceID]
}
```

Add optional manifest properties so schemas 2–6 still decode. Nil provenance constructs schema 6 exactly. Non-nil emits schema 7, derives the top-level voice from distinct mapped voices, requires empty `chapterVoices`, and validates decision coverage. Forward optional provenance through the listening-reel request without changing reel timing.

- [ ] **Step 4: Wire runner provenance**

Build `blockVoices` from every resolved block. Keep speaker IDs out of the audit because the plan hash binds them. Pass nil on legacy runs.

- [ ] **Step 5: Run audit and runner tests**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAuditTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Expected: schema-7 tests pass and schema-6 fixture tests remain unchanged.

- [ ] **Step 6: Commit audit provenance**

```sh
git add EchoCore/Services/Narration/PronunciationAudit.swift EchoCore/Services/Narration/PronunciationListeningReel.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/PronunciationAuditTests.swift EchoTests/HeadlessNarrationRunnerTests.swift
git commit -m "feat(narration): audit block voice provenance"
```

### Task 6: End-to-End Artifact and Timing Acceptance

**Files:**
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerParallelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: executable acceptance proof for one M4B, normal sidecar, internal captures, timing, resume, and compatibility.

- [ ] **Step 1: Add a two-chapter end-to-end fixture test**

Render a small EPUB whose plan alternates narrator, POV, and dialogue voices. Assert completion, two M4B chapters, one output `.m4b`, one normal sidecar, strictly increasing anchors and word timing, and no output filename containing speaker or voice IDs. List `workDir` and permit only chapter M4As and marker/state files.

```swift
#expect(result.complete)
#expect(result.chapters == 2)
#expect(FileManager.default.fileExists(atPath: output.path))
#expect(FileManager.default.fileExists(atPath: sidecar.path))
#expect(try M4BParser.chapterCount(at: output) == 2)
```

- [ ] **Step 2: Run end-to-end test and verify RED**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Expected: the new artifact or timing assertion fails until all plan paths reuse the chapter stream and final exporter.

- [ ] **Step 3: Make only corrections exposed by acceptance**

Route plan chapters through the existing `AudioExportService` item list and `assembleSidecar`. Do not add a second export or sidecar schema. Keep pronunciation review separate from required M4B completion.

- [ ] **Step 4: Run the complete Echo gate**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
git diff --check
```

Expected: all tests pass, the release CLI builds, and `git diff --check` prints nothing.

- [ ] **Step 5: Commit end-to-end acceptance**

```sh
git add EchoTests/HeadlessNarrationRunnerTests.swift EchoTests/HeadlessNarrationRunnerParallelTests.swift EchoCore/Services/Narration
git commit -m "test(narration): verify mixed-voice artifact integrity"
```

### Task 7: Final Compatibility Review and Handoff

**Files:**
- Modify only files already changed if verification exposes a defect.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a clean Echo branch ready for the Explainer Audiobooks implementation.

- [ ] **Step 1: Inspect compatibility-sensitive diffs**

```sh
git diff nightly HEAD -- Tools/echo-cli/NarrateCommand.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoCore/Services/Narration/PronunciationAudit.swift
```

Confirm no-plan commands still default to `af_heart`, chapter mappings retain legacy precedence, schema-1 captures remain legacy-only, and schema-6 audits remain byte-compatible where fixtures assert it.

- [ ] **Step 2: Run the final gate from a clean process**

```sh
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
git status --short --branch
```

Expected: tests and CLI build pass; status lists only committed branch state.

- [ ] **Step 3: Record the downstream contract**

Capture `echo-cli narrate --help`, one schema-2 marker, and one schema-7 audit from test fixtures. Give their exact shapes to the Explainer Audiobooks implementer without committing generated audio or private book data.

- [ ] **Step 4: Stop before publication**

Do not push or open a PR until the Explainer Audiobooks plan is implemented and GPT-5.6-sol review accepts both repositories.
