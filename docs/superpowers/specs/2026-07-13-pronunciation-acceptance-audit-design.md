# Pronunciation Acceptance Audit Design

Status: approved in conversation on 2026-07-13.

## Goal

Make Echo's normal headless narration path both correct and testable for the
pronunciation failures found in *The Question Machine*. Approved pronunciation
choices must be resolved before TTS, persisted as structured evidence, and
sampled into a short listening artifact generated from the audio that was
actually exported.

## Problem statement

The planned-pronunciation runtime slice is active in render version 11, but its
deterministic homograph rules are narrower than natural prose. Two exact source
sentences demonstrate the failure:

- `That gap is where this entire subject lives.` falls through to Misaki's noun
  pronunciation `lˈIvz` instead of verb `lˈɪvz`.
- `...and record whatever it says...` falls through to noun `ɹˈɛkəɹd` instead
  of verb `ɹəkˈɔɹd`.

The prior automated QA corpus did not catch this because its sentences supplied
strong allow-listed cues such as `she lives in` and `please record`. It also
left the human tester with no generated map from a full audiobook to the rules
that fired. A full-book listen therefore could not serve as a practical
acceptance test.

## Approaches considered

### 1. Post-render ASR report

This is rejected as the acceptance mechanism. ASR can support intelligibility
checks, but normally returns the same spelling for noun and verb homographs and
cannot prove vowel or stress selection.

### 2. Full token dump for every word

This would be complete but noisy, large, and hard to review. It would also pull
the larger source-mapped pronunciation-plan work into a bounded repair.

### 3. Structured decisions plus a bounded listening reel

This is the selected approach. Echo records every explicit pronunciation
decision, fallback, and monitored historical regression term in the actual
render plan. The completed CLI run writes all occurrences to JSON and samples
the first occurrence of each distinct selected pronunciation into a short,
chapter-labeled M4B reel.

## Scope

### Contextual fixes

The deterministic resolver gains three narrow, reusable cues:

- `lives` is a verb when a same-sentence `where` clause supplies its subject,
  unless an existing strong plural-noun cue already won.
- `lives as ...` is a verb; an existing possessive/determiner noun cue still
  takes precedence for phrases such as `their lives as immigrants`.
- `record` is a verb before a same-sentence wh-object such as `what` or
  `whatever`. Compound-noun guards continue to win for `record labels`,
  `record stores`, and similar phrases.

The exact *Question Machine* sentences become permanent regression tests. The
resolver remains a compatibility layer; this slice does not claim to replace
the future contextual model described by the pronunciation-planner design.

### Structured pronunciation evidence

The shared planning layer records a `PronunciationAuditDecision` with:

- block identifier and canonical whitespace-word span;
- source word and local source context;
- selected IPA and the corresponding Kokoro token IDs;
- stable source/rule identifier and concise rationale;
- chapter index;
- chapter-relative and final book-relative audio ranges;
- timing precision: exact synthesis word timing or block-anchor fallback.

Decision sources are occurrence override, book override, global override,
built-in override, contextual homograph, monitored lexicon, and fallback.
Existing `apply(to:)` APIs remain as compatibility wrappers around structured
rewrite APIs.

The monitored-lexicon path exists for historically important cases that are
supposed to remain ordinary lexicon output, beginning with `verified`. The
watch vocabulary is the union of shipped built-in terms, contextual-homograph
terms, and explicitly listed historical lexicon regressions. This makes the
six-word acceptance matrix visible even when a term intentionally has no
override.

### Resume-safe persistence

Each `.anchors-chN.json` capture gains optional pronunciation decisions. Old
capture files continue to decode. A resumed render containing old captures is
reported as incomplete audit coverage; Echo never silently reconstructs a plan
after the fact and claims it was the plan synthesized.

The portable alignment sidecar is unchanged. Pronunciation evidence is a local
render artifact, not part of the reader's stable alignment contract.

### Automatic CLI outputs

A completed `echo-cli narrate` run writes beside the requested M4B:

- `<stem>.pronunciation-audit.json`
- `<stem>.pronunciation-reel.m4b` when at least one review sample exists

The JSON includes schema version, render version, voice, coverage status,
watch-vocabulary occurrence counts (including zero), every decision, and the
relative reel filename. It is pretty-printed, sorted-key, and atomically
written.

The reel deterministically chooses the first occurrence per
`(normalized word, selected IPA, rule ID)`, in reading order, capped at 16
samples. Exact synthesis word timings receive short edge padding. When exact
word timing is unavailable (for example, a one-word `filesystem` display link
with spaced IPA), the reel uses the persisted block anchor and marks that
fallback in JSON. `AudioExportService` creates the reel from time-ranged
`ExportItem`s, preserving chapter labels without a new media dependency.

Generation is on by default. `--no-pronunciation-review` is an explicit opt-out
for callers that do not want local source context or the additional audio file.
The completion message names the artifacts or states that review generation
was disabled; it never silently omits the acceptance surface.

## Privacy and repository policy

Audit JSON can contain private source excerpts and the reel contains copyrighted
audio. Both remain local-only beside the user's requested output. Generated
audit JSON and reels are ignored by Git. No source text, manifest, clip, or full
book is uploaded or committed as a fixture.

Automated tests use synthetic/public fixtures. *The Question Machine* is used
only for a local Release acceptance render.

## Failure handling

- A bad pronunciation plan still fails before synthesis through strict
  vocabulary validation.
- Manifest write or reel export failure fails an otherwise complete `narrate`
  command, because an acceptance artifact requested by the default contract is
  not optional success.
- No applicable decisions produces a valid zero-decision manifest and no empty
  reel.
- Legacy resume captures produce `coverage: incompleteLegacyCapture` and list
  the affected chapters.
- Audio ranges are clamped to the exported asset duration and must be positive.

## Verification

The implementation follows red-green-refactor for each layer:

1. Exact resolver and pre-TTS plan tests fail, then pass.
2. Structured decision/provenance and monitored-lexicon tests fail, then pass.
3. Resume capture and absolute-timing assembly tests fail, then pass.
4. Manifest/reel tests fail, then pass, including AVFoundation-visible reel
   chapter titles.
5. Focused suites, the full Echo scheme, a gated macOS build, and a gated
   universal Release `echo-cli` build pass.
6. A fresh Release render of the synthetic six-word matrix and a small
   *Question Machine* proof selection produces a valid sidecar, audit JSON, and
   non-silent review reel. The artifact receipt records hashes and distinguishes
   automated proof from the user's final human listening decision.

## Non-goals

- Learned OOV or contextual model packs.
- Exact original-character mappings through every normalization edit.
- An in-app audit UI.
- Uploading private text/audio or expanding the portable alignment sidecar.
- Claiming human acoustic approval from ASR or automated media checks.
