# Task 7: Materialize Candidate Advisories Without Changing Selection

## Delivered

- Added the concrete, injected `PronunciationCandidateAnalyzer`; it normalizes,
  validates, deduplicates, and source/candidate-orders audit alternatives while
  never selecting one.
- Attached advisory evidence only after the final G2P chunks and contextual
  evidence exist, before materialization. Selected IPA, Kokoro IDs, synthesis
  chunks, and production cache identity remain unchanged.
- Loaded the advisory pack in the app, macOS batch, QA, and headless construction
  paths. The headless runner has a defaulted audit-pack loader for equivalent
  injected operation.
- Extended preflight's portable reason vocabulary and added focused regressions
  for comparison scope, source disagreement, app/headless equivalence, cache
  identity, and advisory ordering.

## Files

- New: `EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift`
- New: `EchoTests/PronunciationCandidateAnalyzerTests.swift`
- Changed: narration render planning, service injection, headless and named app
  constructors, advisory ordering, decision-seed copying, preflight vocabulary,
  and the focused narration tests.

`NarrationRenderPlan.swift` and `PronunciationAudit.swift` are the actual
attachment/copy seams. `PronunciationPlanner.swift` intentionally remains
unchanged: it must stay the owner of the exact selected synthesis phonemes.

## TDD record

### RED

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Result: expected failure, `PronunciationCandidateAnalyzer` not in scope in the
new analyzer tests (with consequent type-inference errors).

### GREEN and verification

After implementation, the first rebuild found one closure-return compile error
in the new `compactMap`; it was corrected before the final GREEN rebuild.

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationCandidateAnalyzerTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationPronunciationPreflightTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationPlannerTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationFileNamingTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAdvisoryEvidenceTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPlanTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

Result: final test build, all eight focused/regression invocations, and the
release `echo-cli` build completed successfully through the governed slot. The
source suites contain 6, 4, 8, 53, 45, 17, 2, and 42 tests respectively (177
declared tests across the eight listed suites).

The first headless-suite invocation stalled before launching a test host: its
wrapper/xcodebuild processes were idle for more than six minutes and no xctest
process existed. It was terminated only after explicit authorization, the
simulator was confirmed shutdown, and the suite was retried once. The retry
launched `Echo.app`, sustained active test-host CPU work, and completed; only
that retry is verification evidence.

`git diff --check` passed after the final changes.

## Self-review

- The analyzer is concrete, `Sendable`, and receives both immutable packs; no
  protocol or dependency was added.
- Alternatives are canonicalized, strict-vocabulary validated, IPA-deduplicated,
  and sorted by source then candidate ID. Audit candidates stay uncertain and
  shadow-only.
- Advisory evidence attaches after final token evidence/fallback collection and
  preserves every existing selected-seed field. Materialization and timing-copy
  paths preserve the optional evidence.
- The production policy signature remains the sole pronunciation input to
  filename/content signatures; the audit-pack regression asserts version
  changes cannot affect them.
- All named construction paths load/pass the same bundled audit pack alongside
  the production pack. The app-vs-headless regression compares the resulting
  advisory payload directly.

## Concern

Title case alone is not treated as evidence that a token is a proper noun:
sentence-initial ordinary words must not become noisy advisories. Acronyms still
trigger comparison, while title-cased names materialize only when another
concrete signal exists (audit disagreement, production ambiguity, contextual or
watch membership, fallback, or invalid output). This is an intentional,
advisory-only conservative limitation until a real proper-name signal exists.

## Commit

Pending the coherent Task 7 commit:
`feat(narration): surface shadow pronunciation alternatives`

## Fix round 1: retain invalid G2P advisory receipts

### Delivered

- Empty or unsupported selected G2P output with advisory evidence now creates an
  explicit evidence-only audit decision. It preserves the raw selected value
  for review, has no Kokoro IDs, and is never matched to a synthesis chunk.
- The materializer emits the corresponding mismatch diagnostic, which makes the
  manifest coverage incomplete rather than presenting the review receipt as
  fully evidenced.
- Render timing explicitly preserves this decision as untimed, so the listening
  reel cannot derive a sample from it. Existing matched-token decisions retain
  their exact final IPA/ID and timing behavior.
