# Local-First Pronunciation Planner — Product and Architecture Design

**Date:** 2026-07-09
**Status:** Conversational design approved; awaiting written-spec review
**Author:** Dan Fakkeldy. Ground-truthed and drafted with Codex.
**Base verified:** origin/nightly at 9d0b2b8310cd6e373c62af3ae5e1bac2586f9f03

> **Grounding note.** This design is based on the live Echo pipeline, focused
> G2P probes, the narration produced on 2026-07-09 with Echo Kokoro ONNX rv10
> and voice am_michael, and current upstream pronunciation-model research.
> Private manuscript text and generated media remain outside the repository.

---

## 1. Executive decision

Echo will keep Kokoro as its acoustic speech engine and add a dedicated,
local-first **PronunciationPlanner** before narration chunking.

The planner will combine:

1. Existing user overrides and trusted lexicon entries.
2. A compact bundled neural grapheme-to-phoneme model for genuinely unknown
   words.
3. A separately downloaded contextual pronunciation model for homographs and
   other sentence-dependent ambiguity.

The enhanced model pack is downloaded once, installed atomically, and then
works fully offline. Book text, phonemes, correction history, and generated
audio never need to leave the device. Echo and echo-cli will call the same
planner and produce the same immutable pronunciation plan.

This is a root-cause change. User overrides remain valuable for names and
personal terminology, but they stop being the primary strategy for ordinary
English words.

---

## 2. Problem statement and verified evidence

### 2.1 Current pipeline

The current production path is effectively:

    original block text
      → optional FMNormalizer refinement
        (app defaults to auto; echo-cli defaults to off)
      → TextNormalizer
      → occurrence override
      → book/global override
      → HomographPronunciationResolver
      → text chunking
      → text-only TTSEngine boundary
      → engine-local splitting, retry, Misaki G2P, and duration timing
      → Kokoro acoustic synthesis

NarrationRenderPlanner applies overrides and the handwritten homograph resolver
before splitting text into speech segments. The current TTSEngine contract
accepts text, so OnnxKokoroEngine, quality retries, duration timing, and silence
recovery can split text and run G2P again after the render plan was made.

FMNormalizer is another pre-plan input today. It can replace an entire block
with a String but provides no structured edit map back to the source. Its
availability and defaults differ between the app and echo-cli.

### 2.2 Representative failures

| Example | Verified front-end result | Diagnosis |
| --- | --- | --- |
| startable | stˈæɹtæblɛ, fallback rating 1 | The word is absent from the lexicon, the supported morphology does not cover the productive -able form, and the rule fallback maps terminal letters mechanically. This is a pre-Kokoro OOV failure. |
| receipt lives | lˈIvz | The intended verb is lˈɪvz. Apple lexical tagging selected a noun and the finite preceding/following-word lists had no matching cue. This is a context-disambiguation failure. |
| live evidence | lˈIv | Correct in this context. It proves that some paths work but does not generalize to unseen syntax. |
| index lives elsewhere | lˈɪvz | Correct because elsewhere is an explicit handwritten verb follower. It illustrates why the current solution becomes list maintenance. |
| verified | vˈɛɹəfˌId | The current front end produces a reasonable IPA sequence. If the rendered word still sounds wrong, the remaining defect is acoustic realization or voice/model behavior rather than spelling-to-phoneme selection. |
| record | Controlled noun and verb probes are correct | No exact record token existed in the inspected manuscript. It remains an important held-out homograph, not a confirmed source-specific regression. |

### 2.3 Root causes

1. Echo's vendored MisakiSwift deliberately removed its MLX-backed learned OOV
   fallback. The replacement is documented as aiming for “never silent, always
   plausible,” not pronunciation correctness.
2. Homographs are handled by a finite resolver plus general lexical tagging.
   Every new syntactic context can fall outside the lists.
3. NarrationPronunciationPreflight detects risk classes such as fallback use,
   acronyms, proper nouns, and empty phonemes. It does not independently know
   the correct pronunciation, and it is not a production render gate.
4. PronunciationFallbackDiscovery can offer the same approximate fallback IPA
   that triggered the issue as the proposed repair. That records uncertainty as
   authority rather than resolving it.
5. Listen-back QA is transcription-oriented. Whisper can recognize the intended
   spelling despite unnatural stress or vowels, so matching ASR text is not
   proof of good pronunciation.
6. Chunking before a complete pronunciation decision can remove sentence
   context that a homograph resolver needs.
7. The text-only TTSEngine boundary means a pronunciation decision cannot yet
   be guaranteed to survive engine splitting, quality retry, timing, and
   recovery paths.
8. Optional FM normalization can silently change spoken text without stable
   source ranges, and its app/CLI policy currently differs.

The result is predictable whack-a-mole: add a word, add a suffix, extend a
context list, or accept an unverified IPA, then discover the next miss.

---

## 3. Goals and non-goals

### Goals

