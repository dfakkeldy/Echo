# Global Pronunciation Foundation and Hybrid Context Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve Echo narration for all future books by adding a reproducible bundled American-English pronunciation pack, conservative auditable morphology, a noun-first fallback for `content`, on-device Foundation Models contextual classification recorded in shadow-mode audits, and a bounded development-only direct-audio judge used before final Phase 0–2 qualification/publication.

**Architecture:** Keep Echo's existing override → homograph → Kokoro G2P pipeline and insert one deterministic universal-pronunciation rewrite between overrides and homographs. Foundation Models run independently before rendering, choose only among stable candidate IDs for four approved contextual families, and attach evidence to the audit without changing narration or synthesis cache identity in Phases 0–2. Task 10 adds a standard-library Python development tool that sends only eligible short public-domain or synthetic production Echo renders to the pinned OpenAI audio-input model, strictly validates machine verdicts, and records separate capped evidence outside the repository; it is not a production authority or runtime cloud fallback.

**Tech Stack:** Swift 6, Swift Testing, Foundation Models behind iOS 26/macOS 26 availability gates, MisakiSwift/Kokoro G2P, Foundation, NaturalLanguage sentence segmentation, standard-library Python 3 tooling, OpenAI Chat Completions direct audio input, JSON/JSONL resources, Make, Xcode synchronized groups.

**Design source:** `docs/superpowers/specs/2026-07-28-global-pronunciation-context-design.md`

## Global Constraints

- Implement only the approved Phase 0–2 boundary. Do not allow a model selection to change narration, block a render, downgrade a deterministic decision, or enter synthesis cache identity.
- Preserve precedence: occurrence override → book/global/built-in override → supplemental exact entry → conservative morphology → deterministic contextual homograph → existing Misaki/Kokoro path.
- Keep contextual-family words out of supplemental and morphology automatic rewrites. Their production result continues to come from `HomographPronunciationResolver`.
- Send only the target sentence plus at most one adjacent sentence on each side to Foundation Models. Never send a book, chapter, transcript, title, author, local path, or user identifier.
- Foundation Models choose stable candidate slots only. They never emit IPA, rewrite text, or create candidates.
- Treat frequency as a build-time prioritization band only. It may not decide pronunciation.
- Do not add a runtime dictionary updater, cloud service, adapter, neural OOV model, or third-party package.
- Keep CMUdict and generated pack inputs pinned, licensed, reproducible, and reviewable. `wordfreq` remains an optional development-only input until separately licensed.
- Keep private books and generated model evidence out of committed fixtures and logs.
- Paid OpenAI audio calls are authorized only for short public-domain or
  synthetic pronunciation clips. Never send private or copyrighted book text
  or audio, titles, authors, paths, identifiers, or metadata.
- Pin the Task 10 audio judge to the current official audio-input model at
  implementation time: `gpt-audio-1.5` through Chat Completions. Record both
  the requested model ID and the API-returned `model` value.
- `gpt-audio-1.5` does not support Structured Outputs. Request one small JSON
  object, strictly validate every field and the closed vocabulary locally,
  reject malformed/duplicate/extra/unknown output, and never treat parsing
  fallback as a pass.
- Read `OPENAI_API_KEY` only from the process environment or an established
  secret provider in the repository/API credential workflow. Never accept a
  key in arguments, persist it, print it, log request headers, or commit it.
- If no credential exists, continue every independent local task and report
  only the audio-judge lane as `WAITING_FOR_USER`, never passed or failed.
- The first unattended audio-judge run stops before request 201 and before the
  estimated cumulative cost would exceed USD 10.00; the stricter limit wins.
  Estimate before every request and record actual API usage when returned.
- Keep current official model rates in an explicit versioned pricing
  configuration with source URL and check date. Judge requests use audio input
  and text output only.
- Mac speakers remain muted. The model evaluates MP3/WAV files directly;
  acoustic playback is not needed.
- Treat audio-judge results as development evidence. Transcription may assist
  diagnosis, but machine verdicts are never human labels or final human
  listening, and machine-proposed corpus examples remain `provisional` until
  independently human-labelled and adjudicated.
- Agents may implement and test corpus schemas and prepare separately
  identified `provisional` candidates, but must never populate `labelA`,
  `labelB`, or `adjudicated` as human evidence. Only independently supplied or
  source-verifiable human-labelled/adjudicated rows count toward thresholds.
  Without enough such rows, report `WAITING_FOR_HUMAN_LABELS`, continue
  independent Tasks 2–10, and keep corpus-dependent qualification and final
  Phase 0–2 acceptance pending. This is distinct from the audio-key state
  `WAITING_FOR_USER`.
- Admit paid clips only when they are MP3/WAV, at most 15.0 seconds, exactly
  `public-domain` or `synthetic`, and identified by `clip_` plus a canonical
  lowercase random UUIDv4 generated independently of all semantic content and
  metadata. `provisional` clips may be evaluated diagnostically but never count
  toward corpus accuracy, human labels/listening, qualification, or graduation.
- The audio model cannot edit production pronunciation data. Allow one narrow
  diagnosis/fix proposal at a time and no more than two automated fix attempts
  per failing clip before morning review; require red/green tests, negative
  guards, implementation review, rerender, retest, and full touched-family
  regression.
- `audio_judge.py` only emits proposals and records evidence. It never edits a
  production file or invokes an editor. Its outside-repository durable ledger
  owns the per-clip zero-through-two reviewed-attempt counter; only an explicit
  `record-attempt` operation with source commit plus red/green,
  negative-guard, and review receipts may increment it.
- Results and morning queues contain no raw private text/audio, titles,
  authors, paths, identifiers, API keys, or request headers. Public/synthetic
  clip IDs are opaque corpus IDs.
- Use concrete types and closure injection; do not introduce a provider protocol for the single Foundation Models implementation.
- Run all model and lexicon preflight work off the UI actor, propagate cancellation, and use a fresh `LanguageModelSession` per batch.
- Feature work branches from and opens a PR to `nightly`; never push directly to `main`, `weekly`, or `nightly`.

## Execution Setup

- [ ] Read `ARCHITECTURE.md` and the design source above before changing code.
- [ ] Run `git status --short --branch`, confirm the implementation is in a dedicated clean worktree containing the approved spec and this plan, and preserve unrelated work.
- [ ] Confirm the feature branch is based on the intended `nightly` state. Fetching is read-only; do not rebase, reset, clean, or rewrite user-owned history as an automatic setup step.
- [ ] Run the narrow baseline gates for the touched pronunciation stack before Task 1:

```bash
make build-tests
make test-only FILTER=EchoTests/HomographPronunciationResolverTests
make test-only FILTER=EchoTests/PronunciationAuditTests
make echo-cli
```

- [ ] Record any pre-existing failure and stop if it prevents distinguishing the implementation from the baseline.

## File Map

### Create

- `Tools/Pronunciation/pronunciation_corpus.py`
- `Tools/Pronunciation/build_pronunciation_pack.py`
- `Tools/Pronunciation/audio_judge.py`
- `Tools/Pronunciation/cmudict.lock.json`
- `Tools/Pronunciation/tests/test_pronunciation_corpus.py`
- `Tools/Pronunciation/tests/test_build_pronunciation_pack.py`
- `Tools/Pronunciation/tests/test_audio_judge.py`
- `ThirdParty/CMUdict/LICENSE`
- `ThirdParty/CMUdict/cmudict.dict`
- `THIRD_PARTY_NOTICES.md`
- `EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json`
- `EchoCore/Services/Narration/EnglishPronunciationPack.swift`
- `EchoCore/Services/Narration/UniversalPronunciationResolver.swift`
- `EchoCore/Services/Narration/ContextualPronunciationTypes.swift`
- `EchoCore/Services/Narration/ContextualPronunciationFamilies.swift`
- `EchoCore/Services/Narration/ContextualPronunciationDiscovery.swift`
- `EchoCore/Services/Narration/ContextualPronunciationPreflight.swift`
- `EchoCore/Services/Narration/FoundationModelsContextualPronunciationEvaluator.swift`
- `EchoTests/EnglishPronunciationPackTests.swift`
- `EchoTests/UniversalPronunciationResolverTests.swift`
- `EchoTests/ContextualPronunciationFamiliesTests.swift`
- `EchoTests/ContextualPronunciationDiscoveryTests.swift`
- `EchoTests/ContextualPronunciationPreflightTests.swift`
- `EchoTests/FoundationModelsContextualPronunciationEvaluatorTests.swift`
- `EchoTests/PronunciationProgramAcceptanceTests.swift`
- `EchoTests/Fixtures/Pronunciation/named_regressions_v1.jsonl`
- `EchoTests/Fixtures/Pronunciation/contextual_family_candidates_v1.jsonl`
- `EchoTests/Fixtures/Pronunciation/contextual_families_v1.jsonl` only when
  independently supplied or source-verifiable labels are legally cleared and
  meet the qualification contract
- `EchoTests/Fixtures/Pronunciation/distribution_works_v1.json`
- `EchoTests/Fixtures/Pronunciation/morphology_v1.jsonl`
- `docs/reports/pronunciation-phase2-qualification.md`

### Modify

- `Makefile`
- `Echo.xcodeproj/project.pbxproj`
- `EchoCore/Services/Narration/MisakiResources/us_gold.json`
- `EchoCore/Services/Narration/HomographPronunciationResolver.swift`
- `EchoCore/Services/Narration/PronunciationPlanner.swift`
- `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- `EchoCore/Services/Narration/NarrationService.swift`
- `EchoCore/Services/Narration/NarrationFileNaming.swift`
- `EchoCore/Services/Narration/PronunciationAudit.swift`
- `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- `EchoTests/HomographPronunciationResolverTests.swift`
- `EchoTests/KokoroG2PTests.swift`
- `EchoTests/NarrationRenderPlanTests.swift`
- `EchoTests/NarrationServiceTests.swift`
- `EchoTests/NarrationFileNamingTests.swift`
- `EchoTests/PronunciationAuditTests.swift`
- `EchoTests/PronunciationListeningReelTests.swift`
- `ARCHITECTURE.md`

## Explicit Phase 3+ Deferrals

- Model selections do not control pronunciation in this plan. Family graduation, automatic acceptance policy, and any runtime-family allowlist require a new reviewed decision after Phase 2 evidence exists.
- The semantic human-review UI, persistent human candidate/scope decisions, and the proposed `--allow-limited-pronunciation` CLI mode are deferred because shadow results neither block nor control production.
- Phase 2 batches stage atomically in memory. Persistent staged-batch resume is deferred; cancellation or process exit recomputes shadow evidence, while existing completed audio is never re-analyzed in place.
- A model runtime, prompt schema, or candidate selection enters synthesis cache identity only in a future phase where it actually affects accepted pronunciation.
- Correction contribution/export, runtime pack downloads, Foundation Models
  adapters, production/runtime cloud inference, and neural OOV/context models
  remain out of scope. The narrowly authorized Task 10 development audio judge
  is not a runtime endpoint or production fallback.
- The audio judge cannot graduate a Phase 2 family. A “graduated-family
  regression” in Task 10 means all previously passing cases in a touched
  deterministic family plus its negative controls.

---

## Task 1: Freeze the Phase 0 Evaluation Contracts

**Files:**

- Create: `Tools/Pronunciation/pronunciation_corpus.py`
- Create: `Tools/Pronunciation/tests/test_pronunciation_corpus.py`
- Create: `EchoTests/Fixtures/Pronunciation/named_regressions_v1.jsonl`
- Create: `EchoTests/Fixtures/Pronunciation/contextual_family_candidates_v1.jsonl`
- Create only when qualifying labels are actually available:
  `EchoTests/Fixtures/Pronunciation/contextual_families_v1.jsonl`
- Create: `EchoTests/Fixtures/Pronunciation/distribution_works_v1.json`
- Create: `EchoTests/Fixtures/Pronunciation/morphology_v1.jsonl`
- Modify: `Makefile`

### 1.1 Write failing contract and qualification-validator tests

- [ ] Add standard-library `unittest` coverage for missing fields, invalid
  family/candidate pairs, unresolved dual-label disagreements, duplicate case
  IDs, private-looking paths, unbalanced senses, fewer than 200 independently
  labelled examples per family, fewer than 10 distribution works, and
  morphology entries without an expected derivation result.
- [ ] Test two separate operations:
  - contract validation accepts a well-formed `provisional` candidate with
    `labelA`, `labelB`, and `adjudicated` all absent/null, but rejects a
    provisional row that populates any human-evidence field;
  - qualification validation counts only rows marked `human-labelled` with an
    independently supplied or source-verifiable label-evidence receipt, and
    returns `WAITING_FOR_HUMAN_LABELS` rather than fabricating or failing when
    valid evidence is below a threshold.

```python
class PronunciationCorpusTests(unittest.TestCase):
    def test_contract_accepts_provisional_candidate_without_human_evidence(self):
        case = contextual_case(
            label_status="provisional",
            label_a=None,
            label_b=None,
            adjudicated=None,
        )
        validate_contract([case])

    def test_qualification_waits_for_independent_human_labels(self):
        result = qualification_status([provisional_contextual_case()])
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)

    def test_distribution_requires_ten_distinct_public_or_synthetic_works(self):
        works = [
            {"workID": f"synthetic-{index}", "provenance": "synthetic", "cases": 1}
            for index in range(9)
        ]
        with self.assertRaisesRegex(ValueError, "at least 10 works"):
            validate_distribution_works(works)
```

- [ ] Run the tests and confirm they fail because the validator does not exist.

Run:

```bash
python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_pronunciation_corpus.py'
```

Expected: import failure for `pronunciation_corpus`.

### 1.2 Implement split contract and qualification validation

- [ ] Implement dataclass-backed parsing and validation with these exact contextual fields:

```python
CONTEXTUAL_FAMILIES = {
    "content": {"content.material", "content.satisfied"},
    "read": {"read.present", "read.past"},
    "live": {"live.adjective", "live.verb", "lives.noun", "lives.verb"},
    "record": {"record.noun", "record.verb"},
}

@dataclass(frozen=True)
class ContextualCase:
    case_id: str
    family_id: str
    target_word: str
    preceding_sentence: str | None
    target_sentence: str
    following_sentence: str | None
    label_status: str
    label_a: str | None
    label_b: str | None
    adjudicated: str | None
    label_evidence_kind: str | None
    label_evidence_id: str | None
    provenance: str
```

