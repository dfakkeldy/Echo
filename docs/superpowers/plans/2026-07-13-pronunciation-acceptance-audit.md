# Pronunciation Acceptance Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task, with a fresh implementation agent and a fresh review agent for each slice.

**Goal:** Make Echo resolve the natural-prose pronunciation misses found in *The Question Machine*, preserve evidence of every watched pronunciation choice from the plan actually synthesized, and make every completed headless narration produce a practical local acceptance manifest and listening reel by default.

**Architecture:** Keep pronunciation resolution at the existing pre-chunk planning boundary. Structured rewrite results carry stable rule provenance into `NarrationRenderPlan`; Misaki token evidence adds watched ordinary-lexicon and fallback decisions without turning them into overrides. `NarrationService` enriches those immutable decisions with the audio timing it actually rendered, `HeadlessNarrationRunner` persists them in resume captures, and a completed `echo-cli narrate` run atomically writes a schema-versioned JSON audit plus a bounded chaptered M4B reel assembled from the exported audiobook.

**Tech Stack:** Swift 6.0, Swift Testing, Swift concurrency, MisakiSwift/Kokoro G2P, AVFoundation, Xcode 26.6, iOS 18/macOS 15/watchOS 11 targets, Echo's Release `echo-cli`.

## Global Constraints

- Work only in `/Users/dfakkeldy/.codex/worktrees/pronunciation-acceptance/Echo` on `codex/pronunciation-acceptance-audit`, based on `origin/nightly`.
- Preserve the unrelated dirty changes in every other Echo checkout and worktree.
- Add no dependency, network pronunciation service, private-book fixture, model artifact, or platform-version increase.
- Preserve pronunciation precedence: occurrence override > book override > global override > built-in override > contextual homograph rule > ordinary G2P.
- Apply all override and contextual rules before link-aware chunking; never resolve a chunk again after its pronunciation plan is frozen.
- Keep `AlignmentSidecar` unchanged. Pronunciation evidence belongs in local render artifacts and resume captures, not the portable reader contract.
- Audit the plan actually sent to TTS. Never re-plan completed audio and claim the reconstruction was synthesized.
- Keep old `.anchors-chN.json` captures decodable. A legacy capture without pronunciation evidence must produce explicit incomplete coverage.
- Watch vocabulary is the union of shipped built-in terms, contextual-homograph words, and historical ordinary-lexicon regressions beginning with `verified`; occurrence counts include zero.
- Keep generated source excerpts and audio local-only. Ignore `*.pronunciation-audit.json`; M4B output is already ignored.
- Review generation is on by default. `--no-pronunciation-review` is the explicit opt-out and must be named in completion output.
- A requested audit/reel write or export failure fails the completed `narrate` command. Zero samples still produces a valid zero-decision JSON manifest and no empty reel.
- Reel selection is deterministic: first occurrence per `(normalized word, selected IPA, rule ID)`, reading order, maximum 16 samples.
- Prefer exact synthesis-word timing; use a persisted block-anchor range only when exact timing is unavailable, and report the timing precision in JSON.
- Clamp every sample to the exported audiobook duration and require a positive range.
- Run every Xcode build/test through `"$HOME/.claude/bin/xcode-build-gate.sh" --wait`, use `-parallel-testing-enabled NO`, `CODE_SIGNING_ALLOWED=NO`, and a task-specific `-derivedDataPath`. Do not use uncapped `-jobs`.
- Follow strict red-green-refactor. Record the failing command/output before production edits and the passing command/output after them in each task report.
- Commit each reviewed task coherently with a Conventional Commit message. Before publishing, rebase onto current `origin/nightly`, push the feature branch, open a ready PR against `nightly`, and check hosted `Build gate + tests`.

---

## Task 1: Fix Natural-Context `lives` and `record` Resolution

**Files:**

