# M5 — Optional Shared Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** Land the two *buildable-now* pieces of the deferred shared-improvement milestone — a content-free term-level `PronunciationContributionPayload` with a privacy export filter that derives ONLY allowed fields from a resolved QA fix, and a local public-domain regression-corpus harness in `EchoTests` gated on out-of-repo fixtures — while shipping the live contribution transport + consent UI as a clearly-labelled design-only skeleton (a stubbed, inert `ContributionConsent` gate that never transmits and never reuses the CloudKit public-anchor DB).

**Architecture:** `PronunciationContributionPayload` is a tiny pure `Codable` struct (term + ipa + language + voiceModelVersion + confidence) plus a pure `ContributionPayloadFilter` enum that maps a resolved `NarrationQualityIssueRecord` (from M3) into a payload, dropping every field that could carry private prose. `ContributionConsent` is a pure value type recording opt-in state; the transport is a deliberately-inert stub that asserts "nothing leaves the device" by design. The regression-corpus harness is an env-gated Swift Testing suite that mirrors the existing `OnnxKokoroEngineWordTimingTests` / `HeadlessNarrationRunner` job-pattern: it loads public-domain fixtures from an out-of-repo directory (no private content in-repo) and replays them through the deterministic detector to assert stable issue counts.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`), GRDB (`DatabaseService(inMemory: ())`), Foundation. Pure `EchoCore/Services` logic with no UIKit import (auto-bundles into all targets). No new migration (M5 adds no schema — it reads M3's `narration_quality_issue`).

## Global Constraints

- **Deployment floor:** iOS 18.0 / macOS 15.0 / watchOS 11.0. Any Foundation Models code is dark for most users and MUST be triple-gated: `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)` + runtime `SystemLanguageModel.default.availability`. watchOS never compiles FM. The deterministic path is the workhorse.
- **Canonical audiobook id** = `folderURL.absoluteString`. It is the `id` of `AudiobookRecord` (table `audiobook`) and the FK target of `epub_block`, `timeline_item`, `word_timing`, `standalone_transcript`, `alignment_anchor`. NEVER key by `audioFileURL.absoluteString`.
- **WordTokenizer is the single word-boundary authority** (`Shared/WordTokenizer.swift`): `static func wordRanges(in:) -> [Range<String.Index>]`, `static func words(in:) -> [Substring]`. The `word_timing.word_index` producer and the reader highlight MUST both go through it. Whitespace-delimited; punctuation stays attached.
- **DI:** concrete-type + closure/constructor injection (the `DatabaseService(inMemory:)` pattern). Do NOT add a protocol/mock unless two real implementations exist. The ONE justified new protocol is `DivergenceClassifier` (FM impl + deterministic impl).
- **Migrations:** additive-only; new enum `Schema_Vxx` in `Shared/Database/Migrations/`; register in `DatabaseService.runMigrations` before `try migrator.migrate(writer)`; `ifNotExists`; for ADD COLUMN guard with a `db.columns(in:)` existence check; snake_case; FK `.references("audiobook", onDelete: .cascade)`; index `idx_<table>_<cols>`. Re-verify the next free version against `origin/nightly` when the branch opens (V28 is the latest registered; tentatively M1=V29, M3=V30 — re-check) and run the `schema-migration-reviewer` agent before committing the migration. Every migration ships an `EchoTests/SchemaVxxTests.swift`.
- **SPDX:** every new Swift/Swift-test file starts with line 1 `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows the WHOLE file on edit and can push the SPDX header below an import — after any edit, verify SPDX is still line 1.
- **Build/test:** iOS tests via `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. `make` targets run under `CODE_SIGNING_ALLOWED=NO`. 16 GB machine: never run two `xcodebuild`s concurrently and never enable parallel testing; prefix builds with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`. UI-test action stays excluded. Under `CODE_SIGNING_ALLOWED=NO` the iOS-sim Keychain round-trip is flaky — don't add Keychain-dependent tests.
- **Cross-platform parity:** materialization/alignment/QA/overrides are shared logic. Any new UIKit-only or `PlayerModel`-only file must be excluded from BOTH the `Echo macOS` AND the `echo-cli` targets in `Echo.xcodeproj/project.pbxproj` (CI step order masks macOS/cli build breaks behind iOS test passes). Pure `EchoCore/Services` logic with no UIKit import auto-bundles into all targets and needs no exclusion. Run `cross-platform-parity-reviewer` after touching `Shared/`/`EchoCore`.
- **Branching:** branch off `nightly`; commit at checkpoints (Conventional Commits); PR `--base nightly`; never push protected branches.

