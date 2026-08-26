# Planned Pronunciation TTS Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task, with a fresh implementation agent and a fresh review agent for each independent slice.

**Goal:** Make Echo carry an approved, immutable pronunciation plan all the way into Kokoro synthesis, then prove the production headless narration path renders the approved pronunciations for `startable`, `filesystem`, `verified`, `live`, `lives`, and `record`.

**Architecture:** Resolve occurrence, book/global, and contextual rules once on the full normalized block. Split only after that resolution. Each resulting `PlannedSynthesisChunk` stores plain display text, resolved Misaki-link input, phonemes, strict BOS/EOS-wrapped token IDs, word count, and fallback evidence. `NarrationService` passes that plan through the `TTSEngine` existential. `OnnxKokoroEngine` consumes the supplied IDs for both waveform and duration inference and never re-runs G2P for a planned request. Speed nudges remain engine-local; any text split happens in the service using the already-resolved fragment.

**Tech Stack:** Swift 6.0, Swift Testing, Swift concurrency/actors, MisakiSwift/Kokoro G2P, ONNX Runtime, Xcode 26.6, iOS 18/macOS 15 targets, Echo's Release `echo-cli`, FFmpeg/ffprobe/afinfo for rendered-audio inspection.

## Global Constraints

- Work only in `/Users/dfakkeldy/.codex/worktrees/pronunciation-planned-tts/Echo` on `codex/pronunciation-planned-tts-slice`.
- Preserve the unrelated dirty changes in the original and main Echo worktrees.
- Add no dependency, network pronunciation service, private book fixture, or model artifact.
- Keep rule precedence: occurrence override > per-book/global override > contextual homograph rule > ordinary G2P.
- Never run contextual rules again after a fragment has been resolved into Misaki links.
- Reject unsupported planned phoneme characters; do not silently drop them.
- Use `PlannedSynthesisChunk.phonemeIDs` unchanged for waveform and duration inference.
- Run every Xcode build/test through `$HOME/.claude/bin/xcode-build-gate.sh --wait`, with `-parallel-testing-enabled NO -jobs 5`.
- Keep rendered media outside Git. Commit only compact verification evidence and checksums.

## Task 1: Add Strict Immutable Pronunciation Plans

**Files:**

- Create: `EchoCore/Services/Narration/PlannedSynthesisChunk.swift`
- Create: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/KokoroPhonemeVocab.swift`
- Modify: `EchoTests/KokoroPhonemeVocabTests.swift`
- Create: `EchoTests/PronunciationPlannerTests.swift`

### Step 1: Write failing strict-vocab tests

Replace the existing silent-drop expectation and add explicit validation:

```swift
@Test func legacyMappingCanStillDropUnknownCharacters() throws {
    let vocab = try KokoroPhonemeVocab()
    #expect(vocab.ids(forPhonemes: " .\u{0000}") == [0, 16, 4, 0])
}