- [ ] Accept only `labelStatus: provisional` or `human-labelled`.
  `provisional` requires null/absent `labelA`, `labelB`, `adjudicated`,
  `labelEvidenceKind`, and `labelEvidenceID`. `human-labelled` requires
  `labelA`, `labelB`, `labelEvidenceKind` of `independent-human` or
  `source-verifiable`, and a nonempty externally supplied evidence ID.
- [ ] For qualifying human-labelled rows, resolve the gold label as `labelA`
  when the two labels agree, otherwise require `adjudicated`. Reject labels
  outside the declared family candidate set. Agents may import independently
  supplied/source-verifiable evidence but may not invent or fill these fields
  to complete the task.
- [ ] Contract validation checks schema, provenance, licensing fields, private
  data, and candidate-family consistency without enforcing human-label counts.
  Qualification validation counts only qualifying `human-labelled` rows,
  requires at least 200 cases per family and at least 50 cases for each two-way
  sense, and requires at least 50 each for `live.adjective`, `live.verb`,
  `lives.noun`, and `lives.verb`.
- [ ] A well-formed but insufficient corpus yields the valid pending result
  `WAITING_FOR_HUMAN_LABELS`. It is not a pass, failure, or permission to lower
  thresholds. Independent Tasks 2–10 may continue, but corpus-dependent metrics,
  qualification, and final Phase 0–2 acceptance remain pending.
- [ ] Require ten distinct distribution work IDs. Allow only `public-domain`, `permissive`, or `synthetic` provenance and require a `sourceURL` plus license for non-synthetic work.
- [ ] Reject absolute paths, `file://` URLs, and fields named `bookTitle`, `author`, `userID`, or `localPath`.
- [ ] Give morphology rows these exact fields:

```json
{"caseID":"morph-able-001","word":"startable","expectedBase":"start","expectedRuleID":"morphology.able.exact-base","expectedIPA":"stˈɑɹtəbəl","automatic":true}
```

### 1.3 Add contract fixtures and only truthful evidence

- [ ] Add a named regression matrix containing at least these ambiguity shapes for each family: direct grammatical cue, long-distance cue within the target sentence, misleading adjacent cue, quotation/dialogue, heading fragment, malformed fragment, capitalization, punctuation adjacency, and override markup.
- [ ] Prepare synthetic or legally cleared discovery candidates in
  `contextual_family_candidates_v1.jsonl` with
  `labelStatus: "provisional"` and no human-evidence fields. These rows exercise
  the contract and may guide later independent labelling, but do not count
  toward accuracy or qualification.
- [ ] Create/populate `contextual_families_v1.jsonl` only from independently
  supplied or source-verifiable human-labelled/adjudicated rows whose sentence
  redistribution is cleared. Never have an agent or model fill `labelA`,
  `labelB`, or `adjudicated` as evidence. If fewer than 200 per family or 50 per
  represented sense are available, preserve
  `WAITING_FOR_HUMAN_LABELS`.
- [ ] Add at least ten public-domain, permissive, or synthetic work profiles to `distribution_works_v1.json`. Store only short test sentences, source/license metadata, and counts—not full copyrighted books.
- [ ] Add positive and negative `-able`/`-ible` morphology cases, including proper nouns, multiple possible bases, exception-list words, already-explicit words, and contextual-family exclusions.

Example provisional candidate row, not human evidence:

```json
{"caseID":"candidate-read-001","familyID":"read","targetWord":"read","precedingSentence":null,"targetSentence":"Yesterday, Mira read the final chapter aloud.","followingSentence":null,"labelStatus":"provisional","labelA":null,"labelB":null,"adjudicated":null,"labelEvidenceKind":null,"labelEvidenceID":null,"provenance":"synthetic"}
```

- [ ] Record these candidate-source research findings without treating them as
  accepted data:
  - Google's official archived
    `https://github.com/google-research-datasets/WikipediaHomographData`
    repository is Apache-2.0-labelled, says three annotators plus fourth-person
    disagreement adjudication, and directly includes `content` (100), `read`
    (125), `live` (98), `lives` (101), and `record` (100);
  - those counts are insufficient alone, and the Wikipedia-derived sentence
    redistribution/attribution/share-alike implications require explicit
    review before committing source sentences despite the repository label;
  - CMUdict is human-maintained pronunciation data, not contextual labels;
  - WordNet is a permissively licensed sense inventory, not the held-out
    labelled corpus;
  - Common Voice and LibriSpeech provide licensed audio/transcripts, not sense
    labels.

### 1.4 Add repeatable contract and qualification gates

- [ ] Add these Make targets:

```make
pronunciation-corpus-test:
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_pronunciation_corpus.py'
	python3 Tools/Pronunciation/pronunciation_corpus.py validate-contract \
		--fixtures EchoTests/Fixtures/Pronunciation

pronunciation-corpus-qualification:
	python3 Tools/Pronunciation/pronunciation_corpus.py qualification-status \
		--fixtures EchoTests/Fixtures/Pronunciation
```

- [ ] Run both twice and verify deterministic identical summaries.

Run:

```bash
make pronunciation-corpus-test
make pronunciation-corpus-qualification
```

Expected: contract/schema tests pass with zero validation errors. Qualification
prints either `QUALIFIED` with independently supplied/source-verifiable counts
meeting every threshold, or `WAITING_FOR_HUMAN_LABELS` with exact missing
family/sense counts. `WAITING_FOR_HUMAN_LABELS` is a truthful non-error status
for this command, not corpus acceptance; corpus-dependent qualification and
final Phase 0–2 acceptance remain pending.

### 1.5 Commit

- [ ] Commit only the Phase 0 corpus contract, truthful fixtures, provisional
  candidates, and any legally cleared independently supplied/source-verifiable
  labels actually available. Do not fabricate labels to satisfy this commit.
- [ ] If qualification is `WAITING_FOR_HUMAN_LABELS`, record that status and
  continue independent Tasks 2–10. Do not rename provisional candidates as the
  held-out corpus or claim Task 1 corpus qualification is complete.

```bash
git add Makefile Tools/Pronunciation/pronunciation_corpus.py \
  Tools/Pronunciation/tests/test_pronunciation_corpus.py \
  EchoTests/Fixtures/Pronunciation
git commit -m "test: freeze pronunciation evaluation corpora"
```

---

## Task 2: Build the Reproducible Supplemental Pronunciation Pack

**Files:**

- Create: `Tools/Pronunciation/build_pronunciation_pack.py`
- Create: `Tools/Pronunciation/cmudict.lock.json`
- Create: `Tools/Pronunciation/tests/test_build_pronunciation_pack.py`
- Create: `ThirdParty/CMUdict/LICENSE`
- Create: `ThirdParty/CMUdict/cmudict.dict`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json`
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: `Makefile`

### 2.1 Pin and license the source

- [ ] Import CMUdict from commit `74790861f652b15e4ac49015a90074ad62a27690`.
- [ ] Verify before committing:

```text
cmudict.dict SHA-256: 81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22
LICENSE SHA-256:      bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a
```

- [ ] Record those hashes, upstream URL, commit, source dialect, and license path in `Tools/Pronunciation/cmudict.lock.json`.
- [ ] Treat the lock as a receipt, not authority. Require the exact official
  upstream URL `https://github.com/cmusphinx/cmudict`, source ID `cmudict`,
  pinned commit, `en-US` dialect, repository paths, dictionary SHA-256, and
  license SHA-256 above. Reject a self-consistent lock that names any other
  bytes, URL, or paths.
- [ ] Preserve the upstream license notice in `ThirdParty/CMUdict/LICENSE`. Do not add `wordfreq` to production inputs.
- [ ] Add a CMUdict section to `THIRD_PARTY_NOTICES.md` containing its project name, upstream URL, pinned commit, copyright notice, disclaimer, and the complete redistribution terms from the pinned license.

### 2.2 Write failing generator and semantic-identity tests

- [ ] Cover ARPAbet stress conversion, alternate-pronunciation suffix
  normalization, pinned inline `#` metadata on sole and alternate
  pronunciations, stable candidate IDs, exact gold/silver exclusion, ambiguity
  suppression, Kokoro-vocabulary rejection, deterministic sorted output,
  optional coarse frequency bands, normalized-frequency-key collision
  rejection in both input orders, and pinned-input hash failure.
- [ ] Add a self-consistent malicious-lock negative and a controlled
  swapped-read regression proving CMUdict, license, gold, silver, vocabulary,
  and optional frequency bytes are each read once and that those same captured
  bytes drive verification, hashing, UTF-8 decoding, and parsing.
- [ ] Require every candidate field and status from design Section 6.2.
  Unique compatible CMUdict candidates are `validated-automatic`; ambiguous
  unlabeled variants are `report-only-missing-sense-label`, non-automatic, and
  inert until genuine human-reviewed sense labels exist.
- [ ] Require every manifest field from design Section 6.1: schema and semantic
  pack version, all source snapshot identities, generator version,
  entry/candidate counts, normalized-data SHA-256, Kokoro vocabulary version,
  dialect, licenses, required acknowledgments, and RFC 3339 UTC audit generation
  timestamp.
- [ ] Test the exact semantic-identity rules:
  - identical normalized content, source snapshots, generator behavior, and
    phoneme vocabulary produce the same `packVersion` even with different
    generation timestamps;
  - changing normalized content, any source snapshot identity, any generator
    behavior version, or the Kokoro vocabulary identity changes `packVersion`;
  - changing only `generationTimestamp`, counts/report presentation, license
    display text, or acknowledgment display text does not change
    `packVersion`;
  - entry and candidate counts and `normalizedDataSHA256` must match the
    canonical entries object;
  - reordering JSON object keys or source-input order cannot change the
    identity because source snapshots are sorted by `sourceID`.

```python
def test_ambiguous_cmudict_word_is_not_automatic(self):
    result = build_pack(
        cmu_lines=[
            "RECORD  R EH1 K ER0 D",
            "RECORD(2)  R IH0 K AO1 R D",
        ],
        gold={},
        silver={},
        kokoro_vocab=KOKORO_VOCAB,
    )
    candidates = result["entries"]["record"]
    self.assertEqual(2, len(candidates))
    self.assertTrue(all(not item["automaticWithoutContext"] for item in candidates))

def test_existing_gold_word_is_report_only(self):
    result = build_pack(
        cmu_lines=["APPLE  AE1 P AH0 L"],
        gold={"apple": {"DEFAULT": "ˈæpəl"}},
        silver={},
        kokoro_vocab=KOKORO_VOCAB,
    )
    self.assertNotIn("apple", result["entries"])
    self.assertEqual(1, result["report"]["existingGold"])
```

- [ ] Run and confirm failure because the generator does not exist.

### 2.3 Implement deterministic CMUdict conversion

- [ ] Normalize alternate forms such as `RECORD(2)` to lowercase `record`.
- [ ] Before tokenizing ARPAbet, remove only the pinned CMUdict format's inline
  metadata beginning at the first `#`. Do not pass the delimiter or metadata
  words to ARPAbet conversion.
- [ ] Accept only keys matching `[a-z]+(?:['-][a-z]+)*`.
- [ ] Convert ARPAbet using this mapping:

```python
VOWELS = {
    "AA": ("ɑ", "ɑ"), "AE": ("æ", "æ"), "AH": ("ə", "ʌ"),
    "AO": ("ɔ", "ɔ"), "AW": ("aʊ", "aʊ"), "AY": ("aɪ", "aɪ"),
    "EH": ("ɛ", "ɛ"), "ER": ("ɚ", "ɜɹ"), "EY": ("eɪ", "eɪ"),
    "IH": ("ɪ", "ɪ"), "IY": ("i", "i"), "OW": ("oʊ", "oʊ"),
    "OY": ("ɔɪ", "ɔɪ"), "UH": ("ʊ", "ʊ"), "UW": ("u", "u"),
}
CONSONANTS = {
    "B":"b","CH":"ʧ","D":"d","DH":"ð","F":"f","G":"ɡ","HH":"h",
    "JH":"ʤ","K":"k","L":"l","M":"m","N":"n","NG":"ŋ","P":"p",
    "R":"ɹ","S":"s","SH":"ʃ","T":"t","TH":"θ","V":"v","W":"w",
    "Y":"j","Z":"z","ZH":"ʒ",
}
STRESS = {"0": "", "1": "ˈ", "2": "ˌ"}
```

- [ ] Use the unstressed form for stress `0` and the stressed form for stress `1` or `2`.
- [ ] Validate every emitted scalar against `EchoCore/Services/Narration/_kokoro_vocab.json`; reject rather than partially importing an incompatible candidate.
- [ ] Import a spelling only when it is absent from both `us_gold.json` and `us_silver.json`.
- [ ] Deduplicate identical IPA variants. Set `automaticWithoutContext` to
  `true` only when exactly one compatible candidate remains and mark it
  `validated-automatic`. When multiple compatible variants remain, keep every
  candidate with `senseLabel: null`,
  `validationStatus: "report-only-missing-sense-label"`, and
  `automaticWithoutContext: false`. Do not invent lexical classes, sense
  labels, or ordinal pseudo-senses.
- [ ] Derive the candidate ID from source, normalized spelling, and IPA:

```python
candidate_id = "cmudict." + word + "." + hashlib.sha256(
    f"cmudict@{commit}\0{word}\0{ipa}".encode("utf-8")
).hexdigest()[:12]
```

- [ ] Accept an optional reviewed JSON map from normalized word to one of `veryCommon`, `common`, `uncommon`, `rare`, or `unknown`. Default to `unknown`; never use the band to select among IPA candidates. Reject duplicate raw JSON members before decoding can overwrite one, and reject any two distinct raw keys that normalize to the same spelling, even when the bands agree and regardless of object-key order.
- [ ] Canonicalize JSON for hashing with UTF-8, `ensure_ascii=False`,
  `sort_keys=True`, compact separators, source snapshots sorted by `sourceID`,
  and no trailing newline in hashed bytes. The written file adds one final
  newline.
- [ ] Hash the canonical entries object into
  `normalizedDataSHA256 = "sha256:<digest>"`. Hash the canonical normalized
  phoneme-vocabulary content into
  `kokoroVocabularyVersion = "sha256:<digest>"`.