---

## Milestone status legend

- **BUILDABLE NOW:** Tasks 1, 2, 3, 5 (payload type, export filter, consent value type, regression harness). These ship real code + tests.
- **DEFERRED / SKELETON:** Task 4 (transport stub). Ships an inert, well-documented placeholder that compiles and is unit-tested to *not* transmit; the live channel is explicitly out of scope until M3/M4 produce real fix data and the owner approves a transport design.

> **No migration in M5.** This milestone reads M3's `narration_quality_issue` table (already created by `Schema_V30`) and writes nothing to the database. There is therefore no Task-0 migration; the first task introduces the payload type.

---

## Task 1 — `PronunciationContributionPayload` (content-free term-level value type) — BUILDABLE NOW

**Files**
- Create: `EchoCore/Services/Contribution/PronunciationContributionPayload.swift`
- Create: `EchoTests/PronunciationContributionPayloadTests.swift`

**Interfaces**
- Produces: `struct PronunciationContributionPayload: Codable, Equatable, Sendable { let term: String; let ipa: String; let language: String; let voiceModelVersion: String; let confidence: Double }`
- Consumes: nothing (leaf type).

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/PronunciationContributionPayloadTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationContributionPayloadTests {
    @Test func encodesOnlyAllowedFields() throws {
        let payload = PronunciationContributionPayload(
            term: "Cholmondeley",
            ipa: "ˈtʃʌmli",
            language: "en",
            voiceModelVersion: "kokoro-v1.0",
            confidence: 0.92)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactly the five allowed keys — no surrounding-prose carrier fields.
        #expect(Set(json.keys) == ["term", "ipa", "language", "voiceModelVersion", "confidence"])
        #expect(json["term"] as? String == "Cholmondeley")
        #expect(json["ipa"] as? String == "ˈtʃʌmli")
    }

    @Test func roundTrips() throws {
        let payload = PronunciationContributionPayload(
            term: "data", ipa: "ˈdeɪtə", language: "en",
            voiceModelVersion: "kokoro-v1.0", confidence: 0.5)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            PronunciationContributionPayload.self, from: data)
        #expect(decoded == payload)
    }
}
```

- [ ] **Step 2: Run it (expected FAIL — type undefined).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/PronunciationContributionPayloadTests
```
Expected: build/compile failure (`cannot find 'PronunciationContributionPayload' in scope`).

- [ ] **Step 3: Write the minimal implementation.** Create `EchoCore/Services/Contribution/PronunciationContributionPayload.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The ONLY shape allowed to leave the device for community pronunciation
/// improvement. Term-level by construction: it carries a single mispronounced
/// term, its corrected IPA, the language, the voice/model version the fix was
/// validated against, and a confidence. It deliberately has NO field that can
/// hold surrounding prose, block text, audio, file paths, or the book id —
/// those never leave the device (design doc §8 / Decision D7). `Codable` is the
/// wire shape; encoding produces exactly these five keys.
struct PronunciationContributionPayload: Codable, Equatable, Sendable {
    /// The single term being corrected (e.g. a proper noun or acronym). One word
    /// only — never a phrase that could reconstruct private source text.
    let term: String
    /// Corrected pronunciation in IPA (the Misaki override value).
    let ipa: String
    /// BCP-47-ish language tag (English-only v1 → "en").
    let language: String
    /// The narration voice/model version the fix was validated against, so a
    /// contribution can be scoped to the engine that produced the mispronunciation.
    let voiceModelVersion: String
    /// 0...1 confidence in the fix (from the resolved QA issue).
    let confidence: Double
}
```

- [ ] **Step 4: Run the test (expected PASS).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/PronunciationContributionPayloadTests
```
Expected: both tests pass.

- [ ] **Step 5: Verify SPDX is line 1** in both new files (the SwiftFormat hook can reorder). If displaced, move `// SPDX-License-Identifier: GPL-3.0-or-later` back to line 1.