- Produce natural first-pass English pronunciation without requiring users to
  maintain a growing dictionary of ordinary words.
- Resolve unknown words through a learned OOV model rather than a crude
  letter-by-letter approximation.
- Resolve homographs from the complete sentence while preserving known
  Kokoro-compatible pronunciation alternatives.
- Freeze pronunciation before chunking so render boundaries cannot change the
  linguistic decision.
- Carry exact planned phoneme IDs through normal synthesis, duration timing,
  quality retry, and silence-recovery paths.
- Make deterministic, source-mapped normalization the canonical app and CLI
  input.
- Keep enhanced narration fully functional offline after an optional one-time
  model-pack download.
- Use one planner and one cache signature contract in Echo and echo-cli.
- Preserve occurrence, book, and global overrides with their existing priority.
- Expose uncertainty and provenance instead of silently treating guesses as
  verified pronunciations.
- Separate linguistic correctness from acoustic realization and test both.
- Turn every confirmed regression category into replayable synthetic coverage.

### Non-goals

- Replacing Kokoro as part of the first implementation.
- Sending private text or audio to a hosted pronunciation service.
- Training or fine-tuning a model inside the shipping app.
- Supporting every language in the first release. The first planner is English
  and must leave an explicit language-provider seam.
- Automatically sharing user corrections.
- Re-rendering or deleting existing narration without an explicit user action.
- Treating overrides as obsolete. They remain the correct tool for names,
  invented terms, dialect preferences, and exceptional acoustic workarounds.

---

## 4. Locked product and technical decisions

| ID | Decision | Locked choice |
| --- | --- | --- |
| D1 | Speech engine | Keep Kokoro. Repair pronunciation planning before considering an acoustic-engine replacement. |
| D2 | Planner shape | Use two tiers: a small bundled OOV model and a downloaded sentence-context model. |
| D3 | Offline contract | No render-time network dependency. Once installed, the contextual pack works fully offline. |
| D4 | Privacy | Source text, phoneme plans, corrections, and audio stay on-device. No silent cloud fallback or content telemetry. |
| D5 | Timing | Plan pronunciation over complete sentences before splitting into Kokoro-sized chunks. |
| D6 | Overrides | Priority remains occurrence, then book, then global, then automatic planning. |
| D7 | Shared behavior | Echo and echo-cli use the same planner, model packs, validation, cache signature, and audit format. |
| D8 | Runtime | Prefer Echo's existing ONNX Runtime integration. Consider Core ML only if measured conversion parity, memory, energy, or latency is materially better. |
| D9 | Uncertainty | Low-confidence or unavailable-model decisions are explicit states. The system never labels an emergency guess as confirmed. |
| D10 | Handwritten rules | Keep current rules initially as compatibility hints or limited-mode fallback. Retire them only after the new planner proves parity or better on the frozen corpus. |
| D11 | Acoustic defects | Correct IPA that still sounds wrong is an acoustic/voice defect. Do not respond by expanding semantic spelling rules. |
| D12 | Rollout | Shadow benchmark, opt-in beta, then default for new renders. Retain the old path for one release as rollback. |
| D13 | Synthesis boundary | Production synthesis consumes exact planned phoneme IDs and token mappings. Text-only synthesis is a compatibility API, not the enhanced path. |
| D14 | Normalization | Deterministic, source-mapped normalization is canonical in both app and CLI. Foundation Models rewriting becomes advisory and explicit, never a silent production input. |
| D15 | Runtime tagging | NLTagger may supply a compatibility hint during migration but cannot remain the final authority for enhanced contextual decisions. |
| D16 | Asset readiness | “Fully offline” means both the Kokoro speech assets and required pronunciation assets have been installed and verified before rendering starts. |
| D17 | Pack trust | Downloaded model manifests are signed, anti-rollback protected, and verified against an app-embedded public key before any model graph is loaded. |
| D18 | Render metadata | A local render-metadata record preserves plan/version identity for current and legacy audio; cleanup never deletes an audio file still referenced by a track. |

---

## 5. Target architecture

### 5.1 Component map

    Original source blocks
      → deterministic normalization with source edit mappings
      → sentence segmentation with source ranges
      → PronunciationPlanner
          ├─ occurrence/book/global overrides
          ├─ Misaki compatibility provider
          ├─ lexicon candidate index
          ├─ ContextualPronunciationProvider for ambiguous candidates
          ├─ OOVPronunciationProvider for missing candidates
          ├─ legacy compatibility hints when required
          └─ PronunciationValidator
      → immutable PronunciationPlan
      → PlannedSynthesisChunk values
      → plan-aware TTSEngine
          ├─ exact phoneme-ID slices for quality retry
          ├─ the same IDs for duration timing
          └─ the same IDs for silence recovery
      → Kokoro acoustic synthesis
      → local plan summary, cache signature, audio, and alignment

### 5.2 PronunciationPlanner

