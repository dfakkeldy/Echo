# Pronunciation Phases 0–2 Qualification

Date: 2026-07-29

Overall status: **PENDING**. The independent local implementation gates listed
below are complete, but corpus-dependent qualification is
`WAITING_FOR_HUMAN_LABELS`. The development audio-judge API lane is
`WAITING_FOR_USER`. Eligible-device, rendered-audio, human-listening, hosted-CI,
merge, installation, and release proof are also absent and are reported
separately.

## Exact source state

- Branch: `codex/global-pronunciation-context-design`, based on
  `origin/nightly`.
- Last committed implementation before this receipt:
  `273cc88d444074e9f8e289da4337abd4a48dbbc4`.
- The source state qualified by this report is that commit plus the Task 10
  commit that contains this receipt. The final Task 10 identity is therefore
  the commit containing this file; no circular placeholder hash is embedded
  here.
- The canonical Echo checkout and the separate Article Anthologies worktree
  were not modified by this work.

## Local unit and build gates

The following independent local gates passed on 2026-07-29:

| Gate | Result |
| --- | --- |
| Pronunciation corpus tests | 44 passed |
| Pronunciation pack tests and regeneration check | 38 passed; generated pack matched the committed pack |
| Development audio-judge tests | 38 passed without an API request |
| Task 10 Swift acceptance suite | 6 passed |
| Echo test-products build | Passed |
| Complete Echo unit-test gate | Passed |
| Release `echo-cli` build | Passed |
| Deterministic program report | Two runs were byte-identical; SHA-256 `12e0ad90053c066ccea016d489cc6bf5b191d44c1734b107740fc4012f24cc22` |

A local test or build is not hosted CI, device execution, rendered-audio
verification, human listening, installation, or release proof.

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
identity changes, and every production-affecting policy mutation changes the
reconstructed cache signature.

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

Deterministic metric counts were 0 definitive/resolved, 13 advisory, and 23
abstained. Those values are an explicit frozen discovery/analyzer-state
contract for all 36 named rows, and the Swift acceptance suite binds every row
to the production discovery and analyzer result. They are not inferred from
case names, intended labels, or a generic `automatic`/`review` assertion.
Morphology fixtures contained two exact-base `-able`, one silent-e `-able`, two
exact-base `-ible`, and nine negative cases. The pack report counted 76,125
imported spellings, 3,982 ambiguous spellings, zero incompatible spellings,
36,966 existing-gold exclusions, and 12,021 existing-silver exclusions.
Frequency-band reporting is
`unavailable-no-approved-source`; no unapproved frequency source was inferred.

Corpus-dependent qualification and final Phase 0–2 acceptance remain pending.
No agent-generated, model-generated, provisional, or source-order label is
represented as human evidence.

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
- Conservative estimated cost: USD 1.029561
- Structured results: none
- Validation outcome: the dry run admitted the clip and completed with no HTTP
  request; the credential-free run emitted `WAITING_FOR_USER`
- Retry outcome: no retry was eligible or attempted
- Morning queue count: 0
- Dry-run receipt SHA-256:
  `87d4ea680bbddde1fd3280c3f945ad9260d864036197fcf931057eb2bda7330d`
- Credential-free receipt SHA-256:
  `6ca48b76ef74b71cb2aa322cc83121d413a0abe61b648b6ef9512b1d11939b1a`

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
