# Global Pronunciation Foundation and Hybrid Context Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve Echo narration for all future books by adding a reproducible bundled American-English pronunciation pack, conservative auditable morphology, a noun-first fallback for `content`, and on-device Foundation Models contextual classification recorded in shadow-mode audits.

**Architecture:** Keep Echo's existing override → homograph → Kokoro G2P pipeline and insert one deterministic universal-pronunciation rewrite between overrides and homographs. Foundation Models run independently before rendering, choose only among stable candidate IDs for four approved contextual families, and attach evidence to the audit without changing narration or synthesis cache identity in Phases 0–2.

**Tech Stack:** Swift 6, Swift Testing, Foundation Models behind iOS 26/macOS 26 availability gates, MisakiSwift/Kokoro G2P, Foundation, NaturalLanguage sentence segmentation, standard-library Python 3 tooling, JSON/JSONL resources, Make, Xcode synchronized groups.

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
- `Tools/Pronunciation/cmudict.lock.json`
- `Tools/Pronunciation/tests/test_pronunciation_corpus.py`
- `Tools/Pronunciation/tests/test_build_pronunciation_pack.py`
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
- `EchoTests/Fixtures/Pronunciation/contextual_families_v1.jsonl`
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
- Correction contribution/export, runtime pack downloads, Foundation Models adapters, cloud inference, and neural OOV/context models remain out of scope.

---

## Task 1: Freeze the Phase 0 Evaluation Contracts

**Files:**

- Create: `Tools/Pronunciation/pronunciation_corpus.py`
- Create: `Tools/Pronunciation/tests/test_pronunciation_corpus.py`
- Create: `EchoTests/Fixtures/Pronunciation/named_regressions_v1.jsonl`
- Create: `EchoTests/Fixtures/Pronunciation/contextual_families_v1.jsonl`
- Create: `EchoTests/Fixtures/Pronunciation/distribution_works_v1.json`
- Create: `EchoTests/Fixtures/Pronunciation/morphology_v1.jsonl`
- Modify: `Makefile`

### 1.1 Write failing corpus-validator tests

- [ ] Add standard-library `unittest` coverage for missing fields, invalid family/candidate pairs, unresolved dual-label disagreements, duplicate case IDs, private-looking paths, unbalanced senses, fewer than 200 examples per family, fewer than 10 distribution works, and morphology entries without an expected derivation result.

```python
class PronunciationCorpusTests(unittest.TestCase):
    def test_balanced_corpus_requires_two_human_labels_or_adjudication(self):
        case = contextual_case(
            label_a="read.past",
            label_b="read.present",
            adjudicated=None,
        )
        with self.assertRaisesRegex(ValueError, "unresolved label disagreement"):
            validate_contextual_cases([case] * 800)

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

### 1.2 Implement the corpus schemas and validator

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
    label_a: str
    label_b: str
    adjudicated: str | None
    provenance: str
```

- [ ] Resolve the gold label as `labelA` when the two labels agree, otherwise require `adjudicated`. Reject labels outside the declared family candidate set.
- [ ] Require at least 200 cases per family and at least 50 cases for each two-way sense. For the `live` family, require at least 50 each for `live.adjective`, `live.verb`, `lives.noun`, and `lives.verb`.
- [ ] Require ten distinct distribution work IDs. Allow only `public-domain`, `permissive`, or `synthetic` provenance and require a `sourceURL` plus license for non-synthetic work.
- [ ] Reject absolute paths, `file://` URLs, and fields named `bookTitle`, `author`, `userID`, or `localPath`.
- [ ] Give morphology rows these exact fields:

```json
{"caseID":"morph-able-001","word":"startable","expectedBase":"start","expectedRuleID":"morphology.able.exact-base","expectedIPA":"stˈɑɹtəbəl","automatic":true}
```

### 1.3 Add the committed corpora

- [ ] Add a named regression matrix containing at least these ambiguity shapes for each family: direct grammatical cue, long-distance cue within the target sentence, misleading adjacent cue, quotation/dialogue, heading fragment, malformed fragment, capitalization, punctuation adjacency, and override markup.
- [ ] Add at least 200 independently human-labeled examples per family to `contextual_families_v1.jsonl`; keep every sentence synthetic or appropriately licensed.
- [ ] Add at least ten public-domain, permissive, or synthetic work profiles to `distribution_works_v1.json`. Store only short test sentences, source/license metadata, and counts—not full copyrighted books.
- [ ] Add positive and negative `-able`/`-ible` morphology cases, including proper nouns, multiple possible bases, exception-list words, already-explicit words, and contextual-family exclusions.