- [ ] **Step 6: Commit.**
```
git add EchoCore/Services/Contribution/PronunciationContributionPayload.swift EchoTests/PronunciationContributionPayloadTests.swift
git commit -m "feat(contribution): add content-free PronunciationContributionPayload"
```

---

## Task 2 — `ContributionPayloadFilter` (privacy export filter from a resolved QA fix) — BUILDABLE NOW

**Files**
- Create: `EchoCore/Services/Contribution/ContributionPayloadFilter.swift`
- Create: `EchoTests/ContributionPayloadFilterTests.swift`

**Interfaces**
- Consumes: `NarrationQualityIssueRecord` (from M3 — fields: `id, audiobookID, sourceBlockID?, sourceWordStart?, sourceWordEnd?, audioStartTime, audioEndTime, expectedText, heardText, issueType, confidence, suggestedFixJSON?, status, createdAt, resolvedAt?`); `enum NarrationQAIssueType` (M3); `enum NarrationQAIssueStatus` (M3, values `open|resolved|ignored`).
- Produces: `enum ContributionPayloadFilter { static func payload(from issue: NarrationQualityIssueRecord, language: String, voiceModelVersion: String) -> PronunciationContributionPayload? }`
- The `suggestedFixJSON` decodes to the shared `SuggestedFix` Codable type (defined in M3): `{ spokenForm?, ipa? }`. The filter pulls `term` from the issue's `expectedText` (single word only), `ipa` from `SuggestedFix.ipa`, and `confidence` from the issue row's `confidence` column.

> **Dependency note:** This task references M3 symbols (`NarrationQualityIssueRecord`, `NarrationQAIssueType`, `NarrationQAIssueStatus`, `SuggestedFix`). It can only build once the M3 branch has merged into `nightly`. When the M5 branch opens off `nightly`, confirm those symbols exist (`grep -rn "struct NarrationQualityIssueRecord" Shared EchoCore`); if M3 has not yet landed, defer Task 2 (and Tasks 3–5's dependence on it) until it does, and note that in the PR.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/ContributionPayloadFilterTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionPayloadFilterTests {
    private func issue(
        expectedText: String,
        issueType: NarrationQAIssueType,
        status: NarrationQAIssueStatus,
        suggestedIPA: String?
    ) -> NarrationQualityIssueRecord {
        let fix = SuggestedFix(spokenForm: nil, ipa: suggestedIPA)
        let fixJSON = String(
            data: try! JSONEncoder().encode(fix), encoding: .utf8)
        return NarrationQualityIssueRecord(
            id: "issue-1",
            audiobookID: "file:///book/",
            sourceBlockID: "epub-file:///book/-s0-b0",
            sourceWordStart: 3,
            sourceWordEnd: 4,
            audioStartTime: 10.0,
            audioEndTime: 11.0,
            expectedText: expectedText,
            heardText: "chumly",
            issueType: issueType.rawValue,
            confidence: 0.9,
            suggestedFixJSON: fixJSON,
            status: status.rawValue,
            createdAt: "2026-06-29T00:00:00Z",
            resolvedAt: "2026-06-29T01:00:00Z")
    }

    @Test func emitsTermLevelPayloadForResolvedPronunciationFix() throws {
        let rec = issue(
            expectedText: "Cholmondeley",
            issueType: .pronunciation,
            status: .resolved,
            suggestedIPA: "ˈtʃʌmli")
        let payload = ContributionPayloadFilter.payload(
            from: rec, language: "en", voiceModelVersion: "kokoro-v1.0")
        let p = try #require(payload)
        #expect(p.term == "Cholmondeley")
        #expect(p.ipa == "ˈtʃʌmli")
        #expect(p.language == "en")
        #expect(p.voiceModelVersion == "kokoro-v1.0")
        #expect(p.confidence == 0.9)
    }

    @Test func dropsUnresolvedIssues() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .pronunciation,
            status: .open, suggestedIPA: "ˈtʃʌmli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsNonPronunciationIssues() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .omission,
            status: .resolved, suggestedIPA: "ˈtʃʌmli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsMissingIPA() {
        let rec = issue(
            expectedText: "Cholmondeley", issueType: .pronunciation,
            status: .resolved, suggestedIPA: nil)
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }

    @Test func dropsMultiWordExpectedTextToAvoidProseLeak() {
        let rec = issue(
            expectedText: "the dread pirate",
            issueType: .pronunciation,
            status: .resolved,
            suggestedIPA: "ˈtʃʌmli")
        #expect(
            ContributionPayloadFilter.payload(
                from: rec, language: "en", voiceModelVersion: "kokoro-v1.0") == nil)
    }
}
```

- [ ] **Step 2: Run it (expected FAIL — filter undefined).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionPayloadFilterTests
```
Expected: compile failure (`cannot find 'ContributionPayloadFilter' in scope`).