- [ ] Treat CMUdict, `us_gold.json`, and `us_silver.json` as source snapshot
  inputs. Record each stable `sourceID`, exact `snapshotID`, and SHA-256; the
  gold/silver hashes matter because exclusion behavior depends on them even if
  the final supplemental entries remain unchanged.
- [ ] Read the pinned CMUdict and license and the supplied gold, silver,
  Kokoro-vocabulary, and optional frequency inputs exactly once into bytes.
  Verify/hash/decode/parse those captured bytes; never verify one read and
  convert or exclude from another.
- [ ] Define this exact generator behavior object. Any behavior change must bump
  the corresponding value and therefore `packVersion`:

```python
generator_behavior = {
    "generatorVersion": "echo-pronunciation-pack-generator-v2",
    "normalizationPolicyVersion": "english-key-normalization-v1",
    "arpabetMappingVersion": "cmudict-arpabet-to-kokoro-v2",
    "sourcePrecedencePolicyVersion": "gold-silver-exclusion-v1",
    "automaticSelectionPolicyVersion": "single-validated-compatible-candidate-v2",
    "candidateValidationPolicyVersion": "source-candidate-validation-v1",
}

sources = [
    {
        "sourceID": "cmudict",
        "snapshotID": "cmudict@74790861f652b15e4ac49015a90074ad62a27690",
        "role": "supplemental-candidates",
        "sha256": "sha256:81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22",
    },
    {
        "sourceID": "echo-us-gold",
        "snapshotID": gold_snapshot_id,
        "role": "exclusion-input",
        "sha256": gold_sha256,
    },
    {
        "sourceID": "echo-us-silver",
        "snapshotID": silver_snapshot_id,
        "role": "exclusion-input",
        "sha256": silver_sha256,
    },
]
```

- [ ] Emit every candidate with this exact compact field shape so its
  candidate-level state participates in `normalizedDataSHA256` and
  `packVersion`:

```python
candidate = {
    "candidateID": candidate_id,
    "ipa": ipa,
    "lexicalClass": None,
    "senseLabel": None,
    "sourceID": "cmudict",
    "sourceTier": "supplemental",
    "kind": "explicit",
    "automaticWithoutContext": is_automatic,
    "frequencyBand": frequency_band,
    "validationStatus": (
        "validated-automatic"
        if is_automatic
        else "report-only-missing-sense-label"
    ),
}
```

- [ ] Keep source and rule provenance immutable and pack-scoped. Require every
  candidate `sourceID` to resolve to exactly one top-level source record.
  Require `semanticIdentityPayload.generatorBehavior` to contain the exact
  generator, normalization, ARPAbet conversion, source-precedence,
  automatic-selection, and candidate-validation policy versions. Do not copy a
  snapshot ID or rule-provenance object into each candidate:
  `(candidateID, candidatePackVersion)` plus the validated pack manifest
  resolves both authorities.
- [ ] Build this semantic-identity payload from actual canonical inputs:

```python
semantic_identity_payload = {
    "identitySchemaVersion": 1,
    "normalizedDataSHA256": normalized_data_sha256,
    "sourceSnapshots": sorted([
        {
            "sourceID": source["sourceID"],
            "snapshotID": source["snapshotID"],
            "sha256": source["sha256"],
        }
        for source in sources
    ], key=lambda item: item["sourceID"]),
    "generatorBehavior": generator_behavior,
    "kokoroVocabularyVersion": kokoro_vocabulary_version,
    "dialect": "en-US",
}
pack_version = "sha256:" + hashlib.sha256(
    canonical_json_bytes(semantic_identity_payload)
).hexdigest()
```

The generated top-level shape must contain every field exactly as follows;
digests, counts, snapshots, and timestamp come from actual inputs:

```python
output = {
    "schemaVersion": 1,
    "packVersion": pack_version,
    "generatorVersion": generator_behavior["generatorVersion"],
    "entryCount": len(entries),
    "candidateCount": sum(len(candidates) for candidates in entries.values()),
    "normalizedDataSHA256": normalized_data_sha256,
    "kokoroVocabularyVersion": kokoro_vocabulary_version,
    "dialect": "en-US",
    "sources": sources,
    "licenses": [{
        "sourceID": "cmudict",
        "licenseID": "CMUdict-BSD-style",
        "licensePath": "ThirdParty/CMUdict/LICENSE",
    }],
    "requiredAcknowledgments": [
        "CMUdict notice bundled from THIRD_PARTY_NOTICES.md",
    ],
    "generationTimestamp": generation_timestamp_rfc3339_utc,
    "semanticIdentityPayload": semantic_identity_payload,
    "entries": entries,
    "report": {
        "existingGold": existing_gold_count,
        "existingSilver": existing_silver_count,
        "ambiguous": ambiguous_count,
        "incompatible": incompatible_count,
        "imported": imported_count,
    },
}
```

- [ ] `generationTimestamp` is audit-only and excluded from
  `semanticIdentityPayload`. When rebuilding over an existing output with the
  same `packVersion`, preserve its valid timestamp so regeneration stays
  byte-stable. When semantic identity changes or no output exists, write the
  current UTC time at whole-second RFC 3339 precision. Tests may inject
  different timestamps and must prove the resulting `packVersion` is unchanged.

### 2.4 Generate and wire the pack resource

- [ ] Generate the pack from the pinned source:

```bash
python3 Tools/Pronunciation/build_pronunciation_pack.py build \
  --lock Tools/Pronunciation/cmudict.lock.json \
  --gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
  --silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
  --vocab EchoCore/Services/Narration/_kokoro_vocab.json \
  --output EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json
```

- [ ] Add the JSON file reference to the root resources group and the `echo-cli` “Copy Narration Resources” phase in `Echo.xcodeproj/project.pbxproj`. The synchronized `EchoCore` group carries it into app targets; do not duplicate it in those resource phases.
- [ ] Add `THIRD_PARTY_NOTICES.md` to the iOS app, macOS app, and `echo-cli` resource phases so binary redistributions carry the CMUdict notice. Verify the built products contain the notice file.
- [ ] Add deterministic check targets:

```make
pronunciation-pack:
	python3 Tools/Pronunciation/build_pronunciation_pack.py build \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--output EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json

pronunciation-pack-test:
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_build_pronunciation_pack.py'
	python3 Tools/Pronunciation/build_pronunciation_pack.py check \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--expected EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json
```

- [ ] Run:

```bash
make pronunciation-pack-test
make pronunciation-pack
git diff --exit-code -- EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json
```

Expected: tests pass and regeneration produces no diff.

### 2.5 Commit

- [ ] Commit the pinned source, license, generator, generated pack, build wiring, and tests together.

```bash
git add Makefile Echo.xcodeproj/project.pbxproj Tools/Pronunciation \
  ThirdParty/CMUdict THIRD_PARTY_NOTICES.md \
  EchoCore/Services/Narration/PronunciationResources
git commit -m "feat: add reproducible pronunciation pack"
```

---

## Task 3: Load the Pack and Record Supplemental Decisions in Audit Schema v4

**Files:**

- Create: `EchoCore/Services/Narration/EnglishPronunciationPack.swift`
- Create: `EchoTests/EnglishPronunciationPackTests.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`

### 3.1 Write failing pack-loader and schema-compatibility tests

- [ ] Cover successful bundled loading through `NarrationResources`,
  exactly-one automatic lookup, ambiguous suppression, invalid schema
  rejection, duplicate candidate ID rejection, and empty fallback behavior.
- [ ] Reject a missing or malformed generator version, entry/candidate count,
  normalized-data SHA-256, Kokoro vocabulary version, source snapshot identity,
  license/required acknowledgment, semantic-identity payload, or audit
  generation timestamp.
- [ ] Recompute the canonical entries hash and semantic identity at load time.
  Reject stale `packVersion`, mismatched counts, unsorted/duplicate source IDs,
  a source projection that differs from `semanticIdentityPayload`, or a
  generator/vocabulary/content/source mutation without the corresponding new
  `packVersion`.
- [ ] Prove two otherwise identical manifests with different valid
  `generationTimestamp` values load with identical validated semantic-identity
  payloads and the same recomputed `packVersion`.
- [ ] Add a checked-in schema-v3 JSON fixture inside the test source and require it to decode with `.incompleteEvidence`.

```swift
@Test func automaticCandidateRequiresExactlyOneApprovedCandidate() throws {
    let pack = try EnglishPronunciationPack(
        data: Data(testPackJSON.utf8))

    #expect(pack.automaticCandidate(for: "example")?.candidateID
        == "cmudict.example.0123456789ab")
    #expect(pack.automaticCandidate(for: "record") == nil)
}

@Test func schemaThreeAuditDecodesAsIncompleteEvidence() throws {
    let decoded = try JSONDecoder().decode(
        PronunciationAuditManifest.self,
        from: Data(schemaThreeManifestJSON.utf8))

    #expect(decoded.schemaVersion == 3)
    #expect(decoded.coverage == .incompleteEvidence)
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/EnglishPronunciationPackTests
make test-only FILTER=EchoTests/PronunciationAuditTests
```

Expected: new tests fail before implementation.

### 3.2 Implement a strict immutable pack value

- [ ] Use a concrete, `Sendable` value with internal Codable DTOs and validated public data:

```swift
nonisolated struct EnglishPronunciationPack: Equatable, Sendable {
    struct SourceSnapshot: Codable, Equatable, Sendable {
        let sourceID: String
        let snapshotID: String
        let role: String
        let sha256: String
    }

    struct LicenseRecord: Codable, Equatable, Sendable {
        let sourceID: String
        let licenseID: String
        let licensePath: String
    }

    struct GeneratorBehavior: Codable, Equatable, Sendable {
        let generatorVersion: String
        let normalizationPolicyVersion: String
        let arpabetMappingVersion: String
        let sourcePrecedencePolicyVersion: String
        let automaticSelectionPolicyVersion: String
        let candidateValidationPolicyVersion: String
    }

    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let lexicalClass: String?
        let senseLabel: String?
        let sourceID: String
        let sourceTier: String
        let kind: String
        let automaticWithoutContext: Bool
        let frequencyBand: FrequencyBand
        let validationStatus: CandidateValidationStatus
    }

    enum FrequencyBand: String, Codable, Equatable, Sendable {
        case veryCommon, common, uncommon, rare, unknown
    }

    enum CandidateValidationStatus: String, Codable, Equatable, Sendable {
        case validatedAutomatic = "validated-automatic"
        case reportOnlyMissingSenseLabel = "report-only-missing-sense-label"
        case validatedHumanReviewed = "validated-human-reviewed"
    }

    let schemaVersion: Int
    let packVersion: String
    let generatorVersion: String
    let entryCount: Int
    let candidateCount: Int
    let normalizedDataSHA256: String
    let kokoroVocabularyVersion: String
    let generatorBehavior: GeneratorBehavior
    let dialect: String
    let sources: [SourceSnapshot]
    let licenses: [LicenseRecord]
    let requiredAcknowledgments: [String]
    let generationTimestamp: String
    private let entries: [String: [Candidate]]

    init(data: Data) throws
    static let empty: EnglishPronunciationPack
    @concurrent static func bundledOrEmpty() async -> EnglishPronunciationPack
    func automaticCandidate(for normalizedWord: String) -> Candidate?
}
```

- [ ] Decode with strict Codable DTOs and explicit required fields; do not make
  identity-bearing fields optional or use `try?` fallbacks. Require schema `1`,
  dialect `en-US`, a lowercase normalized key, unique candidate IDs, non-empty
  IPA, and a `sha256:` pack version.
- [ ] Require every candidate key in the Section 6.2 record, including the
  nullable `lexicalClass` and `senseLabel` keys; a missing nullable key is
  malformed rather than equivalent to explicit JSON null. Require every
  candidate `sourceID` to resolve to exactly one validated top-level source
  record; candidates do not decode snapshot or rule-provenance subrecords.
- [ ] Decode and validate one pack-level `GeneratorBehavior` from
  `semanticIdentityPayload.generatorBehavior`. Require every generator,
  normalization, ARPAbet conversion, source-precedence, automatic-selection,
  and candidate-validation policy version; do not use defaults for missing
  versions.
- [ ] Treat `(candidateID, packVersion)` as the complete compact candidate
  provenance reference. Only after the manifest is fully validated may that
  pair resolve the candidate's `sourceID` to its unique snapshot and the pack
  to its generator behavior; do not materialize repeated provenance inside
  `Candidate`.
- [ ] Enforce the closed validation-status invariants:
  `validated-automatic` is allowed only for the sole candidate in an entry and
  requires `automaticWithoutContext: true`;
  `report-only-missing-sense-label` requires null `senseLabel` and
  `automaticWithoutContext: false`; `validated-human-reviewed` requires a
  nonempty short sense label and remains non-automatic. Reject every other
  status/field combination.
- [ ] Require `generatorVersion`, exact entry/candidate counts, a canonical
  entries hash equal to `normalizedDataSHA256`, a `sha256:` Kokoro vocabulary
  version, unique sorted source records with snapshot IDs and hashes, license
  records and required acknowledgments for the external CMUdict source, and a
  whole-second RFC 3339 UTC `generationTimestamp`.
- [ ] Project sources to `sourceID`/`snapshotID`/`sha256`, reconstruct the exact
  Section 6.1 semantic-identity payload, require it to equal the stored
  `semanticIdentityPayload`, and recompute `packVersion`. Require the top-level
  generator version, normalized-data hash, Kokoro vocabulary version, and
  dialect to equal their payload counterparts. The timestamp, counts, licenses,
  acknowledgments, and report remain outside that hash.
- [ ] `automaticCandidate` returns a candidate only when the entry contains
  exactly one candidate and that candidate is both
  `validationStatus == .validatedAutomatic` and
  `automaticWithoutContext == true`. Report-only ambiguous candidates never
  become automatic or model-selectable merely because another candidate is
  malformed or filtered.
- [ ] `bundledOrEmpty()` uses
  `NarrationResources.url(forResource:withExtension:)`, is explicitly
  `@concurrent async`, checks a fixed 32 MiB ceiling from file metadata before
  mapping and again before decoding, and performs parsing/hashing off the
  caller actor. If the pack is absent or invalid, return a deterministic empty
  pack with version `unavailable-v1` so existing narration remains usable. Log
  only the error category, never source text.