Example contextual row:

```json
{"caseID":"read-001","familyID":"read","targetWord":"read","precedingSentence":null,"targetSentence":"Yesterday, Mira read the final chapter aloud.","followingSentence":null,"labelA":"read.past","labelB":"read.past","adjudicated":null,"provenance":"synthetic"}
```

### 1.4 Add a repeatable validation gate

- [ ] Add this Make target:

```make
pronunciation-corpus-test:
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_pronunciation_corpus.py'
	python3 Tools/Pronunciation/pronunciation_corpus.py validate \
		--fixtures EchoTests/Fixtures/Pronunciation
```

- [ ] Run it twice and verify deterministic identical summaries.

Run:

```bash
make pronunciation-corpus-test
```

Expected: four family counts of at least 200, at least ten distribution works, and zero validation errors.

### 1.5 Commit

- [ ] Commit only the Phase 0 corpus contract.

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
- [ ] Preserve the upstream license notice in `ThirdParty/CMUdict/LICENSE`. Do not add `wordfreq` to production inputs.
- [ ] Add a CMUdict section to `THIRD_PARTY_NOTICES.md` containing its project name, upstream URL, pinned commit, copyright notice, disclaimer, and the complete redistribution terms from the pinned license.

### 2.2 Write failing generator tests

- [ ] Cover ARPAbet stress conversion, alternate-pronunciation suffix normalization, stable candidate IDs, exact gold/silver exclusion, ambiguity suppression, Kokoro-vocabulary rejection, deterministic sorted output, optional coarse frequency bands, and pinned-input hash failure.

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
- [ ] Deduplicate identical IPA variants. Set `automaticWithoutContext` to `true` only when exactly one compatible candidate remains.
- [ ] Derive the candidate ID from source, normalized spelling, and IPA:

```python
candidate_id = "cmudict." + word + "." + hashlib.sha256(
    f"cmudict@{commit}\0{word}\0{ipa}".encode("utf-8")
).hexdigest()[:12]
```

- [ ] Accept an optional reviewed JSON map from normalized word to one of `veryCommon`, `common`, `uncommon`, `rare`, or `unknown`. Default to `unknown`; never use the band to select among IPA candidates.
- [ ] Encode with `ensure_ascii=False`, `sort_keys=True`, compact separators, and a final newline. Derive `packVersion` as `sha256:<digest>` from the canonical entries payload, not from build time.

The generated top-level shape must be built exactly this way; the digest and
counts come from the actual canonical inputs:

```python
output = {
    "schemaVersion": 1,
    "packVersion": derive_pack_version(entries),
    "dialect": "en-US",
    "sources": [{
        "sourceID": "cmudict@74790861f652b15e4ac49015a90074ad62a27690",
        "license": "BSD-style",
        "licensePath": "ThirdParty/CMUdict/LICENSE",
        "sha256": "81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22",
    }],
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

- [ ] Cover successful bundled loading through `NarrationResources`, exactly-one automatic lookup, ambiguous suppression, invalid schema rejection, duplicate candidate ID rejection, and empty fallback behavior.
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
    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let sourceID: String
        let sourceTier: String
        let kind: String
        let automaticWithoutContext: Bool
        let frequencyBand: FrequencyBand
    }

    enum FrequencyBand: String, Codable, Equatable, Sendable {
        case veryCommon, common, uncommon, rare, unknown
    }

    let schemaVersion: Int
    let packVersion: String
    let dialect: String
    private let entries: [String: [Candidate]]

    init(data: Data) throws
    static let empty: EnglishPronunciationPack
    static func bundledOrEmpty() -> EnglishPronunciationPack
    func automaticCandidate(for normalizedWord: String) -> Candidate?
}
```

- [ ] Require schema `1`, dialect `en-US`, a lowercase normalized key, unique candidate IDs, non-empty IPA, and a `sha256:` pack version.
- [ ] `automaticCandidate` returns a candidate only when exactly one candidate is marked automatic.
- [ ] `bundledOrEmpty()` uses `NarrationResources.url(forResource:withExtension:)`; if the pack is absent or invalid, return a deterministic empty pack with version `unavailable-v1` so existing narration remains usable. Log only the error category, never source text.

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