- [ ] **Step 3: Write the minimal implementation.** Create `EchoCore/Services/Contribution/ContributionPayloadFilter.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Derives a content-free `PronunciationContributionPayload` from a *resolved*
/// narration-QA pronunciation issue. This is the privacy gate (design doc §8):
/// it admits ONLY single-term pronunciation fixes and copies across just the
/// five allowed fields, so no surrounding prose, audio, paths, or book id can
/// ride along. Returns nil for anything that is not a clean, single-word,
/// resolved pronunciation fix with a suggested IPA.
enum ContributionPayloadFilter {
    static func payload(
        from issue: NarrationQualityIssueRecord,
        language: String,
        voiceModelVersion: String
    ) -> PronunciationContributionPayload? {
        // Only resolved issues carry a fix the user actually accepted.
        guard issue.status == NarrationQAIssueStatus.resolved.rawValue else { return nil }
        // Only pronunciation fixes contribute IPA.
        guard issue.issueType == NarrationQAIssueType.pronunciation.rawValue else { return nil }
        // The fix's IPA comes from the classifier output.
        guard
            let json = issue.suggestedFixJSON,
            let data = json.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: data),
            let ipa = fix.ipa,
            !ipa.isEmpty
        else { return nil }
        // The term is the expected (source) word. Enforce single-word — multi-word
        // expectedText could reconstruct private prose, so we drop it (use the
        // single canonical word-boundary authority).
        let words = WordTokenizer.words(in: issue.expectedText)
        guard words.count == 1, let term = words.first.map(String.init), !term.isEmpty
        else { return nil }
        return PronunciationContributionPayload(
            term: term,
            ipa: ipa,
            language: language,
            voiceModelVersion: voiceModelVersion,
            confidence: issue.confidence)
    }
}
```

- [ ] **Step 4: Run the test (expected PASS).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionPayloadFilterTests
```
Expected: all five tests pass.

- [ ] **Step 5: Verify SPDX line 1** in both new files; fix if the hook displaced it.

- [ ] **Step 6: Commit.**
```
git add EchoCore/Services/Contribution/ContributionPayloadFilter.swift EchoTests/ContributionPayloadFilterTests.swift
git commit -m "feat(contribution): privacy filter mapping resolved QA fixes to term-level payloads"
```

---

## Task 3 — `ContributionConsent` opt-in value type — BUILDABLE NOW

**Files**
- Create: `EchoCore/Services/Contribution/ContributionConsent.swift`
- Create: `EchoTests/ContributionConsentTests.swift`

**Interfaces**
- Produces: `struct ContributionConsent: Equatable, Sendable { let isOptedIn: Bool; let decidedAt: Date?; static let notDecided: ContributionConsent }` and `enum ContributionConsentGate { static func allows(_ consent: ContributionConsent) -> Bool }`.
- This is a pure value type recording the user's explicit opt-in. It does NOT touch UserDefaults or any persistence yet (the live setting + preview UI is Task 4, deferred). The gate is the single decision point all transport must call.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/ContributionConsentTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionConsentTests {
    @Test func defaultsToNotOptedIn() {
        #expect(ContributionConsent.notDecided.isOptedIn == false)
        #expect(ContributionConsent.notDecided.decidedAt == nil)
    }

    @Test func gateBlocksWhenNotOptedIn() {
        #expect(ContributionConsentGate.allows(.notDecided) == false)
    }

    @Test func gateBlocksWhenExplicitlyDeclined() {
        let declined = ContributionConsent(isOptedIn: false, decidedAt: Date())
        #expect(ContributionConsentGate.allows(declined) == false)
    }

    @Test func gateAllowsOnlyWhenExplicitlyOptedIn() {
        let optedIn = ContributionConsent(isOptedIn: true, decidedAt: Date())
        #expect(ContributionConsentGate.allows(optedIn))
    }
}
```

