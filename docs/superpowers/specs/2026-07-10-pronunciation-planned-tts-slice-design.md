# Planned Pronunciation Before TTS — Bounded Production Slice

**Date:** 2026-07-10
**Status:** Conversational scope approved; awaiting written-spec review
**Base:** `origin/nightly` at `d634c4718ab4cc88c8fd8b34d0075677d5725c58`

## 1. Decision

Implement the first production slice of the approved local-first pronunciation
architecture. Echo will resolve pronunciation on the complete normalized block,
before narration chunking, and pass an immutable planned synthesis value across
the `TTSEngine` boundary. The normal waveform path, duration-head path, quality
retry, and silence recovery must all consume the same resolved pronunciation.

This slice also turns the reported words `startable`, `filesystem`, `verified`,
`live`, `lives`, and `record` into executable linguistic and rendered-audio
regressions. It does not claim to deliver the later neural OOV or contextual
model packs from the full planner design.

## 2. Why this slice

The live pipeline currently applies user and homograph overrides as Misaki
links before `TTSEngine.synthesize`, but the engine boundary still accepts only
`String`. `OnnxKokoroEngine` therefore reruns G2P for waveform synthesis and
again for duration timing, while retry and silence-recovery paths can split and
re-encode text independently. There is no runtime `PronunciationPlanner` or
phoneme-plan carrier despite the merged design in PR #419.

Three approaches were considered:

1. **Planned-synthesis compatibility slice — selected.** Add the real boundary
   and route every production path through it, while using today's trusted
   lexicon, user overrides, and compatibility rules as providers. This fixes
   the architecture seam now without pretending the neural model work is done.
2. **Add six more string overrides.** Fastest, but it preserves the text-only
   boundary and the whack-a-mole failure mode. Rejected as the primary change.
3. **Implement the complete neural planner and signed contextual pack.** This is
   the long-term design, but it requires corpus benchmarking, model selection,
   licensing, conversion, device performance work, and pack security. It is a
   multi-phase program rather than a safe single PR.

## 3. Scope

### In scope

- A shared immutable planned-synthesis value containing resolved text,
  Kokoro-compatible phonemes, token IDs, fallback metadata, and word count.
- A compatibility `PronunciationPlanner` that applies precedence on the full
  block: occurrence override, book/global override, then automatic contextual
  compatibility rules.
- Chunking after contextual decisions are embedded in the resolved block.
- A planned `TTSEngine` entry point used by Echo, Echo macOS, and `echo-cli`.
- Exact planned IDs reused by normal ONNX inference and duration timing.
- Retry and silence-recovery pieces planned from already-resolved text before
  their model calls; contextual semantics may not be selected again on a
  context-reduced fragment.
- macOS batch parity for occurrence overrides.
- Named linguistic fixtures and native Kokoro audio renders with `am_michael`;
  `af_heart` is the control voice.

### Out of scope

- Selecting or shipping the learned OOV model.
- Selecting or shipping the downloadable contextual model pack.
- Model-download UI, signing, anti-rollback, or pack lifecycle.
- Replacing Kokoro or changing deployment targets.
- Claiming ASR agreement alone proves natural pronunciation.
- Re-rendering existing user books or changing stored user overrides.

## 4. Data flow

The production path becomes:

```text
source block
  -> deterministic normalization
  -> optional explicit FM refinement (existing policy)
  -> occurrence override
  -> book/global override
  -> full-block contextual compatibility resolution
  -> chunk boundaries selected from resolved text
  -> PronunciationPlanner encodes each chunk once
  -> PlannedSynthesisChunk
  -> TTSEngine.synthesize(plannedChunk, voice)
       -> waveform model uses planned IDs
       -> duration head uses the same planned IDs
       -> silence recovery plans child fragments from resolved text before run
  -> TTSChunk
```

`PlannedSynthesisChunk` is `Equatable` and `Sendable` and carries:

- `displayText`: normalized source-facing text with no Misaki link markup,
  retained for quality evaluation and word timing;
- `g2pInputText`: the same fragment with authoritative compatibility decisions
  represented in Misaki's exact-IPA link syntax;
- `phonemes`: the exact Kokoro-compatible phoneme sequence;
- `phonemeIDs`: BOS/EOS-wrapped token IDs;
- `wordCount`: the resolved text word count used by timing;
- `pronunciationFallbackHits`: fallback provenance captured during planning.

Chunking produces paired display/G2P fragments so an override whose IPA
contains spaces remains one atomic source token. The render plan stores planned
chunks rather than `[String]`. The existing
text-only `TTSEngine` method remains as a compatibility convenience for tests
and non-production callers. Its default planned overload may delegate to text,
but `OnnxKokoroEngine` must override the planned overload and must not call G2P
again for the supplied chunk.

## 5. Retry and recovery invariants

- Quality retry splits the paired `displayText`/`g2pInputText`, then asks the
  planner to encode each child from the already-resolved G2P input. It never
  reruns occurrence/book/global or contextual selection.
- `OnnxKokoroEngine` keeps speed-nudge recovery for one planned attempt because
  each speed uses identical IDs. Text splitting moves to a service-side planned
  recovery helper: after every speed remains silent, it splits the paired
  resolved fragment, plans both children, and only then calls `TTSEngine` for
  each child. This keeps all G2P and ID creation outside the child model call.
- Misaki pronunciation links are atomic during splitting, including links whose
  IPA contains spaces.
- If a resolved fragment cannot be split without breaking a link or source
  token, keep the prior planned attempt rather than silently changing or
  dropping pronunciation.
