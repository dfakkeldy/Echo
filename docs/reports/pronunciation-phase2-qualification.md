# Pronunciation Phases 0–2 Qualification

Date: 2026-07-30 (fourth consolidated repair round)

Overall status: **PENDING**. The independent local implementation gates listed
below are complete, but corpus-dependent qualification is
`WAITING_FOR_HUMAN_LABELS`. The development audio-judge API lane is
`WAITING_FOR_USER`. Eligible-device, rendered-audio, human-listening, hosted-CI,
merge, installation, and release proof are also absent and are reported
separately.

## Exact source state

- Branch: `codex/global-pronunciation-context-design`, based on
  `origin/nightly`.
- Last committed implementation before this correction round:
  `cd94cdcd9cbe64dc2c4b4d240a86418e21f28098`.
- The source state qualified by this report is that commit plus the commits of
  this repair round, ending with the commit that contains this receipt. The
  final Task 10 identity is therefore the commit containing this file; no
  circular placeholder hash is embedded here.
- **Every gate in the table below was run at
  `3215875b29596039757f15e5763c1fbec1c1cbb6`**, the last source commit of this
  round, and each gate started after that commit was written (last commit
  2026-07-30T23:43:31−03:00; earliest gate log 23:43:49, latest 23:52:20).
  Only this receipt is committed afterwards, and it changes documentation
  only. An earlier revision of this table recorded the complete Echo unit-test
  gate and the Release `echo-cli` build as "not rerun" while `progress.md`
  recorded that both had run. That contradiction is resolved here in favour of
  what was actually executed: both ran, and this table is the authoritative
  record.
- The canonical Echo checkout and the separate Article Anthologies worktree
  were not modified by this work.

### Correction: a controller-supplied SHA that did not resolve

The brief opening this round specified the base commit as
`2c693b8ea1e40e50fe25ea4ea4ae5c4b8a6a1c86`. **No such object exists in this
repository.** `git cat-file -t` failed on it, and
`git rev-parse --disambiguate=2c693b8e` returned exactly one object —
`2c693b8ed5808012abed825262f43bacdc45b6a3`, the actual `HEAD`, whose commit
message matched what the brief described. The two share only the eight-hex
prefix and diverge at character nine; a reviewer's report had given the correct
short prefix in one place and a bad forty-hex expansion in another, and the
expansion was propagated without checking that it resolved.

Recorded rather than quietly repaired, because a controller passing an
unverified identifier down to a worker is the same class of defect this
programme has been catching in the code: an identity asserted rather than
checked. Work stopped and reported instead of proceeding on a guess, and the
base was confirmed before any file was touched. The standing rule taken from
it: **every SHA supplied in a brief is a claim to verify, not a fact.**

## Local unit and build gates

The following independent local gates were each run separately and passed at
the corrected state of this round on 2026-07-30. Nothing in this table is
carried forward from an earlier state; a gate that was not rerun would be
recorded as not rerun and would not count as a pass.

| Gate | Result |
| --- | --- |
| Pronunciation corpus tests (`make pronunciation-corpus-test`) | 53 distinct test methods, 53 executed, all passed; contract `CONTRACT_VALID` with 37 named regressions |
| Corpus qualification (`make pronunciation-corpus-qualification`) | Ran; reports `WAITING_FOR_HUMAN_LABELS` with zero qualifying rows, which is the truthful state and not a pass of qualification |
| Development audio-judge tests (`make pronunciation-audio-judge-test`) | 103 distinct test methods, 127 executed, all passed without an API request |
| Pronunciation pack tests (`make pronunciation-pack-test`) | 38 distinct test methods, 38 executed, all passed; `build_pronunciation_pack.py check` reproduced the committed pack byte-for-byte from the pinned lock, gold, silver, and vocabulary inputs. This gate is named by brief 10.6 but was **absent from every earlier revision of this table**. Because the preamble above promises nothing is carried forward, omitting it was worse than mislabelling it: a reader could not tell "not run" from "not mentioned". It is now run and recorded |
| Deterministic program report (`make pronunciation-program-report`, twice) | Two runs byte-identical; SHA-256 `f592456769e35628573415be183a5d9e37138ce84ed4c34391e36fd229bb0343`, unchanged from the previous round |
| Task 10 Swift acceptance suite | Run together with `EnglishPronunciationPackTests`, which gained the token-scanning sense-label test this round: `EnglishPronunciationPackTests` is 26 tests, all passed. Both suites also ran inside `make test` below |
| Complete Echo unit-test gate (`make test`) | `** TEST SUCCEEDED **`, zero recorded issues (`✘` count zero across the whole log) |
| Release `echo-cli` build (`make echo-cli`) | Completed successfully; `echo-cli (Release) ready at .build/cli/Build/Products/Release/echo-cli`. Production Swift changed again this round (`EnglishPronunciationPack.swift`), so this was a real relink rather than a no-op revalidation |
| Mutation check on the guards fixed or newly tested this round | Seven mutants, each neutralising exactly one guard: all **killed**. Ad-hoc harness, not committed |
| Python compilation | `compileall` clean on both tools and both test modules |
| Diff hygiene | `git diff --check` and `git diff --cached --check` both clean |