```swift
@Test func exactSupplementalCandidateCreatesAuditableLink() {
    let result = UniversalPronunciationResolver.rewrite(
        to: "A foobar appeared.",
        blockID: "b1",
        pack: pack(entry: "foobar", ipa: "fˈubɑɹ"),
        basePronunciation: { _ in nil })

    #expect(result.text == "A [foobar](/fˈubɑɹ/) appeared.")
    #expect(result.decisionSeeds.single?.source == .supplementalLexicon)
    #expect(result.decisionSeeds.single?.candidateID == "cmudict.foobar.fixture")
}

@Test func morphologyRequiresExactlyOneValidatedBase() {
    let result = UniversalPronunciationResolver.rewrite(
        to: "The widget is startable.",
        blockID: "b1",
        pack: .empty,
        basePronunciation: { word in
            word == "start" ? "stˈɑɹt" : nil
        })

    #expect(result.text == "The widget is [startable](/stˈɑɹtəbəl/).")
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
    static let contextualExclusions: Set<String> = [
        "content", "read", "live", "lives", "record", "records",
    ]

    static func rewrite(
        to text: String,
        blockID: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> PronunciationRewriteResult
}
```

- [ ] Reuse the repository's existing word-range and Misaki-link parsing conventions. Never rewrite inside `[word](/ipa/)`.
- [ ] Treat a capitalized token away from sentence start, all-capital tokens longer than one character, and apostrophe possessives as proper-name risk; abstain.
- [ ] Apply an exact pack candidate first.
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
- [ ] Emit one seed with source `.supplementalLexicon` for pack hits and `.derivedMorphology` for derivations. Include the stable candidate/pack fields for pack hits and base/rule fields for derivations.

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
- [ ] Store one `EnglishPronunciationPack` in `NarrationService`, initialized with `.bundledOrEmpty()`, and pass the same immutable value to every plan in that service.
- [ ] In `HeadlessNarrationRunner`, snapshot one pack at run start and pass it to every chapter render; never allow a run to observe two pack versions.

### 4.5 Put production-affecting policy in cache identity

- [ ] Add this computed signature:

```swift
extension EnglishPronunciationPack {
    var productionPolicySignature: String {
        [
            packVersion,
            UniversalPronunciationResolver.morphologyVersion,
            "content-default-v1",
        ].joined(separator: "|")
    }
}
```

- [ ] Add a required `pronunciationPolicySignature` argument to `NarrationFileNaming.contentSignature(spokenBlocks:renderedTexts:includeLeadOutPad:normalizationMode:pronunciationPolicySignature:)` and include it in the hash input.
- [ ] Update every call site to use the run's snapshotted pack signature.
- [ ] Increment `NarrationFileNaming.renderVersion` from `15` to `16` because the production pronunciation front end changes.
- [ ] Add a test proving two pack versions change the content signature.
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
- Modify: `EchoTests/KokoroG2PTests.swift`
- Modify: `EchoTests/HomographPronunciationResolverTests.swift`
- Modify: `EchoTests/NarrationRenderPlanTests.swift`

### 5.1 Write failing regressions

- [ ] Add a G2P test requiring bare, context-free `content` to use the noun pronunciation.
- [ ] Preserve tests that a satisfied/adjectival sentence uses the adjective and content/material sentences use the noun through deterministic homograph rules.
- [ ] Add a fragment/heading regression proving the noun is the safe fallback when no rule fires.

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
- [ ] Regenerate the supplemental pack and verify it remains byte-identical because existing gold entries are excluded.

Run:

```bash
make pronunciation-pack-test
make test-only FILTER=EchoTests/KokoroG2PTests
make test-only FILTER=EchoTests/HomographPronunciationResolverTests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
```

### 5.3 Commit

- [ ] Commit the isolated fallback correction.

```bash
git add EchoCore/Services/Narration/MisakiResources/us_gold.json \
  EchoTests/KokoroG2PTests.swift \
  EchoTests/HomographPronunciationResolverTests.swift \
  EchoTests/NarrationRenderPlanTests.swift
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
pronunciationPack: EnglishPronunciationPack = .bundledOrEmpty(),
contextualPronunciationEvaluator: @escaping ContextualPronunciationBatchEvaluator =
    FoundationModelsContextualPronunciationEvaluator.makeBatchEvaluator()
```