@Test func plannedMappingRejectsUnknownCharacters() throws {
    let vocab = try KokoroPhonemeVocab()
    #expect(throws: KokoroPhonemeVocab.EncodingError.unsupportedCharacters("\u{0000}")) {
        try vocab.validatedIDs(forPhonemes: "hɛ\u{0000}loʊ")
    }
}
```

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/KokoroPhonemeVocabTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: fail because `EncodingError` and `validatedIDs` do not exist.

### Step 2: Implement strict vocab validation

Add an equatable error and a strict sibling to the legacy compatibility API:

```swift
nonisolated struct KokoroPhonemeVocab {
    enum EncodingError: Error, Equatable {
        case unsupportedCharacters(String)
    }

    func validatedIDs(forPhonemes phonemes: String) throws -> [Int32] {
        let unsupported = phonemes.filter { charToId[$0] == nil }
        guard unsupported.isEmpty else {
            throw EncodingError.unsupportedCharacters(String(unsupported))
        }
        return [Self.boundaryTokenId]
            + phonemes.compactMap { charToId[$0] }
            + [Self.boundaryTokenId]
    }
}
```

Keep `ids(forPhonemes:)` for compatibility callers, but update its documentation to state that production planned synthesis uses the validated API.

### Step 3: Write failing plan tests

Create tests that use the bundled resources:

```swift
@Suite struct PronunciationPlannerTests {
    @Test func planCapturesExactResolvedInputsAndFallbackEvidence() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The filesystem works.",
            g2pInputText: "The [filesystem](/fˈIl sˌɪstəm/) works."
        )
        #expect(plan.displayText == "The filesystem works.")
        #expect(plan.g2pInputText == "The [filesystem](/fˈIl sˌɪstəm/) works.")
        #expect(plan.phonemes.contains("fˈIl sˌɪstəm"))
        #expect(plan.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.wordCount == 3)
        #expect(plan.pronunciationFallbackHits.isEmpty)
    }

    @Test func verifiedUsesOrdinaryLexiconWithoutFallback() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The result was verified.",
            g2pInputText: "The result was verified."
        )
        #expect(plan.phonemes.contains("vˈɛɹəfˌId"))
        #expect(plan.pronunciationFallbackHits.allSatisfy { $0.word.lowercased() != "verified" })
    }
}
```

Run the new suite. Expected: fail because the two production types do not exist.

### Step 4: Implement the immutable carrier and planner

Create:

```swift
nonisolated struct PlannedSynthesisChunk: Equatable, Sendable {
    let displayText: String
    let g2pInputText: String
    let phonemes: String
    let phonemeIDs: [Int32]
    let wordCount: Int
    let pronunciationFallbackHits: [PronunciationFallbackHit]
}
```

`PronunciationPlanner` owns one cached `KokoroG2P` and `KokoroPhonemeVocab`. Its `plan(displayText:g2pInputText:)` calls `g2p.result(for:)` exactly once, validates every emitted phoneme through `validatedIDs`, and derives `wordCount` from `displayText`. Task 1 deliberately requires the caller to supply both text forms so this checkpoint compiles before the markup parser exists.

### Step 5: Verify and commit

Run both suites and commit:

```bash
git add EchoCore/Services/Narration/PlannedSynthesisChunk.swift EchoCore/Services/Narration/PronunciationPlanner.swift EchoCore/Services/Narration/KokoroPhonemeVocab.swift EchoTests/KokoroPhonemeVocabTests.swift EchoTests/PronunciationPlannerTests.swift
git commit -m "feat(narration): add strict planned pronunciation chunks"
```

## Task 2: Split Resolved Text Without Breaking Pronunciation Links

**Files:**

- Create: `EchoCore/Services/Narration/MisakiPronunciationMarkup.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationTextChunker.swift`
- Modify: `EchoTests/PronunciationPlannerTests.swift`
- Modify: `EchoTests/NarrationTextChunkerTests.swift`
- Create: `EchoTests/MisakiPronunciationMarkupTests.swift`

### Step 1: Write failing markup and paired-split tests

Cover plain-text recovery, IPA spaces, multiple links, and punctuation:

```swift
@Test func displayTextRemovesOnlyValidMisakiMarkup() {
    #expect(
        MisakiPronunciationMarkup.displayText(
            from: "The [filesystem](/fˈIl sˌɪstəm/) is [live](/lˈIv/)."
        ) == "The filesystem is live."
    )
}