### 3.3 Bump the audit contract to schema v4

- [ ] Add the two universal decision sources:

```swift
case supplementalLexicon
case derivedMorphology
```

- [ ] Add optional universal provenance to both `PronunciationDecisionSeed` and `PronunciationAuditDecision`:

```swift
let candidateID: String?
let candidatePackVersion: String?
let derivationBase: String?
let derivationRuleID: String?
```

- [ ] Give every new initializer parameter a default of `nil` and propagate all four fields through `materialized(selectedIPA:kokoroTokenIDs:)`, `attachingRenderTiming`, and `attachingBookTiming`.
- [ ] Set `currentSchemaVersion = 4` and accept schemas `3...4` during decoding/validation.
- [ ] Implement `init(from:)` so a schema-v3 manifest with `.complete` becomes `.incompleteEvidence`. Preserve `.incompleteLegacyCapture` as the stronger limitation.
- [ ] Continue writing only schema v4. Reject schemas below 3 or above 4.
- [ ] Add validation that supplemental decisions have `candidateID` and `candidatePackVersion`, and derived decisions additionally have `derivationBase` and `derivationRuleID`.
- [ ] Preserve supplemental provenance exactly: `candidateID` remains the
  source-derived CMUdict candidate ID and `candidatePackVersion` remains the
  loaded semantic `packVersion`; supplemental decisions do not acquire
  morphology base/rule fields.
- [ ] Require every `.derivedMorphology` decision to have nonempty
  `candidateID`, `candidatePackVersion`, `derivationBase`, and
  `derivationRuleID`; reject incomplete combinations rather than reconstructing
  them from current policy.
- [ ] Add seed → materialized audit, `attachingRenderTiming`,
  `attachingBookTiming`, and schema-v4 JSON round-trip tests proving all four
  derived fields survive unchanged. Keep the schema-v3 compatibility behavior
  unchanged.

### 3.4 Verify

- [ ] Run:

```bash
make test-only FILTER=EchoTests/EnglishPronunciationPackTests
make test-only FILTER=EchoTests/PronunciationAuditTests
```

Expected: pack validation and v3/v4 audit compatibility tests pass.

### 3.5 Commit

- [ ] Commit the loader and compatible schema foundation.

```bash
git add EchoCore/Services/Narration/EnglishPronunciationPack.swift \
  EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoTests/EnglishPronunciationPackTests.swift \
  EchoTests/PronunciationAuditTests.swift
git commit -m "feat: load pronunciation pack with audit provenance"
```

---

## Task 4: Apply Exact Supplemental Entries and Conservative Morphology

**Files:**

- Create: `EchoCore/Services/Narration/UniversalPronunciationResolver.swift`
- Create: `EchoTests/UniversalPronunciationResolverTests.swift`
- Modify: `EchoCore/Services/Narration/EnglishPronunciationPack.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`

### 4.1 Write failing resolver tests

- [ ] Prove exact candidates rewrite whole words, explicit links are preserved, override precedence wins, capitalization and punctuation are preserved, contextual-family words are excluded, proper nouns are excluded, and ambiguous candidates abstain.
- [ ] Prove morphology accepts only one validated base, supports exact-base `-able`, silent-e `-able`, and exact-base `-ible`, and rejects multiple/no bases, exception words, explicit lexicon words, and proper nouns.
- [ ] Prove every derivation emits deterministic nonempty `candidateID` and
  `candidatePackVersion` as well as `derivationBase` and `derivationRuleID`.
  Add fixed-vector tests showing identical inputs reproduce both IDs, while a
  changed rule, exception-set identity, base/derived IPA, semantic pack version,
  or Kokoro vocabulary version changes the applicable identity.
- [ ] Preserve exact supplemental behavior: pack hits keep the pack candidate's
  existing `candidateID`, use `pack.packVersion` as
  `candidatePackVersion`, and leave derivation base/rule nil.

```swift
@Test func exactSupplementalCandidateCreatesAuditableLink() {
    let supplementalPack = pack(entry: "foobar", ipa: "fˈubɑɹ")
    let result = UniversalPronunciationResolver.rewrite(
        to: "A foobar appeared.",
        blockID: "b1",
        pack: supplementalPack,
        basePronunciation: { _ in nil })

    #expect(result.text == "A [foobar](/fˈubɑɹ/) appeared.")
    #expect(result.decisionSeeds.single?.source == .supplementalLexicon)
    #expect(result.decisionSeeds.single?.candidateID == "cmudict.foobar.fixture")
    #expect(result.decisionSeeds.single?.candidatePackVersion
        == supplementalPack.packVersion)
    #expect(result.decisionSeeds.single?.derivationBase == nil)
    #expect(result.decisionSeeds.single?.derivationRuleID == nil)
}

@Test func morphologyRequiresExactlyOneValidatedBase() {
    let pack = EnglishPronunciationPack.emptyForTesting(
        packVersion: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        kokoroVocabularyVersion: "sha256:1111111111111111111111111111111111111111111111111111111111111111")
    let result = UniversalPronunciationResolver.rewrite(
        to: "The widget is startable.",
        blockID: "b1",
        pack: pack,
        basePronunciation: { word in
            word == "start" ? "stˈɑɹt" : nil
        })

    #expect(result.text == "The widget is [startable](/stˈɑɹtəbəl/).")
    let policyVersion =
        UniversalPronunciationResolver.morphologyCandidatePackVersion(for: pack)
    #expect(result.decisionSeeds.single?.candidatePackVersion == policyVersion)
    #expect(result.decisionSeeds.single?.candidateID ==
        UniversalPronunciationResolver.derivedCandidateID(
            normalizedWord: "startable",
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1",
            baseIPA: "stˈɑɹt",
            derivedIPA: "stˈɑɹtəbəl",
            candidatePackVersion: policyVersion))
    #expect(result.decisionSeeds.single?.derivationBase == "start")
    #expect(result.decisionSeeds.single?.derivationRuleID
        == "morphology.able.exact-base.v1")
}

@Test func contextualFamiliesNeverUseUniversalRewrite() {
    let result = UniversalPronunciationResolver.rewrite(
        to: "The content is live.",
        blockID: "b1",
        pack: pack(entries: ["content": "kˈɑntɛnt", "live": "lˈɪv"]),
        basePronunciation: { _ in nil })

    #expect(result.text == "The content is live.")
    #expect(result.decisionSeeds.isEmpty)
}
```

- [ ] Run and confirm failure:

```bash
make build-tests
make test-only FILTER=EchoTests/UniversalPronunciationResolverTests
```

### 4.2 Expose validated base lookup from the existing G2P owner

- [ ] Add this method to `PronunciationPlanner`, reusing its one `KokoroG2P` instance:

```swift
func validatedBaseIPA(for normalizedWord: String) -> String? {
    let result = g2p.result(for: normalizedWord)
    guard result.tokenEvidence.count == 1,
          let evidence = result.tokenEvidence.first,
          !evidence.usedFallback,
          evidence.rating >= 3,
          evidence.normalizedWord == normalizedWord,
          !evidence.selectedPhonemes.isEmpty
    else {
        return nil
    }
    return evidence.selectedPhonemes
}
```

- [ ] Keep this method internal. It is an evidence gate for derivation, not a second public G2P API.

### 4.3 Implement the pure universal rewrite

- [ ] Use a concrete namespace and closure injection:

```swift
nonisolated enum UniversalPronunciationResolver {
    static let morphologyVersion = "morphology-v1"
    static let morphologyIdentitySchemaVersion = 1
    static let suffixIPA = "əbəl"
    static let minimumBaseLength = 3
    static let properNamePolicyVersion = "proper-name-risk-v2"
    static let baseEvidencePolicyVersion = "kokoro-nonfallback-rating3-v1"
    static let contextualExclusions: Set<String> = [
        "content", "read", "live", "lives", "record", "records",
    ]

    static func morphologyCandidatePackVersion(
        for pack: EnglishPronunciationPack
    ) -> String

    static func derivedCandidateID(
        normalizedWord: String,
        derivationBase: String,
        derivationRuleID: String,
        baseIPA: String,
        derivedIPA: String,
        candidatePackVersion: String
    ) -> String

    static func rewrite(
        to text: String,
        blockID: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> PronunciationRewriteResult
}
```

- [ ] Build the morphology policy payload with canonical UTF-8 JSON using
  recursively sorted object keys, compact separators, unescaped Unicode, rule
  IDs sorted lexicographically, and the reviewed exception strings as a sorted
  JSON array:

```json
{
  "identitySchemaVersion": 1,
  "morphologyVersion": "morphology-v1",
  "ruleIDs": [
    "morphology.able.exact-base.v1",
    "morphology.able.silent-e.v1",
    "morphology.ible.exact-base.v1"
  ],
  "suffixIPA": "əbəl",
  "minimumBaseLength": 3,
  "properNamePolicyVersion": "proper-name-risk-v2",
  "baseEvidencePolicyVersion": "kokoro-nonfallback-rating3-v1",
  "exceptionSetSHA256": "sha256:<canonical-sorted-exception-set-digest>",
  "pronunciationPackVersion": "<pack.packVersion>",
  "kokoroVocabularyVersion": "<pack.kokoroVocabularyVersion>"
}
```

- [ ] Return `candidatePackVersion` as
  `morphology-v1:sha256:<64-lowercase-hex-policy-payload-digest>`.
  The audit-only pack generation timestamp is absent from the policy payload.
- [ ] Return `candidateID` as
  `morphology.<normalizedWord>.<first-12-hex>`. Hash the exact UTF-8 sequence
  `candidatePackVersion + NUL + normalizedWord + NUL + derivationBase + NUL +
  derivationRuleID + NUL + baseIPA + NUL + derivedIPA`; use the first 12
  lowercase hex characters. Validate the normalized word and all input fields
  before hashing.

- [ ] Reuse the repository's existing word-range and Misaki-link parsing conventions. Never rewrite inside `[word](/ipa/)`.
- [ ] Treat a capitalized token away from sentence start, all-capital tokens longer than one character, and apostrophe possessives as proper-name risk; abstain.
- [ ] Apply an exact pack candidate first only through
  `pack.automaticCandidate(for:)`: the entry must contain exactly one
  candidate, its status must be `validated-automatic`, and
  `automaticWithoutContext` must be true. Never rewrite from
  `report-only-missing-sense-label` or choose among ambiguous candidates by
  source order, frequency, or IPA.
- [ ] Record the selected candidate's source-derived `candidateID` together
  with `pack.packVersion` as `candidatePackVersion`. That pair plus the
  validated pack manifest resolves the candidate's unique source snapshot and
  the pack-scoped generator-rule provenance; do not copy those records into
  the decision seed.
- [ ] Attempt these morphology transformations in order and accept only when exactly one produces a validated base:

```swift
enum DerivationRule: String, CaseIterable {
    case ableExactBase = "morphology.able.exact-base.v1"
    case ableSilentE = "morphology.able.silent-e.v1"
    case ibleExactBase = "morphology.ible.exact-base.v1"
}
```

```text
word ending "able" → remove "able"
word ending "able" → remove "able", append "e"
word ending "ible" → remove "ible"
```

- [ ] Require a base length of at least three letters. Do not implement `y`/`i`, doubled-consonant, prefix-stripping, or compound heuristics in v1.
- [ ] Maintain a reviewed exception set containing at minimum the contextual exclusions. Before deriving, call `basePronunciation` on the whole word and abstain when gold/silver already knows it; also abstain when the supplemental pack contains any explicit candidate for the whole word.
- [ ] Append `əbəl` to the validated base IPA. Let the existing `PronunciationPlanner` perform final Kokoro-vocabulary validation.
- [ ] Emit one seed with source `.supplementalLexicon` for pack hits and
  `.derivedMorphology` for derivations. Pack hits retain their exact existing
  pack candidate ID and `pack.packVersion`. Derivations include the
  deterministic morphology `candidateID`, morphology
  `candidatePackVersion`, base, and rule; all four are mandatory.

### 4.4 Integrate at the correct precedence seam

- [ ] In `NarrationRenderPlanner.make(preparedBlocks:overrides:pronunciationPack:maxChars:maxPhonemes:)`, use the existing single `PronunciationPlanner` for both base validation and final chunk planning.
- [ ] For each non-code normalized block, apply:

```swift
let overrideResult = overrides.rewrite(to: normalized, blockID: block.id)
let universalResult = UniversalPronunciationResolver.rewrite(
    to: overrideResult.text,
    blockID: block.id,
    pack: pronunciationPack,
    basePronunciation: pronunciationPlanner.validatedBaseIPA(for:))
let homographResult = HomographPronunciationResolver.rewrite(
    to: universalResult.text,
    blockID: block.id)
```

- [ ] Combine decision seeds in precedence order and continue using the existing first-seed-per-span deduplication.
- [ ] Add `pronunciationPack: EnglishPronunciationPack = .empty` to both `NarrationRenderPlanner.make` overloads so low-level callers remain deterministic.
- [ ] Store one injected `EnglishPronunciationPack` in `NarrationService` and
  pass the same immutable value to every plan in that service. Keep the
  initializer default `.empty` for deterministic low-level/test callers.
  Production composition must first
  `await EnglishPronunciationPack.bundledOrEmpty()` and then inject the
  validated value; loading/parsing must never occur synchronously in a
  MainActor initializer.
- [ ] In `HeadlessNarrationRunner`, await and snapshot one pack at run start,
  then pass it to every chapter render; never allow a run to observe two pack
  versions.

### 4.5 Put production-affecting policy in cache identity

- [ ] Add this computed signature:

```swift
extension EnglishPronunciationPack {
    static let contentDefaultPolicyVersion =
        "content-default-legacy-adjective-v1"

    var productionPolicySignature: String {
        [
            packVersion,
            UniversalPronunciationResolver
                .morphologyCandidatePackVersion(for: self),
            Self.contentDefaultPolicyVersion,
        ].joined(separator: "|")
    }
}
```

- [ ] Add a required `pronunciationPolicySignature` argument to `NarrationFileNaming.contentSignature(spokenBlocks:renderedTexts:includeLeadOutPad:normalizationMode:pronunciationPolicySignature:)` and include it in the hash input.
- [ ] Update every call site to use the run's snapshotted pack signature.
- [ ] Increment `NarrationFileNaming.renderVersion` from `15` to `16` because the production pronunciation front end changes.
- [ ] Add tests proving that changed normalized entries, source snapshot,
  generator behavior, Kokoro vocabulary, morphology rule/exception, or
  base-evidence policy changes the content signature even when rendered text is
  otherwise identical. Prove a changed audit-only `generationTimestamp` does
  not change `packVersion`, morphology policy identity, or content signature.