The planner is the only production entry point that may convert normalized
English text into resolved Kokoro phonemes. In the enhanced/default target,
the same source text, overrides, planner version, model-pack versions, and
locale must produce the same plan across app and CLI. During Phase 1
compatibility mode, plans also record a compatibilityRuntimeID for the
operating-system NaturalLanguage runtime; cross-runtime byte identity is not
claimed until NLTagger leaves the authority path.

It owns orchestration and policy, not model-specific inference. Providers remain
replaceable and independently benchmarkable.

The planner consumes a structured normalized document, not a bare rewritten
String. Every normalization edit retains an original-source range and a spoken
range. Foundation Models may propose a rewrite in preflight, but the rewrite
must be shown and explicitly accepted before it becomes a versioned plan input.
The shipping planner does not silently invoke FMNormalizer.

### 5.3 Misaki compatibility and lexicon candidates

The current Misaki pipeline is sentence-coupled. It resolves tokens right to
left and combines lexicon data with future-vowel and future-to context, weak
forms, morphology, casing, NLTagger, punctuation, and multi-token merging. It
cannot be replaced in Phase 1 by a naive independent-token lookup while also
claiming output compatibility.

Phase 1 therefore introduces two explicit sources:

- **MisakiCompatibilityProvider** runs the current full-sentence path and
  records its selected phonemes and fallback metadata as the migration
  baseline.
- **LexiconCandidateIndex** exposes the raw known alternatives needed by the
  contextual selector.

The candidate index returns:

- zero candidates for an unknown word;
- one candidate for an unambiguous known word; or
- multiple candidates with lexical metadata for an ambiguous word.

Context-sensitive weak forms and merged tokens remain sentence-level records,
not independent dictionary words. The compatibility provider remains
authoritative until the target planner proves parity on those categories.

Known, unambiguous output remains byte-identical unless an approved model
migration explicitly changes it. NLTagger decisions are recorded as
compatibility hints with platform/runtime provenance. Before enhanced planning
becomes default, NLTagger must no longer be the final authority for ambiguous
pronunciations, eliminating cross-platform tagger drift from the target plan.

### 5.4 ContextualPronunciationProvider

The contextual provider receives:

- the complete normalized sentence;
- the target token and source range;
- the lexicon's known alternatives;
- optional lexical and compatibility hints.

Its primary job is to select among known alternatives. This preserves
Kokoro-native stress and phoneme conventions instead of regenerating every
phoneme in every sentence.

It is invoked only for ambiguous tokens. That bounds latency, memory use, and
the regression surface.

### 5.5 OOVPronunciationProvider

The bundled OOV provider runs only when the lexicon has no candidate. It returns
the proposed phonemes, calibrated confidence, and model provenance.

The current approximate fallback may remain as an explicitly named emergency
or limited-mode result, but it cannot be represented as a high-confidence
neural or lexicon pronunciation.

### 5.6 PronunciationValidator

The validator enforces:

- every emitted symbol is supported by the active Kokoro phoneme vocabulary;
- token and source ranges are monotonic and remain aligned;
- no speakable source token silently disappears;
- explicit IPA overrides are preserved exactly when valid;
- sentence-to-chunk transformations retain the selected phonemes;
- provider output cannot inject unsupported markup or escape its target range.

Validation failure stops the affected plan or render unit with an actionable
diagnostic. It never drops unsupported symbols and continues silently.

### 5.7 Exact-phoneme synthesis boundary

The enhanced production TTSEngine contract accepts a PlannedSynthesisChunk
rather than a String. Each chunk contains:

- the plan digest and sentence/chunk identity;
- normalized spoken text for diagnostics;
- the exact Kokoro phoneme string and encoded phoneme IDs;
- token, word-boundary, and original-source mappings;
- planner-approved safe split boundaries.

The engine may slice a chunk only at those boundaries. Every quality retry,
waveform synthesis call, duration-head call, timing calculation, and
silence-recovery attempt reuses the corresponding phoneme-ID slice. None may
call G2P or re-resolve a word.

The existing text-only synthesis API remains temporarily for compatibility,
tests, previews, and non-English providers. It is not used by enhanced English
narration. This engine-boundary change is part of Phase 1; an immutable plan
without it is not considered implemented.

### 5.8 PronunciationModelPackStore

The store owns contextual-pack discovery, download, verification, activation,
rollback, and removal. A model pack is untrusted computational input: ONNX
Runtime parses and executes its graph, so a checksum alone is insufficient.

Each pack manifest records at minimum:

- schema version;
- pack identifier and semantic version;
- language and dialect;
- planner compatibility range;
- model/runtime format;
- phoneme-vocabulary identifier or digest;
- file sizes and SHA-256 digests;
- license and attribution metadata;
- confidence-calibration version.

The manifest is signed with an app-controlled signing key and verified against
an app-embedded public key and key identifier. Version policy rejects rollback
below the installed trust floor unless the app ships an explicit recovery
allowlist.