- Added production-path planner/materializer/manifest regressions for both
  empty and unsupported output. They assert valid planned synthesis phonemes
  remain unchanged, the advisory receipt survives JSON manifest round-trip, the
  coverage is incomplete, and the reel has no entry.

### TDD and final verification

RED first added the empty and unsupported materialization expectations; the
pre-change materializer produced no decision for either case, so the required
decision assertion failed.

Final commands, each through the governed Apple build slot:

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPlanTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAuditTests
```

Result: all final commands completed successfully. The final focused source
suites contain 44 render-plan, 53 narration-service, and 23 pronunciation-audit
tests (120 declared tests total). `git diff --check` passed.

### Fix-round self-review

- Evidence-only materialization is limited to advisory-bearing seeds whose
  dispatch-normalized phonemes are empty or fail Kokoro vocabulary validation;
  it does not change chunks, selected normal pronunciation authority, or cache
  identity.
- Normal final-token matching still requires its exact matched token evidence.
  Evidence-only receipts deliberately carry an empty ID list and no render
  timing, and `PronunciationListeningReel` additionally requires a bounded
  book-relative range before it emits a sample.
- Unsupported raw output is retained only in the audit decision. The synthesis
  chunk stays derived from the already-sanitized planner output; the regression
  uses a null character specifically to prove it never becomes speakable.

### Fix-round concern

The evidence-only receipt intentionally stores the raw unsupported selected
string so reviewers can inspect what G2P returned. JSON encoding safely escapes
control characters (covered by the manifest round-trip test), but any future
human-facing audit UI should render control characters visibly rather than
inserting them as literal display text.

### Fix-round commit

Pending final commit:
`fix(narration): retain invalid G2P advisory evidence`

## Fix round 2: seal invalid-output evidence without synthesis

### Delivered

- `PronunciationAuditContext` now admits a seed when its selected output is
  empty or cannot be encoded by the Kokoro vocabulary, even without fallback,
  watch-word, acronym, or pack-disagreement evidence. Planner vocabulary rules
  remain unchanged.
- The materializer retains that seed as advisory evidence and always emits an
  explicit `decisionEvidenceMismatch` diagnostic. With no matching synthesis
  chunk the diagnostic has `chunkIndex == -1`; it does not invent a chunk.
- Headless capture sealing accepts only this strict evidence-only class:
  valid lexical advisory, valid location, unencodable selected output, no
  token IDs, and no timing/range fields. Ordinary malformed empty decisions,
  including a contextual advisory, remain rejected.
- The end-to-end headless regression uses real token evidence for `""` and a
  NUL output, invokes the analyzer, materializes with no synthesis chunks, and
  seals/validates then encodes and decodes the current schema-5 manifest. It
  proves incomplete coverage, the `-1` mismatch diagnostic, an empty listening
  reel, and the unchanged chapter content signature/cache key.
- Removed the earlier misleading render-plan tests that paired invalid seeds
  with unrelated valid synthesis chunks.

### TDD and verification

The initial RED run of the new headless regression was `47 total, 46 passed,
1 failed`: empty selected output produced no decision seed. The first GREEN
attempt exposed only a fixture provenance omission (the deliberate unowned
diagnostic needed its chapter stamped); after that concrete correction the
full terminal suite passed.

Final commands, through the governed Apple build slot:

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Result: build-for-testing succeeded, and `HeadlessNarrationRunnerTests` passed
47/47 in 428.962 seconds. `git diff --check` passed.

### Fix-round concern

The strict sealed-capture exception is intentionally restricted to lexical,
valid advisory evidence whose raw selected output is unencodable and whose
render timing is entirely absent. Future advisory categories must not reuse
this path without a separate capture integrity rule.

### Fix-round commit

Pending final commit:
`fix(narration): seal invalid G2P audit evidence`

## Fix round 3: typed raw-G2P receipt and sealed provenance

### Delivered

- Added a concrete, test-only `PronunciationPlanner` raw-result injection seam.
  Production still calls its owned `KokoroG2P` directly for planning, base IPA,
  and phoneme counts; successful output and strict `validatedIDs` behavior are
  unchanged.
- A typed planner error carries only a matched raw result with at least one
  unencodable token output. The render planner catches only that error, emits
  the exact raw-token decision/diagnostic, and creates no synthesis chunk.
  Any unproven invalid aggregate continues to fail planning.
- Centralized the evidence-only provenance boundary in
  `InvalidG2PAuditReceipt`. It permits only exact fallback or monitored-lexicon
  raw-G2P shapes with matching rule IDs and advisory authority/reason; override,
  candidate, contextual, and malformed source/rule combinations are rejected
  both by materialization and capture sealing.
- Removed title case as a standalone seed signal. Multi-letter all-caps
  acronyms remain eligible; title-cased tokens require an existing concrete
  signal. The production render-plan regression proves sentence-initial `The`
  produces no audit decision while the `startable` override remains the one
  exact final decision.

### TDD and final verification

The initial full headless RED run failed exactly the two new provenance attacks:
occurrence-override masquerading and a mismatched monitored-lexicon/fallback
rule were incorrectly accepted. A single-case selector was unsupported by this
test runner and executed zero tests, so the suite result is the RED evidence.

An intermediate render-plan run exposed a pre-existing title-case admission
bug: sentence-initial ordinary `The` seeded a monitored-lexicon advisory,
sorting ahead of the explicit override and eventually creating duplicate keys.
Restricting the renamed helper to actual acronyms fixed the production path.

Final commands, all through the governed Apple build slot:

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPlanTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationPlannerTests
```