- [ ] Add a frozen retry-slice test proving `candidateID`,
  `candidatePackVersion`, `derivationBase`, and `derivationRuleID` copy
  byte-for-byte with the selected IPA and cannot be recalculated from the
  current resolver.
- [ ] Do not include contextual shadow evidence, FM availability, model identifier, or model output in the signature.

### 4.6 Verify

- [ ] Run:

```bash
make test-only FILTER=EchoTests/UniversalPronunciationResolverTests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
make test-only FILTER=EchoTests/NarrationServiceTests
make echo-cli
```

Expected: exact and conservative-derived words create stable links/audit seeds; overrides and contextual homographs retain precedence; CLI contains the bundled pack.

### 4.7 Commit

- [ ] Commit the production universal layer and cache invalidation together.

```bash
git add EchoCore/Services/Narration/UniversalPronunciationResolver.swift \
  EchoCore/Services/Narration/EnglishPronunciationPack.swift \
  EchoCore/Services/Narration/PronunciationPlanner.swift \
  EchoCore/Services/Narration/NarrationRenderPlan.swift \
  EchoCore/Services/Narration/NarrationFileNaming.swift \
  EchoCore/Services/Narration/NarrationService.swift \
  EchoCore/Services/Narration/HeadlessNarrationRunner.swift \
  EchoTests/UniversalPronunciationResolverTests.swift \
  EchoTests/NarrationRenderPlanTests.swift \
  EchoTests/NarrationFileNamingTests.swift \
  EchoTests/NarrationServiceTests.swift
git commit -m "feat: apply universal pronunciation resolution"
```

---

## Task 5: Make Context-Free `content` Default to the Noun

**Files:**

- Modify: `EchoCore/Services/Narration/MisakiResources/us_gold.json`
- Modify: `EchoCore/Services/Narration/EnglishPronunciationPack.swift`
- Modify: `EchoTests/KokoroG2PTests.swift`
- Modify: `EchoTests/HomographPronunciationResolverTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`

### 5.1 Write failing regressions

- [ ] Add a G2P test requiring bare, context-free `content` to use the noun pronunciation.
- [ ] Preserve tests that a satisfied/adjectival sentence uses the adjective and content/material sentences use the noun through deterministic homograph rules.
- [ ] Add a fragment/heading regression proving the noun is the safe fallback when no rule fires.
- [ ] Add a cache-signature regression proving Task 4's
  `content-default-legacy-adjective-v1` identity cannot share a chapter or
  headless capture identity with Task 5's
  `content-default-material-noun-v1` identity.

```swift
@Test func contentDefaultsToMaterialNounWithoutContext() throws {
    let g2p = try KokoroG2P()
    let result = g2p.result(for: "Content")

    #expect(result.phonemes == "kˈɑntɛnt")
}

@Test func contentAdjectiveRuleStillWins() {
    let result = HomographPronunciationResolver.rewrite(
        to: "She was content with the result.",
        blockID: "b1")

    #expect(result.text.contains("[content](/kəntˈɛnt/)"))
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/KokoroG2PTests
make test-only FILTER=EchoTests/HomographPronunciationResolverTests
```

Expected: the bare-word test fails before the lexicon edit.

### 5.2 Change only the lexicon default

- [ ] Change the `content` record to:

```json
"content":{"ADJ":"kəntˈɛnt","DEFAULT":"kˈɑntɛnt","NOUN":"kˈɑntɛnt"}
```

- [ ] Do not alter `HomographPronunciationResolver` candidate IPA or production rule logic.
- [ ] In the same commit, change
  `EnglishPronunciationPack.contentDefaultPolicyVersion` from
  `content-default-legacy-adjective-v1` to
  `content-default-material-noun-v1`. This cache-identity change is atomic with
  the lexicon default; do not allow old adjective-default audio or headless
  captures to resume under the noun-default behavior.
- [ ] Regenerate the supplemental pack and verify it remains byte-identical because existing gold entries are excluded.

Run:

```bash
make pronunciation-pack-test
make test-only FILTER=EchoTests/KokoroG2PTests
make test-only FILTER=EchoTests/HomographPronunciationResolverTests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
```

### 5.3 Commit

- [ ] Commit the isolated fallback correction.

```bash
git add EchoCore/Services/Narration/MisakiResources/us_gold.json \
  EchoCore/Services/Narration/EnglishPronunciationPack.swift \
  EchoTests/KokoroG2PTests.swift \
  EchoTests/HomographPronunciationResolverTests.swift \
  EchoTests/NarrationRenderPlanTests.swift \
  EchoTests/NarrationFileNamingTests.swift
git commit -m "fix: default content to material noun"
```

---

## Task 6: Define Stable Contextual Families and Discover Occurrences

**Files:**

- Create: `EchoCore/Services/Narration/ContextualPronunciationTypes.swift`
- Create: `EchoCore/Services/Narration/ContextualPronunciationFamilies.swift`
- Create: `EchoCore/Services/Narration/ContextualPronunciationDiscovery.swift`
- Create: `EchoTests/ContextualPronunciationFamiliesTests.swift`
- Create: `EchoTests/ContextualPronunciationDiscoveryTests.swift`
- Modify: `EchoCore/Services/Narration/HomographPronunciationResolver.swift`
- Modify: `EchoTests/HomographPronunciationResolverTests.swift`

### 6.1 Write failing candidate and discovery tests

- [ ] Prove stable candidate IDs/IPA, a maximum of four candidates, deterministic ordering, sentence-window limits, canonical markup-free word spans, link/override exclusion, punctuation behavior, and independent deterministic analysis.

```swift
@Test func readCandidatesHaveStableSlotsAndNoModelGeneratedIPA() {
    let family = ContextualPronunciationFamilies.family(for: "read")

    #expect(family?.candidates.map(\.candidateID)
        == ["read.present", "read.past"])
    #expect(family?.candidates.map(\.slot) == [.a, .b])
}

@Test func discoveryUsesOnlyOneAdjacentSentencePerSide() {
    let occurrences = ContextualPronunciationDiscovery.discover(
        text: "First. Before. Yesterday I read it. After. Last.",
        blockID: "b1")

    let item = try #require(occurrences.single)
    #expect(item.precedingSentence == "Before.")
    #expect(item.targetSentence == "Yesterday I read it.")
    #expect(item.followingSentence == "After.")
}

@Test func linkedOverrideIsNotRediscovered() {
    let occurrences = ContextualPronunciationDiscovery.discover(
        text: "I [read](/ɹˈɛd/) it.",
        blockID: "b1")

    #expect(occurrences.isEmpty)
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ContextualPronunciationFamiliesTests
make test-only FILTER=EchoTests/ContextualPronunciationDiscoveryTests
```

### 6.2 Define the pure shared types

- [ ] Add:

```swift
nonisolated enum ContextualCandidateSlot: String, Codable, Sendable {
    case a, b, c, d, needsReview
}

nonisolated enum ContextualFamilyState: String, Codable, Sendable {
    case disabled, shadow, graduated
}

nonisolated enum DeterministicRuleStrength: String, Codable, Sendable {
    case definitive, advisory, abstained
}

nonisolated struct ContextualPronunciationCandidate: Codable, Equatable, Sendable {
    let slot: ContextualCandidateSlot
    let candidateID: String
    let ipa: String
    let senseLabel: String
    let lexicalRole: String
}

nonisolated struct ContextualPronunciationOccurrence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let targetWord: String
    let precedingSentence: String?
    let targetSentence: String
    let followingSentence: String?
    let familyID: String
    let candidates: [ContextualPronunciationCandidate]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
}
```

- [ ] Define the model outcome/failure enums now so preflight and provider share one vocabulary:

```swift
nonisolated enum ContextualModelAvailability: String, Codable, Sendable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

nonisolated enum ContextualModelFailure: String, Codable, Sendable {
    case contextTooLarge
    case guardrail
    case refusal
    case unsupportedLanguageOrLocale
    case timeout
    case rateLimited
    case assetsUnavailable
    case concurrentRequest
    case parsing
    case invalidBatch
    case cancelled
    case unknown
}
```

### 6.3 Hard-code the first four candidate families

- [ ] Set `candidatePackVersion = "context-candidates-v1"` and `promptSchemaVersion = "context-shadow-v1"`.
- [ ] Use this exact candidate order:

```text
content.material   kˈɑntɛnt   noun, material/information
content.satisfied  kəntˈɛnt   adjective, satisfied
read.present       ɹˈid       present/base verb
read.past          ɹˈɛd       past/participle verb
live.adjective     lˈIv       adjective, not recorded
live.verb          lˈɪv       verb, reside/remain alive
lives.noun         lˈIvz      plural noun, existences
lives.verb         lˈɪvz      third-person verb
record.noun        ɹˈɛkəɹd    noun/adjective
record.verb        ɹəkˈɔɹd    verb
```

- [ ] Assign `.a`, `.b`, `.c`, `.d` in the displayed order within each spelling-specific candidate list. Never expose IPA as an output field the model may fill.
- [ ] Mark all four families `.shadow`.

### 6.4 Implement discovery and independent deterministic analysis

- [ ] Use `NLTokenizer(unit: .sentence)` only for sentence boundaries. Use the repository's existing word-range conventions for target spans and Misaki links.
- [ ] Calculate `wordStart`/`wordEnd` as the same inclusive, zero-based word indexes used by `PronunciationDecisionSeed` and `PronunciationAuditContext.wordSpan`. Resolve indexes against `MisakiPronunciationMarkup.displayText(from:)` so earlier authored links do not shift later occurrences.
- [ ] Produce stable occurrence IDs as SHA-256 over:

```text
context-shadow-v1\0<blockID>\0<wordStart>\0<wordEnd>\0<normalizedWord>
```

- [ ] Exclude existing pronunciation links, code-block cue text, hidden blocks, proper-name-risk tokens, and tokens outside the four families.
- [ ] Analyze deterministic evidence through a new read-only method on `HomographPronunciationResolver` or a shared internal rule result. The analysis method must not consume model output and must return candidate ID, rule ID, and strength without rewriting.
- [ ] Map an exact satisfied deterministic rule to `.definitive`, heuristic evidence to `.advisory`, and no rule to `.abstained`.
- [ ] Do not weaken or alter current production homograph behavior while exposing analysis.

### 6.5 Verify and commit

- [ ] Run:

```bash
make test-only FILTER=EchoTests/ContextualPronunciationFamiliesTests
make test-only FILTER=EchoTests/ContextualPronunciationDiscoveryTests
make test-only FILTER=EchoTests/HomographPronunciationResolverTests
```

- [ ] Commit:

```bash
git add EchoCore/Services/Narration/ContextualPronunciationTypes.swift \
  EchoCore/Services/Narration/ContextualPronunciationFamilies.swift \
  EchoCore/Services/Narration/ContextualPronunciationDiscovery.swift \
  EchoCore/Services/Narration/HomographPronunciationResolver.swift \
  EchoTests/ContextualPronunciationFamiliesTests.swift \
  EchoTests/ContextualPronunciationDiscoveryTests.swift \
  EchoTests/HomographPronunciationResolverTests.swift
git commit -m "feat: discover contextual pronunciation families"
```

---

## Task 7: Implement the Model-Independent Shadow Preflight Engine

**Files:**

- Create: `EchoCore/Services/Narration/ContextualPronunciationPreflight.swift`
- Create: `EchoTests/ContextualPronunciationPreflightTests.swift`
- Modify: `EchoCore/Services/Narration/ContextualPronunciationTypes.swift`

### 7.1 Write failing batching, validation, fallback, and cancellation tests

- [ ] Test batches of at most eight, conservative character-budget splitting, serial calls, complete ID validation, candidate-slot validation, no partial salvage, context-too-large halving, one transient retry, no guardrail retry, unavailable evidence, and cancellation propagation.

```swift
@Test func invalidBatchRejectsEverySelectionAtomically() async throws {
    let occurrences = fixtures(count: 2)
    let evaluator: ContextualPronunciationBatchEvaluator = { request in
        ContextualPronunciationBatchResult(
            availability: .available,
            selections: [
                .init(occurrenceID: request.occurrences[0].occurrenceID, slot: .a),
                .init(occurrenceID: "unknown", slot: .b),
            ],
            failure: nil,
            runtime: .fixture)
    }

    let evidence = try await ContextualPronunciationPreflight.run(
        occurrences: occurrences,
        evaluator: evaluator,
        environment: .fixture)

    #expect(evidence.count == 2)
    #expect(evidence.allSatisfy { $0.modelCandidateID == nil })
    #expect(evidence.allSatisfy { $0.modelFailure == .invalidBatch })
}

@Test func cancellationNeverBecomesFallbackEvidence() async {
    let evaluator: ContextualPronunciationBatchEvaluator = { _ in
        throw CancellationError()
    }

    await #expect(throws: CancellationError.self) {
        try await ContextualPronunciationPreflight.run(
            occurrences: fixtures(count: 1),
            evaluator: evaluator,
            environment: .fixture)
    }
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ContextualPronunciationPreflightTests
```

Expected: compile failure before the preflight types exist.

### 7.2 Finish the request/result/evidence contracts

- [ ] Add:

```swift
nonisolated struct ContextualPronunciationBatchRequest: Equatable, Sendable {
    let occurrences: [ContextualPronunciationOccurrence]
}

nonisolated struct ContextualModelSelection: Equatable, Sendable {
    let occurrenceID: String
    let slot: ContextualCandidateSlot
}

nonisolated struct ContextualModelRuntime: Codable, Equatable, Sendable {
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
}

nonisolated struct ContextualPronunciationBatchResult: Equatable, Sendable {
    let availability: ContextualModelAvailability
    let selections: [ContextualModelSelection]
    let failure: ContextualModelFailure?
    let runtime: ContextualModelRuntime
}

nonisolated typealias ContextualPronunciationBatchEvaluator =
    @Sendable (ContextualPronunciationBatchRequest) async throws
        -> ContextualPronunciationBatchResult
```