Downloads go to a staging location. Activation requires a valid signature,
every expected digest, bounded file count and expanded size, expected
input/output signatures, supported opset/operator policy, and a successful
resource-limited model-open probe. Archive extraction rejects unexpected files,
duplicates, traversal, and escaping symlinks. Activation is an atomic directory
replacement. A damaged or incompatible pack cannot replace the
last-known-good pack.

### 5.9 Narration asset readiness

Pronunciation assets do not replace Kokoro's acoustic assets. The current
OnnxKokoroEngine can download its speech model on first prepare, so “offline
rendering” is true only after both asset families are ready.

One shared NarrationAssetStore reports:

- Kokoro model/voice readiness and versions;
- bundled OOV readiness;
- contextual-pack readiness;
- missing bytes and installation errors;
- whether full-quality offline rendering is available.

App and CLI receive injectable asset roots and the same verification policy.
The CLI provides install, status, verify, remove, and local-sideload operations
so an air-gapped Mac can be prepared without a render attempting network
access.

---

## 6. Pronunciation plan contract

### 6.1 Plan contents

A PronunciationPlan contains ordered sentence and token records. Each resolved
token records:

- source spelling and normalized spelling;
- source block identifier and character range;
- normalized spoken range and the normalization edit that connects it to the
  source;
- selected Kokoro-compatible IPA or phoneme sequence;
- encoded Kokoro phoneme IDs and planner-approved split boundaries;
- known alternatives when applicable;
- provenance;
- confidence and review state;
- planner version;
- relevant model-pack and lexicon versions.
- compatibilityRuntimeID while a platform NaturalLanguage result can still
  influence compatibility output.

Provenance is one of:

- occurrence override;
- book override;
- global override;
- unambiguous lexicon;
- contextual selection;
- neural OOV;
- legacy compatibility hint;
- emergency fallback;
- unresolved.

The plan is immutable after validation. Chunking may group or split planned
tokens, but it may not run G2P again or change a selected pronunciation.
PlannedSynthesisChunk slices are derived from this plan and retain its digest.

### 6.2 Resolution order

The complete override precedence is:

1. user occurrence override;
2. user book override;
3. user global override;
4. shipped system built-in override;
5. automatic candidate selection.

Legacy homograph hints are not system built-ins. They live inside automatic
selection as compatibility evidence and therefore cannot overwrite any user or
shipped built-in override.

For each normalized sentence:

1. Run deterministic normalization and construct the source edit map.
2. Segment normalized text into sentences while preserving source ranges.
3. Apply the override precedence above.
4. Gather the Misaki compatibility result and lexicon alternatives.
5. Accept a single unambiguous lexicon candidate when it matches the protected
   compatibility categories.
6. Send multiple candidates to the contextual provider.
7. Send zero-candidate words to the bundled OOV provider.
8. Use a trusted legacy homograph hint only under the defined compatibility or
   limited-mode policy.
9. Validate the complete sentence plan against the Kokoro vocabulary.
10. Encode the selected phonemes once, freeze the plan, and derive
    PlannedSynthesisChunk values.

Overrides are authoritative but still vocab-validated. A malformed override is
reported to the user rather than silently replaced.

During Phase 1, compatibility output may still differ across operating-system
NaturalLanguage runtimes and must record that provenance. The target
app/CLI byte-identity gate applies after contextual selection replaces
NLTagger as the authority for ambiguous tokens.

### 6.3 Source mapping and read-along

Source ranges are carried through normalization and planning so existing
read-along highlighting, word timing, QA windows, and occurrence-scoped repairs
can continue to address the original book text. Pronunciation markup must never
become the displayed source.

Deterministic normalization must therefore evolve from a String-only function
to a structured result with source edits. A transformation that cannot produce
a valid mapping fails validation rather than assigning fabricated word ranges.
An explicitly accepted FM rewrite is stored as a user-approved spoken-text
revision with its own source-edit record; it is never an availability-dependent
runtime branch.

---

## 7. Caching and local persistence

The narration cache signature must include:

- normalized source content;
- resolved pronunciation-plan digest;
- occurrence, book, and global override state;
- planner version;
- lexicon version;
- OOV model version;
- contextual model-pack version;
- normalization mode and existing voice/render inputs.

This prevents corrected planning from reusing stale audio.

An additive narration_render_metadata table is keyed by audiobook and track.
It records:

- plan digest and planner version;
- normalization and lexicon versions;
- OOV and contextual-pack versions;
- Kokoro model revision and voice;
- quality state and whether limited mode was used;
- summary counts and creation time.

The full token plan is not stored in the database. A diagnostic plan file may
be retained in Echo's private Application Support area when the user enables
diagnostic retention. Headless exports include only the summary and plan digest
in their local manifest unless an explicit diagnostic-output path is supplied.

A pre-existing track with no metadata row is classified as legacyUnknown and
remains playable. Echo offers a deliberate re-render; it does not mutate audio
mid-book.