- A planned chunk whose IDs contain only boundary tokens is treated as empty,
  matching current behavior.

## 6. Named regression contract

The repository uses synthetic sentences, not private manuscript passages.

| Word | Required semantic/audio outcome |
| --- | --- |
| `startable` | American English “START-uh-bul”; no mechanical fallback and no “star-tab-le.” The compatibility candidate is `stˈɑɹɾəbᵊl`, subject to the real-render gate. |
| `filesystem` | The compound “file system,” not “filly-system.” The compatibility candidate is `fˈIl sˌɪstəm`, subject to the real-render gate. |
| `verified` | Preserve the existing fallback-free `vˈɛɹəfˌId`. If this plan renders poorly, classify it as acoustic/voice behavior rather than adding a semantic spelling rule. |
| `live` | Verb `lˈɪv` in “They live nearby”; adjective `lˈIv` in “It was a live show.” |
| `lives` | Verb `lˈɪvz` in “She lives in Halifax” and “The receipt lives in the archive”; plural noun `lˈIvz` in “Their lives changed.” |
| `record` | Verb `ɹəkˈɔɹd` in “Please record the result”; noun `ɹˈɛkəɹd` in “Review the record before restart.” Include negative compound-noun guards such as “record sales” and “record labels.” |

The `startable` and `filesystem` compatibility entries are deliberately marked
as temporary system provenance. The later learned OOV provider must replace
them only after frozen-corpus and rendered-audio parity.

## 7. Testing

Use strict red/green steps:

1. Planner tests fail because `startable` and `filesystem` currently reach the
   mechanical fallback and because no planned carrier exists.
2. Context tests fail for the reported `lives` and controlled `record` cases,
   with noun/adjective negative guards.
3. A recording `TTSEngine` integration test fails until `NarrationService`
   passes planned chunks rather than raw text.
4. ONNX/front-end tests fail until waveform and duration paths accept the same
   supplied IDs without re-encoding.
5. Retry and silence-recovery tests fail until child attempts preserve the
   already-resolved pronunciation links and planned IDs.
6. App, macOS batch, and headless tests prove identical plans for identical
   inputs and override state.

Focused suites include `NarrationPronunciationTests`,
`HomographPronunciationResolverTests`, `NarrationRenderPlanTests`,
`NarrationServiceTests`, `NarrationSilenceGuardTests`,
`KokoroFrontEndTests`, `OnnxKokoroEngineWordTimingTests`, and
`HeadlessNarrationRunnerTests`. The full Echo unit suite and an `echo-cli`
Release build remain required before publication.

## 8. Rendered-audio gate

Create a small public synthetic EPUB or text-selectable PDF outside the repo,
one probe sentence per paragraph. Render through the real Release `echo-cli`
pipeline with deterministic normalization, isolated work/database paths, and no
global override file:

- primary: `am_michael`;
- control: `af_heart`;
- optional cross-check: `am_puck` if a result appears voice-specific.

The render corpus is fixed to:

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

If either compatibility IPA candidate fails the primary real-render listening
target, revise and re-render it within this task; do not accept the candidate
merely because its phonemes are vocab-valid.

Verification includes:

- source -> headless runner -> `NarrationService` -> planned `TTSEngine` ->
  production Kokoro ONNX, not a direct engine shortcut;
- 24 kHz mono chapter M4A inspection with `ffprobe`/`afinfo`;
- non-silence and level checks with `ffmpeg`;
- deterministic Whisper-assisted QA as supporting evidence;
- playable M4A/M4B artifacts retained outside git for human listening.

ASR can confirm gross word identity but cannot pass stress, vowel, or
naturalness. The task may report automated evidence and provide the listening
artifacts, but it must not claim blind-listening acceptance that did not occur.

## 9. Error handling and compatibility

- Invalid or unsupported planned phonemes fail before ONNX inference; symbols
  are never silently dropped.
- Non-Kokoro/mock engines continue to work through the protocol's text adapter.
- Existing cached audio remains playable. New plan-affecting behavior increments
  the narration render signature so stale audio is not reused.
- Existing occurrence, book, and global user overrides retain their priority.
- macOS batch adds the missing occurrence-override provider but does not migrate
  or rewrite stored data.
- No third-party dependency, network speech service, private text fixture, or
  model asset is added by this slice.

## 10. Definition of done

1. The production app, macOS batch, and headless runner send planned chunks
   across `TTSEngine` before every model call.
2. Normal waveform and duration timing consume the same exact IDs.
3. Quality retry and silence recovery preserve resolved pronunciation.
4. All named regression sentences pass linguistic plan tests in both required
   senses and negative contexts.
5. Real `am_michael` and `af_heart` artifacts are rendered through `echo-cli`,
   inspected, and retained outside git.
6. Any remaining `verified` defect is reported honestly as acoustic if its
   planned phonemes are correct.
7. Focused tests, full tests, Release `echo-cli` build, hosted CI, and PR checks
   are green.
8. The branch is rebased onto current `origin/nightly`, pushed, and represented
   by a ready PR into `nightly`.

## 11. Relationship to the full planner

This PR establishes the production boundary required by Phase 1 of the merged
local-first pronunciation design. It intentionally leaves provider selection
open. A later Phase 0/2 series supplies frozen corpora and the learned OOV
provider; a later Phase 3 series supplies sentence-context inference and the
signed pack store. Those providers plug into this planner rather than reopening
the TTS boundary.