- [ ] Add this audit-ready envelope:

```swift
nonisolated struct ContextualPronunciationEvidence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let familyID: String
    let candidatePackVersion: String
    let submittedCandidateIDs: [String]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
    let modelCandidateID: String?
    let modelAbstained: Bool
    let modelAvailability: ContextualModelAvailability
    let modelFailure: ContextualModelFailure?
    let familyState: ContextualFamilyState
    let acceptanceReason: ContextualAcceptanceReason
    let promptSchemaVersion: String
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
    let humanCandidateID: String?
    let humanCorrectionScope: String?
    let isLimited: Bool
}

nonisolated enum ContextualAcceptanceReason: String, Codable, Sendable {
    case shadowObserved
    case shadowNeedsReview
    case shadowModelUnavailable
    case shadowModelFailure
}
```

- [ ] In Phase 2, `humanCandidateID` and `humanCorrectionScope` are always `nil`, `isLimited` is always `false`, and `familyState` is always `.shadow`.

### 7.3 Implement deterministic batch planning

- [ ] Configure:

```swift
nonisolated struct ContextualPronunciationPreflightConfiguration: Sendable {
    let maximumBatchCount: Int
    let maximumPromptCharacters: Int

    static let phaseTwo = Self(
        maximumBatchCount: 8,
        maximumPromptCharacters: 8_000)
}
```

- [ ] Estimate prompt size from exactly the fields the provider receives: occurrence ID, spelling, three-sentence window, candidate slot, meaning, and lexical role. The 8,000-character ceiling reserves room within the current documented 4,096-token session limit for instructions, guided-output schema, and response; it is not treated as a token-capability API.
- [ ] Preserve source order and split before either limit. Oversized single occurrences remain single so the provider can return `.contextTooLarge`.
- [ ] Invoke batches serially; never use a task group.

### 7.4 Validate results transactionally and implement bounded retries

- [ ] Accept a batch only when:
  - every submitted occurrence ID appears exactly once;
  - no unknown or duplicate ID appears;
  - every selected slot exists for that occurrence or is `.needsReview`;
  - `.needsReview` sets `modelAbstained = true`;
  - availability and failure fields are internally consistent.
- [ ] On validation failure, discard all selections in that batch. Retry once with half-size batches; if already one occurrence, emit `.invalidBatch` evidence.
- [ ] On `.contextTooLarge`, halve the batch down to one occurrence. If one still fails, emit failure evidence.
- [ ] On `.timeout`, `.rateLimited`, or `.assetsUnavailable`, retry once with a fresh provider call.
- [ ] On `.guardrail`, `.refusal`, or `.unsupportedLanguageOrLocale`, do not retry the same occurrence.
- [ ] On `.concurrentRequest`, `.parsing`, or `.unknown`, retry once smaller, then emit failure evidence.
- [ ] Check cancellation before every batch and retry. Rethrow `CancellationError` immediately.
- [ ] Build the entire batch's envelopes in a local array and append only after validation completes.
- [ ] Do not log prompts, source sentences, model selections, or raw errors.

### 7.5 Verify and commit

- [ ] Run:

```bash
make test-only FILTER=EchoTests/ContextualPronunciationPreflightTests
```

- [ ] Commit:

```bash
git add EchoCore/Services/Narration/ContextualPronunciationTypes.swift \
  EchoCore/Services/Narration/ContextualPronunciationPreflight.swift \
  EchoTests/ContextualPronunciationPreflightTests.swift
git commit -m "feat: add transactional pronunciation shadow preflight"
```

---

## Task 8: Add the Gated Foundation Models Candidate Selector

**Files:**

- Create: `EchoCore/Services/Narration/FoundationModelsContextualPronunciationEvaluator.swift`
- Create: `EchoTests/FoundationModelsContextualPronunciationEvaluatorTests.swift`

### 8.1 Write provider-boundary tests before importing the framework

- [ ] Test the pure prompt formatter and response validator on every deployment target. Require that prompts contain occurrence ID, spelling, bounded sentences, slots, meanings, and lexical roles; forbid IPA, deterministic candidate/rule, frequency, override data, title, author, and paths.
- [ ] Add compile-time availability tests following `StudyDeckFMAvailability` so iOS 18/macOS 15 returns `.unsupportedOS` without touching Foundation Models.

```swift
@Test func promptOmitsPronunciationAndDeterministicAnswers() {
    let prompt = FoundationModelsContextualPronunciationEvaluator.prompt(
        for: .fixture)

    #expect(prompt.contains("Occurrence: occ-1"))
    #expect(prompt.contains("A: present/base verb"))
    #expect(!prompt.contains("ɹˈid"))
    #expect(!prompt.contains("deterministic"))
    #expect(!prompt.contains("ruleID"))
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/FoundationModelsContextualPronunciationEvaluatorTests
```

### 8.2 Implement fixed-choice structured output

- [ ] Import Foundation Models only under:

```swift
#if canImport(FoundationModels) && (os(iOS) || os(macOS))
import FoundationModels
#endif
```

- [ ] Gate all model symbols with `@available(iOS 26, macOS 26, *)`.
- [ ] Use fixed generated types:

```swift
@available(iOS 26, macOS 26, *)
@Generable
private struct FMContextualBatch {
    @Guide(.maximumCount(8))
    let decisions: [FMContextualDecision]
}

@available(iOS 26, macOS 26, *)
@Generable
private struct FMContextualDecision {
    let occurrenceID: String
    let selection: FMContextualCandidateSlot
}

@available(iOS 26, macOS 26, *)
@frozen
@Generable
private enum FMContextualCandidateSlot {
    case a, b, c, d, needsReview
}
```

- [ ] Keep static instructions separate from the book-derived prompt:

```text
Classify each target spelling by meaning and grammatical role.
Return exactly one supplied candidate slot for every occurrence.
Use needsReview when the supplied context does not determine a choice.
Do not infer or return pronunciation, rewritten text, rationale, or confidence.
```

- [ ] Format only the approved fields. Do not mention IPA or what the deterministic engine selected.
- [ ] Create a fresh `LanguageModelSession(instructions:)` for every batch and call:

```swift
try await session.respond(
    to: prompt,
    generating: FMContextualBatch.self,
    options: GenerationOptions(sampling: .greedy))
```

### 8.3 Map availability and SDK errors to Echo's stable categories

- [ ] Recheck `SystemLanguageModel.default.availability` before every session and map:

```text
.available                                      → .available
.unavailable(.deviceNotEligible)                → .deviceNotEligible
.unavailable(.appleIntelligenceNotEnabled)      → .appleIntelligenceNotEnabled
.unavailable(.modelNotReady)                    → .modelNotReady
@unknown default                                → .unknown
```

- [ ] Map the iOS 26/macOS 26 `LanguageModelSession.GenerationError` cases:

```text
exceededContextWindowSize   → .contextTooLarge
assetsUnavailable           → .assetsUnavailable
guardrailViolation          → .guardrail
unsupportedLanguageOrLocale → .unsupportedLanguageOrLocale
decodingFailure             → .parsing
rateLimited                 → .rateLimited
concurrentRequests          → .concurrentRequest
refusal                     → .refusal
```

- [ ] Preserve an `@unknown default → .unknown` branch. Map a cancellation to `CancellationError` before classifying any SDK error.
- [ ] If the SDK exposes a dedicated timeout or structured-output parsing error on the active Xcode toolchain, map it to `.timeout` or `.parsing` respectively. Keep those SDK-specific references inside their own availability gate.
- [ ] The current SDK documents the session limit but does not expose a public per-runtime capacity property. If the source-verified SDK used during implementation adds one, feed that value into batch sizing; otherwise retain the conservative character ceiling plus typed `.contextTooLarge` splitting. Do not inspect private framework state.
- [ ] Do not use a broad catch as the complete policy. A final broad catch may map an otherwise unknown SDK error to `.unknown` after cancellation and all known typed errors have been handled.
- [ ] Build `ContextualModelRuntime` from platform name, `ProcessInfo.processInfo.operatingSystemVersionString` plus OS build, and a non-user-specific system model/runtime family identifier. If Apple exposes no stable model identifier, use `foundation-models-system-v1`; do not inspect private frameworks.

### 8.4 Expose one concrete closure factory

- [ ] Expose:

```swift
nonisolated enum FoundationModelsContextualPronunciationEvaluator {
    static func makeBatchEvaluator() -> ContextualPronunciationBatchEvaluator
    static func prompt(for request: ContextualPronunciationBatchRequest) -> String
}
```

- [ ] The closure returns `.unsupportedOS` on iOS 18–25/macOS 15–25 and on non-iOS/macOS builds. It never falls back to a cloud model.
- [ ] Validate the generated decisions again at the pure preflight layer; the provider must not be the trust boundary.

### 8.5 Verify and commit

- [ ] Run:

```bash
make test-only FILTER=EchoTests/FoundationModelsContextualPronunciationEvaluatorTests
make test-only FILTER=EchoTests/ContextualPronunciationPreflightTests
```

- [ ] Build both an eligible and fallback destination through the repository's normal Xcode workflow. Do not claim runtime availability from compilation alone.
- [ ] Commit:

```bash
git add EchoCore/Services/Narration/FoundationModelsContextualPronunciationEvaluator.swift \
  EchoTests/FoundationModelsContextualPronunciationEvaluatorTests.swift
git commit -m "feat: classify pronunciation context on device"
```

---

## Task 9: Integrate Shadow Evidence Without Affecting Narration

**Files:**

- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/ContextualPronunciationTypes.swift`
- Modify: `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`
- Modify: `EchoTests/PronunciationListeningReelTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`

### 9.1 Write failing end-to-end shadow invariance tests

- [ ] Construct one deterministic block set and render plans with evaluators that select A, B, `needsReview`, unavailable, and failure.
- [ ] Require identical block text, chunk boundaries, IPA, Kokoro token IDs, file name, and content signature across all five runs.
- [ ] Require contextual evidence to differ appropriately and exist for every discovered contextual occurrence.

```swift
@Test func shadowSelectionCannotChangePlannedPronunciation() async throws {
    let selectsA = try await service(evaluator: .selecting(.a))
        .renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
    let selectsB = try await service(evaluator: .selecting(.b))
        .renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)

    #expect(selectsA.blocks.map(\.synthesisChunks) == selectsB.blocks.map(\.synthesisChunks))
    #expect(selectsA.blocks.map(\.pronunciationDecisions).map(strippingContextEvidence)
        == selectsB.blocks.map(\.pronunciationDecisions).map(strippingContextEvidence))
    #expect(selectsA.blocks.flatMap(\.pronunciationDecisions)
        .compactMap(\.contextualEvidence) !=
        selectsB.blocks.flatMap(\.pronunciationDecisions)
        .compactMap(\.contextualEvidence))
}
```

- [ ] Add tests that an occurrence/book/global override prevents discovery, an invalid source span stops the plan, unavailable model evidence does not mark the audit incomplete, missing evidence for an evaluated current-schema occurrence does mark it incomplete, and cancellation prevents `NarrationRenderPlanner.make`.

### 9.2 Inject one batch-evaluator closure into `NarrationService`

- [ ] Add stored values:

```swift
private let pronunciationPack: EnglishPronunciationPack
private let contextualPronunciationEvaluator: ContextualPronunciationBatchEvaluator
```

- [ ] Add initializer defaults:

```swift
pronunciationPack: EnglishPronunciationPack = .empty,
contextualPronunciationEvaluator: @escaping ContextualPronunciationBatchEvaluator =
    FoundationModelsContextualPronunciationEvaluator.makeBatchEvaluator()
```

- [ ] Production composition awaits
  `EnglishPronunciationPack.bundledOrEmpty()` off the caller actor and injects
  the resulting immutable value. Preserve the existing `fmEnabled` preference
  for FM text normalization. Contextual shadowing has its own program state and
  runs whenever one of the four families is discovered; do not silently couple
  it to the QA classifier preference.

### 9.3 Run discovery after overrides and before synthesis

- [ ] In `renderPlan(for:overrides:occurrenceOverrides:fmEnabled:)`, after text normalization and occurrence overrides:
  1. Call `overrides.rewrite(to:blockID:)` on a discovery-only copy so book/global/built-in overrides are already linked and excluded.
  2. Discover contextual occurrences and deterministic evidence from that copy.
  3. Run `ContextualPronunciationPreflight` with the injected evaluator.
  4. Key returned envelopes by `(blockID, wordStart, wordEnd)`.
  5. Call the existing production `NarrationRenderPlanner.make` with the original prepared blocks, overrides, pack, and evidence map.
- [ ] Keep production rewriting inside `NarrationRenderPlanner`; discovery-only override rewriting must never become the synthesis input.
- [ ] Rethrow cancellation before plan construction.
- [ ] Do not run discovery for code cues, hidden blocks, or empty text.

### 9.4 Attach evidence by exact source identity

- [ ] Add:

```swift
nonisolated struct ContextualPronunciationKey: Hashable, Sendable {
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
}
```

- [ ] Add `contextualEvidence: [ContextualPronunciationKey: ContextualPronunciationEvidence] = [:]` to the planner overloads.
- [ ] Add `contextualEvidence: ContextualPronunciationEvidence? = nil` to `PronunciationDecisionSeed` and `PronunciationAuditDecision`, then propagate it through materialization and both timing-copy methods.
- [ ] When materializing decision seeds, attach evidence only on an exact block/range match and only when normalized spelling belongs to the same family.
- [ ] Treat a mismatched range, candidate family, or submitted candidate pack as a plan-integrity error; do not attach evidence to a nearby token.
- [ ] Add an audit diagnostic reason `.missingContextualEvidence`.
- [ ] A current-schema contextual decision with a family configured `.shadow` but no envelope yields `.incompleteEvidence`. Model unavailable/failure is complete evidence when its categorized envelope is present.
- [ ] Continue omitting raw prompt, raw output, and three-sentence window from the audit. Existing bounded `sourceContext` remains unchanged.

### 9.5 Apply the approved bounded listening-reel priority

- [ ] Keep the existing maximum of 16 and the existing pronunciation-specific uniqueness key.
- [ ] Rank decisions in this order:
  1. limited fallback;
  2. human-reviewed disagreement;
  3. model-only selection or an unreviewed Phase 2 shadow disagreement;
  4. deterministic/model agreement;
  5. monitored lexicon or derived morphology;
  6. existing watched decisions.
- [ ] Treat Phase 2 rank-3 evidence as a listening priority only; it does not become an accepted model-controlled decision.
- [ ] Add tests that high-risk contextual items displace lower-priority repeats while the reel remains bounded and pronunciation-specific.

### 9.6 Prove cache and retry invariants

- [ ] Add a content-signature test proving different contextual evidence gives the same signature.
- [ ] Add a render-plan test proving frozen retry slicing copies contextual evidence but cannot recalculate or replace the selected IPA.
- [ ] Confirm existing audio is not re-analyzed in place: only a newly requested plan/render runs shadow preflight.

### 9.7 Verify and commit

- [ ] Run:

```bash
make test-only FILTER=EchoTests/ContextualPronunciationPreflightTests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationServiceTests
make test-only FILTER=EchoTests/PronunciationAuditTests
make test-only FILTER=EchoTests/PronunciationListeningReelTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
```

- [ ] Commit:

```bash
git add EchoCore/Services/Narration/NarrationService.swift \
  EchoCore/Services/Narration/NarrationRenderPlan.swift \
  EchoCore/Services/Narration/PronunciationAudit.swift \
  EchoCore/Services/Narration/ContextualPronunciationTypes.swift \
  EchoCore/Services/Narration/PronunciationListeningReel.swift \
  EchoTests/NarrationServiceTests.swift \
  EchoTests/NarrationRenderPlanTests.swift \
  EchoTests/PronunciationAuditTests.swift \
  EchoTests/PronunciationListeningReelTests.swift \
  EchoTests/NarrationFileNamingTests.swift