Cache cleanup changes from render-version deletion to reference-aware cleanup:
an audio file referenced by a track is never swept merely because its planner
or render version is old. Only partial, orphaned, or explicitly replaced cache
files are eligible for deletion. Metadata removal and track/audio deletion are
performed atomically or through a recoverable two-phase cleanup.

---

## 8. Offline, privacy, and security contract

- Once NarrationAssetStore reports offlineReady, planning and rendering make no
  network requests. A missing Kokoro or pronunciation asset is handled as an
  installation state before rendering starts, never as a hidden mid-render
  download.
- A model update check is separate from narration and retrieves only pack
  metadata and model files.
- No book text, token, phoneme, override, audio clip, or audit report is added to
  a pack request.
- Update checks are user initiated or controlled by an explicit setting; lack
  of connectivity never disables an already installed pack.
- Packs are fetched only from configured trusted origins and are rejected on
  manifest signature, anti-rollback policy, digest, graph signature,
  compatibility, operator policy, or size mismatch.
- Archive extraction enforces maximum file count, compressed and expanded byte
  limits, and rejects path traversal, symlinks outside the staging directory,
  duplicate manifest entries, and unexpected files.
- Private production excerpts and rendered media are never committed. Committed
  fixtures use synthetic or public-domain text with a short rights note.
- User corrections remain local unless a later, separately approved opt-in
  contribution design is implemented.
- Full token-level diagnostic retention is off by default. When enabled, files
  use platform file protection, are excluded from backup and sync, expire after
  seven days, and can be purged immediately from Settings or the CLI.
- Normal logs contain digests, counts, and provider/model versions, not source
  text, complete phoneme sequences, or correction contents.

---

## 9. Failure states and user experience

### 9.1 Quality states

| State | Meaning | Behavior |
| --- | --- | --- |
| Ready | Kokoro and required pronunciation assets are valid and all decisions passed validation | Render normally and offline without any network access. |
| Limited | Contextual pack is absent, but overrides, unambiguous lexicon, bundled OOV, and trusted compatibility paths remain available | Continue only when no unresolved ambiguity remains, or when the user explicitly permits a limited preview. |
| Needs review | One or more low-confidence or unresolved decisions remain | Present one book-level review list; do not interrupt token by token. |
| Assets missing | Kokoro or required pronunciation assets are not installed | Offer an explicit install or local-sideload step before rendering. |
| Pack error | Downloaded pack is corrupt, untrusted, incompatible, rolled back, or failed activation | Keep the last-known-good pack and offer repair. |
| Plan error | Validation found unsupported phonemes, missing mappings, or malformed output | Stop the affected render unit with an actionable diagnostic. |

### 9.2 App behavior

Narration preflight shows a compact summary such as:

- enhanced pack and version;
- ambiguous tokens resolved;
- OOV tokens resolved;
- unresolved or low-confidence items;
- expected render quality state.

Only unresolved items require attention. The review list groups repeated terms
and offers candidate audio previews. A user selection can be saved for this
occurrence, this book, or globally.

Common English words repeatedly entering review are treated as planner
regressions, not normal user maintenance.

Narration settings show the installed contextual-pack version, status, size,
update, repair, removal, and diagnostic-purge actions. The same surface reports
Kokoro readiness so “offline ready” describes the complete narration stack.
Advanced diagnostics expose local IPA, confidence, provenance, and model
versions.

### 9.3 CLI behavior

echo-cli uses the same preflight and plan. Publish-quality narration exits
nonzero when unresolved decisions remain. The explicit
--allow-limited-pronunciation option permits preview or recovery workflows and
must be recorded in the output manifest.

Machine-readable preflight and audit output must contain decisions and ranges
without requiring generated audio. Raw private source text is emitted only when
the user explicitly chooses an output file in their local workspace.

The CLI also exposes narration-assets install, status, verify, remove, and
sideload commands. All use the same injectable store and trust policy as the
app. The narrate command never installs or updates a model implicitly.

---

## 10. Correctness and evaluation strategy

### 10.1 Frozen corpus

The repository will contain a synthetic/public-domain English evaluation corpus
with:

- every confirmed regression category, including startable and contextual
  live/lives examples;
- verified as both a front-end and acoustic-realization probe;
- noun/verb and other sense-balanced examples for record, read, lead, wind,
  close, use, object, present, content, resume, and similar homographs;
- productive morphology, compounds, mixed case, acronyms, names, punctuation,
  possessives, and inflection;
- negative guards proving ordinary unambiguous words do not change;
- a development split and a held-out release split.

Expected results may allow multiple acceptable dialect-compatible phoneme
sequences, but every contextual case carries one intended semantic sense.
Private examples are reduced to minimal synthetic sentences before becoming
repository fixtures.

The held-out contextual set contains at least 1,000 sentences. Each priority
homograph sense has at least 50 independently authored contexts, and no sentence
template or source passage crosses development and held-out splits. Production
distribution testing uses at least ten synthetic or public-domain works across
fiction, nonfiction, dialogue, and technical prose.

