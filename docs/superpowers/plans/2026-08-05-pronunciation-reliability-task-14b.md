# Echo Pronunciation Reliability Task 14B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` and test-driven development.

**Goal:** Replace Task 14's ambiguous neural-shadow receipt contract with a
versioned, word-bound, instability-preserving contract that is safe to publish
while keeping neural G2P advisory-only.

**Context:** This is a fresh redesign cycle after Task 14 exhausted its five
repair rounds at `b1bed56117e6dc3c8af646e42422394b145ed317`. The terminal
review found three load-bearing provenance questions: intermediate schema-5
candidate receipts lacked a migration rule, repeated evaluation could erase a
prior candidate, and candidate IDs were only syntax-checked. A reported
monitored-lexicon conflict contradicted the fallback-only production guard, so
this task must add a direct no-op regression rather than assume either reading.

## Global Constraints

- Neural G2P remains shadow-only. It must not change selected IPA, Kokoro token
  IDs, synthesis chunks, cache identity, resume identity, or production
  pronunciation authority.
- Preserve the production authority order and the fallback-only neural
  comparison guard.
- `NarrationFileNaming.renderVersion` remains `22`; this task changes only
  advisory evidence bytes.
- Rendering remains non-blocking. Cancellation still propagates; other model
  failures remain categorical advisory evidence.
- Do not add a dependency, remote inference, model download, or new narration
  engine.
- Keep private book content out of committed fixtures and reports.
- Every Apple build or test command must run through
  `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- <command>`.
- Do not claim performance, physical-device, audiobook-render, listening,
  human-label, hosted-CI, or production-authority proof unless newly run.
- Do not push or open a PR until the task-scoped immutable review and the
  cumulative Stage 3 review are safe.

## Task 1: Task 14B — Redesign Neural Shadow Receipt Provenance

**Primary files:**

- Modify: `EchoCore/Services/Narration/NeuralG2P/NeuralG2PTypes.swift`
- Modify: `EchoCore/Services/Narration/NeuralG2P/MiniBARTG2PEngine.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAdvisoryEvidence.swift`
- Modify: `EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify only directly affected QA presentation/localization surfaces.
- Modify focused tests under `EchoTests/`.

### 1.1 Prove the redesign RED before production edits

- [ ] Add a schema migration test showing an intermediate schema-5 manifest
  with one structurally governed neural candidate and no
  `neuralShadowObservation` decodes and validates under the schema-5 contract,
  but cannot silently claim the new current-schema contract.
- [ ] Add current-schema tests showing a well-formed invented `sha256:` ID is
  rejected, while the exact ID derived from normalized word, canonical IPA,
  model revision, conversion policy, validation policy, and selection policy
  is accepted. Mutating the word, IPA, or governed identity must invalidate it.
- [ ] Add repeated-evaluation tests: the exact same outcome is idempotent; a
  different governed candidate produces an explicit instability observation
  that retains bounded evidence of both candidates; later attachment cannot
  turn instability back into a clean candidate.
- [ ] Add a direct monitored-lexicon test proving neural attachment is an exact
  no-op and leaves the valid raw-invalid receipt unchanged.
- [ ] Add namespace tests proving delimited and case-varied reserved neural
  qualifiers cannot evade fail-closed classification, while ordinary strings
  that merely contain the letters as part of a larger token are not claimed.
- [ ] Run the narrow focused suite and record the expected behavioral failures.

### 1.2 Implement one governed candidate identity

- [ ] Move candidate-ID construction into `NeuralG2PGovernedIdentity` as one
  deterministic v2 contract. Canonicalize the normalized word and IPA before
  hashing; hash a domain-separated, unambiguous serialization containing the
  normalized word, IPA, exact model revision, conversion policy, validation
  policy, and selection policy.
- [ ] Have `MiniBARTG2PEngine` use that shared constructor. Have analyzer
  admission and persisted current-schema validation recompute the same ID; a
  syntactically valid but nonmatching digest is invalid.
- [ ] Persist the canonical neural-shadow normalized word in current advisory
  evidence so evidence-only validation can recompute the digest. Decision-aware
  validation must also require it to equal the decision's normalized word.

### 1.3 Version legacy acceptance and preserve instability

- [ ] Bump the pronunciation audit manifest to schema 6. Schemas 3 and 4 keep
  discarding injected advisory fields. Schema 5 decodes its full advisory
  decision shape and validates under an explicit legacy schema-5 contract.
  Schema-5 neural candidate evidence without the later observation/word binding
  remains readable as legacy evidence, but encoding must never silently promote
  an unbound legacy candidate to schema 6.
- [ ] Add a closed `unstableEvaluation` neural observation. A second materially
  different outcome must enter this state. Preserve at most the first two
  distinct governed candidates as bounded evidence; once unstable, remain
  unstable on later attachment. An identical repeat stays idempotent.
- [ ] Require current-schema neural observations to carry the bound normalized
  word. A current candidate requires exactly one recomputable governed
  alternative. Instability may retain zero, one, or two recomputable governed
  alternatives depending on the observed outcome sequence. Noncandidate stable
  outcomes carry no governed alternatives.
- [ ] Keep raw-invalid fallback receipt selection reasons sealed and keep the
  monitored-lexicon path model-free.
- [ ] Add a localized display name for the new instability observation and keep
  every enum switch exhaustive.

### 1.4 Verify and commit

- [ ] Run `git diff --check`.
- [ ] Run wrapped `make build-tests`, then the narrow identity/evidence/audit/
  preflight suites and all directly affected narration regressions.
- [ ] Run `make neural-g2p-qualification-test` and
  `make neural-g2p-qualification`; the receipt must remain truthful and
  shadow-only.
- [ ] Run wrapped full `make test`, wrapped macOS build, and wrapped
  `make echo-cli` if the focused gates pass.
- [ ] Confirm `renderVersion == 22` and no synthesis/cache/selection authority
  changed.
- [ ] Commit one coherent conventional commit and leave the tracked worktree
  clean and unpushed for immutable review.

Expected outcome: current neural advisory receipts are recomputably bound to
their word and governed identities, repeated evaluation cannot conceal
instability, schema-5 evidence has an explicit read-only compatibility path,
and Stage 3 remains truthfully shadow-only.
