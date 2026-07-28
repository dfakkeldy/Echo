# Global Pronunciation Foundation and Hybrid Context Resolution

**Date:** 2026-07-28
**Status:** Conversational design approved; awaiting written-spec review
**Author:** Dan Fakkeldy. Ground-truthed and drafted with Codex.
**Base verified:** `origin/nightly` at `33c17fda03a759a531e317a1a6b1830ad6bc9228`

> **Privacy note.** Private books, transcripts, generated audio, prompts, and
> correction history remain outside the repository and never become a required
> server-side dataset.

---

## 1. Executive decision

Echo will improve pronunciation through a layered system that helps every
supported device and uses Apple Foundation Models only where they are available
and proven.

The system has four authorities:

1. **User intent:** occurrence, book, and global overrides retain priority.
2. **Universal linguistic foundation:** a versioned, provenance-bearing English
   lexicon plus conservative morphology improves all supported devices.
3. **Deterministic context:** explicit, testable rules remain available
   everywhere.
4. **Optional model-assisted context:** on eligible iOS 26 and macOS 26 devices,
   Foundation Models may select among Echo-supplied pronunciation candidates.
   It never invents IPA, rewrites source text, or runs during synthesis.

The hybrid contextual resolver starts in **shadow mode**. It may affect
pronunciation only after each ambiguity family independently passes the locked
evaluation gates in this document. Older or ineligible devices keep the same
source material, dictionary, morphology, deterministic rules, review workflow,
and frozen-plan guarantees; they simply omit the model signal.

The first implementation program is deliberately bounded:

- build the universal lexicon and morphology foundation;
- build the evaluation corpus and receipts;
- add Foundation Models contextual classification in shadow mode;
- do not let the model change released narration in the first rollout.

Automatic model-assisted resolution, new neural OOV models, downloadable
pronunciation packs, and a universal compact context model require later
evidence and separately reviewed implementation plans.

---

## 2. Relationship to the 2026-07-09 planner design

This design builds on
[`2026-07-09-pronunciation-planner-design.md`](./2026-07-09-pronunciation-planner-design.md).
It does not replace the planner's completed downstream guarantees.

The following earlier decisions remain in force:

- Kokoro remains Echo's acoustic speech engine.
- Pronunciation is decided before synthesis and frozen into source-mapped
  evidence.
- Exact validated Kokoro phoneme IDs survive splitting, timing, retry, and
  recovery.
- Occurrence, book, and global overrides remain supported.
- App and CLI use the same pronunciation behavior.
- Linguistic correctness and acoustic realization are separately evaluated.
- ASR output can identify a suspicious region but cannot prove pronunciation.
- Existing audio is never silently reinterpreted or re-rendered.

This document supersedes the earlier design only in these areas:

- the first contextual provider is Apple's on-device Foundation Models
  framework, not a separately downloaded sentence-context model;
- the first universal improvement is lexicon provenance plus conservative
  morphology, not immediate selection of a bundled neural OOV model;
- contextual families graduate independently rather than enabling one model
  for the whole language;
- model output is a constrained candidate choice, not IPA or rewritten prose;
- failure reduces automation and routes to deterministic fallback or review;
- model-assisted contextual resolution is evaluated per runtime family because
  the system model can change with OS releases.

The earlier downloaded-context-pack and neural-OOV proposals are therefore
deferred, not silently carried into implementation. Either may return through a
future design if measured gaps justify its complexity.

---

## 3. Problem statement

Echo already contains a large English pronunciation resource, deterministic
homograph handling, user overrides, source-position corrections, immutable
pronunciation evidence, and a post-render listening reel. The remaining problem
is not the absence of pronunciation machinery. It is the lack of a durable way
to improve ordinary English coverage and resolve unseen context without adding
one-off fixes forever.

The current checked-in resources contain:

- 90,217 gold entries;
- 93,492 silver entries;
- explicit alternatives for contextual words including `content`, `read`,
  `live`, `lives`, `record`, and `arithmetic`;
- deterministic contextual rules for a small set of known ambiguity families.

Several gaps remain:

1. The resource files do not expose a unified, versioned provenance and
   candidate contract to the planner.
2. Frequency is not represented, so rare and common failures receive the same
   discovery priority.
3. Productive morphology deliberately excludes `-able` and `-ible` from the
   closed-compound fallback. Unknown forms can therefore reach the approximate
   fallback despite a known base word.
4. Context rules are finite cue lists. They can be correct for named sentences
   and still miss unseen syntax.
5. Current Foundation Models usage in narration QA is an enrichment layer that
   can suggest free-form IPA and collapses all model errors to one fallback. It
   is not suitable as the semantic authority for planned pronunciation.
6. Foundation Models is unavailable on Echo's iOS 18 and macOS 15 deployment
   floors and can also be unavailable on nominally supported devices.
7. A system-model update can alter outputs without an Echo code change.