### 10.2 Model-selection benchmark

Candidates are evaluated behind the same provider interfaces. At minimum, the
benchmark compares:

- today's lexicon plus rule fallback;
- a compact learned word-level OOV model;
- a sentence-aware contextual pronunciation model;
- any converted ONNX or Core ML form against its reference implementation.

The selected models must have acceptable redistribution terms, deterministic
packaging, documented provenance, and reproducible conversion scripts. No
candidate is selected solely because it is easy to integrate.

#### Current candidate posture

- Upstream MisakiSwift's learned BART resources are approximately 3 MB per
  dialect and are a credible compact OOV baseline. The released fallback is
  word-level, not a sentence-semantic homograph resolver.
- Upstream MisakiSwift currently pins MLX Swift 0.30.2. A documented arm64 iOS
  Simulator linker problem in that version was fixed in MLX Swift 0.30.6.
  Phase 0 must still verify inference on Echo's supported simulator and physical
  device matrix; it must not assume either blanket failure or blanket support.
- SoundChoice is a useful sentence-context quality challenger, but not a
  preselected mobile dependency. Its model repository is approximately 129 MB
  and its reference configuration also enables an external BERT-base model,
  making the unmodified runtime footprint substantially larger. It ships as a
  SpeechBrain/PyTorch checkpoint with ARPAbet output, not an official mobile
  ONNX or Core ML artifact.
- Apple's NLContextualEmbedding may be useful as features for a small
  homograph classifier, but asset availability, cold latency, size, device
  support, and simulator behavior are benchmark questions rather than assumed
  product guarantees.

The likely Phase 0 comparison is therefore a compact Misaki-family word model
for OOV coverage plus multiple context-selector candidates, with SoundChoice
serving as a quality ceiling/challenger. The benchmark, not this design
document, makes the final model choice.

### 10.3 Linguistic release gates

- 100 percent of named regression cases pass.
- Known unambiguous lexicon tokens remain byte-identical unless an approved
  migration lists the intended changes.
- At least 99 percent of automatically resolved held-out ambiguous cases select
  the intended sense, with a Wilson 95 percent lower bound of at least 98
  percent; uncertain cases abstain instead of guessing.
- Auto-resolution coverage is at least 95 percent overall and at least 90
  percent for every priority homograph sense with the minimum sample size.
- Accuracy and abstention are reported per word, sense, morphology category,
  dialect set, and source genre so a strong average cannot hide a weak class.
- The production corpus averages no more than one unresolved review item per
  narrated hour, its P95 book is no more than two per hour, and no tested book
  exceeds three per hour before the planner becomes default.
- OOV phoneme error is reduced by at least 50 percent from today's fallback on
  the held-out OOV set.
- No catastrophic syllable splitting remains in the production regression set.
- Zero unsupported or silently dropped phonemes.
- App and CLI plans are byte-identical for identical inputs.
- Repeated runs with pinned versions produce identical plan digests.

### 10.4 Acoustic release gates

Planner correctness and rendered-audio correctness are separate test results.
The acoustic suite renders frozen sentences through the production Kokoro model
and representative shipped voices, including am_michael.

Acceptance uses randomized, level-matched, blind A/B listening. At least three
raters score each sample for semantic correctness and naturalness. The deep
suite contains at least 100 targeted regressions and 100 unambiguous control
sentences on the primary voices; every shipped voice receives the named
regression smoke set.

The candidate must:

- make every named regression semantically correct by majority judgement;
- be preferred over the baseline on at least 80 percent of baseline-failure
  samples;
- be judged worse on no more than two percent of unambiguous controls;
- show no statistically significant naturalness regression on the control set.

Disagreements on a named regression are adjudicated by an additional listener
before release. ASR matching may assist triage, but it cannot pass a
pronunciation by itself.

If planned phonemes are correct and the audio still sounds wrong:

1. classify the result as an acoustic model or voice defect;
2. reproduce it across voices and model revisions;
3. upgrade, replace, or block the affected model/voice combination if the error
   is systematic;
4. permit a narrowly documented acoustic override only for isolated residual
   cases.

The semantic planner must not absorb acoustic defects through expanding
word-context rules.

### 10.5 Reliability, offline, and performance gates

- Full planning and synthesis pass with networking denied after pack install.
- A clean offline-ready check proves both Kokoro and pronunciation assets are
  present before the network is denied.
- Interrupted, corrupt, oversized, incompatible, and wrong-digest packs leave
  the last-known-good version active.
- Invalid signatures, replayed/older signed manifests, graph-signature
  mismatches, excess archive expansion, and disallowed ONNX operators are
  rejected before activation.
- Cache signatures change whenever any pronunciation-affecting input changes.
- Source ranges and read-along mappings remain correct across sentence and
  chunk boundaries.
- Cold-start time, peak resident memory, sustained planning throughput, and
  thermal behavior are measured on the oldest supported device class and an
  Apple-silicon Mac.