Distinct and executed test counts are stated separately because both
audio-judge gate classes inherit from `ManifestAdmissionTests`. Twelve methods
defined on that base class therefore execute three times — once in the base
class and once in each of `EvaluationGateTests` and `AttemptLedgerTests`.
The arithmetic: 91 methods defined on the leaf classes execute once each, and
the 12 base-class methods execute three times each, so **103 distinct methods
produce 127 executed tests** (91 + 36 = 127; 91 + 12 = 103).

An earlier revision of this report stated only the executed figure. The
revision after that stated **95 distinct and 119 executed in this paragraph
while the gate table above said 98 and 122** — a self-contradiction within one
document. The table was the correct pair. Both figures have since moved
together, because this round added five test methods, all on leaf classes:
one for the erasure-laundering defect (B-1), two for the previously untested
`_morning_queue_row_authority` and recovery-precondition guards (S-3), one for
canonical-encoding failures, and one pinning the `HTTPError` clause ordering
that broadening the transport handler put at risk. Counts are now derived
mechanically from `unittest`'s loader rather than by hand, which is what the
earlier contradiction warranted.

The pronunciation corpus and audio-judge suites now run in hosted CI as
dedicated pre-Xcode steps, with a pinned and cached `ffmpeg`/`ffprobe` install
step. The suites keep their hard `assertIsNotNone`/`check=True` media
requirement rather than a skip condition, so an absent media toolchain fails
the gate instead of silently reporting a pass. `.github/workflows/ci.yml` was
not in the Task 10 Files list when the task was written; the user authorized
keeping it inside Task 10, and the implementation plan now records it with its
rationale.

A local test or build is not hosted CI, device execution, rendered-audio
verification, human listening, installation, or release proof. No hosted CI run
has yet executed these gates on this branch.

## Pack reproducibility and attribution

The committed pack passed strict decoding, compact candidate-shape validation,
source resolution, regeneration, and independent identity checks.

- Schema version: `1`
- Semantic pack version:
  `sha256:9296e01d067d8ed852ef27af12ffae555e6949c8c4c2168dc1f3206aaf27b11a`
- Generator: `echo-pronunciation-pack-generator-v2`
- Entry count: `76125`
- Candidate count: `80407`
- Canonical normalized-data SHA-256:
  `sha256:42a327d7529de213ee4ed95d63a2f0fb3b084174d0906bf2985c93511a206a8e`
- Kokoro vocabulary version:
  `sha256:248ee3192acfc27a9907180354a0efaa63389047a6ff78c3f75e2e19466d0b76`
- Dialect: `en-US`
- Audit-only generation timestamp: `2026-07-29T14:25:08Z`
- CMUdict snapshot: `cmudict@74790861f652b15e4ac49015a90074ad62a27690`,
  SHA-256
  `sha256:81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22`
- Existing gold exclusion snapshot:
  `echo-us-gold@sha256:41a6a1eac110cd2f5fed4d3dd45ea63668bd04723ce2048b78d07782ba3a9a83`
- Existing silver exclusion snapshot:
  `echo-us-silver@sha256:ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c`
- Generator behavior: ARPAbet mapping
  `cmudict-arpabet-to-kokoro-v2`; automatic selection
  `single-validated-compatible-candidate-v2`; candidate validation
  `source-candidate-validation-v1`; normalization
  `english-key-normalization-v1`; source precedence
  `gold-silver-exclusion-v1`.
- License and acknowledgment: `CMUdict-BSD-style` at
  `ThirdParty/CMUdict/LICENSE`; the required CMUdict notice is bundled from
  `THIRD_PARTY_NOTICES.md`.

The canonical semantic payload was independently rebuilt from normalized
content, all three source snapshots, generator behavior, Kokoro vocabulary, and
dialect. Its hash matched the stored pack version. Candidate/content, source,
generator-behavior, and vocabulary mutations changed the semantic identity.
Timestamp-only mutations did not change semantic, morphology, production-plan,
or cache identity.

The independent morphology fixture freezes policy identity
`morphology-v1:sha256:58523e5570d98308c8f233be1e1cadb6c0f32079f54725f87ddabaa4151ca5d9`
and exact candidate vectors for `startable`
(`morphology.startable.14f4cfb4f8f1`), `testable`
(`morphology.testable.57a53afaf83e`), `reusable`
(`morphology.reusable.be1a57f13876`), `digestible`
(`morphology.digestible.8a5b26d6f3a9`), and `deductible`
(`morphology.deductible.f0169beb0e5d`). Acceptance tests separately mutate the
rule set, exception set, base-evidence policy, semantic pack, Kokoro vocabulary,
normalized word, derivation base/rule, and base/derived IPA. Each applicable
identity changes through the actual render plan, and every production-affecting
policy mutation changes `NarrationFileNaming`'s cache signature.