Result: build-for-testing passed; render-plan passed 43 tests in 40.788 seconds;
headless passed 49 tests in 436.485 seconds; planner passed 8 tests in 8.649
seconds. `git diff --check` passed.

### Fix-round concern

The sealed receipt proves only the constrained structural provenance carried in
the manifest; it is not a cryptographic attestation that a particular renderer
process produced the raw G2P result. The no-synthesis, exact-source/rule, empty
ID/timing, and diagnostic gates are intentionally fail-closed.

### Fix-round commit

Deferred pending independent re-review; no push.

## Fix round 4: schema-five rejected-output proof and marker exclusion

### Delivered

- Schema 5 manifest decoding now requires every rejected raw G2P selected
  output to carry the same exact evidence-only invalid-output provenance used
  by capture sealing. This rejects an occurrence override, a wrong
  source/rule pairing, partial timing, and a fabricated nonempty token-ID
  payload; schemas 3 and 4 retain their legacy behavior of ignoring advisory
  fields.
- Added one shared semantic predicate for a rejected raw G2P output. The
  planner, render-plan mapping, candidate-analysis scope, receipt validation,
  and manifest validation now agree on that boundary.
- The exact standalone `KokoroPhonemeVocab.oovMarker` is deliberately excluded
  from the rejected-output predicate. Its established planner stripping path
  therefore remains synthesizeable and produces no invalid-output decision,
  diagnostic, zero-ID receipt, or capture warning. A raw string that combines
  the marker with another unsupported character is still rejected, preserving
  the fail-closed boundary for non-marker invalid output.

### TDD and final verification

The RED audit test initially showed that schema-five decoding accepted three
of the adversarial receipt shapes: occurrence override, wrong source/rule,
and partial timing. The RED render-plan test showed the marker-only result
still created a zero-ID fallback advisory even though its synthesizeable
phoneme payload was empty.

While making the legacy-schema test meaningful, the general decision fixture
was corrected from an invalid placeholder IPA to valid `ə`; invalid-output
tests now opt into an explicit NUL raw value. The final schema-five test also
supplies a fabricated `[42]` token ID, so the stricter rule is exercised with
nonempty fake IDs rather than relying on the historical empty-ID case.

Final commands, all through the governed Apple build slot:

```sh
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAuditTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPlanTests
XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
```

Result: build-for-testing passed; audit passed 24/24 in 11.371 seconds;
render-plan passed 44/44 in 33.561 seconds; and headless passed 49/49 in
440.594 seconds. `git diff --check` passed.

### Fix-round concern

The marker exception is deliberately exact-match only. It preserves the
existing isolated marker stripping behavior without broadening the set of
unsupported raw output that may become a normal synthesis result.