- Candidate-specific numerical performance budgets are locked from Phase 0
  baselines before a model is selected. A candidate that causes memory-pressure
  termination or prevents continuous narration is rejected regardless of
  accuracy.

---

## 11. Rollout and implementation slices

### Phase 0 — Corpus and model benchmark

- Build the frozen development and held-out corpora.
- Add direct current-pipeline baselines.
- Benchmark word-level and sentence-aware candidates in their reference
  runtimes.
- Verify licenses, conversion reproducibility, disk size, memory, latency, and
  confidence calibration.
- Choose models only after the quality and device results are recorded.

No shipping narration behavior changes in this phase.

### Phase 1 — Immutable planner with compatibility behavior

- Standardize app and CLI on deterministic normalization; remove silent
  FMNormalizer rewriting from production and retain FM only as an explicit
  advisory rewrite flow.
- Introduce structured normalization edits, plan types, source mappings,
  validation, provenance, and plan digests.
- Add MisakiCompatibilityProvider and LexiconCandidateIndex without pretending
  the current sentence-coupled pipeline is an independent-token API.
- Add PlannedSynthesisChunk and the exact-phoneme TTSEngine contract.
- Route normal synthesis, quality retry, duration timing, and silence recovery
  through the same planned phoneme-ID slices.
- Route Echo and echo-cli through the same planner.
- Preserve deterministic lexicon, override, weak-form, merged-token, and
  compatibility behavior; explicitly measure temporary NLTagger platform drift.
- Move chunking after plan finalization.
- Add reference-safe cache cleanup, narration_render_metadata, plan signatures,
  and manifest integration.

This phase proves the architecture without yet changing deterministic
automatic pronunciations. Existing FM-refined cached audio remains playable,
but new app and CLI renders share the canonical deterministic policy.

### Phase 2 — Bundled neural OOV provider

- Integrate the selected compact model using the provider seam.
- Replace rule fallback for eligible OOV words.
- Keep emergency fallback explicitly marked and low-confidence.
- Gate on the OOV corpus, memory, and offline tests.

### Phase 3 — Contextual pack and pack store

- Add signed pack manifests, secure download, anti-rollback verification,
  graph/resource validation, atomic activation, rollback, and removal.
- Unify Kokoro and pronunciation readiness behind NarrationAssetStore and add
  app/CLI install, status, verify, remove, and sideload paths.
- Integrate contextual candidate selection only for ambiguous words.
- Add pack and no-pack behavior tests.
- Keep legacy rules as compatibility hints during the beta.

### Phase 4 — Preflight, review, and settings

- Make pronunciation preflight a real render gate.
- Add app quality summary, grouped review, previews, and model-pack controls.
- Add CLI exit policy, allow-limited flag, and machine-readable audit.
- Preserve local-only diagnostics and explicit correction scopes.

### Phase 5 — Default and retirement

- Run blind acoustic review and the complete linguistic/reliability matrix.
- Enable enhanced planning by default for new renders.
- Require the target app/CLI byte-identity gate with NLTagger removed as final
  contextual authority.
- Retain the prior planner as a rollback for one release.
- Retire handwritten rules only when corpus evidence proves they are redundant.
- Keep a small emergency compatibility layer with explicit provenance.

Each phase is a separately reviewable PR or PR series against nightly. Later
phases do not bypass an earlier quality gate.

---

## 12. Alternatives considered

### One sentence-level model for every token

This is conceptually simple but needlessly re-generates known pronunciations,
increases memory and latency, and expands the regression surface. The approved
design invokes context only where context matters.

### Replace Kokoro entirely

Another TTS system might improve acoustic realization, but it would also change
voices, timing, model delivery, export behavior, performance, and much of the
existing test surface. It does not directly explain or repair the verified OOV
and homograph front-end defects.

### Cloud pronunciation service

A hosted language model could provide strong context, but it would create
privacy, availability, cost, latency, and reproducibility dependencies for
private books. Cloud tools may be used on public or synthetic material during
research, never as the production authority.

### Continue expanding overrides and handwritten rules

Overrides are precise and necessary for exceptional terms. They do not scale to
productive morphology or unseen sentence structure and reproduce the
whack-a-mole problem this design is intended to end.

### Use Apple system speech as the main narrator

System speech is useful as an evaluation comparator and accessibility fallback,
but switching would surrender Echo's existing Kokoro voices, deterministic
phoneme pipeline, timing behavior, and model control. It is not the recommended
root fix.

---