- Modify: `EchoTests/HomographPronunciationResolverTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify: `EchoCore/Services/Narration/HomographPronunciationResolver.swift`

### Step 1: Add the exact failing resolver cases

Add assertions for these source sentences and outcomes:

- `That gap is where this entire subject lives.` → `[lives](/lˈɪvz/)`
- `Every token lives as a point in semantic space.` → `[lives](/lˈɪvz/)`
- `This is where hype lives.` → `[lives](/lˈɪvz/)`
- `Listen and record whatever it says.` → `[record](/ɹəkˈɔɹd/)`
- `Record what the caller says.` → `[Record](/ɹəkˈɔɹd/)`

Keep explicit negative assertions for:

- `Their lives changed.` and `Their lives as immigrants changed.` → noun `lˈIvz`
- `The live argument continued.` → adjective `lˈIv`
- `The record labels agreed.` and `Vinyl and record stores survived.` → noun `ɹˈɛkəɹd`
- a sentence boundary such as `Keep a record. Whatever happens matters.` must not use the second sentence as a cue.

### Step 2: Add the pre-TTS plan regression

In `NarrationRenderPlanTests`, plan blocks containing the exact `subject lives` and `record whatever` sentences. Assert both that:

- `g2pInputText` contains the selected verb IPA links before synthesis; and
- the planned phoneme string contains `lˈɪvz` and `ɹəkˈɔɹd`.

This is the proof that the fix crosses Echo's actual planning boundary, not only the resolver helper.

### Step 3: Run the tests and capture RED

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceTask1Red \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/HomographPronunciationResolverTests \
  -only-testing:EchoTests/NarrationRenderPlanTests
```

Expected: the newly added natural-context assertions fail because the current resolver leaves those words unchanged or selects the noun pronunciation.

### Step 4: Implement narrow same-sentence cues

Preserve the existing strong noun and compound-noun guards, then add:

- a same-sentence `where`-clause cue for verb `lives`;
- immediate follower `as` for verb `lives`, after noun cues have had precedence;
- immediate same-sentence wh-object followers for verb `record`, including at least `what` and `whatever`.

Use the resolver's existing token and `startsSentence` information. Do not add `and` as a general verb cue and do not make an unbounded lexical guess such as treating every noun before `lives` as a subject.

### Step 5: Run GREEN and commit

Re-run the Step 3 command with `/tmp/EchoPronunciationAcceptanceTask1Green`, confirm the entire focused suites pass, then commit:

```bash
git add EchoCore/Services/Narration/HomographPronunciationResolver.swift \
  EchoTests/HomographPronunciationResolverTests.swift \
  EchoTests/NarrationRenderPlanTests.swift
git commit -m "fix(narration): resolve natural homograph contexts"
```

---

## Task 2: Carry Structured Override and Homograph Decisions into the Render Plan

**Files:**

- Create: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/PronunciationOccurrenceOverrides.swift`
- Modify: `EchoCore/Services/Narration/PronunciationOverrides.swift`
- Modify: `EchoCore/Services/Narration/PronunciationOverrideStore.swift`
- Modify: `EchoCore/Services/Narration/HomographPronunciationResolver.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoTests/PronunciationOccurrenceOverridesTests.swift`
- Modify: `EchoTests/PronunciationOverridesTests.swift`
- Modify: `EchoTests/PronunciationOverrideStoreTests.swift`
- Modify: `EchoTests/HomographPronunciationResolverTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`

### Step 1: Define the portable planning evidence with failing tests

Add tests that require a structured decision to contain:

- portable block ID and canonical whitespace word span;
- normalized watched word, original source word, and bounded local source context;
- selected IPA and Kokoro IDs for only that IPA, without synthetic boundary IDs;
- stable source and rule ID;
- concise, deterministic rationale;
- optional chapter/timing fields that are unset during planning.

Use a Codable, Equatable schema model in `PronunciationAudit.swift`. Decision source values must be exactly:

- `occurrenceOverride`
- `bookOverride`
- `globalOverride`
- `builtInOverride`
- `contextualHomograph`
- `monitoredLexicon`
- `fallback`

Tests must cover precedence and provenance separately: occurrence over book, book over global, global over built-in, and built-in over contextual resolution. The selected source must describe the winning rule rather than the flattened dictionary it came from.

### Step 2: Run the structured-decision tests and capture RED

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceTask2 \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/PronunciationOccurrenceOverridesTests \
  -only-testing:EchoTests/PronunciationOverridesTests \
  -only-testing:EchoTests/PronunciationOverrideStoreTests \
  -only-testing:EchoTests/HomographPronunciationResolverTests \
  -only-testing:EchoTests/NarrationRenderPlanTests \
  -only-testing:EchoTests/NarrationServiceTests
```