## Corpus contract, human-label status, and deterministic metrics

Status: **`WAITING_FOR_HUMAN_LABELS`**.

The committed contract contains 12 explicitly provisional synthetic rows: three
for each of `content`, `read`, `live`, and `record`. It contains zero qualifying
independent human-labelled rows and zero adjudicated rows. Provisional rows
were excluded from labelled counts and accuracy; no accuracy was calculated.

The exact remaining qualification requirement is 200 qualifying rows per
family and 50 per sense for:

- `content.material`, `content.satisfied`
- `read.past`, `read.present`
- `live.adjective`, `live.verb`, `lives.noun`, `lives.verb`
- `record.noun`, `record.verb`

Deterministic metric counts were 1 definitive/resolved, 13 advisory, and 23
abstained across 37 named rows. Those values are an explicit frozen
discovery/analyzer-state contract, and the Swift acceptance suite binds every
row to the production discovery and analyzer result. They are not inferred
from case names or intended labels.

The single definitive row was added in this round. The matrix previously froze
the definitive count at zero, which meant `homograph.content.adjective.copula`
— the only promoted definitive rule in the system — had no named coverage, the
`content` family could have passed its §13.3 named gate without ever running
its own rule, and the definitive branch of the outcome derivation was dead with
respect to this matrix. `named-content-definitive-copula` now exercises it.

Every named row also carries the spec §13.1 `expectedOutcome`, restored as a
required field alongside — not in place of — the discovery and analyzer-state
fields. Analyzer strength is deterministic evidence; the outcome is the
§9.1/§9.2 decision that evidence produces, and the two axes are asserted
separately. The Swift suite derives each row's outcome from production
evidence rather than restating the fixture: a valid Misaki override, a
definitive deterministic rule, or one explicit unambiguous lexicon candidate
is `automatic` (§9.1), and everything else is `review` (§9.2). The result is 5
`automatic` rows — the four `override-markup` rows plus the definitive copula
row — and 32 `review` rows.

The premise that makes the remaining rows review decisions is the resolver's
`UniversalPronunciationResolver.contextualExclusions` set, which refuses these
spellings *before* the pronunciation pack is consulted. An earlier revision of
this receipt cited the pack's silence on those spellings instead. That premise
was incidental — the pack is supplemental and already excludes 36,966 gold
spellings — so it proved the wrong thing even though the behavior was
fail-closed. The suite now asserts the exclusion set for every named row and
feeds that into the outcome derivation.

Every named row also declares
`expectedOutcomePolicyMode: phase2-shadow-deterministic-only`, and the suite
asserts the declared mode equals the mode it evaluates. The outcome column
encodes one policy mode: §9.1's fifth clause — deterministic and model
agreement on a graduated family — is inert while every family is shadow-only
and goes live at Phase 3, which would otherwise silently invalidate the frozen
column at exactly the moment §13.3 uses it to gate graduation. Adding a second
mode is now an explicit, testable change rather than a silent reinterpretation.

### Phase 0 contract amendment

§14 Phase 0 froze the named-regression and morphology corpus contracts, and
Task 10 materially rewrote the named contract: `expectedDiscoveryState` and
`expectedAnalyzerState` were added, `expectedOutcome` was removed and then
restored, `expectedOutcomePolicyMode` was added, and one row was appended. This
is the explicit amendment record.

The pre-removal `expectedOutcome` column was a per-shape constant, identical
across all four families, that marked `misleading-adjacent-cue`,
`heading-fragment`, and `malformed-fragment` as `review` and everything else as
`automatic`. That assignment is unsatisfiable under §9.1: it marked rows
`automatic` that have no override, no definitive rule, and no unambiguous
lexicon candidate. It is superseded by the derived column described above,
which is bound to production evidence. The morphology contract changes are
recorded in the Task 10 report and commit history.

Named rows are now evaluated over their full authored three-sentence window.
`precedingSentence` and `followingSentence` are decoded and composed before
discovery and analysis, and the target's word index is resolved inside the
target sentence and then offset, because a preceding sentence may contain the
same spelling. The four `misleading-adjacent-cue` rows therefore actually
present their misleading adjacent sentence for the first time; discovery and
analyzer counts were unchanged by the correction, and each row still resolves
to its expected candidate. `override-markup` rows now run the production
analyzer instead of being assigned a literal `.abstained`; the analyzer
abstains on all four, so the override-authority invariant is proven by
production code rather than by a self-fulfilling assertion.
Morphology fixtures contained two exact-base `-able`, one silent-e `-able`, two
exact-base `-ible`, and nine negative cases. The pack report counted 76,125
imported spellings, 3,982 ambiguous spellings, zero incompatible spellings,
36,966 existing-gold exclusions, and 12,021 existing-silver exclusions.
Frequency-band reporting is
`unavailable-no-approved-source`; no unapproved frequency source was inferred.

