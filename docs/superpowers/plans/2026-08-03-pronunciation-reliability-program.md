# Echo Pronunciation Reliability Program Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Echo's complete pronunciation-reliability program: correct English number and currency narration (including `$100 billion` as “one hundred billion dollars”), non-blocking disagreement review, a qualification-gated local neural OOV candidate, independent contextual-family graduation, one bounded same-voice acoustic retry, and truthful release evidence.

**Architecture:** Preserve Echo's existing narration spine and authority order. Fix deterministic normalization in vendored MisakiSwift; extend `PronunciationAuditDecision`, the QA issue store, app review views, listening reels, and headless manifests for advisory evidence; reuse ONNX Runtime behind an actor-confined Mini-BART evaluator; and permit neural or contextual choices to affect synthesis only through versioned qualification records. Shadow-only evidence never enters cache identity, while every byte-affecting policy does.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, GRDB migrations, MisakiSwift, NaturalLanguage, ONNX Runtime CPU, standard-library Python 3, JSON/JSONL assets, Make, Xcode 26 synchronized groups, iOS 18/macOS 15/watchOS 11 deployment floors.

**Design source:** `docs/superpowers/specs/2026-08-03-pronunciation-reliability-program-design.md`

## Global Constraints

- Preserve the production authority order: deterministic spoken-text normalization → occurrence override → book/global override → qualified deterministic context → trusted lexicon → qualified neural OOV selection → deterministic OOV fallback → audit → Kokoro.
- Rendering remains non-blocking. Uncertainty creates advisory evidence; it never silences a letter-bearing word or prevents an otherwise viable render.
- A known-word source disagreement is advisory. Neural production authority is limited to genuine OOV spellings and exists only after the exact model, conversion, validation, and selection policy passes every gate.
- Candidate authority is categorical (`trusted`, `qualified`, or `uncertain`); a lower-authority candidate never wins because of an uncalibrated numeric confidence.
- Contextual families graduate independently. A failed family or unknown runtime remains shadow-only without disabling another graduated family.
- Keep private book text, audio, titles, paths, identifiers, and local review evidence out of committed fixtures, public reports, and logs.
- Reuse Echo's existing ONNX Runtime dependency. Do not add another runtime or third-party package.
- Do not add eSpeak, non-English G2P, a remote inference path, a second narration engine, or a system-voice fallback.
- No model download occurs during narration. A production-authoritative model must be pinned, integrity-checked, bundled, and available before selection.
- Keep model loading, inference, corpus work, audio analysis, and report generation off `MainActor`; propagate cancellation.
- At most one acoustic retry is allowed. It uses the same `VoiceID`, the same frozen pronunciation plan, and smaller chunking or adjusted context only. Never switch voices silently.
- Preserve `SuggestedFix` as the minimal accepted-fix contract used by contribution filtering. Store alternatives and advisory metadata separately in `evidence_json`.
- Shadow-only packs, model results, and family decisions do not change synthesis/cache identity. Any policy that can alter output bytes must update the render version or production policy signature.
- Agents may create provisional public/synthetic evaluation cases, but may not impersonate independent human labelers or populate trusted human receipts. Missing evidence produces an explicit waiting state, never a fabricated pass.
- App unit tests, Release CLI build, hosted CI, production rendering, physical-device execution, and human listening are separate proof states.
- Every Apple build or test command in this plan must run through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- <command>`. Do not call `xcodebuild`, Apple build/test Make targets, or `swift test` directly.
- Each stage is a coherent review boundary. Implement it on a clean `feature/*` branch based on the intended `nightly` state, commit coherent changes, push, and open a ready PR to `nightly`. Do not start the next production-affecting stage until its dependency is either merged or explicitly stacked.
- Stop a stage at its qualification gate when evidence is insufficient. Commit the tooling and truthful receipt, keep the component shadow-only, and continue independent stages.

---

## Execution Setup

- [ ] Read `ARCHITECTURE.md`, the approved design source, and this plan before editing.
- [ ] Run `git status --short --branch` and `git worktree list --porcelain`; confirm the implementation uses a dedicated clean worktree and preserves unrelated work.
- [ ] Fetch the intended base and create the Stage 1 branch from `origin/nightly` using the repository's normal worktree workflow. Never reset or clean a user-owned checkout.
- [ ] Record the starting SHA and baseline proof states in the stage PR description.
- [ ] Run the platform-neutral pronunciation tooling baseline:

```bash
make pronunciation-pack-test
make pronunciation-corpus-test
make pronunciation-program-report
```

Expected: all tooling contracts pass; the current contextual qualification may truthfully report `WAITING_FOR_HUMAN_LABELS`.

- [ ] Run the focused Apple baseline through the slot:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationProgramAcceptanceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

Expected: each command passes. If a baseline failure prevents attribution, record it and stop before changing that surface.

---

## Program File Map

The stage task lists below are authoritative for exact edits. This map fixes the responsibility boundaries before implementation:

- **Vendored deterministic normalization:** `EnglishNum2Word.swift` owns cardinal words; new `EnglishCurrencyExpression.swift` owns currency grammar and semantic spoken forms; `EnglishG2P.swift` recognizes/merges complete source spans before per-token phonemization.
- **Production vs. audit lexicons:** `EnglishPronunciationPack.swift` remains the only CMUdict-derived automatic production pack; new `EnglishPronunciationAuditPack.swift` exposes disagreement alternatives and is deliberately absent from production policy identity.
- **Portable evidence:** new `PronunciationAdvisoryEvidence.swift` owns authority/category/validation/selection vocabulary; `PronunciationAudit.swift` carries it through manifest schema 5; `PronunciationListeningReel.swift` and `HeadlessNarrationRunner.swift` serialize the same identities.
- **Candidate comparison:** new `PronunciationCandidateAnalyzer.swift` compares only scoped words and never mutates a selected seed unless a later qualification object grants authority.
- **Persistent review:** new `Schema_V40.swift` adds origin/evidence columns; `NarrationQualityIssueDAO.swift` replaces open rows per origin; new `PronunciationAdvisoryIssueBuilder.swift` maps portable audit evidence into the existing QA queue without changing `SuggestedFix`.
- **App review:** `NarrationQAReviewModel.swift` owns decoded candidate presentation and delegates accepted choices to the existing override/repair path; the current iOS and macOS QA views remain presentation layers.
- **Neural evaluator:** `MiniBARTG2PTokenizer.swift` and `ARPAbetToKokoroIPA.swift` are pure conversion; `MiniBARTG2PEngine.swift` owns cached ONNX sessions; `NeuralG2PQualification.swift` is the sole production-authority gate.
- **Contextual graduation:** existing family/discovery/preflight types stay authoritative; new `ContextualPronunciationQualification.swift` binds individual families to exact corpus, prompt, candidate-pack, and runtime identities.
- **Acoustic handling:** `NarrationChunkQuality.swift` owns mechanical rejection reasons; `NarrationService.swift` owns the single retry; the portable advisory and QA issue systems record the outcome without modifying lexical data.
- **Qualification/release tooling:** Python tools validate public/synthetic fixtures plus external trusted human receipts and emit content-free reports. They do not edit production policy files or claim human authority.

---

# Stage 1 — Deterministic Number and Currency Correctness

## Task 1: Repair Cardinal Tens 20–29

**Files:**

- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Num2Word/EnglishNum2Word.swift`
- Modify: `ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/MisakiSwiftTests.swift`

**Interfaces:**

- Consumes: `EnglishNum2Word.convert(_ number: Decimal, to format: ConversionFormat = .decimal) -> String`.
- Produces: correct cardinal output for every integer in 20...29 without changing the API.

### 1.1 Pin the regression with failing tests

- [ ] Add table-driven assertions for `20`, `21`, `22`, and `29`, preserving Misaki's established punctuation/hyphen style.

```swift
@Test(arguments: [
  (20, "twenty"),
  (21, "twenty-one"),
  (22, "twenty-two"),
  (29, "twenty-nine"),
])
func cardinalTwentyRange(value: Int, expected: String) {
  #expect(EnglishNum2Word().convert(Decimal(value)) == expected)
}
```

- [ ] Run the package suite through the slot.

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- swift test --package-path ThirdParty/MisakiSwift
```

Expected: the new 20–29 assertions fail because `midNumWords` has no `20` entry.

### 1.2 Add the missing tens entry

- [ ] Add `(20, "twenty")` to `midNumWords` in numeric order; do not change other number rules.
- [ ] Re-run the package suite through the slot.

Expected: all MisakiSwift tests pass.

### 1.3 Commit

```bash
git add ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Num2Word/EnglishNum2Word.swift ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/MisakiSwiftTests.swift
git commit -m "fix(narration): pronounce cardinal twenties"
```

## Task 2: Introduce a Fail-Closed Currency Expression Parser

**Files:**

- Create: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/EnglishCurrencyExpression.swift`
- Create: `ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/EnglishCurrencyExpressionTests.swift`
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/Lexicon.swift`

**Interfaces:**

- Consumes: `EnglishNum2Word.convert`, existing lexicon number expansion, and the three supported symbol records.
- Produces: `EnglishCurrencyExpression.parse(_ source: String) -> EnglishCurrencyExpression?` and `EnglishCurrencyUnitForms`.

### 2.1 Define the semantic contract in tests

- [ ] Add parser tests for both sign positions, valid comma grouping, leading fractions, two-decimal unscaled values, scaled decimals, case-insensitive magnitudes, and punctuation termination.
- [ ] Add negative controls for malformed grouping, multiple decimal points, unsupported abbreviations, unsupported symbols, a bare symbol, and non-currency prose.

```swift
@Suite struct EnglishCurrencyExpressionTests {
  @Test(arguments: [
    ("$0", "zero dollars"),
    ("$1", "one dollar"),
    ("$2", "two dollars"),
    ("$1.00", "one dollar"),
    ("$1.01", "one dollar and one cent"),
    ("$0.50", "fifty cents"),
    ("£0.01", "one penny"),
    ("£0.02", "two pence"),
    ("€1.01", "one euro and one cent"),
    ("$5.5 million", "five point five million dollars"),
    ("$100 billion", "one hundred billion dollars"),
    ("£1.5 million", "one point five million pounds"),
    ("€2 trillion", "two trillion euros"),
    ("$2 BILLION", "two billion dollars"),
    ("-$2 billion", "minus two billion dollars"),
    ("$-2 billion", "minus two billion dollars"),
    ("$1,234.56", "one thousand, two hundred and thirty-four dollars and fifty-six cents"),
    ("$1.0 million", "one million dollars"),
    ("$5.50 million", "five point five million dollars"),
    ("$.5 million", "zero point five million dollars"),
  ])
  func supported(input: String, spoken: String) throws {
    let expression = try #require(EnglishCurrencyExpression.parse(input))
    #expect(expression.spokenForm == spoken)
  }

  @Test(arguments: [
    "$1,23", "$1.2.3", "$1.001", "$2 bn", "$2 quadrillion",
    "¥2", "$", "100 billion people",
  ])
  func unsupportedIsNotConsumed(input: String) {
    #expect(EnglishCurrencyExpression.parse(input) == nil)
  }
}
```

- [ ] Run the package suite through the slot.

Expected: compilation fails because `EnglishCurrencyExpression` does not exist.

### 2.2 Implement exact semantic value types

- [ ] Add these concrete types; keep parsing independent from token mutation.

```swift
struct EnglishCurrencyUnitForms: Equatable, Sendable {
  let majorSingular: String
  let majorPlural: String
  let minorSingular: String
  let minorPlural: String
}

struct EnglishCurrencyExpression: Equatable, Sendable {
  enum Magnitude: String, CaseIterable, Sendable {
    case thousand, million, billion, trillion
  }

  let source: String
  let symbol: Character
  let isNegative: Bool
  let integerDigits: String
  let fractionalDigits: String?
  let magnitude: Magnitude?
  let spokenForm: String

  static func parse(_ source: String) -> Self?
}
```

- [ ] Replace `Lexicon.currencies` tuple values with `EnglishCurrencyUnitForms` using the exact dollar/cent, pound/penny/pence, and euro/cent forms from the design.
- [ ] Validate comma groups as one to three leading digits followed by groups of exactly three; validate at most one decimal point and at least one digit overall.
- [ ] Parse digit strings directly into integer/fraction components; do not round-trip through `Double` or binary floating-point.
- [ ] For unscaled values with zero to two fractional digits, speak major/minor units with exact-one inflection and omit a zero major or minor component when the other is non-zero.
- [ ] For scaled values, normalize trailing fractional zeros, speak decimal digits with `point`, append the magnitude, and always use the plural major unit.
- [ ] Preserve the sign as a single leading `minus` regardless of whether it precedes the symbol or amount.
- [ ] Re-run the package suite.

Expected: parser tests and existing MisakiSwift tests pass.

### 2.3 Commit the isolated parser

```bash
git add ThirdParty/MisakiSwift/Sources/MisakiSwift/English/EnglishCurrencyExpression.swift ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/Lexicon.swift ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/EnglishCurrencyExpressionTests.swift
git commit -m "feat(narration): parse semantic currency expressions"
```

## Task 3: Integrate Currency Phrases Before Per-Token Phonemization

**Files:**

- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/EnglishG2P.swift`
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/DataStructures/MToken.swift`
- Modify: `ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/EnglishCurrencyExpressionTests.swift`
- Modify: `EchoTests/MisakiPronunciationMarkupTests.swift`

**Interfaces:**

- Consumes: `EnglishCurrencyExpression.parse(_:)` and mutable `MToken` metadata.
- Produces: `EnglishG2P.retokenize(_:)` output containing one alias-bearing token per valid complete currency source span; invalid spans are unchanged.

### 3.1 Add end-to-end red tests

- [ ] For every required spoken form, call `EnglishG2P.phonemizeWithMetadata` and compare the reconstructed spoken/token surface—not only whether a phoneme substring exists.
- [ ] Assert that `"Revenue was $100 billion."` preserves the period and yields a single semantic currency span before ordinary G2P.
- [ ] Assert malformed supported-symbol expressions preserve all source tokens and emit no empty letter-bearing token.
- [ ] Assert `"100 billion people"` receives no currency metadata.
- [ ] Run the MisakiSwift package suite and focused Echo markup suite through the slot.

Expected: `$100 billion` still orders the unit before the magnitude, and the new metadata assertions fail.

### 3.2 Replace the one-token pending-currency state

- [ ] Add optional `currencyExpressionSource` to `Underscore`, its initializer, copying initializer, and `mergeTokens` propagation.
- [ ] In `EnglishG2P.retokenize`, flatten the initial split tokens once, scan left-to-right for the supported grammar, and replace each accepted range with one `MToken` whose:
  - `text` is the exact source span;
  - `_.alias` is `EnglishCurrencyExpression.spokenForm`;
  - `_.currencyExpressionSource` is the exact source span;
  - `_.rating` is `4`;
  - whitespace and source range come from the consumed boundary tokens.
- [ ] Remove the old `var currency` / `canCarryPendingCurrency` path after the semantic scan is green.
- [ ] Keep rejected candidates untouched. A parser miss must never discard a symbol, sign, digit, magnitude, or punctuation token.
- [ ] Re-run both focused suites.

Expected: every supported phrase passes; all negative controls preserve speech; existing markup behavior remains green.

### 3.3 Commit

```bash
git add ThirdParty/MisakiSwift/Sources/MisakiSwift/English/EnglishG2P.swift ThirdParty/MisakiSwift/Sources/MisakiSwift/DataStructures/MToken.swift ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/EnglishCurrencyExpressionTests.swift EchoTests/MisakiPronunciationMarkupTests.swift
git commit -m "feat(narration): normalize complete currency phrases"
```

## Task 4: Add Currency Diagnostics and Invalidate Stale Narration

**Files:**

- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/KokoroG2P.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`
- Modify: `EchoTests/KokoroG2PTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`

**Interfaces:**

- Consumes: Misaki token metadata through `KokoroG2P.Result` and `NarrationFileNaming.renderVersion`.
- Produces: `.currencyNormalizationRejected` diagnostics and render identity version 21.

### 4.1 Write failing diagnostic and identity tests

- [ ] Add `currencyNormalizationRejected` to the expected diagnostic vocabulary and test that malformed `$1,23` remains voiced while producing that advisory.
- [ ] Test that a valid supported currency phrase produces no currency diagnostic.
- [ ] Change the file-naming test expectation from render version `20` to `21`.
- [ ] Run the three focused suites through the slot.

Expected: tests fail because the diagnostic and render version do not yet exist.

### 4.2 Implement the evidence and cache change

- [ ] Add `.currencyNormalizationRejected` to `PronunciationAuditDiagnostic.Reason`.
- [ ] Extend `KokoroG2P.Result` with a default-empty `[PronunciationAuditDiagnostic]` or a narrower currency-normalization diagnostic value that `PronunciationPlanner` converts into the audit type. Do not encode private text in logs.
- [ ] Emit the diagnostic only when a supported symbol begins a candidate expression and fail-closed parsing rejects it.
- [ ] Set `NarrationFileNaming.renderVersion = 21` and document the currency-byte change in the version history comment.
- [ ] Re-run all three suites.

Expected: focused tests pass; valid currency input is clean and malformed input remains audible plus advisory.

### 4.3 Run Stage 1 gates and real probes

- [ ] Run all MisakiSwift tests and the focused Echo acceptance suite.

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- swift test --package-path ThirdParty/MisakiSwift
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationProgramAcceptanceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

Expected: all pass.

- [ ] Use the built `echo-cli` G2P/narration probe path on a synthetic text containing `21`, `$1.01`, `$100 billion`, `£0.02`, `€2 trillion`, both minus positions, and malformed controls. Save only content-free command/result counts in the PR.
- [ ] Render a short synthetic reel with the primary voice and one control voice. Record rendered status separately from human listening; do not claim the spoken forms are accepted until listened to.

### 4.4 Commit and publish Stage 1

```bash
git add EchoCore/Services/Narration/PronunciationAudit.swift EchoCore/Services/Narration/KokoroG2P.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/PronunciationAuditTests.swift EchoTests/KokoroG2PTests.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "feat(narration): audit currency normalization and bump cache"
git status --short --branch
```

- [ ] Push the clean feature branch and open a ready PR to `nightly` titled `feat(narration): correct number and currency speech`.
- [ ] Report unit tests, CLI build, render, listening, hosted CI, merge, and device status separately.

---

# Stage 2 — Disagreement-Aware Advisory Review

## Task 5: Preserve Gold/Silver–CMUdict Disagreements in an Audit-Only Pack

**Files:**

- Create: `Tools/Pronunciation/build_pronunciation_audit_pack.py`
- Create: `Tools/Pronunciation/tests/test_build_pronunciation_audit_pack.py`
- Create: `EchoCore/Services/Narration/PronunciationResources/us_pronunciation_audit_pack.json`
- Create: `EchoCore/Services/Narration/EnglishPronunciationAuditPack.swift`
- Create: `EchoTests/EnglishPronunciationAuditPackTests.swift`
- Modify: `Makefile`
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**

- Consumes: pinned CMUdict/gold/silver JSON, Kokoro vocabulary, and existing pack normalization rules.
- Produces: reproducible audit-pack JSON and `EnglishPronunciationAuditPack.alternatives(for normalizedWord: String) -> [Candidate]` with no automatic-selection API.

### 5.1 Test the generator's safety boundary

- [ ] Add Python tests proving the generator retains only normalized spellings present in CMUdict and gold/silver whose normalized IPA sets actually differ.
- [ ] Assert identical-source candidates collapse deterministically, incompatible IPA is rejected, source/hash/license metadata is mandatory, output ordering is stable, and changing input changes `auditPackVersion`.
- [ ] Assert no audit candidate is marked automatic and no production `EnglishPronunciationPack` identity changes.

```python
def test_overlap_is_advisory_only(self):
    pack = build_audit_pack(cmu={"record": ["R EH1 K ER0 D"]},
                            gold={"record": "ɹɪkˈɔɹd"}, silver={})
    self.assertEqual(False, pack["entries"]["record"][0]["automaticEligible"])
    self.assertIn("auditPackVersion", pack)
```

- [ ] Run the new Python test and confirm it fails because the generator is absent.

### 5.2 Implement and generate reproducibly

- [ ] Reuse the normalization, ARPAbet conversion, Kokoro-vocabulary validation, strict JSON, and canonical hashing rules from `build_pronunciation_pack.py`; extract shared pure helpers to `Tools/Pronunciation/pronunciation_pack_common.py` only if both generators immediately use them.
- [ ] Emit schema `1`, semantic `auditPackVersion`, source snapshots, licenses, normalized digest, and entries of this shape:

```json
{
  "normalizedWord": "record",
  "candidates": [
    {
      "candidateID": "cmudict.record.<digest>",
      "ipa": "...",
      "sourceID": "cmudict",
      "authority": "uncertain",
      "validation": "shadow",
      "automaticEligible": false
    }
  ]
}
```

- [ ] Add `pronunciation-audit-pack` and `pronunciation-audit-pack-test` Make targets, with the same pinned inputs as the production pack.
- [ ] Generate and check in `us_pronunciation_audit_pack.json`; add it to the correct app/macOS/CLI resource-copy phases in `project.pbxproj`.
- [ ] Implement this read-only API with strict size, schema, digest, candidate, and vocabulary validation:

```swift
nonisolated struct EnglishPronunciationAuditPack: Equatable, Sendable {
    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let sourceID: String
        let authority: String
        let validation: String
        let automaticEligible: Bool
    }

    static let empty: EnglishPronunciationAuditPack
    static func bundledOrEmpty() async -> EnglishPronunciationAuditPack
    func alternatives(for normalizedWord: String) -> [Candidate]
}
```

- [ ] Expose no automatic-selection method and validate `authority == "uncertain"`, `validation == "shadow"`, and `automaticEligible == false` on every candidate.
- [ ] Explicitly test that `EnglishPronunciationPack.productionPolicySignature` is unchanged when the audit pack version changes.
- [ ] Run Python and focused Swift suites.

Expected: all pass and the audit pack is never consulted for automatic selection.

### 5.3 Commit

```bash
git add Tools/Pronunciation EchoCore/Services/Narration/PronunciationResources/us_pronunciation_audit_pack.json EchoCore/Services/Narration/EnglishPronunciationAuditPack.swift EchoTests/EnglishPronunciationAuditPackTests.swift Makefile Echo.xcodeproj/project.pbxproj THIRD_PARTY_NOTICES.md
git commit -m "feat(narration): retain audit-only pronunciation disagreements"
```

## Task 6: Extend the Existing Audit Spine with Versioned Alternatives

**Files:**

- Create: `EchoCore/Services/Narration/PronunciationAdvisoryEvidence.swift`
- Create: `EchoTests/PronunciationAdvisoryEvidenceTests.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`
- Modify: `EchoTests/PronunciationListeningReelTests.swift`

**Interfaces:**

- Consumes: existing `PronunciationDecisionSeed`, `PronunciationAuditDecision`, manifest schema 3/4 decoders, and reel builder.
- Produces: `PronunciationAdvisoryEvidence`, optional `advisoryEvidence` on seeds/decisions, and manifest schema 5.

### 6.1 Freeze schema 5 compatibility in red tests

- [ ] Add round-trip tests for lexical, contextual, and acoustic evidence; trusted/qualified/uncertain authority; eligible/shadow/rejected validation; alternatives; override suppression; policy identity; and selection/abstention reason.
- [ ] Assert schema 3 and 4 manifests decode with `advisoryEvidence == nil` and re-encode as schema 5.
- [ ] Assert unknown manifest schema versions remain rejected.
- [ ] Assert alternatives are deterministically sorted and duplicate candidate IDs/IPA pairs are rejected.
- [ ] Run the two focused suites through the slot.

Expected: compilation fails because advisory evidence and schema 5 do not exist.

### 6.2 Implement the evidence types

- [ ] Add these closed vocabularies and value types:

```swift
nonisolated struct PronunciationAdvisoryEvidence: Codable, Equatable, Sendable {
    enum Authority: String, Codable, Sendable { case trusted, qualified, uncertain }
    enum Category: String, Codable, Sendable { case lexical, contextual, acoustic }
    enum Validation: String, Codable, Sendable { case eligible, shadow, rejected }
    enum SelectionReason: String, Codable, Sendable {
        case occurrenceOverride, bookOverride, globalOverride
        case qualifiedDeterministicContext, trustedLexicon
        case qualifiedNeuralOOV, deterministicFallback
        case sourceDisagreement, shadowCandidate, invalidCandidate
        case modelUnavailable, modelIntegrityFailure, modelInferenceFailure
        case contextShadow, contextUnavailable
        case acousticRetryRejected
    }

    struct Alternative: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let source: String
        let authority: Authority
        let validation: Validation
        let policyVersion: String
    }

    let category: Category
    let selectedAuthority: Authority
    let selectedCandidateID: String?
    let alternatives: [Alternative]
    let selectionReason: SelectionReason
    let overrideSuppressedAutomation: Bool
    let policyVersion: String
}
```

- [ ] Add optional `advisoryEvidence` to `PronunciationDecisionSeed` and `PronunciationAuditDecision`, default it to `nil`, and preserve it through every copy/timing/slicing path.
- [ ] Set `PronunciationAuditManifest.currentSchemaVersion` to `5`; decode schema 3/4 with nil evidence and validate schema 5's exact closed vocabulary.
- [ ] Extend listening-reel entries with the same candidate IDs, category, authority, and audio ranges; avoid copying full source context into public receipts.
- [ ] Re-run the suites.

Expected: schema compatibility and evidence validation tests pass.

### 6.3 Commit

```bash
git add EchoCore/Services/Narration/PronunciationAdvisoryEvidence.swift EchoCore/Services/Narration/PronunciationAudit.swift EchoCore/Services/Narration/PronunciationListeningReel.swift EchoTests/PronunciationAdvisoryEvidenceTests.swift EchoTests/PronunciationAuditTests.swift EchoTests/PronunciationListeningReelTests.swift
git commit -m "feat(narration): add versioned pronunciation advisory evidence"
```

## Task 7: Materialize Candidate Advisories Without Changing Selection

**Files:**

- Create: `EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift`
- Create: `EchoTests/PronunciationCandidateAnalyzerTests.swift`
- Modify: `EchoCore/Services/Narration/NarrationPronunciationPreflight.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/NarrationPronunciationPreflightTests.swift`
- Modify: `EchoTests/PronunciationPlannerTests.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`

**Interfaces:**

- Consumes: selected `PronunciationDecisionSeed`, fallback hits, watch-word membership, production pack, and audit pack.
- Produces: `PronunciationCandidateAnalyzer.evidence(for:fallbackHits:isWatchWord:) -> PronunciationAdvisoryEvidence?` while leaving the selected seed unchanged.

### 7.1 Test authority and comparison scope

- [ ] Test that occurrence/book/global overrides remain selected and set `overrideSuppressedAutomation = true` when lower alternatives exist.
- [ ] Test that known lexicon disagreements produce advisory alternatives but never change selected IPA.
- [ ] Test comparison occurs for fallback/OOV, multi-pronunciation, source disagreement, contextual-family, acronym/proper-noun, empty/unsupported output, and watch words only.
- [ ] Test an ordinary unanimous known word yields no advisory evidence.
- [ ] Test headless and app planning receive byte-equivalent advisory evidence for the same synthetic source.
- [ ] Run all four focused suites and confirm missing analyzer failures.

### 7.2 Implement a pure analyzer

- [ ] Add a concrete analyzer with injected packs and no protocol:

```swift
nonisolated struct PronunciationCandidateAnalyzer: Sendable {
    let productionPack: EnglishPronunciationPack
    let auditPack: EnglishPronunciationAuditPack

    func evidence(
        for decision: PronunciationDecisionSeed,
        fallbackHits: [PronunciationFallbackHit],
        isWatchWord: Bool
    ) -> PronunciationAdvisoryEvidence?
}
```

- [ ] Deduplicate alternatives by normalized IPA, validate all alternatives through `KokoroPhonemeVocab`, and sort by source then candidate ID.
- [ ] Keep the selected seed unchanged. This task observes authority; it does not choose a lower-authority candidate.
- [ ] Extend `NarrationPronunciationCandidate.Reason` with `.sourceDisagreement`, `.multipleTrustedPronunciations`, `.contextualFamily`, and `.unsupportedPhonemes`.
- [ ] Add `pronunciationAuditPack: EnglishPronunciationAuditPack = .empty` to `NarrationService` construction, load the bundled audit pack alongside the production pack in `PlayerModel+Narration`, `NarrationQAReviewModel`, `MacBatchProcessingService`, and `HeadlessNarrationRunner`, then attach evidence to seeds before synthesis.
- [ ] Re-run the focused suites.

Expected: app and headless evidence match, while planned phonemes remain byte-for-byte unchanged.

### 7.3 Verify shadow identity and commit

- [ ] Add a cache test proving changes to `auditPackVersion` do not alter narration filenames or content signatures.
- [ ] Commit.

```bash
git add EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift EchoCore/Services/Narration/NarrationPronunciationPreflight.swift EchoCore/Services/Narration/PronunciationPlanner.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/ViewModels/NarrationQAReviewModel.swift 'Echo macOS/Services/MacBatchProcessingService.swift' EchoTests/PronunciationCandidateAnalyzerTests.swift EchoTests/NarrationPronunciationPreflightTests.swift EchoTests/PronunciationPlannerTests.swift EchoTests/NarrationServiceTests.swift EchoTests/HeadlessNarrationRunnerTests.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "feat(narration): surface shadow pronunciation alternatives"
```

## Task 8: Persist Advisory Origins Without Clobbering ASR Issues

**Files:**

- Create: `Shared/Database/Migrations/Schema_V40.swift`
- Create: `EchoTests/SchemaV40NarrationQualityEvidenceTests.swift`
- Create: `EchoCore/Services/Narration/PronunciationAdvisoryIssueBuilder.swift`
- Create: `EchoTests/PronunciationAdvisoryIssueBuilderTests.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Modify: `Shared/Database/NarrationQualityIssueRecord.swift`
- Modify: `Shared/Database/DAOs/NarrationQualityIssueDAO.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/QA/NarrationQAService.swift`
- Modify: `EchoTests/NarrationQualityIssueDAOTests.swift`
- Modify: `EchoTests/NarrationQAServiceTests.swift`

**Interfaces:**

- Consumes: schema V39, `PronunciationAdvisoryEvidence`, and existing `NarrationQualityIssueRecord`/DAO behavior.
- Produces: schema V40, `NarrationQualityIssueOrigin`, origin-scoped `replaceOpen(for:blockIDs:origin:with:)`, and stable advisory issue rows.

### 8.1 Write migration and DAO collision tests

- [ ] Test migration from a real V39 database: existing rows become origin `asr`, `evidence_json` is nil, and indexes exist.
- [ ] Test `replaceOpen` deletes only rows matching audiobook, block set, status `open`, and requested origin.
- [ ] Test an ASR refresh preserves pronunciation-preflight and acoustic issues, and vice versa.
- [ ] Run focused tests through the slot; expect failures for missing columns/API.

### 8.2 Add the additive schema

- [ ] Add V40 columns and an origin-aware index:

```swift
enum NarrationQualityIssueOrigin: String, Codable, Sendable {
    case asr
    case pronunciationPreflight
    case acoustic
}
```

```sql
ALTER TABLE narration_quality_issue ADD COLUMN origin TEXT NOT NULL DEFAULT 'asr';
ALTER TABLE narration_quality_issue ADD COLUMN evidence_json TEXT;
CREATE INDEX idx_narration_quality_issue_book_origin_status
ON narration_quality_issue(audiobook_id, origin, status);
```

- [ ] Add `origin: String` and `evidenceJSON: String?` to `NarrationQualityIssueRecord` and its coding keys, defaulting source initializers to `NarrationQualityIssueOrigin.asr.rawValue` where that preserves existing call sites.
- [ ] Change the DAO API to `replaceOpen(for:blockIDs:origin:with:)` and require every inserted record to match the supplied origin.
- [ ] Update `NarrationQAService` to pass `.asr`.
- [ ] Re-run migration, DAO, and QA suites.

Expected: all pass; issue lanes no longer delete each other.

### 8.3 Build preflight issue rows

- [ ] Implement this pure mapping API:

```swift
nonisolated struct PronunciationAdvisoryIssueBuilder: Sendable {
    func records(
        audiobookID: String,
        decisions: [PronunciationAuditDecision],
        diagnostics: [PronunciationAuditDiagnostic],
        createdAt: String
    ) -> [NarrationQualityIssueRecord]
}
```

- [ ] Group non-contextual rows by normalized spelling plus selected candidate and keep contextual rows separate by block/word range and selected sense.
- [ ] Put the accepted candidate only in `suggestedFixJSON`; encode full `PronunciationAdvisoryEvidence` in `evidenceJSON`.
- [ ] Give every row stable content-derived identity, source word ranges, category-specific origin, and non-blocking `open` status.
- [ ] Add tests for grouping, contextual separation, stable IDs, evidence round trips, and no private metadata fields.
- [ ] Integrate the builder in `NarrationService` after preflight/audit materialization and call the origin-scoped DAO replacement. If DB materialization fails, keep the render and surface a report-write operational error.
- [ ] Re-run focused tests.

### 8.4 Commit

```bash
git add Shared/Database/Migrations/Schema_V40.swift Shared/Database/DatabaseService.swift Shared/Database/NarrationQualityIssueRecord.swift Shared/Database/DAOs/NarrationQualityIssueDAO.swift EchoCore/Services/Narration/PronunciationAdvisoryIssueBuilder.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/Narration/QA/NarrationQAService.swift EchoTests/SchemaV40NarrationQualityEvidenceTests.swift EchoTests/PronunciationAdvisoryIssueBuilderTests.swift EchoTests/NarrationQualityIssueDAOTests.swift EchoTests/NarrationQAServiceTests.swift
git commit -m "feat(narration): persist origin-scoped pronunciation advisories"
```

## Task 9: Expose the Same Non-Blocking Review on iOS and macOS

**Files:**

- Modify: `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify: `EchoCore/Views/Narration/NarrationQAReviewView.swift`
- Modify: `Echo macOS/Views/MacNarrationQAReviewView.swift`
- Modify: `EchoCore/Views/BookSettingsView.swift`
- Modify: `EchoTests/NarrationQAReviewModelTests.swift`

**Interfaces:**

- Consumes: V40 issue rows, `SuggestedFix`, `PronunciationAdvisoryEvidence`, and `acceptFix(issue:scope:)`.
- Produces: `pronunciationPresentation(for:)` and `acceptCandidate(_:for:scope:)`, rendered consistently by the existing iOS/macOS QA views.

### 9.1 Test view-model behavior first

- [ ] Add a decoded presentation value that exposes category, selected IPA, alternatives, source, authority, validation, occurrence count, and chosen candidate ID.
- [ ] Test selecting an eligible alternative changes only the `SuggestedFix` passed to the existing `acceptFix(issue:scope:)` path.
- [ ] Test shadow/rejected alternatives are visible but cannot be accepted without explicitly entering IPA through the existing correction flow.
- [ ] Test load/run failures leave prior issues visible and show a non-blocking error.
- [ ] Run `NarrationQAReviewModelTests`; expect missing presentation/selection failures.

### 9.2 Implement shared presentation state

- [ ] Add to `NarrationQAReviewModel`:

```swift
struct PronunciationReviewPresentation: Identifiable, Equatable {
    let id: String
    let category: PronunciationAdvisoryEvidence.Category
    let selectedIPA: String
    let alternatives: [PronunciationAdvisoryEvidence.Alternative]
    let occurrenceCount: Int
    var chosenCandidateID: String?
}

func pronunciationPresentation(for issue: NarrationQualityIssueRecord)
    -> PronunciationReviewPresentation?
func acceptCandidate(
    _ candidateID: String,
    for issue: NarrationQualityIssueRecord,
    scope: FixScope
) async
```

- [ ] Decode advisory evidence fail-closed; malformed evidence remains a normal QA row without candidate controls.
- [ ] Reuse `acceptFix` so occurrence/book/global override semantics remain authoritative.

### 9.3 Update both platform views

- [ ] Add a `Pronunciation review available` state in the existing Book Settings narration section when open pronunciation-preflight/acoustic issues exist.
- [ ] On iOS, show selected IPA/source and alternatives in the existing QA row/dialog; retain occurrence, book, and all-books scope choices.
- [ ] On macOS, show the same evidence and candidate picker; extend `Save Override` to occurrence/book/global scope rather than hard-coding book scope.
- [ ] Mark acoustic rows distinctly and do not offer a lexical override unless an explicit lexical candidate exists.
- [ ] Preserve VoiceOver labels, Dynamic Type, keyboard focus, and current swipe/button actions.
- [ ] Re-run the model suite and focused app tests.

Expected: both surfaces present the same evidence and all accepted corrections use existing override storage.

### 9.4 Stage 2 gates, commit, and publish

```bash
make pronunciation-audit-pack-test
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PronunciationAuditTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationQAReviewModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

- [ ] Confirm an identical synthetic disagreement appears in iOS/macOS model data, headless audit manifest, and listening reel with no synthesis/cache change.
- [ ] Commit UI/model changes.

```bash
git add EchoCore/ViewModels/NarrationQAReviewModel.swift EchoCore/Views/Narration/NarrationQAReviewView.swift 'Echo macOS/Views/MacNarrationQAReviewView.swift' EchoCore/Views/BookSettingsView.swift EchoTests/NarrationQAReviewModelTests.swift
git commit -m "feat(narration): review pronunciation advisories across platforms"
git status --short --branch
```

- [ ] Push and open the Stage 2 ready PR to `nightly`; report UI tests as distinct from simulator/device visual acceptance.

---

# Stage 3 — Neural OOV Shadow Evaluation

## Task 10: Pin Model Provenance and Fetch Reproducibly

**Files:**

- Create: `Tools/Pronunciation/mini_bart_g2p.lock.json`
- Create: `Tools/Pronunciation/fetch_mini_bart_g2p.py`
- Create: `Tools/Pronunciation/tests/test_fetch_mini_bart_g2p.py`
- Create: `docs/reports/mini-bart-g2p-provenance.md`
- Modify: `THIRD_PARTY_NOTICES.md` only after the license gate passes
- Modify: `Makefile`

**Interfaces:**

- Consumes: immutable HTTPS artifact URLs and caller-supplied destination paths.
- Produces: `mini_bart_g2p.lock.json`, `fetch_mini_bart_g2p.py fetch|check`, and a binary bundling verdict in the provenance report.

### 10.1 Freeze the immutable artifact contract

- [ ] Add tests that reject moving revisions, HTTP URLs, missing license files, size mismatch, hash mismatch, path traversal, symlinks, and output inside unrelated repository/worktree roots.
- [ ] Pin revision `f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06` from [jonschneider/mini-bart-g2p](https://huggingface.co/jonschneider/mini-bart-g2p/tree/f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06) and these artifacts:
  - `onnx/encoder_model.onnx`: 6,634,844 bytes, SHA-256 `5df81746fe1872b63aa120205ce267ed44163b7894a54e931a1d4b4b09568faa`;
  - `onnx/decoder_model.onnx`: 9,999,491 bytes, SHA-256 `2c199ceaa241186259167a8e79c5ff3498609ee8fc01c28c8a3d76a351d33c3d`;
  - `tokenizer.json`: 3,212 bytes, SHA-256 `40193885f8093d3bf59dfc199db502cfa8618b24bfcb2d08aa5f8d538bc34495`;
  - `config.json`: 1,066 bytes, SHA-256 `d647577ad51cacdab20f82c479ab8fd75ae569edba480475ca6c732881256415`;
  - `generation_config.json`: 182 bytes, SHA-256 `f36f1cb8f814ff32f744ced2e00610ce37de166d5a21bd92050972e220fa0449`;
  - `LICENSE`: 11,356 bytes, SHA-256 `43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1`.
- [ ] Run the Python test and confirm the fetch tool is missing.

### 10.2 Implement fetch and license review gates

- [ ] Implement standard-library HTTPS download to a caller-supplied temporary directory, stream hashing, exact-size checks, atomic rename, and a `check` command that performs no network work.
- [ ] Add `neural-g2p-fetch-test` and `neural-g2p-fetch` Make targets. The fetch target must require an explicit destination and never write into app resources implicitly.
- [ ] Write `docs/reports/mini-bart-g2p-provenance.md` with upstream model license, training-data sources (LibriSpeech alignments and CMUdict), each source license, revision, artifact hashes/sizes, tokenizer contract, attribution, reviewer, date, and verdict `COMPATIBLE_FOR_BUNDLING` or `DEVELOPMENT_ONLY`.
- [ ] If any model/data license is incompatible or unverifiable, do not add model bytes or a production resource. Record `DEVELOPMENT_ONLY`, keep all later runtime selection disabled, and continue with any legally allowed offline evaluation.
- [ ] If compatible, add exact notices to `THIRD_PARTY_NOTICES.md`.
- [ ] Run the fetch tests and an offline `check` against fetched files.

Expected: hashes and sizes match the immutable lock; the report gives a truthful gate verdict.

### 10.3 Commit provenance before runtime code

```bash
git add Tools/Pronunciation/mini_bart_g2p.lock.json Tools/Pronunciation/fetch_mini_bart_g2p.py Tools/Pronunciation/tests/test_fetch_mini_bart_g2p.py docs/reports/mini-bart-g2p-provenance.md Makefile THIRD_PARTY_NOTICES.md
git commit -m "build(narration): pin neural G2P provenance"
```

## Task 11: Implement the Mini-BART Tokenizer and ARPAbet Conversion

**Files:**

- Create: `EchoCore/Services/Narration/NeuralG2P/MiniBARTG2PTokenizer.swift`
- Create: `EchoCore/Services/Narration/NeuralG2P/ARPAbetToKokoroIPA.swift`
- Create: `EchoTests/MiniBARTG2PTokenizerTests.swift`
- Create: `EchoTests/ARPAbetToKokoroIPATests.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` when compatible bundled tokenizer/config resources are admitted

**Interfaces:**

- Consumes: locked Mini-BART `tokenizer.json` and decoded output token IDs.
- Produces: `MiniBARTG2PTokenizer.encode/decodeOutput` and `ARPAbetToKokoroIPA.convert(_:) -> String` with versioned conversion identity.

### 11.1 Add deterministic red vectors

- [ ] Copy a small public/synthetic set of tokenizer input/output IDs and ARPAbet/model-output strings into tests; include apostrophe, hyphen, capitalization, punctuation stripping, unknown characters, stress digits, and unmappable tokens.
- [ ] Pin the exact input envelope: lowercase accepted word characters, BOS ID `0`, EOS ID `2`, pad ID `1`, and character-token WordLevel vocabulary from the locked tokenizer.
- [ ] Pin conversion output against the same ARPAbet mapping semantics used by the pronunciation pack generator.
- [ ] Run the focused tests; expect missing types.

### 11.2 Implement pure, Sendable conversion

- [ ] Add:

```swift
nonisolated struct MiniBARTG2PTokenizer: Sendable {
    let vocabularyVersion: String
    init(data: Data) throws
    func encode(word: String) throws -> [Int64]
    func decodeOutput(ids: [Int64]) throws -> [String]
}

nonisolated enum ARPAbetToKokoroIPA {
    static let policyVersion = "mini-bart-arpabet-to-kokoro-v1"
    static func convert(_ tokens: [String]) throws -> String
}
```

- [ ] Reject sentence input, unsupported characters, empty tokens, duplicate vocab IDs, unknown output IDs, malformed stress, and any final IPA rejected by `KokoroPhonemeVocab.validatedIDs`.
- [ ] Keep this code independent of ONNX so corpus and decoder tests remain fast.
- [ ] Re-run focused suites.

Expected: all pure tokenization/conversion tests pass deterministically.

### 11.3 Commit

```bash
git add EchoCore/Services/Narration/NeuralG2P/MiniBARTG2PTokenizer.swift EchoCore/Services/Narration/NeuralG2P/ARPAbetToKokoroIPA.swift EchoTests/MiniBARTG2PTokenizerTests.swift EchoTests/ARPAbetToKokoroIPATests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(narration): add deterministic neural G2P conversion"
```

## Task 12: Add a Cached CPU ONNX Evaluator in Shadow Mode

**Files:**

- Create: `EchoCore/Services/Narration/NeuralG2P/MiniBARTG2PEngine.swift`
- Create: `EchoCore/Services/Narration/NeuralG2P/NeuralG2PTypes.swift`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/encoder_model.onnx`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/decoder_model.onnx`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/tokenizer.json`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/config.json`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/generation_config.json`
- Create only after the Task 10 bundling verdict is `COMPATIBLE_FOR_BUNDLING`: `EchoCore/Services/Narration/NeuralG2PResources/LICENSE`
- Create: `EchoTests/MiniBARTG2PEngineTests.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` only when compatible model resources are bundled

**Interfaces:**

- Consumes: Mini-BART tokenizer/conversion, locked encoder/decoder resources, and ONNX Runtime CPU bindings.
- Produces: actor-confined `MiniBARTG2PEngine.evaluate(word:) async throws -> NeuralG2PShadowResult` and `unload()`.

### 12.1 Define lifecycle and failure tests with injected inference

- [ ] Test one cached environment plus encoder/decoder sessions across many words, cancellation before and between decode steps, unload/relaunch, corrupted/missing resources, malformed tensor shapes, empty output, unsupported IPA, stable repeat output, and no session-per-word creation.
- [ ] Test deterministic beam width `5`, maximum output length `20`, lexical ordering as the final tie-breaker, and policy ID `mini-bart-g2p-beam5-max20-v1`.
- [ ] Test every failure returns a categorized advisory result and never an automatically selected pronunciation.
- [ ] Run the focused suite; expect missing engine/types.

### 12.2 Implement typed shadow results

- [ ] Add:

```swift
nonisolated struct NeuralG2PCandidate: Codable, Equatable, Sendable {
    let candidateID: String
    let ipa: String
    let modelRevision: String
    let conversionPolicyVersion: String
    let validationPolicyVersion: String
    let selectionPolicyVersion: String
}

nonisolated enum NeuralG2PFailure: String, Codable, Sendable {
    case unavailable, integrity, tokenization, inference, decoding
    case emptyOutput, unsupportedOutput, cancelled
}

nonisolated enum NeuralG2PShadowResult: Equatable, Sendable {
    case candidate(NeuralG2PCandidate)
    case rejected(NeuralG2PFailure)
}

actor MiniBARTG2PEngine {
    static let shared = MiniBARTG2PEngine()
    func evaluate(word: String) async throws -> NeuralG2PShadowResult
    func unload()
}
```

- [ ] Implement `actor MiniBARTG2PEngine` with `static let shared`, cached `ORTEnv`, encoder session, decoder session, generation-checked unload, CPU-only optimized session options, and shrink-arena run options following `OnnxKokoroEngine`. Tests construct isolated injected instances; live app/CLI paths use `shared` so a process never creates one session pair per word.
- [ ] Build tensors for encoder `input_ids`/`attention_mask` and decoder `input_ids`/`encoder_attention_mask`/`encoder_hidden_states`; read `logits`; perform stable beam decoding; check cancellation each decode iteration.
- [ ] Resolve only bundled, lock-verified files through `NarrationResources`. If the provenance verdict is not compatible, compile the pure evaluator/test seams but make live resource resolution return `.unavailable`.
- [ ] When the verdict is compatible, use `fetch_mini_bart_g2p.py fetch` to a temporary directory, verify it with `check`, copy the six exact locked artifacts into `NeuralG2PResources`, and add all six to app/macOS/CLI resource-copy phases. Do not download them from runtime code.
- [ ] Re-run focused tests and a compatible-artifact smoke test when bytes are admitted.

Expected: lifecycle tests pass; no production planner calls the evaluator yet.

### 12.3 Commit

```bash
git add EchoCore/Services/Narration/NeuralG2P EchoCore/Services/Narration/NeuralG2PResources EchoTests/MiniBARTG2PEngineTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(narration): evaluate neural OOV candidates in shadow"
```

If Task 10 says `DEVELOPMENT_ONLY`, omit `NeuralG2PResources` and `project.pbxproj` from `git add`; commit the evaluator, injected tests, and unavailable live resolver only.

## Task 13: Build the OOV Qualification Corpus and Receipt Tooling

**Files:**

- Create: `Tools/Pronunciation/neural_g2p_qualification.py`
- Create: `Tools/Pronunciation/tests/test_neural_g2p_qualification.py`
- Create: `EchoTests/Fixtures/Pronunciation/neural_oov_candidates_v1.jsonl`
- Create: `docs/reports/neural-g2p-qualification.md`
- Modify: `Makefile`

**Interfaces:**

- Consumes: public/synthetic JSONL cases plus absolute external trusted-receipt and human-authority files.
- Produces: `neural_g2p_qualification.py validate|qualification-status|report` and a content-free `WAITING_FOR_HUMAN_LABELS`, `FAILED`, or `QUALIFIED` receipt.

### 13.1 Test the gate mathematically

- [ ] Add tests for at least 500 independently reviewed qualifying rows, at least 75 in each required category, exact automatic precision ≥99%, 95% Wilson lower bound ≥98%, zero invalid output, stable repetition, and category/case uniqueness.
- [ ] Reuse the existing external trusted-receipt and human-evidence-authority pattern from `pronunciation_corpus.py`; reject repository-contained, symlinked, hardlinked, changing, or mismatched receipt files.
- [ ] Test separate `WAITING_FOR_HUMAN_LABELS`, `FAILED`, and `QUALIFIED` results.
- [ ] Test that provisional rows never count, even when model output matches their provisional expected value.
- [ ] Run the Python suite; expect missing module.

### 13.2 Implement qualification and fixtures

- [ ] Define categories exactly as `proper-noun`, `technical`, `morphology`, `loanword`, and `adversarial`.
- [ ] Store only public-domain, permissive, or synthetic source context in committed fixtures. Add candidates as `provisional`; leave human evidence fields absent.
- [ ] Compute precision and Wilson bounds from the complete selection policy, not raw model top-1 output. Reject duplicate, empty, unmappable, unstable, and Kokoro-incompatible outputs before scoring.
- [ ] Emit a content-free JSON receipt with corpus hash, category counts, model/hash identities, conversion/validation/selection versions, precision, Wilson bound, invalid counts, and status.
- [ ] Add `neural-g2p-qualification-test` and `neural-g2p-qualification` Make targets. The qualification target accepts explicit absolute external receipt/authority paths; without them it truthfully reports waiting.
- [ ] Generate `docs/reports/neural-g2p-qualification.md` from the receipt plus separately recorded performance/device proof states.
- [ ] Run the Python suite and waiting-state command.

Expected: contracts pass; status remains `WAITING_FOR_HUMAN_LABELS` until qualifying external evidence exists.

### 13.3 Commit

```bash
git add Tools/Pronunciation/neural_g2p_qualification.py Tools/Pronunciation/tests/test_neural_g2p_qualification.py EchoTests/Fixtures/Pronunciation/neural_oov_candidates_v1.jsonl docs/reports/neural-g2p-qualification.md Makefile
git commit -m "test(narration): define neural OOV qualification gates"
```

## Task 14: Wire Shadow Evaluation and Measure the Full Gate

**Files:**

- Modify: `EchoCore/Services/Narration/NarrationPronunciationPreflight.swift`
- Modify: `EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/NarrationPronunciationPreflightTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Modify: `docs/reports/neural-g2p-qualification.md`

**Interfaces:**

- Consumes: `MiniBARTG2PEngine.evaluate(word:)`, comparison-scope candidates, and existing deterministic decisions.
- Produces: shadow `PronunciationAdvisoryEvidence` on app/headless decisions plus measured qualification proof; selected pronunciation remains unchanged.

### 14.1 Add shadow-only integration tests

- [ ] Test only comparison-scope words invoke the neural evaluator; ordinary known words do not.
- [ ] Test OOV output is recorded as `authority: uncertain`, `validation: shadow`, while deterministic fallback remains selected.
- [ ] Test model absence, integrity failure, cancellation, invalid output, and inference failure preserve deterministic narration and categorical evidence.
- [ ] Test chapter cancellation propagates rather than being converted into a successful fallback render.
- [ ] Test shadow results do not change cache identity.
- [ ] Run focused suites; expect missing integration.

### 14.2 Integrate off-main preflight

- [ ] Add `typealias NeuralEvaluator = @Sendable (String) async throws -> NeuralG2PShadowResult` and an injected evaluator to `NarrationService` with a deterministic-disabled default for tests. Live constructors pass `{ word in try await MiniBARTG2PEngine.shared.evaluate(word: word) }`; do not instantiate an engine per word.
- [ ] Batch unique normalized OOV words, check cancellation between words, and attach results to `PronunciationAdvisoryEvidence.alternatives` without changing selected seeds.
- [ ] Continue rendering while non-cancellation model failures become advisories.
- [ ] Re-run focused suites.

Expected: all integration tests pass and selected IPA remains the deterministic fallback.

### 14.3 Run measurable qualification lanes

- [ ] On the oldest supported physical iPhone, measure added peak RSS (≤64 MB), cold preflight (≤2 seconds/book), sustained preflight (≤5% of Kokoro render time for the same source), cancellation, relaunch, foreground, lock-screen, and background behavior.
- [ ] Render human-listening probes with the primary and one control voice; record render completion separately from listening verdicts.
- [ ] Run stable repeated model/policy output checks over the full public/synthetic candidate corpus.
- [ ] Update the qualification report with exact measured device/OS/app SHA, model/policy IDs, proof state per gate, and no private source content.
- [ ] Do not mark Stage 3 qualified unless corpus, validity, performance, device, render, and human-listening gates all pass.

### 14.4 Commit and publish Stage 3

```bash
git add EchoCore/Services/Narration/NarrationPronunciationPreflight.swift EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/ViewModels/NarrationQAReviewModel.swift 'Echo macOS/Services/MacBatchProcessingService.swift' EchoTests/NarrationPronunciationPreflightTests.swift EchoTests/HeadlessNarrationRunnerTests.swift docs/reports/neural-g2p-qualification.md
git commit -m "feat(narration): collect neural OOV shadow evidence"
git status --short --branch
```

- [ ] Push and open the Stage 3 ready PR to `nightly`, even if the truthful result is shadow-only. The PR must not claim production authority.

---

# Stage 4 — Qualified Neural OOV Activation

## Task 15: Create a Fail-Closed Production Qualification Record

**Precondition:** The Stage 3 receipt says `QUALIFIED` for every required gate. If it says waiting or failed, complete this task's disabled-state tests and receipt path, leave production selection disabled, and skip Task 16's activating branch.

**Files:**

- Create: `EchoCore/Services/Narration/NeuralG2P/NeuralG2PQualification.swift`
- Create: `EchoCore/Services/Narration/NeuralG2PResources/qualification.json` only for a fully qualified artifact
- Create: `EchoTests/NeuralG2PQualificationTests.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` only for a qualified resource

**Interfaces:**

- Consumes: a fully passing Stage 3 content-free qualification receipt and exact bundled resource identities.
- Produces: `NeuralG2PQualification` or nil; nil is the complete disabled production state.

### 15.1 Test qualification binding

- [ ] Test default/missing/corrupt/unknown qualification data is disabled.
- [ ] Test the record binds exact model revision and hashes, tokenizer version, conversion version, validation version, selection version, corpus digest, performance/device receipts, and status `qualified`.
- [ ] Test any one-byte or identity mismatch disables authority.
- [ ] Run focused tests; expect missing type.

### 15.2 Implement strict loading

- [ ] Add:

```swift
nonisolated struct NeuralG2PQualification: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case qualified }
    let status: Status
    let modelRevision: String
    let encoderSHA256: String
    let decoderSHA256: String
    let tokenizerVersion: String
    let conversionPolicyVersion: String
    let validationPolicyVersion: String
    let selectionPolicyVersion: String
    let corpusSHA256: String
    let receiptSHA256: String
    var productionPolicySignature: String { get }
}
```

- [ ] Validate strict schema, exact keys, hashes, resource integrity, and current code policy constants. Return `nil` on any mismatch.
- [ ] Generate/bundle `qualification.json` only from a fully passing signed-off receipt; otherwise keep the live loader nil and document shadow-only status.
- [ ] Re-run focused tests.

Expected: qualified fixtures load; every mismatch fails closed.

### 15.3 Commit qualification state

```bash
git add EchoCore/Services/Narration/NeuralG2P/NeuralG2PQualification.swift EchoCore/Services/Narration/NeuralG2PResources/qualification.json EchoTests/NeuralG2PQualificationTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(narration): bind neural G2P production qualification"
```

If no qualification resource exists, omit that path from `git add` and use commit message `test(narration): fail closed without neural G2P qualification`.

## Task 16: Activate Only Eligible OOV Decisions

**Files:**

- Modify: `EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoCore/Services/Narration/EnglishPronunciationPack.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoTests/PronunciationCandidateAnalyzerTests.swift`
- Modify: `EchoTests/PronunciationPlannerTests.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`
- Modify: `EchoTests/PronunciationProgramAcceptanceTests.swift`

**Interfaces:**

- Consumes: `NeuralG2PQualification`, eligible `NeuralG2PCandidate`, and existing planner precedence.
- Produces: `.neuralOOV` selected decisions and a production policy signature only when exact qualification is active.

### 16.1 Write precedence and failure tests

- [ ] Test neural selection is eligible only when the production pack and Misaki lexicons have no entry, no contextual family owns the spelling, no override applies, the exact qualification loads, and candidate validation succeeds.
- [ ] Test occurrence/book/global overrides, trusted lexicon, and qualified contextual rules always win.
- [ ] Test known-word disagreements remain advisory even when neural output agrees with one source.
- [ ] Test load/inference/validation/cancellation behavior preserves the existing deterministic safety net as specified.
- [ ] Test selected neural evidence becomes `authority: qualified`, `validation: eligible`, with exact model/policy identity.
- [ ] Run focused suites; expect the qualified candidate still remains shadow-only.

### 16.2 Implement the narrow activation

- [ ] Add a single selection branch after trusted lexicon resolution and before deterministic fallback. Require a non-nil matching `NeuralG2PQualification`.
- [ ] Add `.neuralOOV` to `PronunciationAuditDecision.Source`, carry it through schema 5 validation, and permit it only when candidate/model/conversion/validation/selection qualification identities are all present and matching.
- [ ] Carry the selected candidate ID/model/policy versions through `PronunciationDecisionSeed` and `PronunciationAuditDecision`.
- [ ] Include `NeuralG2PQualification.productionPolicySignature` in `EnglishPronunciationPack.productionPolicySignature` only when authority is enabled.
- [ ] Increment `NarrationFileNaming.renderVersion` from `21` to `22` only in the qualified activation change because final phoneme bytes can differ.
- [ ] If Task 15 remains disabled, assert render version stays `21` and no shadow identity enters the signature.
- [ ] Re-run focused suites.

Expected: qualified OOV fixtures select neural IPA; every other word and failure path preserves prior precedence.

### 16.3 Full gate, commit, and publish

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
make neural-g2p-qualification
```

- [ ] Re-run real OOV renders and primary/control human listening on the exact release SHA. Re-run physical-device background/cancellation/relaunch evidence because activation changes production behavior.
- [ ] Commit only if all activation gates remain passing.

```bash
git add EchoCore/Services/Narration/PronunciationCandidateAnalyzer.swift EchoCore/Services/Narration/PronunciationPlanner.swift EchoCore/Services/Narration/PronunciationAudit.swift EchoCore/Services/Narration/EnglishPronunciationPack.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/PronunciationCandidateAnalyzerTests.swift EchoTests/PronunciationPlannerTests.swift EchoTests/PronunciationAuditTests.swift EchoTests/NarrationFileNamingTests.swift EchoTests/PronunciationProgramAcceptanceTests.swift
git commit -m "feat(narration): activate qualified neural OOV selection"
git status --short --branch
```

- [ ] Push and open a ready PR only when qualified. When not qualified, publish the Stage 3 shadow receipt instead and record Stage 4 as `NOT_ACTIVATED`.

---

# Stage 5 — Independent Contextual-Family Graduation

## Task 17: Extend Qualification Tooling to Per-Family Production Gates

**Files:**

- Modify: `Tools/Pronunciation/pronunciation_corpus.py`
- Modify: `Tools/Pronunciation/tests/test_pronunciation_corpus.py`
- Create: `docs/reports/contextual-pronunciation-qualification.md`
- Modify: `Makefile`

**Interfaces:**

- Consumes: existing contextual fixtures, external trusted labels, and content-free runtime/listening receipts.
- Produces: `pronunciation_corpus.py production-qualification` with one `GRADUATED` or `SHADOW` result per family.

### 17.1 Add family-by-family gate tests

- [ ] Test each of `content`, `read`, `live`/`lives`, and `record` independently requires ≥200 trusted human-labelled cases, ≥50 per sense, 100% named/negative regression correctness, ≥99% held-out precision, Wilson lower bound ≥98%, ≥95% overall coverage, ≥90% per-sense coverage, zero invalid/duplicate/unsupported output, stable qualified-runtime repeats, and separate human-listening proof.
- [ ] Test one failed family does not change another family's result.
- [ ] Test provisional/model/machine-judge labels never count.
- [ ] Test unknown runtime family and missing external receipt produce `SHADOW`, not graduation.
- [ ] Run Python tests and confirm current tool lacks these complete family metrics.

### 17.2 Implement the qualification report

- [ ] Add a `production-qualification` command that consumes the existing validated fixtures plus external trusted receipts/authority and a content-free runtime/listening receipt.
- [ ] Emit one closed result per family: `GRADUATED` or `SHADOW`, with corpus/runtime/prompt/candidate pack hashes and every threshold value.
- [ ] Keep `qualification-status` backward compatible for the existing Phase 2 report.
- [ ] Add `pronunciation-context-qualification` Make target and generate the Markdown report from its JSON result.
- [ ] Run the Python suite and current evidence.

Expected: tooling passes; families without enough trusted evidence truthfully remain shadow.

### 17.3 Commit

```bash
git add Tools/Pronunciation/pronunciation_corpus.py Tools/Pronunciation/tests/test_pronunciation_corpus.py docs/reports/contextual-pronunciation-qualification.md Makefile
git commit -m "test(narration): qualify contextual families independently"
```

## Task 18: Bind Graduated Families to Runtime Selection and Cache Identity

**Files:**

- Create: `EchoCore/Services/Narration/ContextualPronunciationQualification.swift`
- Create: `EchoCore/Services/Narration/PronunciationResources/contextual_pronunciation_qualification.json` containing only families with complete passing receipts
- Create: `EchoTests/ContextualPronunciationQualificationTests.swift`
- Modify: `EchoCore/Services/Narration/ContextualPronunciationTypes.swift`
- Modify: `EchoCore/Services/Narration/ContextualPronunciationFamilies.swift`
- Modify: `EchoCore/Services/Narration/ContextualPronunciationPreflight.swift`
- Modify: `EchoCore/Services/Narration/PronunciationPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoTests/ContextualPronunciationFamiliesTests.swift`
- Modify: `EchoTests/ContextualPronunciationPreflightTests.swift`
- Modify: `EchoTests/PronunciationPlannerTests.swift`
- Modify: `EchoTests/NarrationFileNamingTests.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` when at least one family qualification resource is bundled

**Interfaces:**

- Consumes: per-family production qualification JSON and existing candidate/prompt/runtime identities.
- Produces: `ContextualPronunciationQualification` lookup, independently derived `ContextualFamilyState`, and graduated-family-only cache signatures.

### 18.1 Add production-authority red tests

- [ ] Test family state comes from a strict qualification record, not a hard-coded `.graduated` literal.
- [ ] Test only an exact candidate pack, prompt schema, runtime family ID, OS build policy, corpus receipt, and family ID can graduate.
- [ ] Test unknown runtime, malformed output, abstention, unavailable model, low-confidence/review outcome, and record mismatch preserve deterministic authority plus advisory evidence.
- [ ] Test a qualified family can select only one of its existing opaque candidate IDs; IPA never comes from the model.
- [ ] Test a graduated family's production identity changes cache keys while every shadow family is excluded.
- [ ] Run focused suites; expect missing qualification binding.

### 18.2 Implement independent family state

- [ ] Add this strict qualification record and loader:

```swift
nonisolated struct ContextualPronunciationQualification: Codable, Equatable, Sendable {
    struct GraduatedFamily: Codable, Equatable, Sendable {
        let familyID: String
        let candidatePackVersion: String
        let promptSchemaVersion: String
        let qualifiedRuntimeFamilyID: String
        let corpusSHA256: String
        let receiptSHA256: String
        let productionPolicySignature: String
    }

    let schemaVersion: Int
    let families: [String: GraduatedFamily]
    static func bundledOrEmpty() async -> ContextualPronunciationQualification
    func family(
        id: String,
        runtimeFamilyID: String
    ) -> GraduatedFamily?
}
```

- [ ] Load `contextual_pronunciation_qualification.json` through `NarrationResources`; absence, duplicate family IDs, unknown keys, or any identity mismatch means the affected family is shadow.
- [ ] Generate the JSON from the content-free qualification receipt with a deterministic command in `pronunciation_corpus.py`; include only `GRADUATED` families and add the resource to app/macOS/CLI copy phases when non-empty.
- [ ] Replace `family(... state: .shadow)` with lookup-derived state that defaults to `.shadow` on missing/mismatched/unknown data.
- [ ] Extend `ContextualAcceptanceReason` with production reasons that distinguish qualified agreement/selection from shadow observations and abstentions.
- [ ] In `ContextualPronunciationPreflight`, permit a model candidate to affect the decision only for its graduated family and exact qualified runtime. Preserve higher override and definitive deterministic authority.
- [ ] Include only graduated family signatures in narration production identity. Increment render version from the active current value because bytes may change.
- [ ] Re-run focused suites.

Expected: passing families activate independently; failed/unknown families remain advisory.

### 18.3 Render, listen, commit, and publish

- [ ] Render balanced held-out and named probes for every candidate family on primary/control voices; human-listen only those claiming graduation.
- [ ] Re-run exact-runtime repeated selection and report any system/context/genre/capitalization/position pattern failure as a family failure.
- [ ] Commit qualification resources only for passing families.
- [ ] If no family graduates, omit `contextual_pronunciation_qualification.json` and `project.pbxproj` from the commit command below; commit the fail-closed loader, tests, and `SHADOW` report without changing render identity.

```bash
git add EchoCore/Services/Narration/ContextualPronunciationQualification.swift EchoCore/Services/Narration/PronunciationResources/contextual_pronunciation_qualification.json EchoCore/Services/Narration/ContextualPronunciationTypes.swift EchoCore/Services/Narration/ContextualPronunciationFamilies.swift EchoCore/Services/Narration/ContextualPronunciationPreflight.swift EchoCore/Services/Narration/PronunciationPlanner.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/ContextualPronunciationQualificationTests.swift EchoTests/ContextualPronunciationFamiliesTests.swift EchoTests/ContextualPronunciationPreflightTests.swift EchoTests/PronunciationPlannerTests.swift EchoTests/NarrationFileNamingTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(narration): graduate qualified contextual families"
git status --short --branch
```

- [ ] Push and open the Stage 5 ready PR to `nightly`, listing each family as `GRADUATED` or `SHADOW` separately.

---

# Stage 6 — Acoustic Diagnosis and One Same-Voice Retry

## Task 19: Replace Recursive Quality Recovery with One Frozen Retry

**Files:**

- Modify: `EchoCore/Services/Narration/NarrationChunkQuality.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/Narration/PronunciationAudit.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/PronunciationAuditTests.swift`
- Modify: `EchoTests/PronunciationProgramAcceptanceTests.swift`

**Interfaces:**

- Consumes: frozen `PlannedSynthesisChunk`, `VoiceID`, `NarrationChunkQuality.evaluate`, and existing retained-output failure policy.
- Produces: zero-or-one same-voice retry and `PronunciationAcousticEvidence`; recursive recovery is removed.

### 19.1 Rewrite tests around the approved invariant

- [ ] Replace tests that expect `maximumQualityRetryDepth = 3` or recursive retry trees with tests that assert exactly zero or one retry attempt per rejected source chunk.
- [ ] Assert retry plans are frozen slices of the original `PlannedSynthesisChunk`: identical selected IPA, decision seeds, candidate/policy IDs, and `VoiceID`.
- [ ] Assert accepted first audio makes one synthesis call; rejected first/accepted retry makes two; rejected retry makes two and preserves the existing failure-policy output.
- [ ] Assert cancellation propagates and no acoustic path invokes a different voice.
- [ ] Add mechanical reason coverage for empty, near-silent, implausible duration, clipping, and dropout.
- [ ] Run `NarrationServiceTests`; expect recursive behavior and missing quality reasons to fail.

### 19.2 Add mechanical acoustic evidence

- [ ] Extend `NarrationChunkQuality.RejectionReason` with `.clipping` and `.dropout`, using deterministic sample-window thresholds pinned by tests.
- [ ] Add `PronunciationAcousticEvidence` or the equivalent fields on advisory evidence:

```swift
nonisolated struct PronunciationAcousticEvidence: Codable, Equatable, Sendable {
    let reason: String
    let retryCount: Int
    let voiceID: String
    let originalPlanIdentity: String
    let retryPlanIdentities: [String]
    let intendedPronunciationIdentity: String
    let retryAccepted: Bool
}
```

- [ ] Record both render identities and category `.acoustic`; never mutate lexical candidates based on acoustic failure.

### 19.3 Implement exactly one retry

- [ ] Remove recursive `recoverRejectedSynthesis(... retryDepth:)`, `maximumQualityRetryDepth`, and debug recursion instrumentation.
- [ ] On first rejection, derive frozen smaller slices once and synthesize each once with the original `VoiceID`.
- [ ] Do not retry any rejected retry slice. Return the existing retained-output failure policy and append one acoustic advisory.
- [ ] Preserve exact pronunciation evidence through slices and aggregate accepted retry chunks once.
- [ ] Re-run the focused suites.

Expected: retry count never exceeds one, voice and intended pronunciation identities match, and persistent failures remain audible plus advisory.

### 19.4 Invalidate bytes and commit

- [ ] Increment `NarrationFileNaming.renderVersion` from the active current value because retry policy can alter final audio bytes; update file-naming tests.
- [ ] Run focused service, audit, and file naming suites.
- [ ] Commit.

```bash
git add EchoCore/Services/Narration/NarrationChunkQuality.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/Narration/PronunciationAudit.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/NarrationServiceTests.swift EchoTests/PronunciationAuditTests.swift EchoTests/PronunciationProgramAcceptanceTests.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "feat(narration): bound acoustic recovery to one same-voice retry"
```

## Task 20: Persist and Review Acoustic Advisories

**Files:**

- Modify: `EchoCore/Services/Narration/PronunciationAdvisoryIssueBuilder.swift`
- Modify: `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify: `EchoCore/Views/Narration/NarrationQAReviewView.swift`
- Modify: `Echo macOS/Views/MacNarrationQAReviewView.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoCore/Services/Narration/PronunciationListeningReel.swift`
- Modify: `EchoTests/PronunciationAdvisoryIssueBuilderTests.swift`
- Modify: `EchoTests/NarrationQAReviewModelTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Modify: `EchoTests/PronunciationListeningReelTests.swift`

**Interfaces:**

- Consumes: `PronunciationAcousticEvidence` and V40 origin-scoped issue persistence.
- Produces: acoustic QA rows, iOS/macOS presentation, and matching headless/reel evidence without lexical fixes.

### 20.1 Add red cross-surface tests

- [ ] Assert an unrecovered acoustic failure persists with origin `.acoustic`, category `.acoustic`, original/retry identities, retry count `1`, and no automatic lexical `SuggestedFix`.
- [ ] Assert iOS/macOS presentation labels it as acoustic/voice output rather than a known lexical error.
- [ ] Assert headless manifest and listening reel carry the same evidence and audio range.
- [ ] Run focused suites; expect acoustic persistence/presentation failures.

### 20.2 Materialize and present the advisory

- [ ] Extend the issue builder to create stable acoustic rows without deleting ASR or preflight rows.
- [ ] Add platform copy explaining that the selected pronunciation was retained and one same-voice retry failed; offer Ignore/Resolved and listening navigation, not an automatic global pronunciation override.
- [ ] Include original and retry reel clips where ranges exist, clearly labeled and using the same voice ID.
- [ ] Re-run focused suites.

Expected: acoustic issues remain distinct everywhere and never corrupt dictionary data.

### 20.3 Mechanical and listening gate

- [ ] Render every named regression, balanced held-out probes, and unambiguous controls on primary/control voices.
- [ ] Confirm non-empty audio, exact planned phoneme consumption, positive bounded timing, no clipping/dropout, retry ≤1, and same voice.
- [ ] Have humans judge semantic correctness and naturalness; ASR/machine evidence may prioritize but cannot pass the gate.
- [ ] Commit and publish Stage 6.

```bash
git add EchoCore/Services/Narration/PronunciationAdvisoryIssueBuilder.swift EchoCore/ViewModels/NarrationQAReviewModel.swift EchoCore/Views/Narration/NarrationQAReviewView.swift 'Echo macOS/Views/MacNarrationQAReviewView.swift' EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoCore/Services/Narration/PronunciationListeningReel.swift EchoTests/PronunciationAdvisoryIssueBuilderTests.swift EchoTests/NarrationQAReviewModelTests.swift EchoTests/HeadlessNarrationRunnerTests.swift EchoTests/PronunciationListeningReelTests.swift
git commit -m "feat(narration): expose acoustic retry advisories"
git status --short --branch
```

- [ ] Push and open the Stage 6 ready PR to `nightly` with mechanical render and human-listening proof states separated.

---

# Stage 7 — Complete Release Proof

## Task 21: Add Book-Level Burden and Privacy Receipts

**Files:**

- Create: `Tools/Pronunciation/pronunciation_release_report.py`
- Create: `Tools/Pronunciation/tests/test_pronunciation_release_report.py`
- Create: `docs/reports/pronunciation-reliability-release.md`
- Modify: `Makefile`

**Interfaces:**

- Consumes: content-free per-book burden records and component/proof-state receipts.
- Produces: `pronunciation_release_report.py validate|report` with deterministic `PASS`, `FAIL`, or `WAITING`.

### 21.1 Test the release math and fail-closed states

- [ ] Add tests for mean unresolved items/hour ≤1, P95 ≤2/hour using a pinned percentile definition, no book >3/hour, zero dropped phonemes, zero private-log leakage, and explicit proof states for all lower/higher layers.
- [ ] Test empty books, zero duration, duplicate book IDs, malformed counts, missing evidence, provisional evidence, and pending gates cannot produce `PASS`.
- [ ] Test neural and each contextual family may be `SHADOW` without failing the complete program, provided their qualification receipts are complete and truthful.
- [ ] Run Python tests; expect missing report tool.

### 21.2 Implement content-free aggregation

- [ ] Accept only content-free per-book inputs: opaque corpus book ID, narrated seconds, unresolved count, dropped-phoneme count, log-leak count, app SHA, and proof-state IDs.
- [ ] Emit exact mean, nearest-rank P95, maximum, gate booleans, component activation states, and a final `PASS`, `FAIL`, or `WAITING`.
- [ ] Add `pronunciation-release-report-test` and `pronunciation-release-report` Make targets.
- [ ] Generate the Markdown report without private titles, excerpts, paths, or audio.
- [ ] Run the suite and a synthetic passing/failing receipt pair.

Expected: math is deterministic and missing proof never appears green.

### 21.3 Commit

```bash
git add Tools/Pronunciation/pronunciation_release_report.py Tools/Pronunciation/tests/test_pronunciation_release_report.py docs/reports/pronunciation-reliability-release.md Makefile
git commit -m "test(narration): define pronunciation release proof"
```

## Task 22: Run the Complete Local Verification Ladder

**Files:**

- Modify: `ARCHITECTURE.md`
- Modify: `docs/reports/pronunciation-reliability-release.md`
- Modify only if behavior changed during fixes: affected source and tests

**Interfaces:**

- Consumes: every Stage 1–6 test/tool target and final source tree.
- Produces: a green local test/CLI proof set or an exact attributable failure; it grants no device/listening/CI proof.

### 22.1 Run platform-neutral gates

- [ ] Run:

```bash
make pronunciation-pack-test
make pronunciation-audit-pack-test
make pronunciation-corpus-test
make pronunciation-program-report
make neural-g2p-fetch-test
make neural-g2p-qualification-test
make pronunciation-release-report-test
```

Expected: all tooling tests pass. Qualification commands may report shadow/waiting, but must not error or claim pass without evidence.

### 22.2 Run Apple gates through the slot

- [ ] Run one complete test command:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

Expected: all Echo unit tests pass.

- [ ] Build the Release CLI:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
```

Expected: Release `echo-cli` builds successfully.

- [ ] Re-run the vendored package suite:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- swift test --package-path ThirdParty/MisakiSwift
```

Expected: all MisakiSwift tests pass.

### 22.3 Verify source-level invariants

- [ ] Confirm no direct Apple build/test command escaped the slot in implementation notes or scripts.
- [ ] Confirm no neural inference for ordinary unanimous known words.
- [ ] Confirm no shadow identity in production cache signatures.
- [ ] Confirm no retry recursion or alternate voice selection remains.
- [ ] Confirm `SuggestedFix` retains its minimal schema and contribution filtering still passes.
- [ ] Confirm every new JSON/ONNX resource has correct target membership and an integrity test.
- [ ] Confirm all created reports contain only public/synthetic or content-free evidence.

## Task 23: Run Production Render, Listening, CI, and Physical-Device Acceptance

**Files:**

- Modify: `docs/reports/pronunciation-reliability-release.md`
- Modify: `ARCHITECTURE.md`

**Interfaces:**

- Consumes: exact candidate SHA, public/synthetic probes, physical-device measurements, human verdicts, hosted CI, and content-free book metrics.
- Produces: the final proof-state report and ready PR, with each qualified or shadow component stated independently.

### 23.1 Direct and rendered probes

- [ ] Run direct G2P probes for every deterministic currency example and negative control.
- [ ] Generate audit manifests and listening reels for deterministic currency, known-word disagreement, OOV fallback/model shadow or activation, every contextual family, and acoustic retry.
- [ ] Validate manifest schema 5, content hashes, audio ranges, selected/alternative identities, and cache version against the exact release SHA.
- [ ] Render with the primary and at least one control voice. Record `RENDERED` before listening; record human verdicts only after actual listening.

### 23.2 Physical iPhone acceptance

- [ ] On the oldest supported physical test iPhone, verify foreground render, lock screen, background render, cancellation, relaunch, cold preflight, sustained preflight, and peak memory.
- [ ] Repeat deterministic fallback with neural resources unavailable to prove iOS 18 behavior remains viable.
- [ ] Verify the macOS 15 fallback and review surface independently.
- [ ] Record exact device model, OS build, app SHA, voice IDs, resource/policy identities, timings, memory, and result without private source data.

### 23.3 Hosted CI and book-level release gate

- [ ] Push the exact candidate SHA and wait for hosted CI; record pending/failing/passing honestly.
- [ ] Run book-level release aggregation over legally usable test books until mean ≤1/hour, P95 ≤2/hour, no book >3/hour, zero dropped phonemes, and zero log leakage—or report the exact failing gate.
- [ ] A neural model or contextual family with a complete non-passing receipt remains `SHADOW`; do not relabel it as an implementation failure or production pass.

### 23.4 Documentation and final commit

- [ ] Update `ARCHITECTURE.md` only where the final shipped authority order, resources, qualification loaders, issue origins, cache identities, or retry policy changed.
- [ ] Finalize `docs/reports/pronunciation-reliability-release.md` with a proof-state table for unit tests, CLI, corpus qualification, render, listening, CI, physical iPhone, macOS, book-level burden, and each component's active/shadow state.
- [ ] Commit the exact receipts and documentation.

```bash
git add ARCHITECTURE.md docs/reports/pronunciation-reliability-release.md
git commit -m "docs(narration): record pronunciation reliability proof"
git status --short --branch
```

- [ ] Push and open/update the final ready PR to `nightly`. Do not merge unless separately requested.

---

## Final Acceptance Checklist

- [ ] `21` is spoken as “twenty-one.”
- [ ] `$100 billion` is spoken as “one hundred billion dollars,” never “one hundred dollars billion.”
- [ ] Every supported `$`, `£`, and `€` example, magnitude, sign, decimal, grouping, singular/plural, and negative control passes.
- [ ] Malformed currency remains voiced and produces a controlled advisory.
- [ ] Known-word disagreements are local, versioned, visible, and advisory only.
- [ ] iOS, macOS, headless manifests, and listening reels expose equivalent evidence.
- [ ] Overrides remain highest authority and accepted fixes reuse occurrence/book/global storage.
- [ ] Neural OOV selection is either fully qualified and OOV-only or truthfully shadow-only with a completed receipt.
- [ ] `content`, `read`, `live/lives`, and `record` are each independently `GRADUATED` or `SHADOW` from trusted evidence.
- [ ] Acoustic failures are distinct from lexical/contextual failures.
- [ ] Retry count is at most one and the selected voice and intended pronunciation never change.
- [ ] Shadow-only changes do not invalidate audio; every production-byte change does.
- [ ] No letter-bearing word becomes silent and deterministic fallback remains available.
- [ ] No private source material appears in fixtures, reports, receipts, or logs.
- [ ] Full local tests, Release CLI, hosted CI, real render, listening, physical-device, and book-level gates are each reported separately.
- [ ] The worktree is clean and every durable agent-authored change is committed before handoff.