git commit -m "feat: record contextual pronunciation shadow evidence"
```

---

## Task 10: Qualify Phases 0–2 and Document the Proof Boundaries

**Files:**

- Create: `EchoTests/PronunciationProgramAcceptanceTests.swift`
- Create: `Tools/Pronunciation/audio_judge.py`
- Create: `Tools/Pronunciation/tests/test_audio_judge.py`
- Create after real qualification: `docs/reports/pronunciation-phase2-qualification.md`
- Modify: `Makefile`
- Modify: `Tools/Pronunciation/pronunciation_corpus.py`
- Modify: `ARCHITECTURE.md`

### 10.1 Write the program-level acceptance tests

- [ ] Load every committed contract fixture and assert the validator's exact
  counts from Swift-facing test data. Exclude `provisional` rows from labelled
  counts and accuracy.
- [ ] If independently supplied/source-verifiable labels meet every threshold,
  assert qualification is `QUALIFIED`. Otherwise assert the exact valid
  `WAITING_FOR_HUMAN_LABELS` status and missing family/sense counts; do not fail
  independent implementation wiring, fabricate evidence, or mark the corpus
  accepted. Corpus-dependent qualification and final Phase 0–2 acceptance
  remain pending.
- [ ] For each named regression row, require discovery to produce the expected family/candidate set and the deterministic analyzer to match its declared expectation or explicit abstention.
- [ ] For every automatic morphology row, require the final planned IPA and all
  four frozen provenance values: deterministic `candidateID`, morphology
  `candidatePackVersion`, `derivationBase`, and `derivationRuleID`. Prove they
  survive seed-to-audit materialization, render/book timing attachment, retry
  slicing/copy, and schema-v4 JSON round-trip unchanged. For every negative row,
  require no `.derivedMorphology` decision.
- [ ] Prove supplemental rows preserve their source-derived `candidateID` and
  semantic pack `candidatePackVersion` exactly and never acquire morphology
  base/rule fields.
- [ ] Validate every bundled candidate's exact compact field shape, required
  nullable lexical/sense keys, closed validation status, and `sourceID`.
  Require each candidate source to resolve to exactly one top-level snapshot,
  and require the pack-level generator behavior to include every frozen
  generator, normalization, ARPAbet conversion, source-precedence,
  automatic-selection, and candidate-validation policy version.
- [ ] Recompute both the entries hash and semantic pack identity. Prove a
  candidate-level field change affects `normalizedDataSHA256` and
  `packVersion`, while a source snapshot or generator-rule version change
  affects `packVersion` even when entries are unchanged. Prove
  `(candidateID, candidatePackVersion)` plus the validated manifest resolves
  source/rule provenance without per-candidate copies.
- [ ] Prove an exact supplemental rewrite requires one and only one
  `validated-automatic` candidate with `automaticWithoutContext: true`.
  Require every multi-candidate CMUdict spelling with null labels to remain
  `report-only-missing-sense-label`, non-automatic, absent from contextual
  model candidate sets, and absent from automatic production decisions.
- [ ] Admit `validated-human-reviewed` candidates to contextual model-selection
  tests only when their nonempty sense labels are backed by the qualifying
  independent human/source-verifiable fixture contract. Never promote an
  ordinal, source order, spelling variant, model-authored label, or CMUdict
  annotation to a sense label.
- [ ] Prove the pack manifest contains and validates schema/semantic pack
  versions, every CMUdict/gold/silver source snapshot identity, generator
  version, exact entry/candidate counts, normalized-data SHA-256, Kokoro
  vocabulary version, dialect, licenses/required acknowledgments, and the
  audit-only RFC 3339 UTC generation timestamp.
- [ ] Independently rebuild the canonical semantic-identity payload and
  `packVersion`. Assert identical semantic inputs keep the same identity across
  timestamp changes, while a normalized-content, source, generator-behavior, or
  phoneme-vocabulary identity change changes `packVersion` and production cache
  signature. Assert timestamp-only changes never affect semantic, morphology,
  plan, or cache identity.
- [ ] Independently rebuild the exact morphology policy payload and verify its
  `candidatePackVersion` and candidate-ID fixed vectors. Prove a rule,
  exception-set, base-evidence, semantic-pack, Kokoro-vocabulary, base/derived
  IPA, or normalized-word identity change updates the applicable derived
  identity and cache signature.
- [ ] Prove unavailable-model execution produces the same production plan as a build with contextual preflight omitted.
- [ ] Scan encoded v4 audit JSON for forbidden keys and values:

```swift
let forbiddenKeys = [
    "rawPrompt", "rawResponse", "bookTitle", "author",
    "userID", "localPath", "precedingSentence",
    "targetSentence", "followingSentence",
]
for key in forbiddenKeys {
    #expect(!encodedAuditString.contains("\"\(key)\""))
}
```

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/PronunciationProgramAcceptanceTests
```

Expected: failures identify any incomplete cross-layer wiring.

### 10.2 Add deterministic metric reporting

- [ ] Add `report` to `pronunciation_corpus.py`. It must emit sorted JSON containing:
  - pack imported/ambiguous/incompatible/existing counts;
  - corpus counts by family, sense, provenance, and morphology rule;
  - deterministic resolved/advisory/abstained counts;
  - provisional candidate counts separately from qualifying
    human-labelled/adjudicated counts;
  - `corpusQualificationStatus` as `QUALIFIED` or
    `WAITING_FOR_HUMAN_LABELS`, with exact missing family/sense counts;
  - fallback counts by frequency band only when a legally approved band input exists;
  - `"frequencyBandReport":"unavailable-no-approved-source"` otherwise.
- [ ] Do not calculate accuracy from model-labelled or `provisional` rows.
- [ ] Add a Make target:

```make
pronunciation-program-report:
	python3 Tools/Pronunciation/pronunciation_corpus.py report \
		--fixtures EchoTests/Fixtures/Pronunciation \
		--pack EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json
```

- [ ] Run twice and verify byte-identical JSON:

```bash
make pronunciation-program-report
make pronunciation-program-report
```

### 10.3 Build the development audio judge with TDD

- [ ] Write failing standard-library `unittest` cases in
  `Tools/Pronunciation/tests/test_audio_judge.py`. Tests create temporary
  manifests and MP3/WAV fixtures; no private or copyrighted fixture enters the
  repository. Cover:
  - manifest admission only for MP3/WAV clips whose measured duration is at
    most 15.0 seconds and whose provenance is exactly `public-domain` or
    `synthetic`;
  - media-probed duration rather than trust in the manifest declaration, with
    rejection when measured and declared duration differ;
  - rejection before encoding of private/copyrighted provenance, raw text or
    audio fields, titles, authors, local paths, user/book identifiers, metadata,
    clips longer than 15.0 seconds, and content-hash mismatches;
  - `clipID` grammar
    `^clip_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`,
    canonical lowercase, UUID version 4, RFC 4122 variant, duplicate rejection,
    and random generation independent of text/audio/title/author/path/metadata;
  - paid admission for `labelStatus: provisional` only into distinct
    `provisional_evidence`/`provisional_review` categories, with assertions that
    it never contributes to accuracy, human labels/listening, qualification,
    touched-family graduation, or Phase 3 graduation;
  - a dry-run that performs eligibility, privacy, request-cap, and cost checks
    without constructing or sending an HTTP request;
  - stop before request 201 and before estimated cumulative cost would exceed
    USD 10.00, with the stricter limit winning;
  - direct base64 encoding of MP3 (`audio/mpeg`) and WAV (`audio/wav`) inputs;
  - strict duplicate-key-aware JSON validation with no extra fields, the exact
    `clipID`, finite confidence from 0 through 1, and the closed verdict and
    category vocabularies;
  - no-credential `WAITING_FOR_USER` with no passed/failed API-evaluation
    status while independent local tests continue;
  - one bounded retry for an eligible transient transport failure and no
    reinterpretation of malformed output or model refusal as a pass;
  - morning-queue routing for confidence below `0.80`, `uncertain`, malformed
    output, model refusal, transport failure, deterministic disagreement, and
    repeated regression failure;
  - proposal emission without repository mutation, production-file writes, or
    editor invocation;
  - a durable outside-repository append-only per-clip attempt ledger with
    `attemptCount` limited to 0...2;
  - rejection of `record-attempt` without source commit plus red-test,
    green-test, negative-guard, and implementation-review receipts;
  - increment only after the external reviewed workflow is recorded complete,
    one proposal at a time, no third attempt, and forced `morning_review` after
    the second failed rerender;
  - redaction of private fields, keys, headers, and source paths from results,
    errors, logs, and morning queues;
  - requested and returned model IDs, per-request usage, cost, validation/retry
    outcomes, corpus/content hashes, source commit, and render identity in the
    run receipt.

Run:

```bash
python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_audio_judge.py'
```

Expected: import failure for `audio_judge`.

- [ ] Implement `Tools/Pronunciation/audio_judge.py` using only the Python
  standard library and existing repository/runtime tools. The production code
  must not import it. Default run artifacts go outside the repository under
  `~/Library/Application Support/Echo/PronunciationAudioJudge/<run-id>/`.
  Store the authoritative append-only attempt ledger at
  `<run-id>/attempt-ledger.jsonl` with an atomically derived state snapshot.
  The tool only evaluates audio, emits proposals, and records evidence/state;
  it never edits production pronunciation data, writes production files,
  invokes an editor, or performs an autonomous implementation.
- [ ] Measure duration from the MP3/WAV file with an existing trusted
  repository/runtime media probe, compare it with the manifest declaration,
  and fail closed on probe failure or mismatch. Never admit a clip based only
  on a caller-supplied duration.
- [ ] Use Chat Completions with the current implementation-time pin
  `gpt-audio-1.5`. As verified on 2026-07-28, the official model page identifies
  it as the best audio-in/audio-out Chat Completions model, supports text and
  audio input/output, and does not support Structured Outputs. Judge requests
  use audio input and text output only.
- [ ] Put pricing in an explicit versioned configuration in the tool. Recheck
  and record the current official rates at implementation time. The
  2026-07-28 reference rates are USD 2.50 per million text-input tokens, USD
  10.00 per million text-output tokens, USD 32.00 per million audio-input
  tokens, and USD 64.00 per million audio-output tokens. Record the pricing
  source and check date from:
  - `https://developers.openai.com/api/docs/models/gpt-audio-1.5`
  - `https://developers.openai.com/api/docs/models/all`
  - `https://developers.openai.com/api/docs/guides/audio`
  - `https://platform.openai.com/docs/api-reference/chat`
- [ ] Before each request, calculate a conservative estimate from the
  versioned input-estimation rule and bounded maximum text output, add it to the
  cumulative estimate, and refuse the request if it would be request 201 or
  make estimated cumulative cost exceed USD 10.00. Record actual API usage
  when the response supplies it; actual usage does not relax the prospective
  cap.
- [ ] Read `OPENAI_API_KEY` only through `os.environ` or an already established
  repository secret-provider hook. Do not add a key argument or config field,
  and never persist/print the key or log request headers. If neither source
  yields a credential, write a credential-free receipt with
  `status: "WAITING_FOR_USER"` and leave all independent local work runnable.
- [ ] Request exactly one JSON object per clip and decode it with duplicate-key
  rejection. Accept only these fields and vocabularies:

```json
{
  "clipID": "clip_3f38e874-2f8e-4a90-8c42-b8f1599c8393",
  "verdict": "pass | fail | uncertain",
  "confidence": 0.0,
  "category": "correct | wrong_word | wrong_sense | stress | vowel | consonant | timing | artifact | inaudible | other",
  "heard": "optional, at most 160 Unicode scalar values",
  "note": "optional, at most 400 Unicode scalar values"
}
```

- [ ] Require `clipID`, `verdict`, `confidence`, and `category`; allow only the
  bounded `heard` and `note` optionals. Reject missing, duplicate, extra,
  unknown, wrong-type, non-finite, out-of-range, and overlong fields. Never
  salvage prose, fenced JSON, partial objects, or parsing fallback as a pass.
- [ ] Generate `clipID` as `clip_` plus a canonical lowercase random UUIDv4
  independently of text, audio, title, author, path, identifier, and metadata.
  Validate the exact regex, parse and verify version 4 and RFC 4122 variant, and
  reject duplicates. A semantic hash, filename-derived UUID, UUIDv5, or
  caller-authored descriptive ID is ineligible.
- [ ] Record corpus identity and content hashes; requested and returned model
  IDs; request and clip counts; per-request usage; estimated cost and pricing
  source/check date; verdict/confidence/category; validation and retry outcomes;
  source commit and production render identity. Results and morning queues
  contain no raw private text/audio, titles, authors, paths, identifiers, API
  keys, or request headers; expose clips only through opaque corpus IDs.