Corpus-dependent qualification and final Phase 0–2 acceptance remain pending.
No agent-generated, model-generated, provisional, or source-order label is
represented as human evidence.

Any future trusted human receipt must be paired at evaluation time with an
absolute, single-link regular, non-symlink authority file outside the
repository. The authority is read once through a no-follow descriptor and is
rejected if its inode, link count, size, or modification metadata changes
during the read. It binds the canonical SHA-256 of the exact contextual corpus
plus the exact trusted-receipt set and is required before those receipts can
contribute to qualification. The report API and CLI accept the paired external
receipt and authority paths explicitly; with neither path, the default Make
report remains `WAITING_FOR_HUMAN_LABELS`. It is an explicit
operator-controlled integrity root, not cryptographic proof of who listened or
how a label was obtained; the receipt schema, source-verifiability rules, and
human adjudication requirement remain independent gates. No trusted receipts
or human-evidence authority were present for this report.

## Development audio-judge API evaluation

Status: **`WAITING_FOR_USER`**. No usable OpenAI API credential was available,
so this lane has neither passed nor failed.

One one-second, provisional synthetic WAV was used for admission and cap
validation only. It was not private or copyrighted material, not a book
excerpt, and not a production Echo pronunciation render.

- Corpus identity:
  `sha256:70d359f4d696e5afb2219cc3efcaf21a58b0c03093bb494f1d3e27efe5a1c7fa`
- Manifest content SHA-256:
  `c3777da6145aef904aa33ddae1f7c9cd4a7865068782b57ddd4085de8f551b76`
- External provenance-authority SHA-256:
  `1a2953b33b444e40331e8f31dffd7ab43cf0cb020289597dbd62e995c80cc729`
- Audio content and render identity:
  `sha256:be50f5a6c63045f14eb158c94377b2ed153f848bc21b4364727bbc83179c4e61`
- Source commit:
  `273cc88d444074e9f8e289da4337abd4a48dbbc4`
- Requested model: `gpt-audio-1.5`
- Returned models: none
- Admitted clips: 1
- API requests: 0
- Transport attempts: 0
- Per-request usage: none
- Conservative estimated cost: USD 1.030021
- Structured results: none
- Validation outcome: the dry run admitted the clip and completed with no HTTP
  request; the credential-free run emitted `WAITING_FOR_USER`
- Retry outcome: no retry was eligible or attempted
- Morning queue count: 0
- Dry-run ID: `public-synthetic-v1-authority-v3-dry`
- Credential-free run ID: `public-synthetic-v1-authority-v3-waiting`
- Dry-run receipt SHA-256:
  `5c15a35787d2d6598b3ba3c50e062af012c3f086b6b04a1f525d198317055b94`
- Credential-free receipt SHA-256:
  `76d16ffe7eac03add142db012ab341b60b6bfc4f2879be8192dbc648b2d59211`

The scalar- and envelope-validation corrections did not regenerate or replace
either valid authority-v3 artifact. The run IDs and receipt hashes above remain
the exact recorded evidence; no new API or transport claim is implied.