Expected: compile/test failures because structured rewrite results and render-plan decisions do not exist.

### Step 3: Add structured rewrite APIs without breaking compatibility

Implement structured rewrite results for occurrence, scoped dictionary, and homograph resolution. Keep the existing `apply(to:)` methods as wrappers returning only rewritten text.

Requirements:

- Every branch has a stable rule ID. Examples: `override.occurrence`, `override.book.<normalized-word>`, and `homograph.lives.verb.where-clause`.
- Homograph rationales name the actual cue that won, not a generic “resolver selected verb.”
- Existing noun/compound guards may also produce explicit contextual decisions when the word is watched.
- Source context is bounded and normalized for deterministic JSON but preserves enough surrounding words for a listener to recognize the sentence.
- Decision word spans use the same `WordTokenizer` semantics as occurrence overrides.
- Resolver regex-token positions must be mapped back onto `WordTokenizer` spans; never record a homograph loop index as though it were a canonical whitespace-word index.
- Preserve scope metadata in `PronunciationOverrideStore`; do not flatten it away before auditing.
- Add one IPA-only ID helper to the existing `PronunciationPlanner`/vocabulary owner, deriving IDs through `KokoroPhonemeVocab.validatedIDs` and removing its leading/trailing boundary tokens. Do not load a second vocabulary solely for auditing.

### Step 4: Carry decisions through `NarrationRenderPlan`

Occurrence overrides are currently applied inside `NarrationService.prepareBlocksForRenderPlan`, before the planner can observe them. Preserve that FM-normalization ordering with a small prepared-block carrier containing the rewritten `EPubBlockRecord` plus occurrence decision seeds. Add a `NarrationRenderPlanner.make(preparedBlocks:overrides:...)` entry point and keep the existing `make(blocks:overrides:...)` as a compatibility wrapper that supplies empty seeds.

Each `NarrationPlannedBlock` must expose the decisions produced from the exact full normalized block before chunking. Combine prepared occurrence seeds with scoped dictionary and homograph seeds inside the planner. Splitting may attach a decision to the one planned chunk containing its canonical word span, or keep decisions at block level, but the public plan must not duplicate a decision and must preserve the original portable block/span identity.

Leave `contentSignature`/`renderedText` behavior unchanged and make legacy `apply` wrappers return the text from their structured rewrite result. This preserves current cache hashes and FM-mode signatures.

Do not change the text or phoneme output of existing resolved cases except for Task 1's approved contextual fixes.

### Step 5: Run GREEN and commit

Re-run the exact Step 2 command using the same task-specific DerivedData path so GREEN reuses the compiled dependencies; then run the existing `PronunciationPlannerTests` as an additional focused guard. Commit:

```bash
git add EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoCore/Services/Narration/PronunciationOccurrenceOverrides.swift \
  EchoCore/Services/Narration/PronunciationOverrides.swift \
  EchoCore/Services/Narration/PronunciationOverrideStore.swift \
  EchoCore/Services/Narration/HomographPronunciationResolver.swift \
  EchoCore/Services/Narration/PronunciationPlanner.swift \
  EchoCore/Services/Narration/NarrationRenderPlan.swift \
  EchoCore/Services/Narration/NarrationService.swift \
  EchoTests/PronunciationOccurrenceOverridesTests.swift \
  EchoTests/PronunciationOverridesTests.swift \
  EchoTests/PronunciationOverrideStoreTests.swift \
  EchoTests/HomographPronunciationResolverTests.swift \
  EchoTests/NarrationRenderPlanTests.swift \
  EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): preserve pronunciation decision provenance"
```

---

## Task 3: Audit Watched Ordinary-Lexicon and Fallback Pronunciations

**Files:**

- Modify: `EchoCore/Services/Narration/KokoroG2P.swift`
- Modify: `EchoCore/Services/Narration/PlannedSynthesisChunk.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoTests/KokoroG2PTests.swift`
- Modify: `EchoTests/PronunciationPlannerTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`

### Step 1: Add failing token-evidence and watch-matrix tests

