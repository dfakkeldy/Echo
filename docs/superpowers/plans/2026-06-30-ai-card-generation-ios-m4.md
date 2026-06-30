# AI Card Generation — iOS M4 (on-device Foundation Models) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device Apple Foundation Models study-card generator behind the existing `StudyDeckGenerating` seam, so Apple-Intelligence-capable devices can generate cards with no key and no network, with a provider preference that defaults to "key wins, on-device fills the gap."

**Architecture:** Clone the SHIPPED narration-QA Foundation Models pattern (`FoundationModelsDivergenceClassifier`/`DivergenceClassifierFactory`) — the same `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26)` + `@Generable`/`LanguageModelSession` + try/catch→fallback idiom — to produce a `FoundationModelsStudyDeckGenerator` that emits the existing `GeneratedStudyDeckDraft`. Extend `StudyDeckGeneratorFactory` to choose among on-device FM, BYO-key cloud Claude, and the deterministic fixture by a settings preference + runtime availability. M1–M3 (the BYO-key generator) already ships and is cross-platform; this milestone adds the on-device provider + selection.

**Tech Stack:** Swift, SwiftUI, FoundationModels (iOS 26 / macOS 26), no third-party deps. Builds on the merged M1–M3 feature (`origin/nightly` `d37ab99`, PR #351). Design spec: `docs/superpowers/specs/2026-06-30-ai-card-generation-design.md` (§9 iOS M4).

## Global Constraints

- **SPDX header line 1** of every new Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows files — re-verify SPDX stays line 1 after edits.
- **Foundation Models gating (copy the shipped idiom exactly):** wrap FM code in `#if canImport(FoundationModels) && (os(iOS) || os(macOS))` and annotate FM types/functions `@available(iOS 26, macOS 26, *)`. Availability at runtime is `if case .available = SystemLanguageModel.default.availability` (the `.deviceNotEligible`/`.appleIntelligenceNotEnabled`/`.modelNotReady`/`@unknown default` cases map to "unavailable"). **Do NOT do a locale/`supportsLocale()`/`supportedLanguages` pre-check** — the shipped narration-QA classifier doesn't, and EDB's `supportsLocale()` is a non-existent API (the bug this milestone avoids). An unsupported language surfaces as a `LanguageModelSession` error at runtime and is caught → fallback.
- **FM call idiom:** `LanguageModelSession(instructions:)` then `try await session.respond(to: prompt, generating: <@Generable type>.self, options: GenerationOptions(sampling: .greedy))`; on ANY thrown error, log via `os.Logger` and fall back (never crash). `@Generable` structs use `@Guide(...)` for field constraints. Source text goes ONLY in the prompt (never in `instructions`), framed as the private EPUB excerpt.
- **Provider priority (product decision — "key wins"):** preference `auto` (default) → `hasKey ? cloud-Claude : (fmAvailable ? on-device-FM : fixture)`; preference `cloud` → `hasKey ? cloud-Claude : fixture`; preference `onDevice` → `fmAvailable ? on-device-FM : fixture`. A settings picker sets the preference. The deterministic `FixtureStudyDeckGenerator` is the universal floor.
- **Swift 6 `-default-isolation MainActor`:** the generator/availability/mapper are `nonisolated` value types/enums (they compile into app, macOS, echo-cli, Widget, Watch — except FM code, excluded on Watch via the `&& (os(iOS) || os(macOS))` gate). The factory stays `nonisolated`; availability is computed at the `@MainActor` call site and passed in as a `Bool` (keeps the factory testable off-device — mirror `DivergenceClassifierFactory`).
- **Test module is `Echo`**: `@testable import Echo`. Test framework is not load-bearing (XCTest or Swift Testing; match the nearest existing test). **Pure logic must be testable off-device:** keep the FM-card→draft mapping a plain non-`@Generable`, non-gated function so it tests without an Apple-Intelligence device; the factory-selection matrix is pure and fully tested; the actual `LanguageModelSession` call is not unit-tested (device + iOS-26-gated), exactly as the narration-QA FM classifier is not.
- **Synchronized file groups:** new files under `Shared/`/`EchoCore/`/`EchoTests/` auto-include in targets — no `Echo.xcodeproj/project.pbxproj` edits. No third-party deps.
- **Builds/tests (16 GB machine):** `make build-tests` (iOS) once, then `make test-only FILTER=EchoTests/<Suite>`; for cross-target, `xcodebuild -scheme "Echo macOS" … build` and `-scheme echo-cli build` (CODE_SIGNING_ALLOWED=NO). Never run two `xcodebuild`s concurrently. SourceKit "cannot find type" on new files is index lag — trust `make`.
- **No migration.** Branch is `worktree-ai-card-gen-ios-m4` off `origin/nightly`; commit per task; PR targets `nightly`.

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `Shared/Services/AI/StudyDeckFMAvailability.swift` | On-device FM availability (Bool + status message), gated | New |
| `Shared/Services/AI/FoundationModelsStudyDeckGenerator.swift` | `@Generable` card + `StudyDeckGenerating` FM impl + pure mapper, gated | New |
| `Shared/Services/StudyDeckGenerating.swift` | Extend `StudyDeckGeneratorFactory.make` to 3-way (preference + fmAvailable) | Modify |
| `EchoCore/Views/AICardGenerationSettingsView.swift` | Add `provider` preference + Picker + FM status | Modify |
| `EchoCore/Views/BookSettingsView.swift:371` | Rewire the factory call (preference + computed `fmAvailable`) | Modify |
| `EchoTests/StudyDeck/*` | Mapper, factory-matrix, availability, settings tests | New |
| `ARCHITECTURE.md` / `CHANGELOG.md` | Note the on-device FM provider | Modify |

---

### Task 1: On-device FM availability (`StudyDeckFMAvailability`)

**Files:**
- Create: `Shared/Services/AI/StudyDeckFMAvailability.swift`
- Test: `EchoTests/StudyDeck/StudyDeckFMAvailabilityTests.swift`

**Interfaces:**
- Produces: `enum StudyDeckFMAvailability { nonisolated static var isAvailable: Bool { get }; nonisolated static var statusMessage: String { get } }` — `isAvailable` is `true` only when FoundationModels can be imported, the OS is iOS 26 / macOS 26+, and `SystemLanguageModel.default.availability == .available`; `false` everywhere else. `statusMessage` is a short human-readable reason (e.g. "On-device generation ready" / "Turn on Apple Intelligence to generate on-device" / "On-device generation needs iOS 26 or a newer Mac").

- [ ] **Step 1: Write the failing test** (off-device: the build target here is unlikely to report `.available`, so the test asserts the contract holds without crashing and the message is non-empty)

```swift
// EchoTests/StudyDeck/StudyDeckFMAvailabilityTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Echo

final class StudyDeckFMAvailabilityTests: XCTestCase {
    func testAvailabilityIsADeterministicBoolWithoutCrashing() {
        let a = StudyDeckFMAvailability.isAvailable
        XCTAssertEqual(a, StudyDeckFMAvailability.isAvailable)   // stable, no crash
    }
    func testStatusMessageNonEmpty() {
        XCTAssertFalse(StudyDeckFMAvailability.statusMessage.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `make build-tests && make test-only FILTER=EchoTests/StudyDeckFMAvailabilityTests` → FAIL (undefined).

- [ ] **Step 3: Implement** (mirror `NarrationQAReviewModel.swift:68-71`'s availability idiom — no locale check)

```swift
// Shared/Services/AI/StudyDeckFMAvailability.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationModels) && (os(iOS) || os(macOS))
    import FoundationModels
#endif

/// Whether on-device Apple Foundation Models can generate study cards on THIS device,
/// computed exactly like the shipped narration-QA availability check (no locale pre-check).
enum StudyDeckFMAvailability {
    nonisolated static var isAvailable: Bool {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
        #endif
        return false
    }

    nonisolated static var statusMessage: String {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return "On-device generation ready (free, fully private)."
                case .unavailable(.deviceNotEligible): return "This device isn't Apple-Intelligence capable."
                case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to generate on-device."
                case .unavailable(.modelNotReady): return "Apple Intelligence model is still downloading."
                @unknown default: return "On-device generation is unavailable."
                }
            }
        #endif
        return "On-device generation needs iOS 26 or macOS 26."
    }
}
```

- [ ] **Step 4: Run to verify it passes** — `make test-only FILTER=EchoTests/StudyDeckFMAvailabilityTests` → PASS.
- [ ] **Step 5: Verify SPDX line 1, then commit** — `git commit -m "feat(study): add on-device Foundation Models availability check"`

### Task 2: On-device FM generator (`FoundationModelsStudyDeckGenerator`) + pure mapper

**Files:**
- Create: `Shared/Services/AI/FoundationModelsStudyDeckGenerator.swift`
- Test: `EchoTests/StudyDeck/FoundationModelsStudyDeckMapperTests.swift`

**Interfaces:**
- Consumes: `StudyDeckSource` (`.sourceBlockID`, `.text`), `GeneratedStudyDeckCardDraft(id:sourceBlockID:frontText:backText:tags:kind:clozeText:)`, `GeneratedStudyDeckDraft(cards:validSourceBlockIDs:)`, `StudyDeckCardKind` (`.basic`/`.cloze`), `StudyDeckGenerationSettings.maximumCardCount`, `FixtureStudyDeckGenerator`.
- Produces:
  - PURE (not gated, testable): `enum StudyDeckFMCardMapper { nonisolated static func draft(sourceBlockID: String, frontText: String, backText: String, kind: String, clozeText: String, tags: [String]) -> GeneratedStudyDeckCardDraft }` — maps a model's raw fields to a draft: `id = "fm-\(sourceBlockID)"`, `tags = ["generated","on-device"] + cleaned model tags`, `kind = StudyDeckCardKind(rawValue: kind) ?? .basic`, `clozeText = (kind == "cloze") ? clozeText : nil`.
  - GATED: `@available(iOS 26, macOS 26, *) struct FoundationModelsStudyDeckGenerator: StudyDeckGenerating { let fallback: any StudyDeckGenerating; init(fallback: any StudyDeckGenerating = FixtureStudyDeckGenerator()) }` — per-source (capped at `settings.maximumCardCount`) `LanguageModelSession.respond` generating a `@Generable StudyDeckGeneratedCard`, mapped via `StudyDeckFMCardMapper.draft`, accumulated, wrapped in `GeneratedStudyDeckDraft(cards:validSourceBlockIDs:)`; per-source error → skip that source (log); whole-run failure with zero cards → returns the empty draft (draft validation still applies — cloze/anchor/length).

- [ ] **Step 1: Write the failing test for the PURE mapper** (off-device, not gated)

```swift
// EchoTests/StudyDeck/FoundationModelsStudyDeckMapperTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Echo