Pricing was rechecked on 2026-07-29 and stored as
`gpt-audio-1.5-pricing-2026-07-29`: USD 2.50 per million text-input tokens,
USD 10.00 per million text-output tokens, USD 32.00 per million audio-input
tokens, and USD 64.00 per million audio-output tokens. Sources:
[model](https://developers.openai.com/api/docs/models/gpt-audio-1.5),
[model catalog](https://developers.openai.com/api/docs/models/all),
[audio guide](https://developers.openai.com/api/docs/guides/audio), and
[Chat Completions API](https://platform.openai.com/docs/api-reference/chat).
The `exact-request-bytes-and-probed-audio-v2` rule derives its text bound from
the exact minified request bytes with audio data removed, derives its audio
bound from the greater of actual decoded payload bytes and 1,000 tokens per
probed second, and fixes the maximum text output at 180 tokens. The manifest
supplies no token estimates. Each real transport attempt, including a retry,
must durably reserve its request number and conservative cost before sending.
Run IDs are atomically claimed and cannot be reused or overwrite an earlier
run.

The append-and-fsync attempt ledger remains the correction workflow's commit
point. Its state snapshot and terminal repeated-failure morning-queue entry are
derived publications. If either publication is interrupted, replaying the
exact complete command rebuilds the snapshot and publishes the queue entry
without appending a duplicate event; any conflicting source, receipt, category,
render, or outcome evidence is rejected. The complete queue is reconciled
against every required terminal ledger event before publication. A collision
on either the authoritative sequence or canonical SHA-256 must match the same
exact ledger row, including clip, category, and reason; exact duplicates
collapse, while strictly valid non-ledger evaluation rows are preserved.

The offline `audio_judge.py recover` command accepts only `--run-id` and
`--output-root`. It validates the external judge-owned claim, strictly replays
the ledger, validates and plans the complete queue, then repeats that validation
under the lock before republishing the snapshot and every required terminal
queue entry. It emits only safe local counts. It does not reopen a manifest,
authority, or audio file; inspect credentials; build a request; reserve an
attempt; or invoke transport. Invalid or conflicting runs fail before changing
ledger-derived state. Queue conflicts detected by the outside-lock preflight
leave the snapshot, queue, ledger, receipt, and lock bytes unchanged.

Recovery opens the claimed directory once with `O_DIRECTORY | O_NOFOLLOW` and
pins its descriptor identity. Claim, ledger, and queue reads; the required
pre-existing lock; under-lock validation; temporary files; and atomic
snapshot/queue replacements all remain relative to that descriptor. A missing
lock is rejected without creation. Pathname identity is checked before lock
open and before publication; deterministic check-to-open and
check-to-publication swaps preserve both directory byte snapshots and create no
replacement artifact. The descriptor prevents an after-check swap from
redirecting writes to the replacement, but no stronger claim is made against a
malicious same-UID actor mutating or renaming the already-open original.

Run-claim, JSONL attempt-ledger, and morning-queue decoding translates
duplicate keys, malformed JSON, non-finite constants, and parser
`ValueError`s such as 5,000-digit integers into controlled `LedgerError`s.
Both direct and shipped-recovery tests confirm no traceback or raw content,
file mutation, or lock creation on those failures.

Claims, ledger events, queue rows, model responses, input manifests, and
provenance-authority bindings require exact JSON scalar types before equality,
membership, regular-expression, finiteness, or bounds checks. Boolean schema
versions, structured closed-vocabulary values, and unbounded integer durations
or confidence values fail as controlled validation errors without a traceback.
Invalid admission data creates no run receipt and reaches no transport.
Invalid model response fields route to `malformed_output` morning review and
are not persisted as verdicts.

The raw API parser also validates every response-envelope layer before
extraction: object root, non-empty choices array, object choice and message,
string-or-null content/refusal, string model ID, and object usage. Malformed
transport JSON, including a decoder `ValueError` for an oversized integer,
becomes a controlled permanent transport failure rather than leaving a
`RUNNING` receipt. Recognized usage counts must be exact non-boolean integers
between zero and 10,000,000. Reported totals must be consistent with prompt and
completion counts when all are present, and recognized detail counts cannot
exceed their parent. Any invalid recognized count rejects the entire usage
envelope; no selected detail fields are salvaged or persisted. Run IDs are
required to be strings before regular-expression validation. A paid transport
call that returns normally without any response is classified as
`malformed_output`, preserves its truthful request and reservation counts, and
routes a redacted item to morning review instead of completing as a pass with a
null verdict.

The normalized response contract also requires `refusal` to be explicitly
present as null or a string; omission is malformed and cannot pass. The
pre-reservation request estimator strictly round-trips each programmatic body,
rejects duplicate/non-finite/oversized JSON, and requires the exact pinned
model, output bound, message/role order, closed prompt, and audio-item shape
with the admitted `wav` or `mp3` format. Missing, extra, duplicate, or mistyped
fields expose only a generic `ManifestError` before a run claim, reservation,
or transport. Strictly decoded audio must also be non-empty and hash to the
exact admitted clip SHA-256. The hash check runs during the pre-claim baseline
and again after each attempt rebuilds from revalidated media, before
reservation or transport. The estimator then re-serializes the data-redacted
body, while valid WAV and MP3 judge-built bodies keep the same request and cost
estimate.

Admission also requires a separate absolute, single-link regular, non-symlink
provenance authority file outside the repository. It binds every admitted
clip's opaque ID, measured audio hash, duration, and
`public-domain`/`synthetic` provenance; the receipt records the authority hash.
The admitted manifest's immutable byte snapshot supplies both the receipt's
corpus identity and its manifest-content hash, so replacing the manifest path
after admission cannot rebind the receipt.
Judge-owned claims and mutable run artifacts must also be single-link files,
preventing append/state writes through an external hardlink. This is an
operator-controlled integrity root that prevents the manifest from authorizing
itself. It is not cryptographic proof that the operator's provenance assertion
is historically true, so licensing/provenance review remains a separate
responsibility.

No raw text/audio, title, author, local path, user/book identifier, metadata,
API key, or request header is present in the receipts or this report. The
machine judge has no production authority, supplies no human label or human
listening result, never contributes to accuracy, and cannot authorize Phase 3.
Optional model-authored `heard` and `note` values are validated but never
persisted.

## Eligible-device Foundation Models shadow run

Status: **NOT RUN**.

No evidence was obtained from an Apple-Intelligence-eligible iOS 26+/macOS 26+
device with the model available. Therefore this report does not claim real
model session execution, two-run agreement, device/model unavailability,
context reduction, transient retry, refusal, structured-output rejection, or
cancellation behavior on eligible hardware. Unit and build evidence are not a
substitute.

## Ineligible/older-platform fallback

Status: **LOCAL TEST EVIDENCE ONLY**.

The source and acceptance tests preserve deterministic production behavior when
the model is unavailable or contextual preflight is omitted, and keep shadow
evidence out of production cache identity. The deployment floors remain iOS 18,
macOS 15, and watchOS 11; Foundation Models are availability-gated at iOS 26
and macOS 26. No actual older/ineligible device run was performed.

## Cancellation and categorized failures

Status: **LOCAL UNIT EVIDENCE ONLY**.

The local Foundation Models selector/integration tests cover cancellation,
availability, bounded retry, context limits, refusals/guardrails, structured
output validation, and categorized failures. No eligible-device execution of
those paths occurred, so runtime behavior remains unqualified.

## Mechanical audio integrity

Status: **NOT RUN FOR PRODUCTION RENDERED AUDIO**.

The audio-judge admission probe independently measured and hashed the synthetic
file. That proves only media admission, direct-file handling, and content
identity. It does not prove a production Echo render, plan-to-waveform
integrity, a listening reel, or pronunciation correctness.

## Human listening

Status: **NOT PERFORMED**.

No person listened to and labelled the bounded qualification set. Machine
verdicts and transcription, if later obtained, remain separate development
evidence and are never described as human listening or human labels.

## Hosted CI

Status: **NOT RUN** for the Task 10 source state at the time this receipt was
written. Local tests and builds are not hosted CI.

## The ledger tamper-evidence invariant, and why it is stated rather than patched

The hostile review found a blocking defect in the attempt-ledger
tamper-evidence scheme in **three consecutive rounds, and each was the sibling
case of the fix before it**: round one hardened truncation and left emptying
open; round two's fix left "delete both files" open; and the schema-1 migration
branch added by that same fix opened a laundering path of its own. Each round
closed the seam in front of it rather than the class of seam. This round states
the invariant and implements it once, in `_verify_run_directory_witnesses`.

**Witness monotonicity.** A run directory's artifacts are *witnesses* to a
history. A proposed state **S** is accepted only if every witness that survives
in the directory is consistent with **S**. An absent witness proves nothing. A
present witness that contradicts **S** refuses it, whatever else is present.
Therefore **deleting an artifact must never widen the accepted set**: for
artifact sets A ⊆ B, no state refused under B may become accepted under A.

The predicates, evaluated as one conjunction rather than as guards at the call
sites, are: **W0 the anchor is present**; W1 `len(L) ≥ A.eventCount`; W2
`chain_head(L[:A.eventCount]) == A.lastEventSHA256`; W3
`len(L) − A.eventCount ≤ 1`; W4 `len(L) ≥ q.sequence` for every queue ledger
row; W5 that row's named event reproduces it exactly; W6 the ledger chains from
genesis with no interior rewrite; W7 the run claim is valid. **Recovery accepts
exactly the mutating path's set minus W3**, the lag rule — it may tolerate
staleness, never contradiction.

### W8 is retired. The anchor is now mandatory.

The previous revision of this receipt recorded W8, "anchor absent ⇒
`len(L) ≤ 1`", as an **assumption, not a witness**, and defended it with this
sentence: *if both the ledger and the anchor are deleted, no surviving witness
can distinguish tampering from a fresh run.* **That sentence was false, and
labelling W8 as the weak point is what made the defect findable.** A fourth
round broke it.

Two things were wrong. First, the claim itself: `receipt.json` survives such a
deletion and records `verdict == "fail"` for every clip `_emit_proposal` ran
for, which contradicts an empty ledger. It is classified "no" in the witness
table because it is not load-bearing, not because it is uninformative. Second,
and decisively, W8's tolerance of `len(L) ≤ 1` existed to accommodate the real
crash window between the first append and the first anchor publication — so
truncating a ledger to its first line landed exactly in the gap the rule
conceded. Neither `rm` of all three artifacts nor `head -1` of the ledger was
refused; both laundered a terminal `morning_review`/2 clip back to
`proposal_emitted`/0, with no forgery and no hash computation.

The fix is **structural, and is a deletion rather than another predicate**.
`_claim_run` now writes a schema-2 anchor — `eventCount: 0`, genesis head —
atomically beside `run-claim.json`. `_atomic_write_json` is temp-plus-rename,
so from the instant a run is claimed the anchor is never legitimately absent;
the crash window W8 existed to tolerate does not exist; and `rm
attempt-state.json` becomes evidence rather than amnesia. W8 is replaced by W0,
"anchor absent ⇒ refuse". This *removes* an underived rule instead of adding a
member to it, and it is what makes the invariant's own headline sentence true
of the anchor.

### The enumeration, re-derived

Because W0 refuses every anchor-absent state outright, the six anchor-absent
rows collapse to one and the table is now **seven states, not twelve**. The
full table is carried in the `_verify_run_directory_witnesses` docstring, which
remains the authoritative copy. What changed:

- **Old rows 1, 8 and 9 — the accepting anchor-absent states — are now
  REFUSED.** Row 1 accepted a fresh run on the strength of its emptiness; rows
  8 and 9 accepted a one-event ledger with no anchor through W8's crash-window
  tolerance. Rows 8 and 9 are precisely where the `head -1` laundering landed.
- **Old rows 3 and 10 keep their REFUSE verdict** but are now refused earlier
  and for a stronger reason: W0 rather than W4/W5.
- **Old row 4 — empty ledger, present count-0 anchor at the genesis head — was
  an oddity reachable only after a completed cycle. It is now the ordinary
  state of every newly claimed run directory**, and is how a genuinely fresh
  run is still accepted rather than refused by W0. It is new row 2.

The reproduction W4 closed in the previous round: from `attemptCount=2,
state=morning_review`, removing `attempt-ledger.jsonl` and `attempt-state.json`
left the run reading as fresh while `morning-queue.json` still carried the
terminal entry, the clip ID, and the SHA-256 of the event that produced it. The
mutating path never loaded the queue at all. A full `_emit_proposal` →
`record_attempt` → `record_rerender` cycle then completed and authorized a
production rerender, taking `attemptCount` 2 → 1 — a transition §13.3(6) calls
irreversible. Removing the queue as well reopened the same laundering through
old rows 8 and 9; W0 is what closes it.

## Known limitations recorded rather than closed

- **Anchor substitution is not covered by W0.** W0 makes an *absent*
  `attempt-state.json` evidence of tampering, restoring deletion-monotonicity
  for the anchor. It does not cover *overwriting* it. An actor with write
  access to a run directory can restore the fixed claim-time anchor
  (`{"clips":{},"eventCount":0,"lastEventSHA256":"0"×64,"schemaVersion":2}`
  — a constant, identical for every run), truncate `attempt-ledger.jsonl` to
  one line, and remove `morning-queue.json`, and the mutating path accepts the
  result: a terminal `morning_review`/2 clip reads back as `proposal_emitted`/0
  and a fresh attempt can be spent. This is the round-4 laundering with a write
  substituted for a delete, at no additional cost to the attacker. It is
  accepted as out of model (same-UID write access to the run directory), not as
  closed. Closing it would require an anchor witness that a fixed constant
  cannot satisfy — e.g. binding the anchor to the claim (run ID + claim-time
  nonce, so the genesis anchor is per-run and not replayable) or a monotone
  counter outside the directory.
- **Recovery requires `.attempt-ledger.lock` to already exist, while the
  mutating path creates it.** So `rm .attempt-ledger.lock` — a zero-content
  file — makes `recover` refuse until it is restored. Reviewed this round and
  **deliberately kept**. The asymmetry is what lets a refused recovery leave
  the run directory byte-identical, a property
  `test_recover_requires_existing_lock_without_creating_one` already pins;
  adding `O_CREAT` would mean the command whose purpose is to restore evidence
  mutates a directory it is in the middle of rejecting. The cost is
  availability, not laundering: the lock is "n/a" in the witness table, so its
  absence widens nothing, and `touch` or any later mutating operation restores
  it. This was changed and then reverted during the round when the existing
  test surfaced the property the change would have broken.
- **The `rank` order-token asymmetry leaks in the false-*accept* direction.**
  `rank` was removed from `EnglishPronunciationPack.senseLabelOrderTokens`
  because an organ *rank* is a real register, so `rank 8` for `organ` names a
  genuine sense. The removal is broader than that case.
  `isMeaningfulSenseLabel` refuses a label only when *every* token is ordering
  vocabulary, so with `rank` out of the set a bare `rank` and a bare `rank
  two` are both admitted as meaningful sense labels, while bare `form`,
  `reading`, `no` and `variant` are still refused. The asymmetry is cosmetic
  and unrelated to the ledger — it
  admits an uninformative label rather than discarding a real one — but the
  narrow fix (`rank` ordering only when it is the whole label, or only when no
  content token accompanies it) is a **named follow-up, recorded not fixed**.
- **The depth-989 encode `RecursionError` does not reproduce on this
  interpreter.** CPython 3.14.6's C encoder does not consume the Python stack
  and survives nesting of 60000; only the pure-Python encoder raises, at about
  2000. The guard is still correct and is now in place, but the reported
  reproduction was interpreter- and build-specific, so the test pins the
  contract — every canonical-encoding failure surfaces as `LedgerError` — with
  one naturally occurring failure and one injected error rather than a literal
  depth.

- **The USD 10 / 200-request cap is per run ID, not cumulative.** Concurrent
  runs, or a fresh run ID, each get their own budget, so N runs can spend
  N × USD 10. The spec scopes the cap per run, so a root-level cumulative
  accumulator is a design change beyond Task 10 and is deferred.
- **The cost estimator is byte-count-floored, which makes WAV effectively
  inadmissible.** `audioInputTokens` is `max(payload bytes, duration ×
  1,000)`, so a 15 s 16 kHz mono WAV estimates about USD 15.36 and a 15 s
  44.1 kHz stereo WAV about USD 84.68 — both above the hard USD 10 cap. A 15 s
  128 kbps MP3 estimates low enough to admit roughly one clip per run. The cap
  is a hard user constraint and is not raised. In practice this lane accepts
  short MP3 clips, and WAV only at very small sizes or durations; a rate-based
  estimator is a deferred follow-up.
- **`frequencyBandReport` has no conditional branch.** It always reports
  `unavailable-no-approved-source`. This is fail-closed and harmless, but it is
  a constant rather than a computed result.
- **A chained `CalledProcessError` carries the probed audio path in
  `__cause__`.** Redaction covers persisted artifacts and reported messages;
  the interpreter's exception chain is not redacted.
- **`ffprobe` and `ffmpeg` are required external binaries for this gate.**
  They are *not* newly required by Task 10, which an earlier revision of this
  receipt stated incorrectly: `Tools/transcription_generator.py` already
  required `ffmpeg` at `273cc88d` and documents `brew install ffmpeg`. What is
  new is that a CI job now depends on them, so the install is pinned to a
  formula version and its download cached rather than floating.

## Named risk to check before the first paid request

**The API refusal-field requirement may reject every real response.**
`_post_chat_completion` requires `"refusal" in message` and treats its absence
as an invalid envelope, which becomes a `PermanentTransportError`. The live
Chat Completions API frequently omits `refusal` entirely. If it does, every
real response fails closed and the paid lane cannot complete. This was found by
code reading only. The paid lane is `WAITING_FOR_USER` and no outbound call was
made to check, so this is recorded rather than tested. **Verify the actual
response envelope against a single cheap request before running the corpus.**

**A crash mid-run consumes a whole request and spend budget with no way to
reclaim it, and repeated crashes give unbounded cumulative spend.** This round
typed four connection-level failures — `RemoteDisconnected`, `IncompleteRead`,
`ssl.SSLError`, and `ConnectionResetError` — that could previously kill the run
with a raw traceback out of `response.read()`. **Typing those exceptions does
not address this budget gap; they are two different problems.** `_claim_run`
makes a run ID single-use, so recovering from any crash that ends a run
prematurely requires a *new* run ID, which starts with a fresh 200-request /
USD-10 budget, while the crashed run has already spent part of one. Nothing
accumulates spend across run IDs. Three crashes therefore authorize up to three
full budgets. The cross-run accumulator that would close this remains
**deferred** — it is a design change to the budget model, not a repair. Until
it exists, an operator must track cumulative spend across run IDs manually
before each paid run.

## Follow-ups recorded from the third review round, not implemented

- **`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`, and `GIT_CONFIG_VALUE_n` are
  missing from the environment scrub list** used when the tool queries git.
  They allow arbitrary configuration injection without touching a config file.
  Recorded rather than fixed this round: the scrub list is shared with other
  callers and changing it belongs with a review of that list as a whole.
- **A repository using `--separate-git-dir` places the shared git directory
  outside the checkout**, so the protected-root computation can over-protect an
  unrelated parent, up to and including `$HOME`. Fail-closed, so recorded.
- **A worktree path containing a newline still drops out of protection**,
  carried forward unchanged from the second round for the same reason.

## Follow-ups recorded from the second review round, not implemented

- **`_with_ledger_lock` does not pin the run directory's `(st_dev, st_ino)` or
  re-validate the run claim under the lock**, unlike
  `_with_recovery_ledger_lock`. Found by code reading; not reproduced. Closing
  it changes the locking design on the mutating path, which is wider than a
  repair round should take unreviewed.
- **`run_evaluation` writes `morning-queue.json` outside the ledger lock**,
  where `record_rerender` writes it under the lock, so a concurrent rerender's
  rows could be clobbered. Found by code reading; not reproduced. Also a
  concurrency design change.
- **`REPOSITORY_ROOT` resolves to `/` if the tool is relocated to a shallow
  path**, which makes every path "inside the repository" with a message that
  does not explain why. Fail-closed but confusing. Not fixed, because skipping
  a filesystem-root result would remove protection rather than add it.
- **A repository rooted at `$HOME` would blanket-protect the home directory**,
  since the protected root is the parent of the shared git directory. This is
  correct behavior for a repository that really is rooted there, so adding a
  `$HOME` exception would be a security regression rather than a fix.
- **`git worktree list --porcelain` output is split with `splitlines()`**, so a
  worktree path containing a newline would drop out of protection. Not fixed,
  because a parsing rewrite for that input carries more risk than the case
  warrants; the shared-git-directory query still protects the canonical
  checkout.

## Explicitly unproven

- The corpus is not qualified; final Phase 0–2 acceptance is pending independent
  human-labelled/adjudicated evidence.
- Phase 2 does not prove that any family is ready for model-controlled
  narration and does not authorize Phase 3.
- The capped OpenAI audio evaluation did not run because no credential was
  available.
- No production Echo audio-judge loop, eligible-device Foundation Models shadow
  run, mechanical production-audio check, or human-listening acceptance was
  completed.
- Hosted CI, PR merge, deployment, installation, device acceptance, and release
  have not occurred and are not implied by local evidence.