- [ ] **Step 2: Run it (expected FAIL).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionConsentTests
```
Expected: compile failure (`cannot find 'ContributionConsent' in scope`).

- [ ] **Step 3: Write the minimal implementation.** Create `EchoCore/Services/Contribution/ContributionConsent.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Records the user's explicit, opt-in decision to contribute term-level
/// pronunciation fixes to the community improvement channel (design doc §8 /
/// Decision D7). Default is NOT opted in — contribution is off until the user
/// makes an affirmative choice. This is a pure value type; persistence and the
/// preview/consent UI are deferred (M5 transport is design-only).
struct ContributionConsent: Equatable, Sendable {
    /// True only when the user has affirmatively opted in.
    let isOptedIn: Bool
    /// When the decision was recorded; nil means the user has not decided.
    let decidedAt: Date?

    /// The default: contribution is off, no decision recorded.
    static let notDecided = ContributionConsent(isOptedIn: false, decidedAt: nil)
}

/// The single decision point any contribution transport MUST consult before it
/// considers sending anything. Centralised so the "nothing leaves without
/// explicit consent" invariant has one enforcement site.
enum ContributionConsentGate {
    static func allows(_ consent: ContributionConsent) -> Bool {
        consent.isOptedIn
    }
}
```

- [ ] **Step 4: Run the test (expected PASS).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionConsentTests
```
Expected: all four tests pass.

- [ ] **Step 5: Verify SPDX line 1** in both new files.

- [ ] **Step 6: Commit.**
```
git add EchoCore/Services/Contribution/ContributionConsent.swift EchoTests/ContributionConsentTests.swift
git commit -m "feat(contribution): add ContributionConsent opt-in gate value type"
```

---

## Task 4 — Inert contribution-transport stub (DEFERRED / SKELETON)

**Files**
- Create: `EchoCore/Services/Contribution/ContributionTransport.swift`
- Create: `EchoTests/ContributionTransportStubTests.swift`

**Interfaces**
- Consumes: `[PronunciationContributionPayload]`, `ContributionConsent`, `ContributionConsentGate`.
- Produces: `struct DeferredContributionTransport { func send(_ payloads: [PronunciationContributionPayload], consent: ContributionConsent) -> ContributionTransportResult }` and `enum ContributionTransportResult: Equatable { case deferred(reason: String); case blockedNoConsent }`.
- **This task ships NO network code.** It is a documented placeholder that proves, by test, that (a) without consent it returns `.blockedNoConsent`, and (b) even *with* consent it returns `.deferred` (the live channel does not exist). This keeps the consent invariant testable and the "nothing raw leaves the device" posture provable, while the real transport waits for an approved design. It MUST NOT import CloudKit or reuse `CloudKitSyncService`.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/ContributionTransportStubTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionTransportStubTests {
    private let payload = PronunciationContributionPayload(
        term: "Cholmondeley", ipa: "ˈtʃʌmli", language: "en",
        voiceModelVersion: "kokoro-v1.0", confidence: 0.9)

    @Test func blocksWithoutConsent() {
        let transport = DeferredContributionTransport()
        let result = transport.send([payload], consent: .notDecided)
        #expect(result == .blockedNoConsent)
    }

    @Test func deferredEvenWithConsentBecauseNoLiveChannel() {
        let transport = DeferredContributionTransport()
        let consent = ContributionConsent(isOptedIn: true, decidedAt: Date())
        let result = transport.send([payload], consent: consent)
        // Live transport is intentionally not built — must NOT transmit.
        guard case .deferred = result else {
            Issue.record("expected .deferred, got \(result)")
            return
        }
    }
}
```

- [ ] **Step 2: Run it (expected FAIL).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionTransportStubTests
```
Expected: compile failure (`cannot find 'DeferredContributionTransport' in scope`).