- [ ] Preserve the existing `fmEnabled` preference for FM text normalization. Contextual shadowing has its own program state and runs whenever one of the four families is discovered; do not silently couple it to the QA classifier preference.

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
- Create after real qualification: `docs/reports/pronunciation-phase2-qualification.md`
- Modify: `Makefile`
- Modify: `Tools/Pronunciation/pronunciation_corpus.py`
- Modify: `ARCHITECTURE.md`

### 10.1 Write the program-level acceptance tests

- [ ] Load every committed corpus fixture and assert the validator's exact counts from Swift-facing test data.
- [ ] For each named regression row, require discovery to produce the expected family/candidate set and the deterministic analyzer to match its declared expectation or explicit abstention.
- [ ] For every automatic morphology row, require the final planned IPA and audit provenance. For every negative row, require no `.derivedMorphology` decision.
- [ ] Prove the pack manifest's source ID, license path, hash, and candidate IPA all match the committed lock and Kokoro vocabulary.
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
  - fallback counts by frequency band only when a legally approved band input exists;
  - `"frequencyBandReport":"unavailable-no-approved-source"` otherwise.
- [ ] Do not calculate model accuracy from a model-labeled corpus.
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

### 10.3 Update architecture documentation

- [ ] Add a concise `ARCHITECTURE.md` section covering:
  - the versioned bundled pack and source precedence;
  - exact-entry and morphology provenance;
  - the `content` noun fallback;
  - four Phase 2 shadow families;
  - on-device/private bounded context;
  - model output as audit-only independent evidence;
  - v4 audit compatibility and incomplete-evidence behavior;
  - production cache identity including pack/morphology but excluding shadow evidence;
  - Phase 3's separate approval requirement.
- [ ] State that the app still deploys to iOS 18/macOS 15 and Foundation Models are gated at iOS 26/macOS 26 with deterministic behavior on older/ineligible devices.

### 10.4 Run the complete mechanical gate

- [ ] Run from a clean task worktree:

```bash
make pronunciation-corpus-test
make pronunciation-pack-test
make test
make echo-cli
git status --short --branch
```

Expected: all local gates pass and only intended qualification/documentation changes remain.

### 10.5 Perform real eligible-device shadow qualification

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

### 10.6 Perform bounded acoustic and human-listening checks

- [ ] Render representative samples for:
  - supplemental exact entries;
  - each accepted morphology rule and a rejected exception;
  - `content` as material noun and satisfied adjective;
  - all senses of `read`, `live`/`lives`, and `record`.
- [ ] Verify plan-to-audio mechanical integrity through the existing audit and listening-reel checks.
- [ ] Have a human listen to the bounded sample set and record pass/fail plus corrections. Do not report mechanical checks as human acceptance.

### 10.7 Write the qualification receipt

- [ ] Create `docs/reports/pronunciation-phase2-qualification.md` with these sections and actual results:

```markdown
# Pronunciation Phases 0–2 Qualification

## Exact source state
## Local unit and build gates
## Pack reproducibility and attribution
## Corpus counts and deterministic metrics
## Eligible-device Foundation Models shadow run
## Ineligible/older-platform fallback
## Cancellation and categorized failures
## Mechanical audio integrity
## Human listening
## Hosted CI
## Explicitly unproven
```

- [ ] Under “Explicitly unproven,” state that Phase 2 does not prove any family is ready for model-controlled narration and does not authorize Phase 3.
- [ ] Keep local tests, eligible-device execution, human listening, hosted CI, merge, installation, and release as separate statuses.

### 10.8 Commit and publish through the repository workflow

- [ ] Commit the acceptance test, metrics, architecture, and evidence receipt:

```bash
git add Makefile Tools/Pronunciation/pronunciation_corpus.py \
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
- [ ] No task introduces a provider protocol, cloud call, runtime download, model adapter, neural OOV model, or `wordfreq` production dependency.
- [ ] All production-affecting inputs enter cache identity; all shadow-only inputs stay out.
- [ ] Old schema-v3 audits decode without being mistaken for complete current evidence.
- [ ] Every contextual shadow occurrence receives one validated v4 envelope, including unavailable/failure outcomes.
- [ ] Cancellation cannot produce a finalized partial plan.
- [ ] The plan uses concrete file paths, type names, commands, expected outcomes, and commits; it contains no unfinished implementation marker or invented publication proof.
