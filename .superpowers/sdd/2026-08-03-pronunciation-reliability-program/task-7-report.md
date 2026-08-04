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