Extend the G2P wrapper and planner tests to require per-token evidence from the same full-context Misaki result used to produce final phonemes. At minimum expose token text, selected phonemes, lexical tag/rating when available, source range, and whether the token used fallback behavior.

Add a render-plan test containing all six acceptance words:

- `startable`
- `filesystem`
- `verified`
- `live`
- `lives`
- `record`

Assert that:

- explicit built-ins/homographs retain their structured source/rule provenance;
- `verified` appears as `monitoredLexicon`, with the exact IPA and selected IDs from the same G2P pass;
- a deliberately unsupported synthetic token produces `fallback` evidence without silently relabeling it as a lexicon decision;
- the watch vocabulary contains all six terms even if a separate block omits some of them.

### Step 2: Run and capture RED

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceTask3 \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/KokoroG2PTests \
  -only-testing:EchoTests/PronunciationPlannerTests \
  -only-testing:EchoTests/NarrationRenderPlanTests
```

Expected: compile/test failures because the current wrapper exposes only the aggregate phoneme string and fallback hits.

### Step 3: Preserve token evidence from the actual G2P pass

Map Misaki's existing token result into a small Echo-owned Codable/Equatable value. Do not invoke a second G2P pass for auditing. Keep `PlannedSynthesisChunk` immutable and attach only the evidence needed to identify watched lexicon/fallback decisions.

The watch-vocabulary declaration must have one deterministic source of truth and include:

- all current built-in override keys;
- all contextual homograph target words;
- `verified` as the initial explicitly monitored ordinary-lexicon regression.

When converting token evidence to decisions, avoid duplicating a word/span already covered by a winning explicit or contextual decision.

### Step 4: Run GREEN and commit

Re-run the exact Step 2 command using the same task-specific DerivedData path, then commit:

```bash
git add EchoCore/Services/Narration/KokoroG2P.swift \
  EchoCore/Services/Narration/PlannedSynthesisChunk.swift \
  EchoCore/Services/Narration/PronunciationPlanner.swift \
  EchoCore/Services/Narration/NarrationRenderPlan.swift \
  EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoTests/KokoroG2PTests.swift \
  EchoTests/PronunciationPlannerTests.swift \
  EchoTests/NarrationRenderPlanTests.swift
git commit -m "feat(narration): audit watched lexicon decisions"
```

---

## Task 4: Persist Actual-Render Decisions and Resume-Safe Audio Timing

**Files:**

- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Modify: `EchoTests/HeadlessNarrationQAInputTests.swift`

### Step 1: Add failing actual-render receipt tests

Require `NarrationService.renderChapter` to return an `@discardableResult` receipt containing the immutable pronunciation decisions from the exact `NarrationRenderPlan` it dispatched. Tests must prove that:

- chapter index is attached;
- an exact synthesis-word match receives a positive chapter-relative range and `exactSynthesisWord` precision;
- a decision that cannot map one display word to one timing token receives the persisted block range and `blockAnchorFallback` precision;
- ranges are not inferred by re-running resolution after render;
- no decision disappears when the service retries/slices an already-resolved planned chunk.

### Step 2: Add failing resume-capture and absolute-time tests

Extend runner tests to require optional captured pronunciation decisions. Cover:

- encode/decode round-trip for a new capture;
- decoding a legacy capture with no decision field;
- complete coverage when every chapter has new evidence;
- `incompleteLegacyCapture` plus the exact affected chapter numbers for mixed old/new resumed captures;
- chapter-relative ranges shifted to final book-relative ranges using the same chapter offsets as sidecar anchors.

### Step 3: Run and capture RED

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceTask4 \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/NarrationServiceTests \
  -only-testing:EchoTests/HeadlessNarrationRunnerTests \
  -only-testing:EchoTests/HeadlessNarrationQAInputTests
```

Expected: compile/test failures because render receipts and captured decisions do not exist.

### Step 4: Implement receipt enrichment and optional persistence

Use the existing anchors and synthesis word timings created during the render. Add the smallest return value needed to `renderChapter`; existing callers may ignore it because it is discardable.

Persist chapter-relative evidence in `ChapterCapture`. During completed-book assembly, create absolute ranges by adding the actual chapter offsets. Preserve both relative and absolute values in the audit model. Do not alter sidecar serialization.