final class FoundationModelsStudyDeckMapperTests: XCTestCase {
    func testBasicCardMapping() {
        let d = StudyDeckFMCardMapper.draft(sourceBlockID: "epub-bk-s0-b0",
            frontText: "What pumps blood?", backText: "The heart.", kind: "basic", clozeText: "", tags: ["anatomy"])
        XCTAssertEqual(d.id, "fm-epub-bk-s0-b0")
        XCTAssertEqual(d.kind, .basic)
        XCTAssertNil(d.clozeText)
        XCTAssertEqual(d.tags, ["generated", "on-device", "anatomy"])
    }
    func testClozeCardMappingCarriesClozeText() {
        let d = StudyDeckFMCardMapper.draft(sourceBlockID: "epub-bk-s0-b0",
            frontText: "", backText: "", kind: "cloze", clozeText: "The {{c1::heart}} pumps blood.", tags: [])
        XCTAssertEqual(d.kind, .cloze)
        XCTAssertEqual(d.clozeText, "The {{c1::heart}} pumps blood.")
    }
    func testUnknownKindFallsBackToBasic() {
        let d = StudyDeckFMCardMapper.draft(sourceBlockID: "x", frontText: "q", backText: "a", kind: "weird", clozeText: "", tags: [])
        XCTAssertEqual(d.kind, .basic)
        XCTAssertNil(d.clozeText)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — undefined `StudyDeckFMCardMapper`.

- [ ] **Step 3: Implement** the pure mapper + the gated generator + `@Generable` card

```swift
// Shared/Services/AI/FoundationModelsStudyDeckGenerator.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Pure model-field → draft mapping (no FoundationModels dependency, so it is unit-testable
/// off-device). The draft's own validation (anchor in batch, length caps, cloze markers) runs later.
enum StudyDeckFMCardMapper {
    nonisolated static func draft(
        sourceBlockID: String, frontText: String, backText: String,
        kind: String, clozeText: String, tags: [String]
    ) -> GeneratedStudyDeckCardDraft {
        let cardKind = StudyDeckCardKind(rawValue: kind.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .basic
        var merged = ["generated", "on-device"]
        for t in tags {
            let n = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, !merged.contains(n) { merged.append(n) }
        }
        return GeneratedStudyDeckCardDraft(
            id: "fm-\(sourceBlockID)", sourceBlockID: sourceBlockID,
            frontText: frontText, backText: backText, tags: merged,
            kind: cardKind, clozeText: cardKind == .cloze ? clozeText : nil)
    }
}

#if canImport(FoundationModels) && (os(iOS) || os(macOS))
    import FoundationModels

    @available(iOS 26, macOS 26, *)
    @Generable
    struct StudyDeckGeneratedCard {
        @Guide(description: "A short quiz question. Use for a basic card; leave empty for a cloze card.")
        let frontText: String
        @Guide(description: "The concise answer for a basic card; leave empty for a cloze card.")
        let backText: String
        @Guide(.anyOf(["basic", "cloze"]))
        let kind: String
        @Guide(description: "A sentence with one or more {{c1::answer}} cloze deletions; only when kind is cloze.")
        let clozeText: String
        @Guide(.maximumCount(4))
        let tags: [String]
    }

    /// On-device Foundation Models study-card generator. One card per source (capped at
    /// settings.maximumCardCount), each its own session to fit the context window; any
    /// per-source error is logged and that source is skipped (never crashes). Output goes
    /// through the same GeneratedStudyDeckDraft validation as every other generator.
    @available(iOS 26, macOS 26, *)
    struct FoundationModelsStudyDeckGenerator: StudyDeckGenerating {
        let fallback: any StudyDeckGenerating
        private static let logger = Logger(category: "StudyDeck.FM")
        private static let instructions = """
        You generate one study flashcard from a private book excerpt. Use only the excerpt — \
        no outside facts. Paraphrase; do not copy long passages verbatim. Choose a basic \
        question/answer or a {{c1::cloze}} sentence, whichever fits. Keep it short and useful. \
        Return a few specific tags; avoid generic tags like book, chapter, or study.
        """
        private static let maxExcerpt = 7_500

        init(fallback: any StudyDeckGenerating = FixtureStudyDeckGenerator()) { self.fallback = fallback }

        func generate(sources: [StudyDeckSource], settings: StudyDeckGenerationSettings) async -> GeneratedStudyDeckDraft {
            let valid = Set(sources.map(\.sourceBlockID))
            let chosen = Array(sources.prefix(settings.maximumCardCount))
            var drafts: [GeneratedStudyDeckCardDraft] = []
            for source in chosen {
                if Task.isCancelled { break }
                let excerpt = String(source.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxExcerpt))
                guard !excerpt.isEmpty else { continue }
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(
                        to: "Book excerpt:\n\(excerpt)",
                        generating: StudyDeckGeneratedCard.self,
                        options: GenerationOptions(sampling: .greedy))
                    let c = response.content
                    drafts.append(StudyDeckFMCardMapper.draft(
                        sourceBlockID: source.sourceBlockID, frontText: c.frontText, backText: c.backText,
                        kind: c.kind, clozeText: c.clozeText, tags: c.tags))
                } catch {
                    Self.logger.error("FM card generation skipped a source: \(error.localizedDescription)")
                }
            }
            return GeneratedStudyDeckDraft(cards: drafts, validSourceBlockIDs: valid)
        }
    }
#endif
```

- [ ] **Step 4: Run to verify the mapper tests pass** — `make build-tests && make test-only FILTER=EchoTests/FoundationModelsStudyDeckMapperTests` → PASS (the gated generator compiles; its `respond` path is exercised only on-device).
- [ ] **Step 5: Verify SPDX line 1, then commit** — `git commit -m "feat(study): add on-device Foundation Models study-deck generator"`

### Task 3: 3-way factory (preference + key + FM availability)

**Files:**
- Modify: `Shared/Services/StudyDeckGenerating.swift:15-24`
- Test: `EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift`

**Interfaces:**
- Consumes: `StudyDeckFMAvailability` (Task 1, indirectly — caller passes the Bool), `FoundationModelsStudyDeckGenerator` (Task 2, constructed under the gate), `FixtureStudyDeckGenerator`, the existing `anthropic` builder.
- Produces: `nonisolated static func make(preference: StudyDeckGeneratorPreference, hasKey: Bool, fmAvailable: Bool, anthropic: @Sendable () -> any StudyDeckGenerating) -> any StudyDeckGenerating` and `enum StudyDeckGeneratorPreference: String, Sendable { case auto, cloud, onDevice }`. The existing 2-arg `make(hasKey:anthropic:)` is REMOVED (single call site is updated in Task 5) — or kept as a thin wrapper delegating to `make(preference: .auto, …, fmAvailable: false, …)` if you prefer not to touch the call site twice; the matrix below is the contract.

Selection matrix (deterministic, fully testable):

| preference | hasKey | fmAvailable | result |
|---|---|---|---|
| auto | true | any | `anthropic()` (cloud — key wins) |
| auto | false | true | on-device FM |
| auto | false | false | fixture |
| cloud | true | any | `anthropic()` |
| cloud | false | any | fixture |
| onDevice | any | true | on-device FM |
| onDevice | any | false | fixture |

- [ ] **Step 1: Write the failing matrix test**

```swift
// EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Echo

final class StudyDeckGeneratorFactoryMatrixTests: XCTestCase {
    private struct CloudSentinel: StudyDeckGenerating {  // stand-in for the anthropic builder
        func generate(sources: [StudyDeckSource], settings: StudyDeckGenerationSettings) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: [])
        }
    }
    private func make(_ p: StudyDeckGeneratorPreference, key: Bool, fm: Bool) -> any StudyDeckGenerating {
        StudyDeckGeneratorFactory.make(preference: p, hasKey: key, fmAvailable: fm) { CloudSentinel() }
    }
    func testAutoKeyWins() { XCTAssertTrue(make(.auto, key: true, fm: true) is CloudSentinel) }
    func testAutoNoKeyFmAvailableUsesOnDevice() {
        let g = make(.auto, key: false, fm: true)
        XCTAssertFalse(g is CloudSentinel); XCTAssertFalse(g is FixtureStudyDeckGenerator)  // FM (or, if SDK<26, fixture — see note)
    }
    func testAutoNoKeyNoFmUsesFixture() { XCTAssertTrue(make(.auto, key: false, fm: false) is FixtureStudyDeckGenerator) }
    func testCloudNoKeyFixture() { XCTAssertTrue(make(.cloud, key: false, fm: true) is FixtureStudyDeckGenerator) }
    func testOnDeviceNoFmFixture() { XCTAssertTrue(make(.onDevice, key: true, fm: false) is FixtureStudyDeckGenerator) }
}
```

> Note on `testAutoNoKeyFmAvailableUsesOnDevice`: `fmAvailable: true` can only be passed honestly when the SDK supports FM; the factory's `#if canImport && #available` guard means that when FM types exist it returns the FM generator, else fixture. On the CI SDK (Xcode 26) the FM branch compiles; if the test runs on an iOS-18 sim the `#available` is false and it returns fixture. Make this assertion tolerant: assert the result is `FoundationModelsStudyDeckGenerator` **or** `FixtureStudyDeckGenerator` (never `CloudSentinel`). Adjust the assertion accordingly so it is green on any runner.

- [ ] **Step 2: Run to verify it fails** — undefined `StudyDeckGeneratorPreference` / new `make`.

- [ ] **Step 3: Implement**

```swift
// Shared/Services/StudyDeckGenerating.swift  (replace the factory enum body)
enum StudyDeckGeneratorPreference: String, Sendable { case auto, cloud, onDevice }

enum StudyDeckGeneratorFactory {
    nonisolated static func make(
        preference: StudyDeckGeneratorPreference,
        hasKey: Bool,
        fmAvailable: Bool,
        anthropic: @Sendable () -> any StudyDeckGenerating
    ) -> any StudyDeckGenerating {
        switch preference {
        case .cloud:
            return hasKey ? anthropic() : FixtureStudyDeckGenerator()
        case .onDevice:
            return onDevice(ifAvailable: fmAvailable) ?? FixtureStudyDeckGenerator()
        case .auto:
            if hasKey { return anthropic() }                 // key wins
            if let fm = onDevice(ifAvailable: fmAvailable) { return fm }
            return FixtureStudyDeckGenerator()
        }
    }

    private nonisolated static func onDevice(ifAvailable: Bool) -> (any StudyDeckGenerating)? {
        guard ifAvailable else { return nil }
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                return FoundationModelsStudyDeckGenerator()
            }
        #endif
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes** — `make test-only FILTER=EchoTests/StudyDeckGeneratorFactoryMatrixTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(study): 3-way generator factory (on-device / cloud / fixture by preference)"`

### Task 4: Provider preference setting + Picker + FM status

**Files:**
- Modify: `EchoCore/Views/AICardGenerationSettingsView.swift`
- Test: `EchoTests/StudyDeck/AICardGenerationSettingsProviderTests.swift`

**Interfaces:**
- Produces: `AICardGenerationSettings.providerPreference` (UserDefaults-backed, key `"ai.cardgen.provider"`, default `.auto`) typed as `StudyDeckGeneratorPreference`. The settings view gains a "Provider" `Picker` (Automatic / On-device only / Cloud only) and shows `StudyDeckFMAvailability.statusMessage` so the user knows whether on-device is usable.

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/StudyDeck/AICardGenerationSettingsProviderTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Echo

final class AICardGenerationSettingsProviderTests: XCTestCase {
    func testProviderPreferenceRoundTripsDefaultsAuto() {
        let key = "ai.cardgen.provider"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AICardGenerationSettings.providerPreference, .auto)   // default
        AICardGenerationSettings.providerPreference = .onDevice
        XCTAssertEqual(AICardGenerationSettings.providerPreference, .onDevice)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — undefined `providerPreference`.

- [ ] **Step 3: Implement** — add to `AICardGenerationSettings`:

```swift
// EchoCore/Views/AICardGenerationSettingsView.swift  (in enum AICardGenerationSettings)
    private static let providerKey = "ai.cardgen.provider"
    static var providerPreference: StudyDeckGeneratorPreference {
        get { StudyDeckGeneratorPreference(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
```

And in the view, add a Provider section above the key field (cross-platform SwiftUI only):

```swift
    @State private var provider: StudyDeckGeneratorPreference = AICardGenerationSettings.providerPreference
    // … in the Form, a new Section:
    Section("Provider") {
        Picker("Generator", selection: $provider) {
            Text("Automatic").tag(StudyDeckGeneratorPreference.auto)
            Text("On-device only").tag(StudyDeckGeneratorPreference.onDevice)
            Text("Cloud only").tag(StudyDeckGeneratorPreference.cloud)
        }
        .onChange(of: provider) { _, new in AICardGenerationSettings.providerPreference = new }
        Text(StudyDeckFMAvailability.statusMessage).font(.footnote).foregroundStyle(.secondary)
    }
```
(Update `.onAppear` to also refresh `provider = AICardGenerationSettings.providerPreference`. Keep the existing key/model/consent UI; "Automatic" = key wins, on-device fills the gap.)

- [ ] **Step 4: Run to verify it passes** — `make test-only FILTER=EchoTests/AICardGenerationSettingsProviderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(study): provider preference picker + on-device status in AI settings"`

### Task 5: Rewire the factory call site + cross-platform build gate + docs

**Files:**
- Modify: `EchoCore/Views/BookSettingsView.swift:371` (the `StudyDeckGeneratorFactory.make` call in `StudyDeckGenerationSheetHost`)
- Modify: `ARCHITECTURE.md` (AI Card Generation section — note the on-device provider), `CHANGELOG.md` (Unreleased entry)

**Interfaces:**
- Consumes: the new `make(preference:hasKey:fmAvailable:anthropic:)`, `AICardGenerationSettings.providerPreference`, `StudyDeckFMAvailability.isAvailable`.

- [ ] **Step 1: Rewire the call site.** At `BookSettingsView.swift:371`, replace the existing `StudyDeckGeneratorFactory.make(hasKey: hasKey) { AnthropicStudyDeckGenerator(...) }` with the 4-arg form, reading the preference + availability on the MainActor View init:

```swift
let generator = StudyDeckGeneratorFactory.make(
    preference: AICardGenerationSettings.providerPreference,
    hasKey: hasKey,
    fmAvailable: StudyDeckFMAvailability.isAvailable
) {
    AnthropicStudyDeckGenerator(client: AnthropicMessagesClient(apiKey: key, model: model))
}
```
(Keep the existing `hasKey`/`key`/`model` locals exactly as they are — only the `make(...)` call changes.)

- [ ] **Step 2: Cross-platform build gate (all three schemes)** — run sequentially, each prefixed with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&` (never two at once):
  - `make build-tests` then `make test-only FILTER=EchoTests/StudyDeckGeneratorFactoryMatrixTests` (and the other new suites) — green.
  - `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — BUILD SUCCEEDED.
  - `xcodebuild -scheme echo-cli build CODE_SIGNING_ALLOWED=NO` — BUILD SUCCEEDED (the FM files compile here too; `#if canImport(FoundationModels)` is true on the macOS SDK, `#available` gates runtime).

- [ ] **Step 3: Docs.** Add to the `### AI Card Generation` section of `ARCHITECTURE.md` a paragraph: a third on-device provider (`FoundationModelsStudyDeckGenerator`, gated iOS 26/macOS 26, no key, fully private) selected by `StudyDeckGeneratorFactory` per `AICardGenerationSettings.providerPreference` (auto = key wins → on-device → fixture), availability via `StudyDeckFMAvailability` (mirrors narration-QA; no locale pre-check). Add a `CHANGELOG.md` [Unreleased] entry.

- [ ] **Step 4: Commit** — `git commit -m "feat(study): wire on-device FM provider into generation + docs"`

---

## Self-Review

**Spec coverage (§9 iOS M4):** "ship same BYO-key generator on iOS" → already merged (cross-platform; this branch builds on it). "add on-device Foundation Models behind the same seam" → Tasks 1–3. "fix EDB's `supportsLocale()` bug" → avoided entirely (Global Constraints + Task 1 do no locale check, mirroring the shipped classifier). "iOS 26 gating" → `#if canImport(FoundationModels) && (os(iOS) || os(macOS))` + `@available(iOS 26, macOS 26)` throughout. "deterministic fixture as universal fallback" → factory matrix + the FM generator's `fallback`. "defer login/sell-tokens" → not built (out of scope). Provider preference (user's "key wins") → Task 3 matrix + Task 4 picker. Settings reachability (iOS + macOS) → the shared `AICardGenerationSettingsView` (already on both surfaces). Wiring → Task 5.

**Placeholder scan:** none — every FM call uses the verified shipped idiom; the mapper/factory code is complete; the device-only `respond` path is explicitly noted as not-unit-tested (matching narration-QA), not a TODO.

**Type consistency:** `StudyDeckGeneratorPreference` defined in Task 3, consumed in Tasks 4/5; `StudyDeckFMAvailability.isAvailable`/`.statusMessage` defined Task 1, consumed Tasks 4/5; `StudyDeckFMCardMapper.draft(...)` defined Task 2, used by the gated generator; `make(preference:hasKey:fmAvailable:anthropic:)` defined Task 3, called Task 5; `GeneratedStudyDeckCardDraft(id:sourceBlockID:frontText:backText:tags:kind:clozeText:)` matches the merged M3 type.