The permanent fix is therefore not “ask a model how to pronounce this word.”
It is a versioned evidence system in which dictionaries provide candidates,
morphology safely derives candidates, context selects only among known
candidates, uncertain decisions abstain, and every accepted decision is frozen
and auditable.

---

## 4. Goals and non-goals

### Goals

- Improve ordinary English pronunciation for every supported Echo device.
- Make common failures more likely to be found and fixed without allowing
  frequency to choose a pronunciation.
- Handle productive `-able` and `-ible` forms without treating arbitrary
  spelling as authoritative pronunciation.
- Resolve contextual words from sentence meaning rather than an ever-growing
  list of neighboring words.
- Use Foundation Models as a private, on-device classifier on eligible
  devices.
- Preserve deterministic behavior and a useful review path when the model is
  unavailable.
- Freeze every accepted result into the existing plan/audit boundary.
- Measure precision, coverage, abstention, review burden, runtime drift, and
  rendered-audio quality separately.
- Let ambiguity families graduate, regress, or be disabled independently.
- Turn every confirmed defect into a reusable entry, rule, exception, or
  regression case.
- Keep source text and corrections local unless a person explicitly prepares a
  reviewed contribution.

### Non-goals

- Replacing Kokoro or changing voice identity.
- Sending book text to a hosted model or adding a cloud fallback.
- Asking Foundation Models to generate IPA, phoneme IDs, definitions, or
  rewritten narration.
- Treating model self-reported confidence as calibrated evidence.
- Removing deterministic rules when the hybrid path first ships.
- Automatically sharing private corrections or book excerpts.
- Re-rendering existing audio after a dictionary, OS, prompt, or policy update.
- Supporting non-English contextual resolution in the first program.
- Training a Foundation Models custom adapter.
- Selecting or shipping a neural OOV model in the first program.
- Downloading mutable pronunciation packs at runtime in the first program.
- Using the `--no-pronunciation-review` CLI flag to bypass unresolved semantic
  decisions.

---

## 5. Locked decisions

| ID | Decision | Locked choice |
| --- | --- | --- |
| D1 | Speech engine | Keep Kokoro. |
| D2 | Universal coverage | Extend the existing lexicon through a versioned, provenance-bearing pack and conservative morphology. |
| D3 | Frequency | Use frequency only to prioritize corpus coverage, audits, review order, and future work. Never use it to select a sense or IPA. |
| D4 | Contextual model role | Select one Echo-supplied candidate or `needsReview`; never generate pronunciation. |
| D5 | Model location | Use Apple's on-device Foundation Models framework only. No automatic cloud fallback. |
| D6 | Deployment compatibility | Keep iOS 18 and macOS 15 behavior complete. Gate Foundation Models at compile time, OS availability, and runtime availability. |
| D7 | Timing | Run contextual resolution during pronunciation preflight, never during synthesis or playback. |
| D8 | Output structure | Use constrained structured output with fixed candidate identifiers and `needsReview`, not manual JSON or free-form text. |
| D9 | Determinism | Use greedy sampling, fresh bounded sessions, frozen accepted results, and versioned runtime evidence. Greedy output is not assumed stable across OS/model updates. |
| D10 | Authority | Echo's policy engine decides whether evidence is sufficient. The model does not provide an acceptance score. |
| D11 | Rollout | Start in shadow mode and graduate one contextual family at a time. |
| D12 | Review scope | Ambiguous contextual corrections default to one occurrence. Book/global scope is reserved for names and genuinely unambiguous terminology. |
| D13 | Privacy | Production logs and contributions contain no raw private context by default. |
| D14 | Existing audio | Old plans and audio remain unchanged until an explicit re-analysis or re-render. |
| D15 | First implementation | Universal foundation plus contextual shadowing only; no model-controlled production pronunciation. |

---

## 6. Universal pronunciation foundation

### 6.1 Versioned bundled pack

The first release keeps pronunciation data bundled with the app and CLI. It
does not introduce a network updater or remote kill switch.

The build produces one immutable English pronunciation pack and a manifest.
The manifest records:

- pack schema version;
- semantic pack version;
- source snapshot identifiers;
- generator version;
- entry and candidate counts;
- normalized-data SHA-256;
- Kokoro vocabulary version;
- dialect identifier;
- licenses and required acknowledgments;
- generation timestamp for audit only, excluded from semantic identity.

The semantic pack identity is derived from normalized content, source
identities, generator behavior, and phoneme vocabulary. Rebuilding identical
inputs must produce the same semantic identity even if the wall-clock timestamp
differs.

The first implementation wraps and validates Echo's existing gold and silver
resources rather than replacing them wholesale. A new source can supplement
them only after provenance, conversion, and conflict checks pass. In Phases
0–2, an external source may automatically fill only a spelling absent from both
existing resources. Conflicting pronunciations and additional alternatives are
report-only until a human-reviewed fixture approves them.

### 6.2 Entry and candidate contract

One normalized spelling may have one or more candidates. Each candidate carries:

- stable candidate ID;
- Kokoro-compatible IPA;
- optional lexical class;
- short, non-copyrighted sense label used for review and model selection;
- source ID and source tier;
- whether it is explicit, derived, or compatibility-only;
- whether it may be selected automatically without context;
- optional coarse frequency band for prioritization;
- validation status and rule/version provenance.

Candidate IDs are stable only within a declared candidate-pack version. They
are identifiers, not semantic truth. A changed IPA, sense label, or candidate
set changes the pack identity and invalidates dependent cached decisions.

All IPA is validated against the exact Kokoro phoneme vocabulary before pack
generation succeeds. Unsupported symbols are build failures, never characters
silently removed at runtime.

### 6.3 Source policy

The recommended first supplemental pronunciation source is
[CMUdict](https://github.com/cmusphinx/cmudict). Its official terms permit
research and commercial use and request acknowledgment. It uses ARPAbet rather
than Kokoro-compatible IPA, so imported entries are candidates only after:

1. pinning an exact upstream snapshot;
2. deterministic ARPAbet-to-Kokoro conversion;
3. stress and dialect validation;
4. conflict comparison with existing gold and silver entries;
5. named-sample listening checks;
6. inclusion of the requested acknowledgment.

Existing Echo gold entries win conflicts until corpus evidence and human review
approve a change. A larger source does not automatically outrank a trusted one.

[wordfreq](https://github.com/rspeer/wordfreq) is a suitable development-time
source for English usage prioritization, but its included data may be
redistributed under CC BY-SA 4.0. The first implementation may use a pinned
snapshot locally to order evaluation and audit work. It may not ship raw scores
or derived frequency bands until Echo records the applicable attribution,
share-alike, and database-rights decision in the pack manifest.

Wiktionary text is not a default bundled source. Its
[licensing terms](https://en.wiktionary.org/wiki/Wiktionary:Copyrights) require
attribution and share-alike handling that must be deliberately designed before
entry text, definitions, or IPA are redistributed. It remains useful for
human research and cross-checking.

This is a provenance rule, not legal advice. A source with unclear
redistribution terms remains development-only regardless of quality.

### 6.4 Frequency policy

Frequency is represented as a coarse band rather than a false-precision global
score:

- very common;
- common;
- uncommon;
- rare;
- unknown.

It may affect:

- which missing words enter the morphology and listening corpus first;
- which ambiguities are reviewed first;
- which fallback hits appear in a bounded listening reel;
- the priority of future dictionary work;
- aggregate coverage reporting by usage band.

It may not affect:

- candidate selection for a specific occurrence;
- override precedence;
- automatic-versus-review decisions;
- a user's correction scope;
- whether unsupported IPA is accepted.

Frequency data is optional in the runtime pack. An absent or legally
unapproved frequency source produces `unknown`, not a guessed band.

### 6.5 Conservative morphology

The first productive families are `-able` and `-ible`.

Morphology generates a candidate only when:

1. the complete word is absent from every accepted whole-word explicit entry;
2. exactly one permitted base analysis succeeds;
3. the base has validated, non-fallback IPA;
4. the applicable transformation rule is explicitly versioned;
5. no exception blocks the derivation;
6. the derived IPA is valid in Kokoro's vocabulary;
7. the rule family has passed its held-out and acoustic gates.

The morphology engine does not append a generic suffix pronunciation to an
arbitrary spelling fallback. It models only documented transformations and
abstains when multiple bases or transformations are plausible.

Explicit whole-word entries always outrank derived candidates. Known
irregularities and false segmentations become exceptions. A derived result
retains its base entry, transformation rule, and candidate-pack version in the
audit evidence.

Later morphology families—inflections, prefixes, and additional compounds—use
the same gate and require their own corpus. The existing closed-compound
resolver remains unchanged until a separately measured family is ready.

### 6.6 `content` fallback correction

The current gold resource uses the “satisfied” adjective pronunciation as
`content`'s default and the “material or subject matter” noun pronunciation
only when a noun tag is available.

The universal pack changes the context-free fallback to the common
material/subject-matter noun. The adjective remains a first-class candidate.
Deterministic context, Foundation Models, or an occurrence override may select
the adjective where the sentence means “satisfied.”

The change is covered by positive and negative tests so improving “a block of
content” does not erase the adjective.

---

## 7. Candidate discovery and resolution

### 7.1 Resolution order

For each source occurrence, Echo resolves in this order:

1. exact occurrence override;
2. book override;
3. global override;
4. built-in override;
5. one explicit unambiguous lexicon candidate;
6. one validated unambiguous morphology candidate;
7. deterministic contextual analysis over a known candidate family;
8. optional Foundation Models candidate selection;
9. explicit review or limited fallback;
10. emergency existing fallback, always marked low-authority.

Higher-priority accepted results stop lower layers from running. Foundation
Models never receives occurrences already decided by an override or one
unambiguous candidate.

Candidate discovery and evidence acceptance are separate operations. The
lexicon discovers what pronunciations are possible; the policy engine decides
whether the available evidence is sufficient.

### 7.2 Contextual family

A contextual family defines:

- normalized spellings it covers;
- fixed candidates and sense labels;
- deterministic rules classified as `definitive` or `advisory`;
- named positive and negative cases;
- candidate-pack version;
- model prompt/schema version;
- rollout state: `disabled`, `shadow`, or `graduated`;
- runtime families qualified for automatic use;
- family-specific acceptance and abstention metrics.

A rule is definitive only because its family definition explicitly says so and
the corpus proves it. Echo does not infer rule strength from a numeric score.

The initial families are:

1. `content`;
2. `read`;
3. `live` and `lives`;
4. `record`.

`resume`, `arithmetic`, and additional homographs follow only after the first
families establish a stable evaluation and rollout process.

---

## 8. Foundation Models contextual provider

### 8.1 Availability

Echo keeps its iOS 18 and macOS 15 deployment floors.

The provider exists only behind:

- `#if canImport(FoundationModels)`;
- `#available(iOS 26, macOS 26, *)`;
- `SystemLanguageModel.default.availability == .available`.

The model availability check is repeated before starting a batch. Availability
may change after launch because Apple Intelligence can be disabled or model
assets can become unavailable. Echo does not treat a cached availability value
as permanent.

watchOS does not perform contextual model inference in this design. It consumes
the already rendered and frozen audiobook.

### 8.2 Input

The model receives only the information needed to classify a known ambiguity:

- an opaque occurrence ID;
- the target spelling;
- the target sentence;
- at most one preceding and one following sentence;
- at most four opaque candidate slots;
- a short meaning and lexical-role label for each slot.

IPA, Kokoro IDs, deterministic selections, frequency, and user override data
are omitted. The model is not told which answer the rule engine prefers.

Static behavioral instructions remain separate from book-derived prompt data.
Private source text is never interpolated into model instructions.

### 8.3 Output

The provider uses `@Generable` structured output with constrained fixed choices:

- candidate A;
- candidate B;
- candidate C;
- candidate D;
- `needsReview`.

Unused candidate slots are not valid choices. The response contains no
free-form IPA, rewritten source, rationale, or confidence. Echo validates every
occurrence ID and selected slot against the submitted batch before accepting
the response.

### 8.4 Execution

- Contextual work runs during preflight before synthesis.
- Batches contain at most eight occurrences and must also fit a conservative
  runtime context budget.
- The implementation reads the runtime model context capability when available
  rather than hard-coding one OS generation's token limit.
- Batches run serially through fresh sessions.
- Generation uses greedy sampling.
- The task remains cancellable and does not block the UI actor.
- No model transcript is reused across books or batches.
- A completed, fully validated batch is staged atomically.

Greedy sampling improves repeatability only for the same system model and
runtime. It does not make outputs stable across OS/model updates, so accepted
decisions are frozen and the runtime signature is recorded.

### 8.5 Independent evidence

Deterministic analysis runs independently from the model. The resolution policy
compares:

- deterministic candidate or abstention;
- Foundation Models candidate or abstention;
- family rollout state;
- runtime qualification;
- candidate-pack and prompt/schema versions;
- any explicit human decision.

The model is not allowed to “confirm” a deterministic answer it was shown.

---

## 9. Acceptance policy and review workflow

### 9.1 Automatic decisions

The following are automatically accepted:

- valid occurrence, book, global, or built-in overrides;
- one explicit unambiguous lexicon candidate;
- one graduated, validated morphology candidate;
- a definitive deterministic rule;
- deterministic and model agreement for a graduated contextual family on a
  qualified runtime.

A model-only candidate may be automatically accepted only when:

- the family is graduated;
- the exact runtime family is qualified;
- the family has separately passed its model-only gate;
- deterministic evidence is advisory or abstains rather than definitively
  disagreeing;
- all batch and plan validation succeeds.

No generic model confidence threshold exists.

### 9.2 Decisions requiring review

Review is required when:

- deterministic and model candidates disagree;
- either source returns `needsReview` and the other is not definitive;
- the model is unavailable and deterministic evidence is advisory;
- the candidate set is malformed or incomplete;
- a source range cannot be proven;
- the candidate or prompt schema is unknown;
- a prior staged decision no longer matches current signatures.

These rules apply after hybrid semantic review is activated in Phase 3. During
Phase 2 shadowing, model agreement, disagreement, abstention, unavailability,
and failure are observational only. They record the hypothetical policy outcome
but cannot change, block, or downgrade the production deterministic decision.

For a family or runtime that remains shadow-only after Phase 3 begins, Echo
ignores the model as acceptance evidence and follows the deterministic-only
policy. The deterministic evidence may independently require review, but shadow
status itself does not create a review item.

If Foundation Models is unavailable but a definitive deterministic rule applies,
Echo may accept the rule while recording degraded provenance.

### 9.3 Semantic preflight

Semantic pronunciation review occurs before synthesis. It is distinct from the
existing post-export acoustic listening reel.

The review surface groups matching ambiguity families and shows:

- source sentence with the occurrence highlighted;
- plain-language candidate meanings;
- optional short pronunciation previews;
- deterministic and model disagreement status when helpful;
- the proposed scope.

The default scope for a contextual choice is the exact occurrence. Book and
global choices are offered only for names, invented terminology, or words whose
pronunciation does not vary by sense in the reviewed material.

The interface reports outcomes and required decisions, not prompts, raw model
responses, or internal error dumps.

### 9.4 CLI semantics

The existing `--no-pronunciation-review` flag disables the post-render audit and
listening-reel artifacts. It does not authorize unresolved semantic narration.

When semantic review becomes a production gate, limited narration requires a
separate explicit option such as `--allow-limited-pronunciation`. That option:

- permits an explicitly marked preview or limited render;
- records every unresolved fallback;
- never labels the result fully reviewed;
- does not weaken source-range or phoneme-integrity failures.

The first shadow-mode implementation does not need to add this flag because the
model does not yet control or block production output.

---

## 10. Plan, audit, cache, and resume contracts

### 10.1 Contextual evidence envelope

The existing pronunciation audit remains canonical. Phase 2 bumps the current
audit schema from version 3 to version 4 and adds a contextual evidence envelope.
The envelope is required for every contextual occurrence evaluated in shadow or
hybrid mode and absent from unrelated decisions. It contains:

- candidate family and candidate-pack version;
- submitted candidate IDs;
- deterministic candidate and rule class;
- model candidate or abstention;
- model availability category;
- family rollout state;
- acceptance reason;
- prompt/schema version;
- platform and OS build;
- qualified runtime-family ID;
- human candidate and correction scope, when present;
- limited/degraded state.

Raw prompts, raw model responses, and full private source windows are not added.
The existing bounded `sourceContext` remains subject to Echo's local artifact
policy.

Older audit schemas continue decoding. Missing evidence required by the current
schema yields incomplete coverage rather than fabricated proof.

### 10.2 Frozen plan identity

Every accepted contextual or derived decision freezes:

- source block and word range;
- source spelling;
- candidate ID;
- selected IPA;
- validated Kokoro IDs;
- decision source and rule ID;
- morphology base/rule when applicable;
- candidate pack;
- contextual policy;
- runtime evidence when consulted;
- human choice when present.

The plan/cache signature changes when any pronunciation-affecting input changes,
including:

- source text;
- occurrence, book, global, or built-in overrides;
- lexicon pack;
- morphology rules and exceptions;
- contextual family definitions;
- prompt/schema;
- acceptance policy;
- selected candidate;
- model runtime when its result affected acceptance.

Shadow-only model output does not change synthesis cache identity because it
does not affect selected pronunciation. It is stored only in the local
evaluation/audit receipt with its own signature.

### 10.3 Transactionality and resume

Preflight first discovers all ambiguous occurrences, then processes them in
small cancellable batches.

A batch is staged only when every occurrence ID and result validates. The
pronunciation plan is finalized only when every occurrence is:

- resolved automatically;
- explicitly reviewed; or
- deliberately marked limited.

Resume may reuse a staged batch only when source, candidate pack,
prompt/schema, overrides, policy, and runtime signature still match. Any
mismatch discards that staged batch and recomputes it. A partial preflight never
marks a plan complete.

Existing completed audio and plans are never re-analyzed in place. A user must
request a new analysis or render, which creates a new plan identity.

### 10.4 Listening reel priority

The post-render listening reel remains bounded. When contextual evidence is
available, samples are prioritized in this order:

1. limited fallback;
2. human-reviewed disagreement;
3. model-only automatic decision;
4. deterministic/model agreement;
5. monitored lexicon or morphology;
6. other existing watched decisions.

The current uniqueness key remains pronunciation-specific so repeated
occurrences do not crowd out other risk categories.

---

## 11. Failure handling

After hybrid activation, Foundation Models failure may reduce automation. It
may not silently increase confidence in the deterministic answer. During Phase
2 shadowing, the same failure categories affect only the shadow receipt and do
not change production resolution.

| Condition | Required behavior |
| --- | --- |
| Device ineligible | Skip model work; use deterministic resolution and review policy. |
| Apple Intelligence disabled | Skip model work; use deterministic resolution and review policy. |
| Model assets not ready or unavailable | Recheck once at the next batch boundary; otherwise fall back without blocking unrelated definitive cases. |
| Context too large | Retry with a smaller batch, then one occurrence. If one occurrence still fails, require review. |
| Guardrail or refusal | Do not repeat the same request. Route the occurrence to deterministic fallback/review. |
| Unsupported language or locale | Do not retry; contextual Foundation Models resolution is English-only in this program. |
| Transient timeout or rate limit | One bounded retry with a fresh session, then fallback/review. |
| Concurrent request error | Prevent through serial execution; if encountered, treat as an implementation defect and safely fall back. |
| Structured-output parsing failure | Reject the entire batch; retry once smaller, then review. |
| Missing, duplicate, unknown, or invalid occurrence/candidate ID | Reject the entire batch; never salvage partial output. |
| User cancellation | Propagate cancellation immediately. Do not convert it into fallback and do not continue rendering. |
| Invalid source range, unsupported IPA, or inconsistent candidate pack | Stop the affected plan as an integrity error. Limited mode cannot bypass it. |

SDK error types differ across Foundation Models generations. The implementation
maps the SDK-specific cases into these stable Echo categories and tests each
supported OS path. It does not rely on one broad `catch` as the complete policy.

### Runtime outcomes

| Outcome | Meaning | Normal export |
| --- | --- | --- |
| `ready` | Every occurrence has accepted evidence. | Allowed |
| `needsReview` | One or more semantic choices remain unresolved. | Blocked |
| `limited` | The user explicitly accepted marked fallback for a preview/limited render. | Not labeled fully reviewed |
| `cancelled` | Preflight was interrupted. | Blocked |
| `planError` | Source, candidate, IPA, or plan integrity failed. | Blocked |

Model unavailability is provenance, not automatically a book-level error. A
book may still be `ready` if every occurrence has sufficient non-model evidence.

---

## 12. Privacy, logging, and contributions

- Foundation Models inference is on-device.
- Echo has no automatic hosted-model fallback.
- No runtime internet connection is required for the first bundled pack.
- Production logs contain counts, durations, version signatures, and stable
  failure categories.
- Production logs do not contain raw prompts, source sentences, model
  responses, IPA sequences, or local file paths.
- Local audit artifacts may contain the existing bounded source context because
  they are private book artifacts, not telemetry.
- Occurrence corrections remain local to one book by default.
- Echo does not infer permission to upload a correction because it was accepted
  locally.
- A future contribution flow must be explicit, reviewed, redact private
  context, state its scope, and preserve source/license provenance.
- Public and synthetic corpora are used for shared evaluation. Private books
  may be used for local acceptance but never committed or automatically
  uploaded.

---

## 13. Evaluation strategy

### 13.1 Corpus layers

#### Named regression matrix

Every known defect receives:

- a positive case;
- a negative guard using the other sense;
- expected candidate ID;
- expected automatic/review outcome;
- expected deterministic and model evidence in shadow runs.

All named cases must pass before a family graduates.

#### Balanced family corpus

Each family has at least:

- 200 held-out opportunities eligible for automatic resolution;
- 50 held-out examples for every represented sense;
- varied syntactic position, punctuation, capitalization, and sentence length;
- contexts authored independently from the production prompt;
- two human labels with adjudication on disagreement.

Foundation Models may help discover candidate examples but cannot label its own
held-out exam.

#### Distribution corpus

The end-to-end corpus contains at least ten public-domain or synthetic works
across fiction, nonfiction, technical prose, dialogue, historical writing, and
instructional material. It measures review burden and fallback distribution at
book scale.

#### Lexicon and morphology corpus

The universal corpus includes:

- common and rare known lexicon words;
- `-able` and `-ible` positives;
- spelling and pronunciation transformations;
- explicit irregular exceptions;
- false segmentations;
- proper nouns that must not be derived;
- words with multiple plausible bases;
- existing inflection and compound controls;
- unsupported-phoneme and empty-output guards.

### 13.2 Metrics

Report:

- automatic-decision precision;
- automatic coverage;
- abstention rate;
- review items per narrated hour;
- review time per narrated hour;
- worst-performing family and sense;
- runtime-to-runtime stability;
- unambiguous control regression rate;
- OOV/fallback rate by frequency band;
- morphology precision and coverage;
- invalid/unsupported phoneme count;
- Foundation Models availability and failure category;
- cold and sustained preflight latency;
- post-render listening outcomes.

Averages never hide per-family, per-sense, or worst-book results.

### 13.3 Family graduation gate

A contextual family graduates only when:

- named regressions and negative guards: 100 percent correct;
- held-out automatic precision: at least 99 percent;
- 95 percent Wilson lower confidence bound on automatic precision: at least
  98 percent;
- automatic coverage: at least 95 percent overall;
- automatic coverage: at least 90 percent for every sense;
- invalid, missing, duplicate, or unsupported outputs: zero;
- no systematic failure by context pattern, genre, capitalization, or sentence
  position;
- repeated greedy runs are stable on the qualified runtime;
- every selected IPA is valid in the production Kokoro vocabulary;
- rendered probes pass human listening on the primary and control voices.

Families graduate independently. A failure in `live` does not disable a proven
`content` improvement.

Model-only automatic selection is measured separately and remains disabled
unless it independently meets the same precision and safety gates.

### 13.4 Runtime qualification

Qualification is bound to:

- platform;
- OS major and minor;
- recorded OS build and assigned build family;
- model availability class;
- prompt/schema version;
- candidate-pack version;
- family definition;
- acceptance-policy version.

An unknown runtime uses model evidence in shadow mode even when the family was
graduated elsewhere. The deterministic path remains authoritative. After the
semantic review gate exists, independently unresolved deterministic evidence
may still require review, but an unknown runtime does not create a review item
solely because it is unknown. It may not use model-assisted automatic decisions
until qualified.

### 13.5 Book-level release gate

Before hybrid automation becomes a default production path, the distribution
corpus must show:

- no more than one unresolved review item per narrated hour on average;
- P95 no more than two unresolved items per hour;
- no tested book above three unresolved items per hour;
- zero silently dropped phonemes;
- zero private text in production logs;
- acceptable latency and memory on the oldest eligible test devices;
- correct fallback on iOS 18/macOS 15 and every Foundation Models unavailable
  state.

### 13.6 Acoustic gate

Correct IPA does not guarantee correct audio.

Each graduated family and morphology release renders:

- a primary shipped voice;
- at least one control voice;
- every named regression;
- balanced held-out probes;
- unambiguous controls.

Mechanical checks verify non-empty audio, timing, exact phoneme consumption,
and absence of clipping/silence failures. Human listeners judge semantic
correctness and naturalness. ASR can prioritize samples but cannot pass them.

If IPA is correct and audio is wrong, Echo records an acoustic/voice defect. It
does not distort the semantic resolver to compensate globally.

---

## 14. Rollout

### Phase 0 — Evidence and pack contract

- Freeze named, balanced, distribution, and morphology corpora.
- Record the current deterministic and rendered baselines.
- Add the pack manifest and reproducible build report around existing gold and
  silver resources.
- Validate licenses and pin candidate external source snapshots.
- Add frequency as a development-time prioritization input.

No narration behavior changes.

### Phase 1 — Universal improvement

- Generate and bundle the versioned English pack.
- Add validated supplemental entries only for spellings absent from both
  existing resources; keep conflicts report-only pending human-reviewed
  fixtures.
- Add conservative `-able` and `-ible` derivation plus exceptions.
- Change `content`'s context-free fallback to the material/subject-matter noun.
- Extend audits and cache signatures for pack and morphology provenance.
- Run linguistic and acoustic gates on all supported deterministic paths.

Every supported device benefits.

### Phase 2 — Contextual shadowing

- Add the dedicated Foundation Models candidate selector.
- Add structured fixed-choice output, availability gates, cancellation, and
  categorized failure handling.
- Run `content`, `read`, `live`/`lives`, and `record` in shadow mode.
- Persist local shadow evidence without changing synthesis identity.
- Test all Foundation Models unavailable states and iOS 18/macOS 15 fallbacks.

The model still cannot change production pronunciation.

### Phase 3 — Family-by-family hybrid graduation

- Review Phase 2 evidence.
- Graduate only families and runtime families that pass every gate.
- Add semantic review and explicit limited-mode behavior.
- Extend the post-render listening reel priorities.
- Keep deterministic and model-independent behavior complete.

This phase requires a separately approved implementation plan after shadow
evidence exists.

### Phase 4 — Continuous expansion

- Add contextual families based on frequency-weighted confirmed defects.
- Add lexicon entries, morphology exceptions, and regression cases.
- Requalify graduated families on new OS/model runtime families.
- Disable or demote any family that regresses.

Updates ship as immutable app/CLI pack versions in this program.

### Phase 5 — Universal contextual capability, only if justified

If measured evidence shows that eligible Foundation Models devices receive a
material benefit that deterministic paths cannot match, Echo may train or
derive a compact bundled classifier from independently human-reviewed public or
synthetic data.

That future project must:

- benefit ineligible and older supported devices;
- remain offline and reproducible;
- avoid treating Foundation Models output as ground truth;
- pass the same family and acoustic gates;
- have a separate model-license, size, memory, and update design.

This phase is not authorized by the current design.

---

## 15. Alternatives considered

### Foundation Models replaces deterministic rules

Rejected. It would exclude supported devices, introduce runtime drift, and
remove an independent evidence source.

### Foundation Models generates IPA

Rejected. The on-device model is appropriate for constrained classification,
not authoritative phonetic transcription. Generated IPA also expands the
unsupported-symbol and hallucination surface.

### Foundation Models rewrites the sentence

Rejected. Rewriting threatens source identity, read-along mapping, quotations,
and authorial text. The contextual provider chooses a candidate without
changing prose.

### One universal server model

Rejected for production. It would send private book context off-device and add
network, cost, availability, and reproducibility dependencies.

### Handwritten rules only

Retained as the universal fallback but rejected as the sole long-term strategy.
Finite cue lists cannot cover every syntactic realization.

### Downloaded contextual model now

Deferred. It adds model selection, licensing, delivery, integrity, memory, and
update systems before Foundation Models shadow evidence proves that a separate
model is needed.

### Foundation Models custom adapter

Rejected for this program. Candidate-constrained base-model classification must
be evaluated first, and adapter lifecycle/version coupling does not solve
coverage for older devices.

### Bundle Wiktionary wholesale

Rejected as a default. Its attribution/share-alike obligations and text-derived
data require a deliberate redistribution design.

---

## 16. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| A larger dictionary introduces worse pronunciations | Preserve source tiers, compare conflicts, require conversion validation, and keep gold entries authoritative until reviewed. |
| Frequency becomes a proxy for correctness | Prohibit it from candidate selection and acceptance policy. |
| `-able` rules overgeneralize | Require one known base, one versioned transformation, explicit exceptions, held-out gates, and abstention. |
| Model agrees with a flawed deterministic rule | Keep inputs independent and test against human labels, not agreement alone. |
| Model changes after an OS update | Bind qualification to runtime families; unknown runtimes return to shadow/review-only. |
| Model confidently selects the wrong candidate | Ignore self-reported confidence, constrain choices, require family precision gates, and preserve review. |
| Private source text leaks through logs | Log only categories, counts, durations, and signatures; test redaction. |
| Guardrails reject legitimate book content | Do not retry the same text or weaken safety globally; fall back locally to deterministic/review. |
| A malformed batch shifts answers between occurrences | Validate all IDs and reject the batch atomically. |
| Shadow results alter cache behavior | Exclude shadow-only output from synthesis identity and store it in a separately versioned local receipt. |
| Review becomes overwhelming | Gate release on review items and review time per narrated hour. |
| Correct IPA still sounds wrong | Maintain the acoustic gate and classify voice/model defects separately. |
| First implementation grows into a model platform | Keep packs bundled, use no adapter/download service, and stop at shadow mode. |

---

## 17. First implementation boundary

The implementation plan produced from this reviewed spec may cover Phases 0–2
only.

It may add:

- a concrete pack manifest and generator;
- deterministic source pinning and attribution receipts;
- validated CMUdict import behind existing source precedence;
- development-time frequency prioritization;
- `-able`/`-ible` morphology and exception data;
- the `content` default correction;
- corpus fixtures and evaluation reports;
- the version-4 contextual evidence envelope for every evaluated shadow
  occurrence;
- a concrete Foundation Models candidate selector;
- shadow-mode family configuration;
- availability, failure, privacy, cancellation, and fallback tests.

It may not:

- graduate a family to model-controlled automatic narration;
- add a cloud endpoint;
- add a Foundation Models adapter;
- select or bundle a neural OOV/context model;
- add runtime pack downloads;
- remove deterministic rules;
- change an existing audio file without explicit re-render;
- upload corrections or private evaluation data.

Phases 0–2 may be delivered as multiple coherent PRs to `nightly`, but they
share this architecture and one ordered implementation plan. Phase 3 begins
only after the shadow evidence is reviewed and a new implementation decision is
approved.

---

## 18. Definition of done for Phases 0–2

The first implementation program is complete when:

- pack generation is reproducible from pinned inputs;
- every shipped source has a provenance and attribution receipt;
- all shipped IPA validates against the production Kokoro vocabulary;
- current gold/silver behavior changes only through reviewed fixtures;
- `content` noun/adjective positive and negative cases pass;
- `-able`/`-ible` positives, exceptions, false bases, and controls pass;
- fallback rate and corpus coverage are reported by frequency band when a
  legally approved frequency source is available;
- the four initial contextual families run in shadow mode on eligible devices;
- model output cannot alter planned IPA or synthesis cache identity;
- ineligible devices and iOS 18/macOS 15 retain complete deterministic behavior;
- every Foundation Models unavailable and relevant failure category has a
  verified fallback test;
- cancellation stops preflight without finalizing a partial plan;
- every evaluated shadow occurrence has version-4 contextual evidence;
- shadow receipts validate occurrence and candidate IDs atomically;
- production logs contain no raw book context or model output;
- existing audit schemas still decode and new incomplete evidence fails closed;
- named linguistic tests pass;
- representative rendered samples pass the mechanical and human listening
  checks defined for the first program;
- `make test` and the narrowest relevant CLI/app builds pass;
- documentation names local tests, device model evaluation, human listening,
  and hosted CI as separate evidence.

Passing Phases 0–2 does not prove a family is ready for automatic model-assisted
pronunciation. It proves only that the universal improvements are shippable and
the shadow system can gather trustworthy evidence.

---

## 19. Implementation-planning handoff

After the user approves this written spec, the next action is to create an
ordered implementation plan for Phases 0–2. The plan must:

1. start with the frozen corpus and current-behavior baselines;
2. land the pack/provenance boundary before external data changes behavior;
3. land morphology behind named and held-out tests;
4. update plan/audit/cache signatures before contextual shadow evidence is
   persisted;
5. add the Foundation Models path behind compile-time, OS, runtime, family, and
   shadow-mode gates;
6. test deterministic fallbacks without requiring Foundation Models in ordinary
   CI;
7. reserve actual model-quality qualification for supported physical Apple
   Intelligence hardware or a verified supported simulator/host combination;
8. finish with human listening evidence rather than treating test completion as
   acoustic acceptance.

No production family graduation belongs in that implementation plan.