For exact matching, use stable plan/block/span identity rather than a global string search. If exact matching is unavailable or ambiguous, use the persisted block anchor honestly.

### Step 5: Run GREEN and commit

Re-run the exact Step 3 command using the same task-specific DerivedData path, then commit:

```bash
git add EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoCore/Services/Narration/NarrationService.swift \
  EchoCore/Services/Narration/HeadlessNarrationRunner.swift \
  EchoTests/NarrationServiceTests.swift \
  EchoTests/HeadlessNarrationRunnerTests.swift \
  EchoTests/HeadlessNarrationQAInputTests.swift
git commit -m "feat(narration): persist pronunciation render receipts"
```

---

## Task 5: Generate the Automatic JSON Audit and Chaptered Listening Reel

**Files:**

- Create: `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `Tools/echo-cli/NarrateCommand.swift`
- Modify: `.gitignore`
- Create: `EchoTests/PronunciationAuditTests.swift`
- Create: `EchoTests/PronunciationListeningReelTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Modify: `EchoTests/AudioExportServiceTests.swift`

### Step 1: Add failing manifest tests

Require a schema-version-1 manifest with:

- render version, voice, coverage, and affected legacy chapters;
- relative audiobook and reel filenames only;
- watch-vocabulary occurrence counts including zero;
- every structured decision in stable reading order;
- chapter-relative and absolute ranges plus timing precision;
- selected IPA and selected Kokoro IDs;
- source, stable rule ID, rationale, span, and bounded context.

Assert pretty-printed, sorted-key JSON and atomic replacement behavior. A zero-decision run must still write a valid manifest and must not request an empty reel.

### Step 2: Add failing deterministic reel tests

Using generated/public synthetic audio fixtures, require the reel selector to:

- choose the first occurrence per `(normalized word, selected IPA, rule ID)`;
- preserve reading order;
- cap at 16 samples;
- pad exact-word ranges modestly and use block ranges for fallback precision;
- clamp samples to the source audiobook duration and reject zero/negative ranges;
- label chapters with sample number, word, rule ID, and IPA;
- export a playable M4B whose chapter titles are visible through AVFoundation.

Use `AudioExportService.ExportItem(title:url:timeRange:)`; do not introduce a clipper or media dependency.

### Step 3: Add failing normal-run behavior tests

At the runner boundary, require narration configuration to generate review artifacts by default and disable them only through an explicit configuration value. Completion results must expose both generated paths, state when no reel was necessary, or state that review generation was disabled.

Manifest or reel failure must propagate as command failure.

The executable parser itself is not part of the `EchoTests` target. Verify its exact `--no-pronunciation-review` spelling and help text later with the built Release CLI rather than adding a test that cannot import the executable target.

### Step 4: Run and capture RED

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceTask5 \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/PronunciationAuditTests \
  -only-testing:EchoTests/PronunciationListeningReelTests \
  -only-testing:EchoTests/HeadlessNarrationRunnerTests \
  -only-testing:EchoTests/AudioExportServiceTests
```

Expected: compile/test failures because the manifest writer, selector/exporter, and CLI flag/output do not exist.

### Step 5: Implement manifest, reel, and CLI integration

Write artifacts beside the requested final M4B:

- `<stem>.pronunciation-audit.json`
- `<stem>.pronunciation-reel.m4b` when samples exist

Generate them only after final chapter assembly succeeds so time ranges refer to the exported audiobook. Use temporary sibling files and atomic replacement for JSON. Ensure a stale reel from a prior run is not reported as current when the new run has no samples or review generation is disabled.

Add `*.pronunciation-audit.json` to `.gitignore`. Do not add private source/audio logging.

### Step 6: Run GREEN and commit

Re-run the exact Step 4 command using the same task-specific DerivedData path, then commit:

```bash
git add .gitignore \
  EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoCore/Services/Narration/PronunciationListeningReel.swift \
  EchoCore/Services/Narration/HeadlessNarrationRunner.swift \
  Tools/echo-cli/NarrateCommand.swift \
  EchoTests/PronunciationAuditTests.swift \
  EchoTests/PronunciationListeningReelTests.swift \
  EchoTests/HeadlessNarrationRunnerTests.swift \
  EchoTests/AudioExportServiceTests.swift