- [ ] **Step 3: Write the minimal implementation.** Create `EchoCore/Services/Contribution/ContributionTransport.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of an attempted contribution send.
enum ContributionTransportResult: Equatable {
    /// The consent gate refused — the user has not opted in.
    case blockedNoConsent
    /// Consent was granted but the live channel does not exist yet; nothing was
    /// transmitted. Carries a human-readable reason for the deferral.
    case deferred(reason: String)
}

/// DEFERRED / SKELETON (design doc §6 M5, Decision D7). The live contribution
/// channel is intentionally NOT implemented: it requires an approved transport
/// design and real fix data from M3/M4 first. This stub exists so the consent
/// invariant is enforced and testable today, and so the codebase has one
/// obvious, inert place the real transport will later replace.
///
/// Hard constraints the eventual implementation MUST keep:
/// - It MUST NOT reuse `CloudKitSyncService` / the public alignment-anchor DB
///   (whose trust posture stays intact — design doc §6 caveat).
/// - It MUST consult `ContributionConsentGate` before doing anything.
/// - It MUST send only `PronunciationContributionPayload` (term-level fields).
///
/// This type imports no networking framework on purpose.
struct DeferredContributionTransport {
    func send(
        _ payloads: [PronunciationContributionPayload],
        consent: ContributionConsent
    ) -> ContributionTransportResult {
        guard ContributionConsentGate.allows(consent) else {
            return .blockedNoConsent
        }
        // Consent granted, but there is no live channel. Do not transmit.
        return .deferred(
            reason: "Contribution transport is not yet implemented; \(payloads.count) "
                + "payload(s) retained locally and not transmitted.")
    }
}
```

- [ ] **Step 4: Run the test (expected PASS).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/ContributionTransportStubTests
```
Expected: both tests pass.

- [ ] **Step 5: Verify SPDX line 1**; confirm the file imports only `Foundation` (no `CloudKit`):
```
grep -n "import" EchoCore/Services/Contribution/ContributionTransport.swift
```
Expected: only `import Foundation`.

- [ ] **Step 6: Commit.**
```
git add EchoCore/Services/Contribution/ContributionTransport.swift EchoTests/ContributionTransportStubTests.swift
git commit -m "feat(contribution): add inert deferred transport stub enforcing consent gate"
```

---

## Task 5 — Local public-domain regression-corpus harness (env-gated, out-of-repo fixtures) — BUILDABLE NOW

**Files**
- Create: `EchoTests/RegressionCorpusHarnessTests.swift`

**Interfaces**
- Consumes (from M3, must exist on `nightly`): `final class NarrationQADetector { static func detect(expectedBlocks: [(blockID: String, text: String)], heardWords: [TranscribedWord], audiobookID: String) -> [DivergenceWindow] }`; `struct TranscribedWord: Equatable, Sendable { let text: String; let start: TimeInterval }` (`EchoCore/Services/AlignmentTranscript.swift`); `struct DivergenceWindow` (M3).
- Produces: an env-gated Swift Testing suite that loads fixture cases from the directory named by `ECHO_REGRESSION_CORPUS_DIR` (out-of-repo, mirroring the `ECHO_RUN_KOKORO_TIMING_IT` pattern in `OnnxKokoroEngineWordTimingTests`), replays each through `NarrationQADetector.detect`, and asserts the observed divergence-window count matches the fixture's expected count. No fixtures are committed; the test is `.disabled` by default so CI stays green and no private/public content lands in-repo.

**Fixture format (documented in the test, NOT committed):** each fixture is a JSON file in the corpus dir:
```json
{
  "audiobookID": "fixture://aesop/",
  "expectedBlocks": [{ "blockID": "b0", "text": "the north wind and the sun" }],
  "heardWords": [{ "text": "the", "start": 0.0 }, { "text": "north", "start": 0.4 }],
  "expectedWindowCount": 1
}
```

Steps:

- [ ] **Step 1: Write the harness test (it is the deliverable; it will be SKIPPED, not FAIL, by default).** Create `EchoTests/RegressionCorpusHarnessTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Local regression-corpus harness (design doc §6 M5, §9). Drives the
    /// deterministic narration-QA detector over PUBLIC-DOMAIN fixtures kept
    /// OUT of the repo (no private or copyrighted content is ever committed),
    /// mirroring the out-of-repo gating used by `OnnxKokoroEngineWordTimingTests`
    /// and the headless narration harnesses.
    ///
    /// To run: point `ECHO_REGRESSION_CORPUS_DIR` at a directory of fixture JSON
    /// files (schema below) and run `make test-only FILTER=EchoTests/RegressionCorpusHarnessTests`.
    /// Default: SKIPPED, so the suite stays fast and repo-safe.
    ///
    /// Fixture JSON schema:
    /// { "audiobookID": String,
    ///   "expectedBlocks": [{ "blockID": String, "text": String }],
    ///   "heardWords": [{ "text": String, "start": Double }],
    ///   "expectedWindowCount": Int }
    @Suite struct RegressionCorpusHarnessTests {
        private struct FixtureBlock: Decodable {
            let blockID: String
            let text: String
        }
        private struct FixtureWord: Decodable {
            let text: String
            let start: TimeInterval
        }
        private struct Fixture: Decodable {
            let audiobookID: String
            let expectedBlocks: [FixtureBlock]
            let heardWords: [FixtureWord]
            let expectedWindowCount: Int
        }

        private static var corpusDir: URL? {
            ProcessInfo.processInfo.environment["ECHO_REGRESSION_CORPUS_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        @Test(
            .enabled(
                if: corpusDir != nil,
                "set ECHO_REGRESSION_CORPUS_DIR to a public-domain fixture dir to run"))
        func detectorIsStableAcrossCorpus() throws {
            let dir = try #require(Self.corpusDir)
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            #expect(!files.isEmpty, "corpus dir had no .json fixtures")

            for file in files {
                let data = try Data(contentsOf: file)
                let fixture = try JSONDecoder().decode(Fixture.self, from: data)
                let expectedBlocks = fixture.expectedBlocks.map {
                    (blockID: $0.blockID, text: $0.text)
                }
                let heardWords = fixture.heardWords.map {
                    TranscribedWord(text: $0.text, start: $0.start)
                }
                let windows = NarrationQADetector.detect(
                    expectedBlocks: expectedBlocks,
                    heardWords: heardWords,
                    audiobookID: fixture.audiobookID)
                #expect(
                    windows.count == fixture.expectedWindowCount,
                    "\(file.lastPathComponent): expected \(fixture.expectedWindowCount) "
                        + "windows, got \(windows.count)")
            }
        }
    }