- [ ] Add this Make target:

```make
pronunciation-audio-judge-test:
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_audio_judge.py'
```

- [ ] Run:

```bash
make pronunciation-audio-judge-test
```

Expected: all local audio-judge tests pass without a credential or API call.

### 10.4 Run the capped public/synthetic audio-judge loop

- [ ] Execute this exact development loop: production Echo render → direct
  audio-file evaluation → validated structured verdict, confidence, and
  category → narrow diagnosis/fix → rerender → retest → graduated-family
  regression run → unresolved and low-confidence morning queue.
- [ ] Prepare only eligible human-labelled or explicitly `provisional`
  public-domain/synthetic production Echo pronunciation renders and a manifest
  at
  `~/Library/Application Support/Echo/PronunciationAudioJudge/input/public-synthetic-v1/manifest.json`.
  Each manifest row contains only `clipID`, provenance, `labelStatus`, media
  type, measured duration, audio content hash, corpus identity, deterministic
  expectation, source commit, render identity, and the input fields required by
  the versioned pre-request cost estimator. Enforce MP3/WAV, duration at most
  15.0 seconds, provenance exactly `public-domain` or `synthetic`, and `clipID`
  matching
  `^clip_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
  with canonical lowercase UUID version/variant checks. Generate the random
  UUIDv4 independently of text/audio/title/author/path/metadata. Resolve each
  clip from a sibling file named `<clipID>.mp3` or `<clipID>.wav`; never put
  that path in a request, result, log, receipt, or morning queue.
- [ ] Permit `labelStatus: "provisional"` for diagnostic paid evaluation when
  every other admission rule passes. Route its output only to
  `provisional_evidence` and `provisional_review`; it cannot count toward corpus
  accuracy, human labels, human listening, qualification, family regression
  graduation, or Phase 3 graduation.
- [ ] Keep Mac speakers muted. Validate direct file evaluation first:

```bash
python3 Tools/Pronunciation/audio_judge.py evaluate \
  --manifest ~/Library/Application\ Support/Echo/PronunciationAudioJudge/input/public-synthetic-v1/manifest.json \
  --run-id public-synthetic-v1-dry-run \
  --dry-run
```

Expected: eligibility, privacy, content hashes, request cap, and cost cap pass;
zero API requests occur; a dry-run receipt is stored outside the repository.

- [ ] Run the first unattended capped evaluation:

```bash
python3 Tools/Pronunciation/audio_judge.py evaluate \
  --manifest ~/Library/Application\ Support/Echo/PronunciationAudioJudge/input/public-synthetic-v1/manifest.json \
  --run-id public-synthetic-v1
```

Expected with a credential: direct MP3/WAV evaluation through
`gpt-audio-1.5`, no request 201, estimated total at or below USD 10.00, actual
usage recorded when returned, and strictly validated receipts and morning
queue. Expected without a credential: `WAITING_FOR_USER`; do not mark the lane
passed or failed, and continue Sections 10.5–10.10 wherever independent.

- [ ] For each `fail`, make at most one narrow diagnosis/fix proposal at a time.
  The judge emits the proposal and ledger state only. It never edits production
  pronunciation data, writes a production file, invokes an editor, runs the
  external implementation, or increments `attemptCount` for a proposal.
- [ ] Perform any accepted production change through the existing external
  reviewed implementation workflow with red/green tests, negative guards, and
  implementation review. Only after that workflow finishes, record it:

```bash
python3 Tools/Pronunciation/audio_judge.py record-attempt \
  --run-id <run-id> \
  --clip-id <canonical-clip-id> \
  --source-commit <full-source-commit> \
  --red-test-receipt <sha256> \
  --green-test-receipt <sha256> \
  --negative-guard-receipt <sha256> \
  --implementation-review-receipt <sha256>
```

Expected: the tool validates the current `proposal_emitted` state and all
required receipts, appends one durable ledger event, increments `attemptCount`
from zero to one or one to two, and transitions to `rerender_pending`. Missing
receipts, a concurrent/unresolved attempt, a reused implementation receipt, or
an attempted third increment is rejected without state change.

- [ ] After the external production Echo rerender, audio retest, and regression
  run containing every previously passing case in the touched deterministic
  family plus its negative controls, record the result:

```bash
python3 Tools/Pronunciation/audio_judge.py record-rerender \
  --run-id <run-id> \
  --clip-id <canonical-clip-id> \
  --render-content-sha256 <sha256> \
  --audio-retest-receipt <sha256> \
  --family-regression-receipt <sha256> \
  --outcome <pass-or-fail>
```

Expected: success transitions to `resolved`. Failure after attempt one may
transition to one new `proposal_emitted`; failure after attempt two must
transition irreversibly to `morning_review`. A fix cannot graduate from only
the failing clip. `record-rerender` never edits a production file or invokes an
editor.
- [ ] Queue confidence below `0.80`, `uncertain`, malformed output, refusal,
  transport failure, deterministic disagreement, and repeated regression
  failure for morning review. Keep machine results separate from human labels
  and final human listening. This loop cannot graduate a Phase 2 family.

### 10.5 Update architecture documentation

- [ ] Add a concise `ARCHITECTURE.md` section covering:
  - the complete versioned bundled-pack manifest, canonical semantic identity,
    timestamp exclusion, and source precedence;
  - exact supplemental candidate/pack provenance and deterministic derived
    candidate/policy-pack/base/rule provenance;
  - the `content` noun fallback;
  - four Phase 2 shadow families;
  - on-device/private bounded context;
  - model output as audit-only independent evidence;
  - v4 audit compatibility and incomplete-evidence behavior;
  - production cache identity including semantic pack and morphology-policy
    identities but excluding audit timestamps and shadow evidence;
  - Phase 3's separate approval requirement.
- [ ] State that the app still deploys to iOS 18/macOS 15 and Foundation Models are gated at iOS 26/macOS 26 with deterministic behavior on older/ineligible devices.
- [ ] Document the development-only audio-judge boundary: public/synthetic
  direct-audio input, no private/copyrighted material, muted speakers, strict
  validated machine evidence, caps and `WAITING_FOR_USER`, no production
  authority, and mandatory human-labelled corpus plus bounded listening.

### 10.6 Run the complete mechanical gate

- [ ] Run from a clean task worktree:

```bash
make pronunciation-corpus-test
make pronunciation-corpus-qualification
make pronunciation-pack-test
make pronunciation-audio-judge-test
make test
make echo-cli
git status --short --branch
```

Expected: all independent local gates pass and only intended
qualification/documentation changes remain. A
`WAITING_FOR_HUMAN_LABELS` qualification-status result is recorded truthfully
and leaves corpus-dependent/final Phase 0–2 acceptance pending.

### 10.7 Perform real eligible-device shadow qualification

- [ ] On an Apple-Intelligence-eligible iOS 26+/macOS 26+ device with the system model available, narrate a synthetic or public-domain fixture containing every family and every sense.
- [ ] Verify the v4 audit contains an envelope for every discovered occurrence and no raw three-sentence window.
- [ ] Run the same fixture twice with unchanged OS/model state and record agreement rate without claiming determinism across OS updates.
- [ ] Exercise and record:
  - device/model unavailable;
  - context-too-large reduction to one occurrence;
  - one transient retry;
  - guardrail/refusal no-retry;
  - structured-output rejection;
  - cancellation before plan finalization.
- [ ] Record device class, platform, OS build, qualified runtime-family ID, candidate pack, prompt schema, occurrence counts, selection/abstention/failure counts, and test dates. Do not record raw private source text or model responses.
- [ ] If no eligible device is available, stop here and report runtime qualification as blocked. Passing simulator/unit tests is not a substitute.

### 10.8 Perform bounded acoustic and human-listening checks

- [ ] Render representative samples for:
  - supplemental exact entries;
  - each accepted morphology rule and a rejected exception;
  - `content` as material noun and satisfied adjective;
  - all senses of `read`, `live`/`lives`, and `record`.
- [ ] Verify plan-to-audio mechanical integrity through the existing audit and listening-reel checks.
- [ ] Have a human listen to the bounded sample set and record pass/fail plus corrections. Do not report mechanical checks as human acceptance.
- [ ] Keep the human result separate from direct-audio API evaluation. Neither
  a machine `pass` nor transcription is a human label or final listening result.

### 10.9 Write the qualification receipt

- [ ] Create `docs/reports/pronunciation-phase2-qualification.md` with these sections and actual results:

```markdown
# Pronunciation Phases 0–2 Qualification

## Exact source state
## Local unit and build gates
## Pack reproducibility and attribution
## Corpus contract, human-label status, and deterministic metrics
## Development audio-judge API evaluation
## Eligible-device Foundation Models shadow run
## Ineligible/older-platform fallback
## Cancellation and categorized failures
## Mechanical audio integrity
## Human listening
## Hosted CI
## Explicitly unproven
```

- [ ] Under “Explicitly unproven,” state that Phase 2 does not prove any family is ready for model-controlled narration and does not authorize Phase 3.
- [ ] Record `QUALIFIED` only when independently supplied/source-verifiable
  human-labelled/adjudicated rows meet every family/sense threshold. Otherwise
  record `WAITING_FOR_HUMAN_LABELS`, exact missing counts, and pending
  corpus-dependent/final Phase 0–2 acceptance while keeping independent local
  results separate.
- [ ] In “Pack reproducibility and attribution,” record all required manifest
  fields, the recomputed canonical semantic payload/hash, source/generator/vocab
  identity checks, entry/candidate counts, normalized-data hash, licenses and
  acknowledgments, and the audit-only timestamp. State explicitly that the
  timestamp did not affect semantic or cache identity.
- [ ] In “Development audio-judge API evaluation,” record the corpus identity
  and hashes, requested/returned model IDs, request/clip counts, per-request
  usage, estimated cost and pricing source/check date, structured results,
  validation/retry outcomes, source commit, render identity, and morning-queue
  count. If no credential exists, record `WAITING_FOR_USER`, never pass/fail.
  Do not include raw private text/audio, titles, authors, paths, identifiers,
  API keys, or request headers.
- [ ] Keep local tests, builds, API evaluation, eligible-device shadow
  execution, rendered-audio integrity, human listening, hosted CI, merge,
  installation, and release as separate statuses.

### 10.10 Commit and publish through the repository workflow

- [ ] Commit the acceptance test, metrics, architecture, and evidence receipt:

```bash
git add Makefile Tools/Pronunciation/pronunciation_corpus.py \
  Tools/Pronunciation/audio_judge.py \
  Tools/Pronunciation/tests/test_audio_judge.py \
  EchoTests/PronunciationProgramAcceptanceTests.swift \
  ARCHITECTURE.md docs/reports/pronunciation-phase2-qualification.md
git commit -m "docs: qualify pronunciation phases zero through two"
```

- [ ] Re-run `git status --short --branch` and preserve unrelated work.
- [ ] Use the repository's branch-finishing workflow to push the feature branch and open a ready PR to `nightly`.
- [ ] Wait for hosted CI and report it as passing, failing, pending, or blocked. Do not call the feature merged, deployed, installed, or listener-accepted unless each event separately occurs.

---

## Implementation Self-Review Checklist

- [ ] Every design requirement in Sections 6–11 and 13–18 of the approved spec maps to an implementation task or is explicitly deferred to Phase 3+.
- [ ] No task enables model-controlled pronunciation.
- [ ] No task introduces a provider protocol, production/runtime cloud call,
  runtime download, model adapter, neural OOV model, or `wordfreq` production
  dependency. The single exception is Task 10's explicitly bounded
  development-only OpenAI audio call.
- [ ] All production-affecting inputs enter cache identity; all shadow-only inputs stay out.
- [ ] The pack manifest contains every Section 6.1 field. `packVersion` is the
  hash of the exact canonical normalized-content/source-snapshot/generator-
  behavior/Kokoro-vocabulary payload; identity changes for each of those inputs
  and not for the audit-only generation timestamp.
- [ ] Task 3 strictly decodes and recomputes manifest counts, normalized-data
  hash, semantic payload, and `packVersion` without optional/`try?` fallback.
- [ ] Every `.derivedMorphology` seed and decision carries deterministic
  `candidateID`, morphology-policy `candidatePackVersion`, `derivationBase`,
  and `derivationRuleID`; all four survive materialization, timing, retry copy,
  and JSON round-trip. Supplemental candidate/pack behavior is unchanged.
- [ ] Old schema-v3 audits decode without being mistaken for complete current evidence.
- [ ] Every contextual shadow occurrence receives one validated v4 envelope, including unavailable/failure outcomes.
- [ ] Cancellation cannot produce a finalized partial plan.
- [ ] The plan uses concrete file paths, type names, commands, expected outcomes, and commits; it contains no unfinished implementation marker or invented publication proof.
- [ ] Task 10 owns the development audio judge, its standard-library tests, dry
  run, and first capped public/synthetic API run; no earlier task or production
  target depends on a credential.
- [ ] Strict response validation has a closed vocabulary and no parsing
  fallback; request/cost caps, `WAITING_FOR_USER`, bounded retries, two-attempt
  fix limit, touched-family regression, and morning-queue rules all have tests.
- [ ] Contract validation can pass without fabricated labels; qualification
  counts only independent/source-verifiable human evidence and otherwise
  reports `WAITING_FOR_HUMAN_LABELS` while independent Tasks 2–10 continue.
- [ ] Paid-run validation enforces MP3/WAV at most 15.0 seconds, exact allowed
  provenance, canonical lowercase random UUIDv4 IDs independent of semantic
  inputs, and isolated provisional evidence/queue categories.
- [ ] The judge never edits production data or invokes an editor. Its
  outside-repository ledger owns explicit proposal, `record-attempt`,
  `record-rerender`, resolved, retry, and forced `morning_review` transitions
  with an attempt count from zero through two.
- [ ] Audio-judge receipts contain the required corpus, hash, model, usage,
  pricing, verdict, validation/retry, source-commit, and render-identity
  evidence without private/copyrighted content or secret/header data.
- [ ] Machine judgments and `provisional` examples remain separate from
  independently human-labelled corpora, rendered-audio integrity, and bounded
  human listening.
- [ ] Qualification reports local tests, builds, API evaluation,
  eligible-device shadow execution, rendered-audio integrity, human listening,
  hosted CI, merge, installation, and release as separate proof states.