## 13. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Context model improves averages but confidently selects the wrong sense | Calibrated confidence, held-out sense-balanced corpus, abstention, and a 99 percent auto-resolved accuracy gate. |
| Model conversion changes outputs | Compare converted inference token-for-token with the reference implementation before packaging. |
| Pack is too large or memory hungry | Invoke it only for ambiguous tokens, benchmark oldest supported hardware, and reject candidates that violate measured budgets. |
| Sentence segmentation loses source mapping | Preserve block/range identities through normalization and test cross-boundary read-along behavior. |
| Model update unexpectedly changes old books | Pin pack versions in plan summaries and require deliberate re-rendering. |
| License or redistribution terms are unsuitable | Complete license review in Phase 0 before committing to a model or distribution channel. |
| Neural output contains unsupported phonemes | Validate before chunking and fail the plan; never drop symbols silently. |
| Confidence is poorly calibrated | Version calibration data separately and measure accuracy at each confidence bucket. |
| A voice renders correct IPA badly | Classify and test it as an acoustic defect; upgrade or constrain the voice/model rather than distorting semantics. |
| Review queue remains burdensome | Gate default rollout on the per-hour unresolved rate, not only model-level accuracy. |
| Existing fixes regress while architecture changes | Phase 1 preserves deterministic Misaki and override output for equivalent canonical normalized input, keeps legacy FM-refined cached audio playable, and retains the legacy path for rollback. |

---

## 14. Definition of done

This program is complete when:

1. Echo and echo-cli plan identical phonemes before chunking.
2. Unknown ordinary English words use a validated learned OOV path.
3. Contextual homographs use complete-sentence evidence rather than finite word
   lists as the primary authority.
4. Full-quality narration works offline after the model pack is installed.
5. Missing or uncertain decisions are visible and cannot silently masquerade as
   confirmed pronunciations.
6. Cache invalidation follows the exact resolved plan and model versions.
7. Named regressions and held-out quality gates pass.
8. Real audio passes blind listening checks, not just IPA or ASR assertions.
9. Existing audio and user overrides remain safe through upgrades and rollback.
10. Private book content and corrections remain local.

---

## 15. Implementation-planning handoff

After this written design is approved, the implementation plan must:

- start with Phase 0 and strict red/green model-evaluation fixtures;
- identify exact files and interfaces from the current nightly branch;
- define one failing test before each production-code step;
- use small, independently reviewable PRs against nightly;
- run package-level G2P tests, focused Echo narration tests, app/CLI parity
  tests, device memory checks, and hosted Build gate + tests;
- keep private books, audio, manifests containing private text, and model
  scratch artifacts outside git;
- include a rollback and pack-compatibility test in every phase that changes
  production planning.

No implementation code is authorized by this document alone. The next artifact
is the detailed implementation plan after Dan approves this written
specification.

---

## Appendix A — Current-code evidence

- EchoCore/Services/Narration/NarrationRenderPlan.swift — normalization,
  override/homograph application, and pre-synthesis splitting.
- EchoCore/Services/Narration/NarrationService.swift — occurrence and merged
  override ordering, cache signatures, render and persistence flow.
- EchoCore/Services/Narration/HomographPronunciationResolver.swift — finite
  deterministic context sets.
- EchoCore/Services/Narration/KokoroG2P.swift — current Misaki/Kokoro front-end
  wrapper and fallback reporting.
- ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/Lexicon.swift —
  lexicon and limited productive morphology.
- ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift
  — approximate non-neural fallback.
- EchoCore/Services/Narration/NarrationPronunciationPreflight.swift — risk
  discovery rather than pronunciation correctness.
- EchoCore/Services/Narration/PronunciationFallbackDiscovery.swift — current
  fallback-to-suggested-fix loop.
- EchoCore/Services/Narration/QA/NarrationQADetector.swift — ASR divergence
  behavior that suppresses exact-spelling matches.
- Echo.xcodeproj/project.pbxproj — iOS 18.0, macOS 15.0, Swift 6.0, and existing
  ONNX Runtime package integration.

## Appendix B — External primary references

- [Kokoro](https://github.com/hexgrad/kokoro) — upstream speech model and
  Misaki-based pronunciation front end.
- [Misaki](https://github.com/hexgrad/misaki) — upstream G2P implementation and
  learned fallback architecture.
- [MisakiSwift resources](https://github.com/mlalma/MisakiSwift/tree/main/Sources/MisakiSwift/Resources)
  — current word-level BART and lexicon assets.
- [SoundChoice paper](https://www.isca-archive.org/interspeech_2022/ploujnikov22_interspeech.pdf),
  [model card](https://huggingface.co/speechbrain/soundchoice-g2p), and
  [configuration](https://huggingface.co/speechbrain/soundchoice-g2p/blob/main/hyperparams.yaml)
  — sentence-aware research candidate and its external BERT configuration.
- [MLX Swift issue 341](https://github.com/ml-explore/mlx-swift/issues/341),
  [fix PR 354](https://github.com/ml-explore/mlx-swift/pull/354), and
  [0.30.6 release](https://github.com/ml-explore/mlx-swift/releases/tag/0.30.6)
  — the specific simulator-linking history that must be re-tested rather than
  generalized.
- [NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
  — a possible on-device context feature source, subject to Phase 0 benchmarks.
- [ONNX Runtime Swift package](https://github.com/microsoft/onnxruntime-swift-package-manager)
  — the runtime family already integrated by Echo.