#endif
```

- [ ] **Step 2: Run it (expected SKIP — env unset — and the suite must COMPILE).**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/RegressionCorpusHarnessTests
```
Expected: the suite compiles and the single test reports as skipped (`set ECHO_REGRESSION_CORPUS_DIR ...`). This proves the harness wires correctly against the real M3 `NarrationQADetector`/`TranscribedWord`/`DivergenceWindow` types without committing fixtures.

- [ ] **Step 3: Local smoke-run the harness with a throwaway fixture (NOT committed).** Create one public-domain fixture in the scratchpad and run:
```
mkdir -p "$TMPDIR/echo-regression-corpus"
cat > "$TMPDIR/echo-regression-corpus/aesop.json" <<'JSON'
{ "audiobookID": "fixture://aesop/",
  "expectedBlocks": [{ "blockID": "b0", "text": "the north wind and the sun" }],
  "heardWords": [
    { "text": "the", "start": 0.0 }, { "text": "north", "start": 0.4 },
    { "text": "wind", "start": 0.8 }, { "text": "and", "start": 1.2 },
    { "text": "the", "start": 1.5 }, { "text": "sun", "start": 1.9 } ],
  "expectedWindowCount": 0 }
JSON
ECHO_REGRESSION_CORPUS_DIR="$TMPDIR/echo-regression-corpus" make test-only FILTER=EchoTests/RegressionCorpusHarnessTests
```
Expected: the test now RUNS and passes (clean transcript → 0 divergence windows). Adjust `expectedWindowCount` if the detector's calibrated heuristics report a different baseline for this fixture; the goal is a *stable, asserted* count, not a specific number. **Do not commit the fixture** — verify it is outside the repo (`$TMPDIR`).

- [ ] **Step 4: Confirm no fixture leaked into the repo.**
```
git status --short
```
Expected: only `EchoTests/RegressionCorpusHarnessTests.swift` shows as new — no `.json` fixtures.

- [ ] **Step 5: Verify SPDX line 1** in the new test file.