git commit -m "feat(cli): generate pronunciation review artifacts"
```

---

## Task 6: Verify the Production Path with Fresh Release Audio

**Files:**

- Create: `docs/qa/2026-07-13-pronunciation-acceptance-audit.md`
- Modify only if needed by discovered defects: files covered by Tasks 1–5 and their focused tests
- Local-only outputs outside Git: `/Users/dfakkeldy/Developer/echo-overnight/pronunciation-acceptance-20260713/`

### Step 1: Run focused and full automated verification

Run the focused suites from Tasks 1–5 on the final branch, then:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,id=4774318C-1444-4660-BF3E-EA00025AEAFA' \
  -derivedDataPath /tmp/EchoPronunciationAcceptanceFull \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

Record exact commands, test counts/results, Xcode/Swift versions, and the Release CLI hash in the QA receipt.

### Step 2: Make fresh local-only proof inputs

Create outside Git:

- a synthetic/public six-word matrix covering noun/verb/adjective contrasts for `startable`, `filesystem`, `verified`, `live`, `lives`, and `record`;
- a small private *Question Machine* proof selection containing the exact `subject lives`, `lives as`, and `record whatever` sentences from the narration EPUB.

Do not modify or reuse the existing `audio-work` directory. Use isolated databases, fresh work directories, Release `echo-cli`, `--jobs 1`, and `--threads 2`.

### Step 3: Render and validate both proof packages

For each proof:

- render through normal `echo-cli narrate` with review generation left enabled;
- run `echo-cli verify-sidecar` on the output;
- parse and schema-check the audit JSON;
- confirm all expected watch-vocabulary counts, selected IPAs, rule IDs, token IDs, and coverage status;
- inspect the audiobook and reel with `ffprobe`/`afinfo` or AVFoundation;
- confirm reel chapter labels and positive/clamped ranges;
- confirm no source block was skipped and no unexpected G2P fallback occurred;
- compute SHA-256 hashes for source, M4B, sidecar, audit JSON, reel, Release CLI, and relevant logs.

The six-word matrix must show all six words in the audit, including correct zero counts where a contrast intentionally omits a spelling. The private proof must show the new contextual rule IDs in the plan actually rendered.

### Step 4: Record honest listening status

Listen to the bounded synthetic and private reels enough to reject silence, truncation, wrong clip selection, or an obvious noun/verb mismatch. Record that as maintainer smoke-listening only. Keep the user's human acoustic approval explicitly pending; automated checks and maintainer listening do not substitute for their decision.

### Step 5: Write and commit the compact QA receipt

The checked-in receipt may contain commands, public synthetic sentences, counts, hashes, media metrics, and local artifact paths. It must not contain private prose beyond the already-approved short regression phrases, copyrighted audio, manifests, or clips.

```bash
git add docs/qa/2026-07-13-pronunciation-acceptance-audit.md
git commit -m "docs(qa): verify pronunciation acceptance artifacts"
```

### Step 6: Update durable business operating context

In a separate clean worktree of `/Users/dfakkeldy/Developer/knowledge-base`, update the relevant Echo project/status/index/log pages with:

- the source design and QA receipt links;
- the feature branch/PR and hosted CI state;
- the distinction between automated proof, maintainer smoke-listening, and user approval pending;
- the practical instruction that future narrations generate their own audit/reel unless explicitly disabled.

Commit the scoped KB update separately. Do not mix KB files into the Echo branch.

### Step 7: Publish through the Echo promotion ladder

After all task reviews and the final whole-branch review are clean:

```bash
git fetch origin nightly
git rebase origin/nightly
git push -u origin codex/pronunciation-acceptance-audit
gh pr create --base nightly --head codex/pronunciation-acceptance-audit \
  --title "feat: add pronunciation acceptance artifacts" \
  --body-file /tmp/echo-pronunciation-acceptance-pr.md
gh pr checks --watch <PR-NUMBER>
```

Report the ready PR URL and whether hosted `Build gate + tests` is passing, failing, pending, or blocked. Do not promote `nightly` to `weekly` or `main` unless separately asked.