@Test func resolvedSplitKeepsIPASpacesInsideOneLink() {
    let source = "The [filesystem](/fˈIl sˌɪstəm/) stores the verified result."
    let pieces = NarrationTextChunker.splitResolved(source, maxPhonemes: 14) { text in
        text.count
    }
    #expect(pieces.count > 1)
    #expect(pieces.joined(separator: " ").contains("[filesystem](/fˈIl sˌɪstəm/)"))
    #expect(pieces.allSatisfy { !$0.contains("[filesystem](/fˈIl") || $0.contains("sˌɪstəm/)") })
}
```

Run the two suites. Expected: fail because the markup utility and `splitResolved` do not exist.

### Step 2: Implement a small link parser and atomic tokenizer

`MisakiPronunciationMarkup` must recognize only `[display](/ipa/)`, return the display text for valid links, and leave malformed editorial brackets untouched. Add a tokenizer in `NarrationTextChunker` that treats a whole valid link as one atomic word even when its IPA contains spaces. Reuse the existing sentence/clause boundary logic outside links. `splitResolved(_:maxPhonemes:phonemeCount:)` returns resolved strings; it never removes or re-applies links.

Add `PronunciationPlanner.planResolved(_:)`, which derives plain display text through `MisakiPronunciationMarkup.displayText(from:)` and then calls `plan(displayText:g2pInputText:)`. It accepts only already-resolved text and never applies override or homograph rules. Add a test proving a supplied `[record](/ɹəkˈɔɹd/)` link survives unchanged in `g2pInputText` while the display text is `record`.

### Step 3: Preserve legacy chunker coverage

Run all `NarrationTextChunkerTests` plus the new markup tests. Confirm the existing normalized-content, max-budget, decorative, and pronunciation-link cases still pass.

### Step 4: Commit

```bash
git add EchoCore/Services/Narration/MisakiPronunciationMarkup.swift EchoCore/Services/Narration/PronunciationPlanner.swift EchoCore/Services/Narration/NarrationTextChunker.swift EchoTests/MisakiPronunciationMarkupTests.swift EchoTests/PronunciationPlannerTests.swift EchoTests/NarrationTextChunkerTests.swift
git commit -m "fix(narration): keep resolved pronunciation links atomic"
```

## Task 3: Build Render Plans From Planned Synthesis Chunks

**Files:**

- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify callers that fail to compile only where the new throwing signature requires it.

### Step 1: Write failing render-plan assertions

Change `NarrationPlannedBlock.speechSegments` expectations to `synthesisChunks` and add precedence/context assertions:

```swift
@Test func resolvesFullBlockBeforePlanningChunks() throws {
    let overrides = PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"])
    let plan = try NarrationRenderPlanner.make(
        blocks: [block(id: "b0", text: "They live by the filesystem.", index: 0)],
        overrides: overrides,
        maxPhonemes: 420
    )
    let chunk = try #require(plan.blocks.first?.synthesisChunks.first)
    #expect(chunk.displayText == "They live by the filesystem.")
    #expect(chunk.g2pInputText.contains("[live](/lˈɪv/)"))
    #expect(chunk.g2pInputText.contains("[filesystem](/fˈIl sˌɪstəm/)"))
    #expect(chunk.phonemeIDs.count > 2)
}
```

Expected: fail on the old string-only render plan.

### Step 2: Convert the render-plan model

Change:

```swift
let synthesisChunks: [PlannedSynthesisChunk]
var isSpeakable: Bool { !synthesisChunks.isEmpty }
```

Make `NarrationRenderPlanner.make` throwing. For every full normalized block:

1. apply `PronunciationOverrides`;
2. apply `HomographPronunciationResolver` once;
3. call `splitResolved` using G2P phoneme counts;
4. call `PronunciationPlanner.planResolved` for each result.

Decorative blocks remain silence-only. Preserve trailing pause behavior. Tests may inject a planner only if deterministic resource loading requires it; production uses `PronunciationPlanner()`.

### Step 3: Verify and commit

Run `NarrationRenderPlanTests`, `PronunciationPlannerTests`, and `NarrationTextChunkerTests`, then commit:

```bash
git add EchoCore/Services/Narration/NarrationRenderPlan.swift EchoTests/NarrationRenderPlanTests.swift
git commit -m "refactor(narration): plan pronunciation before TTS"
```

## Task 4: Carry Planned Chunks Through the Engine Existential

**Files:**

- Modify: `EchoCore/Services/Narration/TTSEngine.swift`
- Modify: `EchoTests/Mocks/MockTTSEngine.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/NarrationServiceSynthesisTimingTests.swift` only if its mock implements the protocol directly.

### Step 1: Write a failing dynamic-dispatch integration test

Teach `MockTTSEngine` to record a `plannedCalls: [(chunk: PlannedSynthesisChunk, voice: VoiceID)]` array and write:

```swift
@Test func renderChapterDispatchesApprovedPlanThroughTTSEngine() async throws {
    let db = try DatabaseService(inMemory: ())
    let blocks = try seed(db, ["The filesystem stores the verified result."])
    let engine = MockTTSEngine(secondsPerChar: 0.01)
    let service = makeService(
        db, tts: engine, writer: MockAudioWriter(),
        overrides: { PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"]) }
    )

    try await service.renderChapter(
        chapterIndex: 0, blocks: blocks, voice: VoiceID("am_michael"))

    let call = try #require(engine.plannedCalls.first)
    #expect(call.chunk.g2pInputText.contains("[filesystem](/fˈIl sˌɪstəm/)"))
    #expect(call.chunk.phonemes.contains("fˈIl sˌɪstəm"))
    #expect(call.chunk.displayText == "The filesystem stores the verified result.")
}
```

Expected: fail because the protocol and service still dispatch `String`.

### Step 2: Add the protocol requirement and compatibility default

Add this as a protocol requirement, not only an extension method:

```swift
func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk
```

The default implementation delegates to `synthesize(chunk.g2pInputText, voice:)` so non-Kokoro implementations continue to work. `MockTTSEngine` overrides the planned method and records the immutable carrier, proving existential dynamic dispatch.

### Step 3: Switch service synthesis and retry to planned chunks

Replace the string synthesis loop with planned chunks. Change quality evaluation to use `chunk.displayText`. Replace `synthesizeWithQualityRetry(_ text:)` with `synthesizeWithQualityRetry(_ planned:)`:

1. synthesize the supplied plan;
2. if accepted, return it;
3. if rejected, `splitResolved(planned.g2pInputText, ...)`;
4. use `PronunciationPlanner.planResolved` on each child;
5. recursively synthesize children with a bounded retry depth.

This is the only text-split recovery path. It starts from the resolved links, so it cannot change rule choices. Aggregate fallback evidence from the planned children/returned chunks exactly once.

### Step 4: Verify and commit

Run focused service/render tests, then commit:

```bash
git add EchoCore/Services/Narration/TTSEngine.swift EchoCore/Services/Narration/NarrationService.swift EchoTests/Mocks/MockTTSEngine.swift EchoTests/NarrationServiceTests.swift EchoTests/NarrationServiceSynthesisTimingTests.swift
git commit -m "feat(narration): dispatch planned chunks through TTS"
```

## Task 5: Make ONNX Consume the Exact Planned IDs

**Files:**

- Modify: `EchoCore/Services/Narration/KokoroFrontEnd.swift`
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift`
- Modify: `EchoTests/KokoroFrontEndTests.swift`
- Modify: `EchoTests/OnnxKokoroEngineWordTimingTests.swift`
- Create: `EchoTests/OnnxKokoroEnginePlannedInputTests.swift` if a separate suite keeps the assertions focused.

### Step 1: Write failing front-end/input tests

Add a front-end test proving style lookup no longer requires G2P:

```swift
@Test func referenceStyleUsesSuppliedPhonemeCount() throws {
    let frontEnd = KokoroFrontEnd()
    let style = try frontEnd.referenceStyle(
        voice: VoiceID("am_michael"), phonemeCount: 37)
    #expect(style.count == 256)
    #expect(frontEnd.cachedVoices == ["am_michael"])
}
```

Add a pure engine input test around a new internal helper:

```swift
@Test func plannedInputsPreserveExactIDsForWaveformAndDuration() throws {
    let planned = try PronunciationPlanner().plan(
        displayText: "live", g2pInputText: "[live](/lˈIv/)")
    let inputs = try OnnxKokoroEngine.plannedInputs(
        for: planned, voice: VoiceID("am_michael"), frontEnd: KokoroFrontEnd())
    #expect(inputs.waveformIDs == planned.phonemeIDs)
    #expect(inputs.durationIDs == planned.phonemeIDs)
}
```

Expected: fail because the style-only API and planned input helper do not exist.

### Step 2: Separate style lookup from text encoding

Add `KokoroFrontEnd.referenceStyle(voice:phonemeCount:)`. Keep `encode(text:voice:)` as a compatibility method, but implement it in terms of the cached G2P/vocab plus the style-only method.

### Step 3: Implement exact planned synthesis

Override the planned protocol requirement in `OnnxKokoroEngine`:

- call `prepare()`;
- ask the front end only for the voice style row, using `planned.phonemes.count`;
- run `NarrationSilenceGuard.synthesizeWithSpeedNudge` over the same `planned.phonemeIDs` for every speed;
- do not call the text-splitting `NarrationSilenceGuard.synthesize` overload;
- run the duration head with the exact same IDs and reference style;
- map timings using `planned.wordCount`;
- copy `planned.pronunciationFallbackHits` into the returned `TTSChunk`.

Refactor private methods to:

```swift
private func runModel(ids32: [Int32], refS: [Float], speed: Float) async throws -> [Float]
private func tokenDurations(ids32: [Int32], refS: [Float]) -> (ids: [Int32], frames: [Float])?
```

The legacy string method builds one plan from the supplied text and delegates to the planned method. It may invoke G2P because it is explicitly the compatibility path; production narration must enter through the planned overload.

### Step 4: Verify and commit

Run front-end, duration-head, word-timing, silence-guard, and planned-input suites. If the opt-in real-model timing test is available, run it after the Release model is prepared. Commit:

```bash
git add EchoCore/Services/Narration/KokoroFrontEnd.swift EchoCore/Services/Narration/OnnxKokoroEngine.swift EchoTests/KokoroFrontEndTests.swift EchoTests/OnnxKokoroEngineWordTimingTests.swift EchoTests/OnnxKokoroEnginePlannedInputTests.swift
git commit -m "fix(narration): synthesize exact planned phoneme IDs"
```

## Task 6: Add the Approved Regression Rules and Surface Parity

**Files:**

- Modify: `EchoCore/Services/Narration/PronunciationOverrides.swift`
- Modify: `EchoCore/Services/Narration/HomographPronunciationResolver.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/PronunciationOverridesTests.swift`
- Modify: `EchoTests/HomographPronunciationResolverTests.swift`
- Modify: `EchoTests/NarrationPronunciationTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`
- Modify or create a macOS batch construction test only if the current target exposes that service to unit tests.

### Step 1: Write the failing six-word matrix

Add exact source-context expectations:

```swift
let cases: [(source: String, expectedLink: String)] = [
    ("The process is startable today.", "[startable](/stˈɑɹɾəbᵊl/)"),
    ("The filesystem stores the verified result.", "[filesystem](/fˈIl sˌɪstəm/)"),
    ("They live nearby.", "[live](/lˈɪv/)"),
    ("It was a live show.", "[live](/lˈIv/)"),
    ("She lives in Halifax.", "[lives](/lˈɪvz/)"),
    ("The receipt lives in the archive.", "[lives](/lˈɪvz/)"),
    ("Their lives changed.", "[lives](/lˈIvz/)"),
    ("Please record the result.", "[record](/ɹəkˈɔɹd/)"),
    ("Review the record before restart.", "[record](/ɹˈɛkəɹd/)"),
    ("Record sales increased.", "[Record](/ɹˈɛkəɹd/)"),
    ("Should record labels pay artists?", "[record](/ɹˈɛkəɹd/)"),
]
```

Separately assert that `verified` produces `vˈɛɹəfˌId` and no fallback/override link. Expected: fail for the two OOV compatibility words, receipt/lives, and record contexts.

### Step 2: Add narrow deterministic rules

- Add built-in compatibility entries:
  - `startable`: `stˈɑɹɾəbᵊl`
  - `filesystem`: `fˈIl sˌɪstəm`
- Keep `verified` on ordinary lexicon G2P.
- Extend `lives` verb evidence to cover concrete singular subjects such as `receipt`, without changing possessive-plural noun evidence.
- Add `record` noun/verb IPA constants. Give noun-compound followers (`sales`, `label`, `labels`, and related record-medium nouns) precedence over modal verb preceders so “Should record labels…” remains noun pronunciation. Determiners imply noun; `please`/`to` and modal contexts imply verb when no noun-compound follower exists.
- Preserve already-authored Misaki links and hyphen guards.

If native rendered listening in Task 8 disproves either compatibility IPA, revise the IPA and rerun the matrix before completion; vocab validity alone is insufficient.

### Step 3: Add macOS occurrence-override parity

At the `MacBatchProcessingService` construction site, retain the current `PronunciationOverrideStore.shared.overrides(forBookID:)` closure and also inject `PronunciationOverrideStore.shared.occurrenceOverrides(forBookID:)`, matching the headless and player construction sites. Do not create a second pronunciation path.

### Step 4: Invalidate stale narration cache

Raise `NarrationFileNaming.renderVersion` from `10` to `11`. Update the named test to explain that v11 moves pronunciation planning before TTS and ensures previously cached audio is regenerated.

### Step 5: Verify and commit

Run the pronunciation, homograph, render-plan, service, file-naming, and macOS compile tests. Commit:

```bash
git add EchoCore/Services/Narration/PronunciationOverrides.swift EchoCore/Services/Narration/HomographPronunciationResolver.swift EchoCore/Services/Narration/NarrationFileNaming.swift 'Echo macOS/Services/MacBatchProcessingService.swift' EchoTests/PronunciationOverridesTests.swift EchoTests/HomographPronunciationResolverTests.swift EchoTests/NarrationPronunciationTests.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "fix(narration): approve six-word pronunciation matrix"
```

## Task 7: Focused Review and Full Automated Verification

**Files:** Review every file changed above; no production edit unless a test/review finding requires it.

### Step 1: Run focused suites

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:EchoTests/KokoroPhonemeVocabTests \
  -only-testing:EchoTests/PronunciationPlannerTests \
  -only-testing:EchoTests/MisakiPronunciationMarkupTests \
  -only-testing:EchoTests/NarrationTextChunkerTests \
  -only-testing:EchoTests/NarrationRenderPlanTests \
  -only-testing:EchoTests/NarrationServiceTests \
  -only-testing:EchoTests/KokoroFrontEndTests \
  -only-testing:EchoTests/OnnxKokoroEnginePlannedInputTests \
  -only-testing:EchoTests/HomographPronunciationResolverTests \
  -only-testing:EchoTests/NarrationPronunciationTests \
  -only-testing:EchoTests/NarrationFileNamingTests \
  -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: all pass.

### Step 2: Run the full Echo test scheme

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`. Record the `.xcresult` path and counts.

### Step 3: Build macOS and Release CLI

Use the gate for each build:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

Expected: both succeed; the CLI is `.build/cli/Build/Products/Release/echo-cli`.

### Step 4: Run a fresh review agent

Have the reviewer inspect rule precedence, existential dispatch, exact-ID reuse, actor isolation, link-safe recovery, fallback accounting, cache invalidation, and macOS occurrence parity. Resolve every High/Medium correctness finding with a failing test first, rerun the affected suites, and commit any fix separately.

## Task 8: Render and Verify the Production Audio Matrix

**Files:**

- Create outside Git: `/Users/dfakkeldy/Developer/echo-overnight/pronunciation-regression-20260711/`
- Create in Git after verification: `docs/qa/2026-07-11-pronunciation-planned-tts-render.md`

### Step 1: Create the text-selectable synthetic source

Create one paragraph per case, in this order:

```text
The process is startable today.
The filesystem stores the verified result.
The result was verified by the reviewer.
They live nearby.
It was a live show.
She lives in Halifax.
The receipt lives in the archive.
Their lives changed.
Please record the result.
Review the record before restart.
Record sales increased.
Should record labels pay artists?
```

Render it to a text-selectable PDF using the PDF artifact workflow. Keep the source and PDF in the external run directory.

### Step 2: Render through the real headless Echo path

For `am_michael` and control voice `af_heart` (add `am_puck` only if a primary/control discrepancy needs another sample), use unique work/database/output paths and no resume state:

```bash
env -u ECHO_RESOURCE_DIR "$CLI" narrate \
  --epub "$SOURCE_PDF" --out "$RUN/$VOICE.m4b" --sidecar "$RUN/$VOICE-sidecar.json" \
  --voice "$VOICE" --title "Echo Pronunciation Regression" --author "Echo QA" \
  --work-dir "$RUN/work-$VOICE" --db "$RUN/$VOICE.sqlite" --jobs 1 --threads 2
```

This must use the Release CLI and native Kokoro model cache, not a direct engine test or system voice.

### Step 3: Prove each artifact is real and non-silent

For each M4B and its closest raw chapter M4A, collect:

- `shasum -a 256`
- `ffprobe -hide_banner -show_streams -show_format`
- `afinfo`
- `ffmpeg -hide_banner -i <audio> -af silencedetect=noise=-50dB:d=0.5 -f null -`
- `ffmpeg -hide_banner -i <audio> -af volumedetect -f null -`

Run headless QA:

```bash
AUDIOBOOK_ID="runner-pronunciation-regression-$VOICE-pronunciation-regression.pdf"
"$CLI" qa --db "$RUN/$VOICE.sqlite" --audiobook-id "$AUDIOBOOK_ID" \
  --work-dir "$RUN/work-$VOICE" --classifier deterministic --report "$RUN/qa-$VOICE.json"
```

Confirm the sidecar covers all 12 paragraphs and that logs/plan evidence show the expected links and strict token IDs reached planned synthesis. If a local ASR is available, transcribe each numbered clip as supporting evidence only.

### Step 4: Create listenable per-case clips

Use sidecar/chapter timings to cut lossless or AAC clips for every sentence, with filenames beginning `01-startable`, `02-filesystem-verified`, `03-verified`, `04-live-verb`, through `12-record-noun-question`. Keep both voices. The user must be able to play the exact regression cases without scrubbing a full book.

### Step 5: Assess pronunciation honestly

Document separately:

- planned-link/phoneme/ID assertions (automated, exact);
- rendered-file integrity, duration, loudness, and silence checks (automated);
- ASR output, if available (supporting only);
- human listening status.

Do not label a pronunciation “heard correct” unless a human actually listened. If the executing agent cannot hear audio, mark human listening as pending and provide the clips; still report the exact plan-to-waveform proof and native render results.

### Step 6: Commit compact QA evidence

The Markdown evidence file records branch SHA, CLI path, model identity, corpus, voices, artifact paths, checksums, commands/results, QA JSON outcomes, and human-listening status. Do not commit audio, PDFs, databases, models, or work directories.

```bash
git add docs/qa/2026-07-11-pronunciation-planned-tts-render.md
git commit -m "test(narration): verify planned pronunciation render"
```

## Task 9: Publish Through Echo's Promotion Ladder

### Step 1: Rebase and rerun proportional verification

```bash
git fetch origin nightly
git rebase origin/nightly
```

Resolve only branch-owned conflicts. Rerun the focused test matrix and Release CLI build after a non-trivial rebase.

### Step 2: Push and open a ready PR into nightly

```bash
git push -u origin codex/pronunciation-planned-tts-slice
gh pr create --base nightly --head codex/pronunciation-planned-tts-slice \
  --title "fix(narration): apply planned pronunciations before TTS" \
  --body-file /tmp/echo-pronunciation-pr.md
```

The PR body must summarize architecture, rule matrix, automated results, native render paths/checksums, and any remaining human-listening status.

### Step 3: Follow hosted CI

Run `gh pr checks --watch` with bounded polling. If `Build gate + tests` fails, inspect the failing Actions job log, fix the concrete issue test-first, push, and re-check. Report passing/failing/pending/blocked truth.

### Step 4: Record narrow durable KB context

In a separate clean knowledge-base worktree, update the existing Echo pronunciation status page from “designed/unimplemented” to the actual PR and verification state, cite the Echo PR and QA evidence, update the appropriate bundle index/log, commit, push, open its normal PR to `main`, and report its CI state. Do not copy private audio into the KB.

### Step 5: Final hygiene

Run `git status --short --branch` in every touched worktree. All agent-authored changes must be committed and represented by their PR, with generated artifacts only in the declared external delivery directory.