- [ ] **Step 6: Commit.**
```
git add EchoTests/RegressionCorpusHarnessTests.swift
git commit -m "test(contribution): add out-of-repo public-domain regression-corpus harness"
```

---

## Task 6 — Parity + doc-sync

**Files**
- Modify: `ARCHITECTURE.md` (add a "Shared Improvement (M5, deferred)" subsection)
- Modify: `CHANGELOG.md` (add the M5 entries under the unreleased/nightly section)

**Interfaces**
- Consumes: all M5 types above. Produces: documentation only.

Steps:

- [ ] **Step 1: Run the cross-platform parity reviewer.** All four new source files live in `EchoCore/Services/Contribution/` and import only `Foundation` (verify: `grep -rn "import" EchoCore/Services/Contribution/`). Pure `EchoCore/Services` logic with no UIKit/`PlayerModel` import auto-bundles into all targets (iOS, macOS, echo-cli, Widget) and needs NO `project.pbxproj` target exclusion. Confirm none of the four files import UIKit or reference `PlayerModel`:
```
grep -rn "UIKit\|PlayerModel" EchoCore/Services/Contribution/
```
Expected: no matches. Then invoke the `cross-platform-parity-reviewer` agent over `EchoCore/Services/Contribution/` to confirm no target gap.

- [ ] **Step 2: Verify the whole new surface still builds and all M5 suites pass together.**
```
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/PronunciationContributionPayloadTests
make test-only FILTER=EchoTests/ContributionPayloadFilterTests
make test-only FILTER=EchoTests/ContributionConsentTests
make test-only FILTER=EchoTests/ContributionTransportStubTests
make test-only FILTER=EchoTests/RegressionCorpusHarnessTests
```
Expected: all pass (the corpus harness reports skipped without the env var).

- [ ] **Step 3: Update `ARCHITECTURE.md`.** Add a subsection (after the narration-QA section M3/M4 introduces) documenting: M5 ships the content-free `PronunciationContributionPayload`, the `ContributionPayloadFilter` privacy gate (single-term, resolved-pronunciation-only), the `ContributionConsent` opt-in gate, the inert `DeferredContributionTransport` (explicitly NOT reusing CloudKit; live channel deferred), and the out-of-repo `ECHO_REGRESSION_CORPUS_DIR` regression harness. State plainly: nothing raw leaves the device; the live transport is design-only pending owner approval.

- [ ] **Step 4: Update `CHANGELOG.md`.** Under the nightly/unreleased heading add:
  - `Added: content-free term-level pronunciation contribution payload + privacy export filter (resolved single-word pronunciation fixes only).`
  - `Added: opt-in contribution consent gate; transport remains deferred/inert (no data leaves the device).`
  - `Added: local public-domain regression-corpus test harness (out-of-repo fixtures via ECHO_REGRESSION_CORPUS_DIR).`

- [ ] **Step 5: Run `doc-sync`** to confirm the docs match the code surface and no other living doc went stale.

- [ ] **Step 6: Verify SPDX still line 1** across all four `EchoCore/Services/Contribution/*.swift` and the five new test files (the SwiftFormat hook touches files on edit):
```
for f in EchoCore/Services/Contribution/*.swift EchoTests/PronunciationContributionPayloadTests.swift EchoTests/ContributionPayloadFilterTests.swift EchoTests/ContributionConsentTests.swift EchoTests/ContributionTransportStubTests.swift EchoTests/RegressionCorpusHarnessTests.swift; do head -1 "$f"; done
```
Expected: every line is `// SPDX-License-Identifier: GPL-3.0-or-later`.

- [ ] **Step 7: Commit + open the PR.**
```
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs(contribution): document deferred M5 shared-improvement surface"
git fetch origin && git rebase origin/nightly
git push -u origin HEAD
gh pr create --base nightly --title "M5: deferred shared-improvement surface (payload + filter + consent + regression harness)" --body "Ships the buildable-now pieces of M5: content-free PronunciationContributionPayload, privacy export filter, opt-in ContributionConsent gate, and an out-of-repo regression-corpus harness. Live transport is an inert, tested skeleton (no CloudKit reuse; nothing leaves the device). See docs/superpowers/specs/2026-06-29-transcript-narration-qa-design.md §6 M5.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
Then check CI: `gh pr checks`.
