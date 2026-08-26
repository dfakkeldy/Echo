# AI Provider Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Echo's cloud study-card generation talk to any Anthropic-compatible endpoint (Anthropic / DeepSeek / Kimi / GLM / Custom) via a persisted per-provider config with per-provider Keychain tokens, named consent, and Test Connection — while paying down the shipped generation-UX debt (progress wiring, dedup on regenerate, explicit no-provider state).

**Architecture:** One Codable value type (`AIProviderConfig`) persists non-secret provider config as JSON in UserDefaults; tokens live in the Keychain under per-provider accounts with a one-time migration from the legacy single Anthropic key. The existing `AnthropicMessagesClient` is parameterized (base URL, auth style, capability-driven dialect) instead of growing a second client: full dialect keeps adaptive thinking + `output_config` structured output; conservative dialect embeds the schema in the prompt and extracts JSON client-side with one corrective retry, then feeds the unchanged `StudyDeckOutputValidation` layer. The 3-way factory (`auto`: configured cloud → FM → **nil**) returns nil instead of a silent fixture, and the generation sheet renders an explicit "No AI Provider Configured" state, batch progress, and a duplicates-skipped note.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, GRDB, Swift Testing (`@Test`/`#expect`) for new value/service tests + XCTest (`StubURLProtocol`) for network-client tests — matching the split the codebase already uses in `EchoTests/StudyDeck/`.

**Spec:** `docs/superpowers/specs/2026-07-01-ai-provider-expansion-design.md` (implement ALL of it).

## Global Constraints

- Worktree/branch: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/pensive-fermi-dae756 on `claude/pensive-fermi-dae756` (already based on origin/nightly). Commit per task with Conventional Commits; do NOT push or open PRs from within a task.
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` as line 1 (a SwiftFormat PostToolUse hook reflows files — after edits verify the SPDX line is still line 1).
- DI style: concrete types + constructor/closure injection, tested against `DatabaseService(inMemory: true)`. NO new protocols or mocks. `@Observable`/@State — never ObservableObject/@Published.
- Concurrency: async/await + @MainActor where UI-adjacent; no DispatchQueue.main.async, no semaphores.
- Logging: os.Logger (match existing subsystem/category conventions); raw print only behind #if DEBUG.
- Tests: run `make build-tests` ONCE after code changes, then `make test-only FILTER=EchoTests/<SuiteName>` per suite (16 GB machine: never two xcodebuild invocations concurrently, never parallel testing). Prefix any full build with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`.
- New files must be added to the Xcode project (project.pbxproj) with correct target membership: Shared/ files → iOS + macOS (+ echo-cli ONLY if free of UIKit/PlayerModel deps); EchoCore/ files → iOS + macOS unless PlayerModel/UIKit-coupled (then iOS-only and EXCLUDED from macOS and echo-cli — broken exclusions surface as CI failures masked behind test steps).
- Simulator Keychain is flaky under unsigned test builds: never unit-test real Keychain round-trips; inject an in-memory store seam instead.
- Do not run macOS builds concurrently with iOS test runs.

### Project-mechanics notes (verified against this repo)

- **pbxproj mechanism:** `Shared/`, `EchoTests/` and `EchoCore/` are `PBXFileSystemSynchronizedRootGroup`s. `Shared/` and `EchoTests/` have **empty exception lists** (`Echo.xcodeproj/project.pbxproj` lines 511–518 and 474–480), so any new file under them is automatically a member of every target that links that group (Shared → iOS, macOS, watchOS, Widget, echo-cli; EchoTests → the test bundle). **No pbxproj edit is needed for any file this plan creates** — but every new `Shared/` file must therefore stay Foundation/GRDB-only (no SwiftUI/UIKit) so watchOS/Widget/echo-cli keep building. `EchoCore/` files are included everywhere except where an exception list excludes them; this plan only *modifies* existing EchoCore files, so membership never changes.
- `DatabaseService(inMemory:)` is spelled `try DatabaseService(inMemory: ())` in this codebase.
- `Logger(category:)` is the repo convenience init that fills in subsystem `com.echo.audiobooks` (`Shared/Logger+Subsystem.swift`).
- The repo compiles with Swift 6 `-default-isolation MainActor`: mark shared value types/functions `nonisolated` exactly as the existing `Shared/Services/AI/` files do.
- macOS build command (never concurrent with an iOS build/test):
  `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet`
- echo-cli build command:
  `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet`

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Shared/Services/AI/AIProviderConfig.swift` | Create | `AIProviderPreset` / `AIProviderAuthStyle` / `AIProviderCapabilities` / `AIProviderConfig` value types + preset defaults |
| `Shared/KeychainStore.swift` | Modify (Key enum, lines 20–27) | Add five per-provider token accounts (`aiProvider.<preset>`) |
| `Shared/Services/APIKeyStore.swift` | Modify (full rewrite) | Per-provider token API + injectable in-memory Keychain seam; legacy `anthropicKey` retained for migration |
| `Shared/Services/AI/AIProviderSettingsStore.swift` | Create | UserDefaults JSON persistence (`ai.provider.config`), generator preference (`ai.provider.preference`), one-time legacy migration |
| `Shared/Networking/LooseJSONExtractor.swift` | Create | First-balanced-JSON-object extraction (raw / fenced / prose-wrapped) for the conservative dialect |
| `Shared/Networking/AnthropicMessagesClient.swift` | Modify (full rewrite) | Base URL + auth style + capability-driven dialect; conservative prompt-embedded schema + one retry; `clients(config:token:)`; `ping()` |
| `Shared/Services/AI/AIProviderConnectionTester.swift` | Create | Test Connection outcome classification + user-facing messages |
| `Shared/Services/AI/AnthropicStudyDeckGenerator.swift` | Modify (lines 35–46, 91–104) | Optional `briefClient` so the Pass-1 book brief can use the light model |
| `Shared/Services/StudyDeckDraftDeduplicator.swift` | Create | Skip draft cards already accepted for the book (sourceBlockID + normalized front) |
| `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` | Modify (full rewrite) | `makeGenerator` init (progress sink + nil = no provider), `noProviderConfigured`, `duplicatesSkipped`, dedup in `runLoad()` |
| `Shared/Services/StudyDeckGenerating.swift` | Modify (factory, lines 26–75) | Replace legacy `make(...)` overloads with `makeForUI(preference:fmAvailable:cloud:)` returning optional |
| `EchoCore/Views/BookSettingsView.swift` | Modify (host, lines 360–392) | Sheet host resolves `AIProviderSettingsStore` config → client pair → factory, wires progress |
| `EchoCore/Views/StudyDeckGenerationSheet.swift` | Modify (body, lines 10–46) | "No AI Provider Configured" state + "N duplicates skipped" note |
| `EchoCore/Views/AICardGenerationSettingsView.swift` | Modify (full rewrite) | Provider dropdown, per-provider fields, capability toggles, named consent, Test Connection; deletes legacy `AICardGenerationSettings` enum |
| `EchoTests/StudyDeck/AIProviderConfigTests.swift` | Create/Test | Preset defaults + Codable round-trip |
| `EchoTests/StudyDeck/APIKeyStoreTests.swift` | Modify/Test (full rewrite) | Per-provider accounts via in-memory seam (no real Keychain) |
| `EchoTests/StudyDeck/AIProviderSettingsStoreTests.swift` | Create/Test | Persistence, preference, legacy migration, `hasConfiguredCloudProvider` |
| `EchoTests/StudyDeck/LooseJSONExtractorTests.swift` | Create/Test | Raw / fenced / prose / nested-brace / no-object cases |
| `EchoTests/StudyDeck/URLRequestBodyJSON.swift` | Create/Test support | Drain `httpBodyStream` so request-body snapshot tests can assert JSON bodies |
| `EchoTests/StudyDeck/AnthropicClientDialectTests.swift` | Create/Test | Body snapshots per dialect, auth headers, base-URL routing, extraction + retry |
| `EchoTests/StudyDeck/StubURLProtocol.swift` | Modify/Test support (lines 4–19, 22) | Add `transportError` injection for unreachable-host tests |
| `EchoTests/StudyDeck/AIProviderConnectionTesterTests.swift` | Create/Test | success / 401 / 429 / 404 / transport / empty-content classification |
| `EchoTests/StudyDeck/AnthropicStudyDeckGeneratorTests.swift` | Modify/Test (append) | Brief pass uses the light-model client |
| `EchoTests/StudyDeck/StudyDeckDraftDeduplicatorTests.swift` | Create/Test | Dedup by sourceBlockID + normalized front |
| `EchoTests/StudyDeckGenerationViewModelTests.swift` | Modify/Test (append) | No-provider state, progress sink hand-off, dedup surfaced |
| `EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift` | Modify/Test (full rewrite) | `makeForUI` matrix incl. explicit nil |
| `EchoTests/StudyDeck/StudyDeckGeneratorFactoryTests.swift` | Delete | Tested the deleted legacy `make(hasKey:)` overload |
| `EchoTests/StudyDeck/AICardGenerationSettingsProviderTests.swift` | Delete | Tested the retired `ai.cardgen.provider` legacy key |

---

## Task 1 — `AIProviderConfig` value types + preset defaults

**Files:**
- Create: `Shared/Services/AI/AIProviderConfig.swift`
- Test: `EchoTests/StudyDeck/AIProviderConfigTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation value types).
- Produces (later tasks depend on these exact signatures):
  - `nonisolated enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable { case anthropic, deepseek, kimi, glm, custom; var id: String; var displayName: String }`
  - `nonisolated enum AIProviderAuthStyle: String, Codable, Equatable, Sendable { case xAPIKey, bearer }`
  - `nonisolated struct AIProviderCapabilities: Codable, Equatable, Sendable { var supportsStructuredOutput: Bool; var supportsThinking: Bool; static let full: AIProviderCapabilities; static let conservative: AIProviderCapabilities }`
  - `nonisolated struct AIProviderConfig: Codable, Equatable, Sendable { var preset: AIProviderPreset; var baseURL: String; var authStyle: AIProviderAuthStyle; var primaryModel: String; var lightModel: String?; var capabilities: AIProviderCapabilities; var consented: Bool; static func defaults(for preset: AIProviderPreset) -> AIProviderConfig }`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeck/AIProviderConfigTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AIProviderConfigTests {
    @Test func anthropicPresetIsFullCapability() {
        let config = AIProviderConfig.defaults(for: .anthropic)
        #expect(config.baseURL == "https://api.anthropic.com")
        #expect(config.authStyle == .xAPIKey)
        #expect(config.capabilities == .full)
        #expect(config.primaryModel == "claude-opus-4-8")
        #expect(config.lightModel == "claude-haiku-4-5")
        #expect(!config.consented)
    }

    @Test(arguments: [AIProviderPreset.deepseek, .kimi, .glm, .custom])
    func compatPresetsAreConservativeBearer(preset: AIProviderPreset) {
        let config = AIProviderConfig.defaults(for: preset)
        #expect(config.authStyle == .bearer)
        #expect(config.capabilities == .conservative)
        #expect(!config.consented)
    }

    @Test func deepseekPresetPointsAtItsAnthropicEndpoint() {
        let config = AIProviderConfig.defaults(for: .deepseek)
        #expect(config.baseURL == "https://api.deepseek.com/anthropic")
        #expect(config.primaryModel == "deepseek-v4-pro[1m]")
        #expect(config.lightModel == "deepseek-v4-flash")
    }

    @Test func customPresetStartsEmpty() {
        let config = AIProviderConfig.defaults(for: .custom)
        #expect(config.baseURL.isEmpty)
        #expect(config.primaryModel.isEmpty)
        #expect(config.lightModel == nil)
    }

    @Test func codableRoundTrip() throws {
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.primaryModel = "deepseek-v4-pro[1m]"
        config.consented = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func displayNamesNameTheSpecificProvider() {
        #expect(AIProviderPreset.anthropic.displayName == "Anthropic")
        #expect(AIProviderPreset.deepseek.displayName == "DeepSeek")
        #expect(AIProviderPreset.kimi.displayName == "Kimi (Moonshot)")
        #expect(AIProviderPreset.glm.displayName == "GLM (Z.ai)")
        #expect(AIProviderPreset.custom.displayName == "Custom")
    }
}
```

- [ ] Run it and confirm it fails to compile (the types don't exist yet):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** with `cannot find 'AIProviderConfig' in scope` (and siblings) in `AIProviderConfigTests.swift`.

- [ ] If you have network access, spot-check the three compat endpoints against provider docs (DeepSeek `…/anthropic`, Kimi `api.moonshot.ai/anthropic`, GLM `api.z.ai/api/anthropic`). They ship as *editable* starting points, so proceed with the values below if offline — just note any correction in the commit body.

- [ ] Create `Shared/Services/AI/AIProviderConfig.swift` (no pbxproj edit needed — `Shared/` is a synchronized group with no exceptions, so this file joins iOS, macOS, watchOS, Widget, and echo-cli automatically; it is Foundation-only so all of them compile):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The five supported provider presets. All speak the Anthropic Messages dialect;
/// non-Anthropic presets point the same client at a compatible endpoint.
nonisolated enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case deepseek
    case kimi
    case glm
    case custom

    var id: String { rawValue }

    /// User-facing provider name; also interpolated into the 5.1.2(i) consent string,
    /// which must name the specific provider.
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi (Moonshot)"
        case .glm: return "GLM (Z.ai)"
        case .custom: return "Custom"
        }
    }
}

/// How the token is presented to the endpoint. Exactly one style is ever sent —
/// the real Anthropic API rejects requests carrying both credential headers.
nonisolated enum AIProviderAuthStyle: String, Codable, Equatable, Sendable {
    /// `x-api-key: <token>` (Anthropic's own style).
    case xAPIKey
    /// `Authorization: Bearer <token>` (most compat endpoints).
    case bearer
}

/// What the endpoint actually implements beyond the request envelope. Conservative
/// presets keep both off: compat endpoints tend to 400 on — or silently ignore —
/// `thinking` and `output_config`, and ignored structured output returns prose.
nonisolated struct AIProviderCapabilities: Codable, Equatable, Sendable {
    var supportsStructuredOutput: Bool
    var supportsThinking: Bool

    static let full = AIProviderCapabilities(
        supportsStructuredOutput: true, supportsThinking: true)
    static let conservative = AIProviderCapabilities(
        supportsStructuredOutput: false, supportsThinking: false)
}

/// Non-secret provider configuration, persisted as Codable JSON under the
/// `ai.provider.config` UserDefaults key. The token itself lives in the Keychain
/// under a per-provider account (see `APIKeyStore`).
nonisolated struct AIProviderConfig: Codable, Equatable, Sendable {
    var preset: AIProviderPreset
    /// Endpoint root; `/v1/messages` is appended by the client. Editable on every
    /// preset (endpoints move), prominent on Custom.
    var baseURL: String
    var authStyle: AIProviderAuthStyle
    /// Free-form model ID passed to the wire verbatim (`deepseek-v4-pro[1m]` is just an ID).
    var primaryModel: String
    /// Optional cheaper model for the Pass-1 book brief; nil/empty = use `primaryModel`.
    var lightModel: String?
    var capabilities: AIProviderCapabilities
    /// Per-provider App Store 5.1.2(i) consent — the toggle names `preset.displayName`.
    var consented: Bool

    /// Shipped starting points; every field stays editable in Settings.
    static func defaults(for preset: AIProviderPreset) -> AIProviderConfig {
        switch preset {
        case .anthropic:
            return AIProviderConfig(
                preset: .anthropic, baseURL: "https://api.anthropic.com",
                authStyle: .xAPIKey, primaryModel: "claude-opus-4-8",
                lightModel: "claude-haiku-4-5", capabilities: .full, consented: false)
        case .deepseek:
            return AIProviderConfig(
                preset: .deepseek, baseURL: "https://api.deepseek.com/anthropic",
                authStyle: .bearer, primaryModel: "deepseek-v4-pro[1m]",
                lightModel: "deepseek-v4-flash", capabilities: .conservative, consented: false)
        case .kimi:
            return AIProviderConfig(
                preset: .kimi, baseURL: "https://api.moonshot.ai/anthropic",
                authStyle: .bearer, primaryModel: "kimi-k2.5",
                lightModel: nil, capabilities: .conservative, consented: false)
        case .glm:
            return AIProviderConfig(
                preset: .glm, baseURL: "https://api.z.ai/api/anthropic",
                authStyle: .bearer, primaryModel: "glm-5",
                lightModel: nil, capabilities: .conservative, consented: false)
        case .custom:
            return AIProviderConfig(
                preset: .custom, baseURL: "",
                authStyle: .bearer, primaryModel: "",
                lightModel: nil, capabilities: .conservative, consented: false)
        }
    }
}
```

- [ ] Verify the SPDX line is still line 1 after the SwiftFormat hook ran.
- [ ] Build once, then run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/AIProviderConfigTests
```

Expected: **TEST SUCCEEDED** (9 test cases: 6 functions, one parameterized ×4).

- [ ] Commit:

```bash
git add Shared/Services/AI/AIProviderConfig.swift EchoTests/StudyDeck/AIProviderConfigTests.swift
git commit -m "feat(ai): add AIProviderConfig value types with five provider presets"
```

---

## Task 2 — Per-provider Keychain accounts + `APIKeyStore` in-memory seam

**Files:**
- Modify: `Shared/KeychainStore.swift` (Key enum, lines 20–27)
- Modify: `Shared/Services/APIKeyStore.swift` (full rewrite)
- Test: `EchoTests/StudyDeck/APIKeyStoreTests.swift` (full rewrite)

**Interfaces:**
- Consumes: `AIProviderPreset` (Task 1); `KeychainStore.data(for:service:)` / `.set(_:for:service:)` / `.remove(_:service:)` (existing, `Shared/KeychainStore.swift`).
- Produces:
  - `KeychainStore.Key` new cases: `.aiProviderAnthropic = "aiProvider.anthropic"`, `.aiProviderDeepSeek = "aiProvider.deepseek"`, `.aiProviderKimi = "aiProvider.kimi"`, `.aiProviderGLM = "aiProvider.glm"`, `.aiProviderCustom = "aiProvider.custom"`
  - `APIKeyStore.init(service: String = "com.echo.audiobooks", readData: @escaping (KeychainStore.Key, String) -> Data?, writeData: @escaping (Data, KeychainStore.Key, String) -> Bool, removeData: @escaping (KeychainStore.Key, String) -> Void)` (all closures defaulted to the real `KeychainStore`)
  - `func token(for preset: AIProviderPreset) -> String?`
  - `func setToken(_ token: String?, for preset: AIProviderPreset)`
  - `var anthropicKey: String? { get set }` (legacy account, migration-only), `var hasKey: Bool`, `func clear()` (both kept temporarily; removed in Task 11 when the last UI caller goes)
  - `extension AIProviderPreset { var keychainKey: KeychainStore.Key }`

**Steps:**

- [ ] Replace the entire contents of `EchoTests/StudyDeck/APIKeyStoreTests.swift` with the failing tests (the old `roundTripAndClear` test exercised the real Keychain via the DEBUG fallback; the seam makes that unnecessary):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

// @MainActor: APIKeyStore is MainActor-isolated. The in-memory dictionary seam keeps
// these tests off the real Keychain entirely (unsigned-simulator Keychain writes are
// run-to-run flaky under CODE_SIGNING_ALLOWED=NO).
@MainActor
@Suite struct APIKeyStoreTests {
    /// In-memory Keychain stand-in injected through APIKeyStore's closure seams.
    private final class MemoryKeychain {
        var storage: [String: Data] = [:]
        func store() -> APIKeyStore {
            APIKeyStore(
                service: "com.echo.test",
                readData: { key, _ in self.storage[key.rawValue] },
                writeData: { data, key, _ in
                    self.storage[key.rawValue] = data
                    return true
                },
                removeData: { key, _ in self.storage[key.rawValue] = nil }
            )
        }
    }

    @Test func perProviderTokensAreIsolated() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.setToken("sk-ant", for: .anthropic)
        store.setToken("sk-ds", for: .deepseek)
        #expect(store.token(for: .anthropic) == "sk-ant")
        #expect(store.token(for: .deepseek) == "sk-ds")
        #expect(store.token(for: .kimi) == nil)
        #expect(keychain.storage.keys.sorted() == ["aiProvider.anthropic", "aiProvider.deepseek"])
    }

    @Test func setTokenTrimsAndNilOrBlankRemoves() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.setToken("  sk-glm \n", for: .glm)
        #expect(store.token(for: .glm) == "sk-glm")
        store.setToken(nil, for: .glm)
        #expect(store.token(for: .glm) == nil)
        store.setToken("   ", for: .kimi)
        #expect(store.token(for: .kimi) == nil)
        #expect(keychain.storage.isEmpty)
    }

    @Test func legacyAccountIsDistinctFromPerProviderAccount() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.anthropicKey = "sk-legacy"
        #expect(store.token(for: .anthropic) == nil)  // different Keychain account
        #expect(keychain.storage.keys.sorted() == ["anthropicAPIKey"])
        store.anthropicKey = nil
        #expect(keychain.storage.isEmpty)
    }

    @Test func everyPresetHasAStableKeychainAccount() {
        #expect(AIProviderPreset.anthropic.keychainKey.rawValue == "aiProvider.anthropic")
        #expect(AIProviderPreset.deepseek.keychainKey.rawValue == "aiProvider.deepseek")
        #expect(AIProviderPreset.kimi.keychainKey.rawValue == "aiProvider.kimi")
        #expect(AIProviderPreset.glm.keychainKey.rawValue == "aiProvider.glm")
        #expect(AIProviderPreset.custom.keychainKey.rawValue == "aiProvider.custom")
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `APIKeyStore` has no `readData:` initializer, no `token(for:)`, and `AIProviderPreset` has no `keychainKey`.

- [ ] In `Shared/KeychainStore.swift`, extend the `Key` enum (currently lines 20–27). Replace:

```swift
    enum Key: String {
        case securityScopedBookmark
        case macLastFileBookmark
        case bookmarkNotes
        case absRefreshToken
        case absPinnedCertificate
        case anthropicAPIKey
    }
```

with:

```swift
    enum Key: String {
        case securityScopedBookmark
        case macLastFileBookmark
        case bookmarkNotes
        case absRefreshToken
        case absPinnedCertificate
        case anthropicAPIKey
        // Per-provider AI tokens (`aiProvider.<preset>`). `anthropicAPIKey` above is
        // the legacy single-key account, retained only so migration can read + clear it.
        case aiProviderAnthropic = "aiProvider.anthropic"
        case aiProviderDeepSeek = "aiProvider.deepseek"
        case aiProviderKimi = "aiProvider.kimi"
        case aiProviderGLM = "aiProvider.glm"
        case aiProviderCustom = "aiProvider.custom"
    }
```

- [ ] Replace the entire contents of `Shared/Services/APIKeyStore.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keychain-backed storage of per-provider AI tokens (BYO-token). Mirrors
/// ABSTokenStore's per-service Keychain pattern. The closure seams default to the
/// real `KeychainStore` and are overridden with an in-memory dictionary in unit
/// tests (the unsigned-simulator Keychain is run-to-run flaky).
@MainActor
final class APIKeyStore {
    private let service: String
    private let readData: (KeychainStore.Key, String) -> Data?
    private let writeData: (Data, KeychainStore.Key, String) -> Bool
    private let removeData: (KeychainStore.Key, String) -> Void

    init(
        service: String = "com.echo.audiobooks",
        readData: @escaping (KeychainStore.Key, String) -> Data? = {
            KeychainStore.data(for: $0, service: $1)
        },
        writeData: @escaping (Data, KeychainStore.Key, String) -> Bool = {
            KeychainStore.set($0, for: $1, service: $2)
        },
        removeData: @escaping (KeychainStore.Key, String) -> Void = {
            KeychainStore.remove($0, service: $1)
        }
    ) {
        self.service = service
        self.readData = readData
        self.writeData = writeData
        self.removeData = removeData
    }

    // MARK: - Per-provider tokens

    func token(for preset: AIProviderPreset) -> String? {
        string(for: preset.keychainKey)
    }

    /// Trims the token; nil/blank removes the entry.
    func setToken(_ token: String?, for preset: AIProviderPreset) {
        setString(token, for: preset.keychainKey)
    }

    // MARK: - Legacy single-key account (migration only)

    /// The pre-provider-expansion `anthropicAPIKey` account. Read + cleared by
    /// `AIProviderSettingsStore.migrateLegacyIfNeeded()`; do not add new callers.
    var anthropicKey: String? {
        get { string(for: .anthropicAPIKey) }
        set { setString(newValue, for: .anthropicAPIKey) }
    }

    var hasKey: Bool { anthropicKey != nil }

    func clear() { removeData(.anthropicAPIKey, service) }

    // MARK: - Shared plumbing

    private func string(for key: KeychainStore.Key) -> String? {
        readData(key, service)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func setString(_ value: String?, for key: KeychainStore.Key) {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, let data = value.data(using: .utf8)
        {
            _ = writeData(data, key, service)
        } else {
            removeData(key, service)
        }
    }
}

extension AIProviderPreset {
    /// Keychain account for this provider's token (`aiProvider.<preset>`).
    var keychainKey: KeychainStore.Key {
        switch self {
        case .anthropic: return .aiProviderAnthropic
        case .deepseek: return .aiProviderDeepSeek
        case .kimi: return .aiProviderKimi
        case .glm: return .aiProviderGLM
        case .custom: return .aiProviderCustom
        }
    }
}
```

Why keep `anthropicKey`/`hasKey`/`clear()`? `AICardGenerationSettingsView` (rewritten in Task 11) and the `BookSettingsView` sheet host (rewired in Task 10) still call them — deleting now would break the build mid-plan. Task 11 removes `hasKey`/`clear()`; `anthropicKey` stays for migration.

- [ ] Verify SPDX is line 1 in both modified files. Build once, run both affected suites serially:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/APIKeyStoreTests
```

Expected: **TEST SUCCEEDED** (4 tests).

- [ ] Commit:

```bash
git add Shared/KeychainStore.swift Shared/Services/APIKeyStore.swift EchoTests/StudyDeck/APIKeyStoreTests.swift
git commit -m "feat(ai): per-provider Keychain token accounts with injectable in-memory seam"
```

---

## Task 3 — `AIProviderSettingsStore`: persistence, preference, legacy migration

**Files:**
- Create: `Shared/Services/AI/AIProviderSettingsStore.swift`
- Test: `EchoTests/StudyDeck/AIProviderSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `AIProviderConfig`/`AIProviderPreset` (Task 1); `APIKeyStore` per-provider API + `anthropicKey` (Task 2); `StudyDeckGeneratorPreference` (existing, `Shared/Services/StudyDeckGenerating.swift` — `enum StudyDeckGeneratorPreference: String, Sendable { case auto, cloud, onDevice }`); `Logger(category:)` (existing).
- Produces:
  - `@MainActor final class AIProviderSettingsStore { init(defaults: UserDefaults = .standard, keyStore: APIKeyStore = APIKeyStore()) }`
  - `var config: AIProviderConfig? { get set }` (get runs migration lazily)
  - `var generatorPreference: StudyDeckGeneratorPreference { get set }`
  - `func token(for preset: AIProviderPreset) -> String?`
  - `func setToken(_ token: String?, for preset: AIProviderPreset)`
  - `var hasConfiguredCloudProvider: Bool`
  - `func migrateLegacyIfNeeded()`
  - Static keys: `configKey = "ai.provider.config"`, `preferenceKey = "ai.provider.preference"`, `legacyModelKey = "ai.cardgen.model"`, `legacyProviderKey = "ai.cardgen.provider"`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeck/AIProviderSettingsStoreTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AIProviderSettingsStoreTests {
    /// In-memory Keychain stand-in (same seam as APIKeyStoreTests).
    private final class MemoryKeychain {
        var storage: [String: Data] = [:]
        func keyStore() -> APIKeyStore {
            APIKeyStore(
                service: "com.echo.test",
                readData: { key, _ in self.storage[key.rawValue] },
                writeData: { data, key, _ in
                    self.storage[key.rawValue] = data
                    return true
                },
                removeData: { key, _ in self.storage[key.rawValue] = nil }
            )
        }
    }

    /// Fresh, isolated defaults per test (never UserDefaults.standard).
    private func makeDefaults() throws -> UserDefaults {
        let suite = "ai-provider-store-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallHasNoConfigAndAutoPreference() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(), keyStore: MemoryKeychain().keyStore())
        #expect(store.config == nil)
        #expect(store.generatorPreference == .auto)
        #expect(!store.hasConfiguredCloudProvider)
    }

    @Test func configRoundTripsAndNilClears() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(), keyStore: MemoryKeychain().keyStore())
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.consented = true
        store.config = config
        #expect(store.config == config)
        store.config = nil
        #expect(store.config == nil)
    }

    @Test func generatorPreferenceRoundTrips() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(), keyStore: MemoryKeychain().keyStore())
        store.generatorPreference = .onDevice
        #expect(store.generatorPreference == .onDevice)
    }

    @Test func legacyAnthropicSetupMigratesOnFirstRead() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-legacy".utf8)
        defaults.set("claude-sonnet-4-6", forKey: AIProviderSettingsStore.legacyModelKey)
        defaults.set("cloud", forKey: AIProviderSettingsStore.legacyProviderKey)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        let config = try #require(store.config)

        #expect(config.preset == .anthropic)
        #expect(config.primaryModel == "claude-sonnet-4-6")
        #expect(config.consented)  // legacy Save toggle already named Anthropic
        #expect(store.generatorPreference == .cloud)
        #expect(store.token(for: .anthropic) == "sk-legacy")
        // Legacy artifacts retired.
        #expect(keychain.storage["anthropicAPIKey"] == nil)
        #expect(defaults.string(forKey: AIProviderSettingsStore.legacyModelKey) == nil)
        #expect(defaults.string(forKey: AIProviderSettingsStore.legacyProviderKey) == nil)
    }

    @Test func migrationNeverClobbersAnExistingPerProviderToken() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-stale".utf8)
        keychain.storage["aiProvider.anthropic"] = Data("sk-current".utf8)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        _ = store.config

        #expect(store.token(for: .anthropic) == "sk-current")
        #expect(keychain.storage["anthropicAPIKey"] == nil)
    }

    @Test func migrationDoesNotOverwriteAnExistingNewStyleConfig() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-legacy".utf8)

        var existing = AIProviderConfig.defaults(for: .deepseek)
        existing.consented = true
        defaults.set(try JSONEncoder().encode(existing), forKey: AIProviderSettingsStore.configKey)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        #expect(store.config == existing)  // untouched
        #expect(store.token(for: .anthropic) == "sk-legacy")  // token still rescued
        #expect(keychain.storage["anthropicAPIKey"] == nil)
    }

    @Test func hasConfiguredCloudProviderRequiresConsentAndToken() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())

        var config = AIProviderConfig.defaults(for: .deepseek)
        config.consented = false
        store.config = config
        store.setToken("sk-ds", for: .deepseek)
        #expect(!store.hasConfiguredCloudProvider)  // no consent

        config.consented = true
        store.config = config
        #expect(store.hasConfiguredCloudProvider)

        store.setToken(nil, for: .deepseek)
        #expect(!store.hasConfiguredCloudProvider)  // no token

        store.setToken("sk-ds", for: .deepseek)
        config.baseURL = "   "
        store.config = config
        #expect(!store.hasConfiguredCloudProvider)  // blank base URL
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `cannot find 'AIProviderSettingsStore' in scope`.

- [ ] Create `Shared/Services/AI/AIProviderSettingsStore.swift` (Foundation-only → automatic membership in all targets, no pbxproj edit):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Persistence facade for the AI provider expansion: non-secret `AIProviderConfig`
/// as Codable JSON in UserDefaults, tokens in the Keychain via `APIKeyStore`, plus
/// a one-time migration of the legacy single-key Anthropic setup
/// (`anthropicAPIKey` Keychain entry + `ai.cardgen.model`/`ai.cardgen.provider`).
@MainActor
final class AIProviderSettingsStore {
    static let configKey = "ai.provider.config"
    static let preferenceKey = "ai.provider.preference"
    // Legacy keys retired by migrateLegacyIfNeeded().
    static let legacyModelKey = "ai.cardgen.model"
    static let legacyProviderKey = "ai.cardgen.provider"

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    private let logger = Logger(category: "AIProviderSettingsStore")

    init(defaults: UserDefaults = .standard, keyStore: APIKeyStore = APIKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
    }

    /// The active provider config, or nil when none is configured yet. Reading runs
    /// the legacy migration first, so pre-expansion installs surface their Anthropic
    /// setup transparently. Migration cost when there is nothing to migrate is one
    /// Keychain read, so calling this per Settings/sheet appearance is fine.
    var config: AIProviderConfig? {
        get {
            migrateLegacyIfNeeded()
            guard let data = defaults.data(forKey: Self.configKey) else { return nil }
            return try? JSONDecoder().decode(AIProviderConfig.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.configKey)
                return
            }
            defaults.set(data, forKey: Self.configKey)
        }
    }

    /// 3-way generator preference (auto / cloud / on-device), successor to the
    /// legacy `ai.cardgen.provider` key.
    var generatorPreference: StudyDeckGeneratorPreference {
        get {
            StudyDeckGeneratorPreference(
                rawValue: defaults.string(forKey: Self.preferenceKey) ?? "auto"
            ) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.preferenceKey) }
    }

    func token(for preset: AIProviderPreset) -> String? { keyStore.token(for: preset) }

    func setToken(_ token: String?, for preset: AIProviderPreset) {
        keyStore.setToken(token, for: preset)
    }

    /// True when the active config can drive cloud generation: consented, token
    /// present, and base URL + primary model non-blank.
    var hasConfiguredCloudProvider: Bool {
        guard let config, config.consented,
            !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !config.primaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            keyStore.token(for: config.preset) != nil
        else { return false }
        return true
    }

    /// One-time migration: an existing legacy `anthropicAPIKey` Keychain entry plus
    /// the `ai.cardgen.model` / `ai.cardgen.provider` defaults become an Anthropic
    /// `AIProviderConfig` (consent carries over — the legacy Save toggle already
    /// named Anthropic). Legacy keys are removed afterwards. Never overwrites an
    /// existing new-style config or per-provider token.
    func migrateLegacyIfNeeded() {
        // Preference migrates independently of the key.
        if let legacyPreference = defaults.string(forKey: Self.legacyProviderKey) {
            if defaults.string(forKey: Self.preferenceKey) == nil {
                defaults.set(legacyPreference, forKey: Self.preferenceKey)
            }
            defaults.removeObject(forKey: Self.legacyProviderKey)
        }

        guard let legacyKey = keyStore.anthropicKey else {
            // No legacy key: still retire a stray legacy model default.
            defaults.removeObject(forKey: Self.legacyModelKey)
            return
        }

        if defaults.data(forKey: Self.configKey) == nil {
            var migrated = AIProviderConfig.defaults(for: .anthropic)
            if let legacyModel = defaults.string(forKey: Self.legacyModelKey) {
                migrated.primaryModel = legacyModel
            }
            migrated.consented = true
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Self.configKey)
            }
            logger.info("Migrated legacy Anthropic key into AIProviderConfig")
        }
        if keyStore.token(for: .anthropic) == nil {
            keyStore.setToken(legacyKey, for: .anthropic)
        }
        keyStore.anthropicKey = nil
        defaults.removeObject(forKey: Self.legacyModelKey)
    }
}
```

- [ ] Verify SPDX is line 1. Build once, run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/AIProviderSettingsStoreTests
```

Expected: **TEST SUCCEEDED** (7 tests).

- [ ] Commit:

```bash
git add Shared/Services/AI/AIProviderSettingsStore.swift EchoTests/StudyDeck/AIProviderSettingsStoreTests.swift
git commit -m "feat(ai): AIProviderSettingsStore with UserDefaults config and legacy Anthropic migration"
```

---

## Task 4 — `LooseJSONExtractor` for the conservative dialect

**Files:**
- Create: `Shared/Networking/LooseJSONExtractor.swift`
- Test: `EchoTests/StudyDeck/LooseJSONExtractorTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces: `nonisolated enum LooseJSONExtractor { static func firstJSONObject(in text: String) -> String? }`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeck/LooseJSONExtractorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct LooseJSONExtractorTests {
    @Test func rawObjectPassesThrough() {
        #expect(LooseJSONExtractor.firstJSONObject(in: #"{"cards":[]}"#) == #"{"cards":[]}"#)
    }

    @Test func fencedBlockIsExtracted() {
        let text = "Here are your cards:\n```json\n{\"cards\":[{\"a\":1}]}\n```\nEnjoy!"
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"cards\":[{\"a\":1}]}")
    }

    @Test func proseWrappedObjectIsExtracted() {
        let text = "Sure! The result is {\"answer\": 42} — let me know if you need more."
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"answer\": 42}")
    }

    @Test func bracesAndEscapedQuotesInsideStringsDoNotUnbalance() {
        let text = #"{"front":"What does {curly} mean?","back":"A \"brace\"}"}"#
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == text)
    }

    @Test func skipsInvalidCandidateAndFindsLaterObject() {
        let text = "{not json} but then {\"ok\":true} follows"
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"ok\":true}")
    }

    @Test func returnsNilWhenNoValidObject() {
        #expect(LooseJSONExtractor.firstJSONObject(in: "no json here") == nil)
        #expect(LooseJSONExtractor.firstJSONObject(in: "{\"never\":\"closed\"") == nil)
        #expect(LooseJSONExtractor.firstJSONObject(in: "") == nil)
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `cannot find 'LooseJSONExtractor' in scope`.

- [ ] Create `Shared/Networking/LooseJSONExtractor.swift` (Foundation-only, automatic membership everywhere):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Client-side JSON recovery for the conservative provider dialect: compat endpoints
/// without structured output return the object raw, fenced (```json … ```), or
/// wrapped in prose. This scans for the first balanced `{…}` that actually parses
/// as a JSON object and returns it verbatim.
nonisolated enum LooseJSONExtractor {
    /// Returns the first balanced, `JSONSerialization`-valid top-level JSON object
    /// in `text`, or nil. Brace matching is string-aware (quotes + escapes), so
    /// braces inside string values never unbalance the scan.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                index += 1
                continue
            }
            if let candidate = balancedObject(in: chars, from: index),
                (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any]
            {
                return candidate
            }
            // Unbalanced or not valid JSON: keep scanning past this opening brace.
            index += 1
        }
        return nil
    }

    /// Substring from `start` to the brace that closes it, or nil when unbalanced.
    private static func balancedObject(in chars: [Character], from start: Int) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let char = chars[index]
            if escaped {
                escaped = false
            } else if inString, char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 { return String(chars[start...index]) }
                }
            }
            index += 1
        }
        return nil
    }
}
```

- [ ] Verify SPDX is line 1. Build once, run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/LooseJSONExtractorTests
```

Expected: **TEST SUCCEEDED** (6 tests).

- [ ] Commit:

```bash
git add Shared/Networking/LooseJSONExtractor.swift EchoTests/StudyDeck/LooseJSONExtractorTests.swift
git commit -m "feat(ai): loose JSON object extractor for conservative provider dialect"
```

---

## Task 5 — Parameterize `AnthropicMessagesClient` (base URL, auth style, dialect)

**Files:**
- Modify: `Shared/Networking/AnthropicMessagesClient.swift` (full rewrite)
- Create (test support): `EchoTests/StudyDeck/URLRequestBodyJSON.swift`
- Test: `EchoTests/StudyDeck/AnthropicClientDialectTests.swift` (new)
- Regression: `EchoTests/StudyDeck/AnthropicMessagesClientTests.swift` and `EchoTests/StudyDeck/AnthropicStudyDeckGeneratorTests.swift` must keep passing unchanged — the new init parameters are inserted *between* `model:` and `session:` with defaults, so existing `(apiKey:session:)` / `(apiKey:model:session:)` call sites still compile.

**Interfaces:**
- Consumes: `AIProviderAuthStyle`, `AIProviderCapabilities`, `AIProviderConfig` (Task 1); `LooseJSONExtractor.firstJSONObject(in:)` (Task 4); `StubURLProtocol` + `XCTAssertThrowsErrorAsync(_:_:)` (existing test support in `EchoTests/StudyDeck/`).
- Produces:
  - `nonisolated init(apiKey: String, model: String = "claude-opus-4-8", baseURL: URL = URL(string: "https://api.anthropic.com")!, authStyle: AIProviderAuthStyle = .xAPIKey, capabilities: AIProviderCapabilities = .full, session: URLSession = .shared)`
  - `static func clients(config: AIProviderConfig, token: String, session: URLSession = .shared) -> (primary: AnthropicMessagesClient, brief: AnthropicMessagesClient)?`
  - `func complete(systemPrompt: String, userPrompt: String, schema: [String: Any], maxTokens: Int) async throws -> String` (unchanged signature; behavior branches on `capabilities`)
  - `static func jsonOnlyInstruction(schema: [String: Any]) -> String`
  - `AnthropicClientError` gains `case invalidJSON`
  - (Test support) `extension URLRequest { nonisolated var stubBodyJSON: [String: Any]? }`

**Steps:**

- [ ] Create the test-support helper `EchoTests/StudyDeck/URLRequestBodyJSON.swift` (URLSession moves `httpBody` into `httpBodyStream` before a `URLProtocol` sees the request, so body-snapshot tests must drain the stream — the existing client tests only ever asserted headers):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension URLRequest {
    /// The URLProtocol-visible request body decoded as a JSON object. URLSession
    /// replaces `httpBody` with `httpBodyStream` before the protocol runs, so this
    /// drains the stream when needed. `nonisolated`: called from StubURLProtocol
    /// handlers on URLSession's queue.
    nonisolated var stubBodyJSON: [String: Any]? {
        var data = httpBody
        if data == nil, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        return data.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
    }
}
```

- [ ] Write the failing tests at `EchoTests/StudyDeck/AnthropicClientDialectTests.swift` (XCTest + `StubURLProtocol`, matching `AnthropicMessagesClientTests` idiom):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AnthropicClientDialectTests: XCTestCase {
    private let okBody = Data(
        #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"cards\":[]}"}]}"#.utf8)

    /// Wraps `text` in the Messages content envelope as a 200 body.
    private func envelope(_ text: String) -> Data {
        let inner = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return Data(
            "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\(inner)}]}"
                .utf8)
    }

    private func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Request-body snapshots per dialect

    func testFullDialectSendsThinkingAndOutputConfig() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            session: session {
                captured = $0
                return (200, self.okBody)
            })
        _ = try await client.complete(
            systemPrompt: "sys", userPrompt: "user", schema: ["type": "object"], maxTokens: 64)
        let body = try XCTUnwrap(captured?.stubBodyJSON)
        XCTAssertNotNil(body["thinking"])
        XCTAssertNotNil(body["output_config"])
        XCTAssertTrue(body["system"] is [[String: Any]])  // cached system block array
    }

    func testConservativeOmitsFeatureFieldsAndEmbedsSchemaInPrompt() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk", capabilities: .conservative,
            session: session {
                captured = $0
                return (200, self.okBody)
            })
        _ = try await client.complete(
            systemPrompt: "sys", userPrompt: "user", schema: ["type": "object"], maxTokens: 64)
        let body = try XCTUnwrap(captured?.stubBodyJSON)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["system"] as? String, "sys")  // plain-string system
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(content.hasPrefix("user"))
        XCTAssertTrue(content.contains("ONLY one JSON object"))
        XCTAssertTrue(content.contains(#"{"type":"object"}"#))  // sorted-keys schema inline
    }

    // MARK: - Auth headers (never both credentials)

    func testBearerAuthSendsExactlyOneCredentialHeader() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "tok-123", authStyle: .bearer,
            session: session {
                captured = $0
                return (200, self.okBody)
            })
        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testXAPIKeyAuthSendsExactlyOneCredentialHeader() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk-XYZ",
            session: session {
                captured = $0
                return (200, self.okBody)
            })
        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-api-key"), "sk-XYZ")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    // MARK: - Base-URL routing

    func testBaseURLRoutesToCompatEndpoint() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "tok", baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
            authStyle: .bearer, capabilities: .conservative,
            session: session {
                captured = $0
                return (200, self.okBody)
            })
        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        XCTAssertEqual(
            captured?.url?.absoluteString, "https://api.deepseek.com/anthropic/v1/messages")
    }

    // MARK: - Conservative JSON extraction + one retry

    func testConservativeExtractsFencedJSON() async throws {
        let client = AnthropicMessagesClient(
            apiKey: "sk", capabilities: .conservative,
            session: session { _ in
                (200, self.envelope("Here you go:\n```json\n{\"cards\":[]}\n```"))
            })
        let text = try await client.complete(
            systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 8)
        XCTAssertEqual(text, "{\"cards\":[]}")
    }

    func testConservativeRetriesOnceThenSucceeds() async throws {
        var callCount = 0
        let client = AnthropicMessagesClient(
            apiKey: "sk", capabilities: .conservative,
            session: session { _ in
                callCount += 1
                let text = callCount == 1 ? "I cannot produce JSON right now." : "{\"ok\":true}"
                return (200, self.envelope(text))
            })
        let result = try await client.complete(
            systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 8)
        XCTAssertEqual(result, "{\"ok\":true}")
        XCTAssertEqual(callCount, 2)
    }

    func testConservativeThrowsInvalidJSONAfterFailedRetry() async {
        var callCount = 0
        let client = AnthropicMessagesClient(
            apiKey: "sk", capabilities: .conservative,
            session: session { _ in
                callCount += 1
                return (200, self.envelope("still prose, no object"))
            })
        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 8)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .invalidJSON)
        }
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - clients(config:token:) factory

    func testClientsFactoryBuildsBriefFromLightModel() throws {
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.lightModel = "deepseek-v4-flash"
        let pair = try XCTUnwrap(AnthropicMessagesClient.clients(config: config, token: "tok"))
        XCTAssertEqual(pair.primary.model, "deepseek-v4-pro[1m]")
        XCTAssertEqual(pair.brief.model, "deepseek-v4-flash")
        XCTAssertEqual(pair.primary.baseURL.absoluteString, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(pair.primary.authStyle, .bearer)
        XCTAssertEqual(pair.primary.apiKey, "tok")

        config.lightModel = nil
        let solo = try XCTUnwrap(AnthropicMessagesClient.clients(config: config, token: "tok"))
        XCTAssertEqual(solo.brief.model, "deepseek-v4-pro[1m]")  // falls back to primary
    }

    func testClientsFactoryRejectsInvalidBaseURL() {
        var config = AIProviderConfig.defaults(for: .custom)
        config.baseURL = "   "
        config.primaryModel = "m"
        XCTAssertNil(AnthropicMessagesClient.clients(config: config, token: "tok"))
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — no `capabilities:`/`baseURL:`/`authStyle:` init parameters, no `clients(config:token:)`, no `.invalidJSON` case.

- [ ] Replace the entire contents of `Shared/Networking/AnthropicMessagesClient.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AnthropicClientError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case refusal(String?)
    case badStatus(Int)
    case emptyContent
    /// Conservative dialect only: the endpoint replied, but no valid JSON object
    /// could be extracted even after the one corrective retry.
    case invalidJSON
    case transport(String)
}

/// Minimal hand-written Anthropic Messages API client (no official Swift SDK), now
/// pointable at any Anthropic-compatible endpoint (DeepSeek / Kimi / GLM / custom
/// proxies) via `baseURL` + `authStyle`.
///
/// The request shape branches on `capabilities` (the dialect):
/// - Structured output ON (Anthropic): unchanged — `output_config.format` guarantees
///   a single JSON object in the assistant's text block; cached system block array.
/// - Structured output OFF (compat endpoints): the schema is embedded in the prompt
///   as a JSON-only instruction, the reply is JSON-extracted client-side (raw /
///   fenced / prose-wrapped) with ONE corrective retry on parse failure. Compat
///   endpoints implement the request *envelope*, not the feature matrix — unknown
///   fields 400 or get silently ignored, and ignored structured output returns prose.
/// - `thinking` is sent only when `capabilities.supportsThinking`.
/// - `anthropic-version` is sent in both dialects (compat endpoints expect it), and
///   exactly ONE credential header is ever set — the real API rejects double
///   credentials.
nonisolated struct AnthropicMessagesClient: Sendable {
    let apiKey: String
    let model: String
    let baseURL: URL
    let authStyle: AIProviderAuthStyle
    let capabilities: AIProviderCapabilities
    let session: URLSession

    nonisolated init(
        apiKey: String,
        model: String = "claude-opus-4-8",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        authStyle: AIProviderAuthStyle = .xAPIKey,
        capabilities: AIProviderCapabilities = .full,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.authStyle = authStyle
        self.capabilities = capabilities
        self.session = session
    }

    /// Builds the (primary, brief) client pair for a provider config. The brief
    /// client carries the cheaper light model when one is set, else it IS the
    /// primary client. Returns nil when the config's base URL is not a parseable
    /// absolute URL (caller surfaces that as a config error, not a crash).
    static func clients(
        config: AIProviderConfig, token: String, session: URLSession = .shared
    ) -> (primary: AnthropicMessagesClient, brief: AnthropicMessagesClient)? {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        func make(_ model: String) -> AnthropicMessagesClient {
            AnthropicMessagesClient(
                apiKey: token, model: model, baseURL: url,
                authStyle: config.authStyle, capabilities: config.capabilities,
                session: session)
        }
        let primary = make(config.primaryModel)
        let light = config.lightModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (primary, light.isEmpty ? primary : make(light))
    }

    nonisolated func complete(
        systemPrompt: String, userPrompt: String, schema: [String: Any], maxTokens: Int
    ) async throws -> String {
        if capabilities.supportsStructuredOutput {
            return try await performMessages(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                schema: schema, maxTokens: maxTokens)
        }
        // Conservative: schema goes into the prompt; JSON is extracted client-side.
        let prompt = userPrompt + Self.jsonOnlyInstruction(schema: schema)
        let first = try await performMessages(
            systemPrompt: systemPrompt, userPrompt: prompt, schema: nil, maxTokens: maxTokens)
        if let object = LooseJSONExtractor.firstJSONObject(in: first) { return object }
        // One corrective retry, then give up.
        let retryPrompt =
            prompt
            + "\n\nYour previous reply was not a single valid JSON object. "
            + "Reply again with ONLY the JSON object — no prose, no markdown fences."
        let second = try await performMessages(
            systemPrompt: systemPrompt, userPrompt: retryPrompt, schema: nil, maxTokens: maxTokens)
        if let object = LooseJSONExtractor.firstJSONObject(in: second) { return object }
        throw AnthropicClientError.invalidJSON
    }

    /// Minimal Messages call for Settings' Test Connection: tiny token budget, reply
    /// text ignored. Reuses the full status/refusal/transport classification below.
    nonisolated func ping() async throws {
        _ = try await performMessages(
            systemPrompt: "You are a connectivity check.",
            userPrompt: "Reply with the single word: pong",
            schema: nil, maxTokens: 16)
    }

    /// One Messages round-trip: builds the dialect-appropriate body (a non-nil
    /// `schema` selects the full structured-output envelope), classifies HTTP /
    /// refusal / transport errors, and returns the first text block.
    private nonisolated func performMessages(
        systemPrompt: String, userPrompt: String, schema: [String: Any]?, maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        switch authStyle {
        case .xAPIKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        if capabilities.supportsThinking {
            body["thinking"] = ["type": "adaptive"]
        }
        if let schema {
            // Full structured output: cached system block + JSON-schema response format.
            body["system"] = [
                ["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]
            ]
            body["output_config"] = [
                "effort": "medium", "format": ["type": "json_schema", "schema": schema],
            ]
        } else {
            // Conservative envelope: plain-string system, no output_config/effort.
            body["system"] = systemPrompt
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw AnthropicClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.transport("no response")
        }
        switch http.statusCode {
        case 200: break
        case 401: throw AnthropicClientError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicClientError.rateLimited(retryAfter: retry)
        default: throw AnthropicClientError.badStatus(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClientError.transport("non-JSON body")
        }
        if (json["stop_reason"] as? String) == "refusal" {
            let explanation = (json["stop_details"] as? [String: Any])?["explanation"] as? String
            throw AnthropicClientError.refusal(explanation)
        }
        let content = json["content"] as? [[String: Any]] ?? []
        guard
            let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"]
                as? String,
            !text.isEmpty
        else {
            throw AnthropicClientError.emptyContent
        }
        return text
    }

    /// Conservative-dialect instruction: demand a bare JSON object and inline the
    /// schema. `.sortedKeys` keeps the embedded schema deterministic for tests.
    static nonisolated func jsonOnlyInstruction(schema: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let schemaText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\n\nRespond with ONLY one JSON object — no prose, no markdown fences, "
            + "no explanations. The object must validate against this JSON schema:\n"
            + schemaText
    }
}
```

- [ ] Verify SPDX is line 1. Build once, then run the new suite **and** the two pre-existing suites that exercise this client (regression — their `(apiKey:session:)` call sites and header expectations must be untouched):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/AnthropicClientDialectTests
make test-only FILTER=EchoTests/AnthropicMessagesClientTests
make test-only FILTER=EchoTests/AnthropicStudyDeckGeneratorTests
```

Expected: **TEST SUCCEEDED** three times (10 new + 5 existing client + existing generator tests).

- [ ] Commit:

```bash
git add Shared/Networking/AnthropicMessagesClient.swift EchoTests/StudyDeck/URLRequestBodyJSON.swift EchoTests/StudyDeck/AnthropicClientDialectTests.swift
git commit -m "feat(ai): parameterize Messages client with base URL, auth style, and capability dialects"
```

---

## Task 6 — Test Connection: `AIProviderConnectionTester`

**Files:**
- Create: `Shared/Services/AI/AIProviderConnectionTester.swift`
- Modify: `EchoTests/StudyDeck/StubURLProtocol.swift` (add transport-error injection; lines 4–19 and `startLoading` at line 22)
- Test: `EchoTests/StudyDeck/AIProviderConnectionTesterTests.swift`

**Interfaces:**
- Consumes: `AnthropicMessagesClient.ping()` + `AnthropicClientError` (Task 5).
- Produces:
  - `nonisolated enum AIProviderConnectionOutcome: Equatable, Sendable { case success, badToken, rateLimited, unreachable(String), badStatus(Int), unexpectedResponse; var message: String }`
  - `nonisolated struct AIProviderConnectionTester: Sendable { let client: AnthropicMessagesClient; func test() async -> AIProviderConnectionOutcome }`
  - (Test support) `StubURLProtocol.transportError: Error?` — fails the request instead of responding; cleared by `reset()`.

**Steps:**

- [ ] In `EchoTests/StudyDeck/StubURLProtocol.swift`, add the error-injection hook. After the `extraHeaders` property (line 11), insert:

```swift
    /// When set, `startLoading` fails the request with this error instead of
    /// responding — simulates unreachable hosts for connection-tester tests.
    nonisolated(unsafe) static var transportError: Error?
```

In `reset()` add `transportError = nil` alongside the existing resets, and at the top of `startLoading()` insert:

```swift
        if let error = Self.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
```

- [ ] Write the failing tests at `EchoTests/StudyDeck/AIProviderConnectionTesterTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AIProviderConnectionTesterTests: XCTestCase {
    private func client(_ handler: @escaping (URLRequest) -> (Int, Data)) -> AnthropicMessagesClient {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: config))
    }

    func testSuccessfulPingReportsSuccess() async {
        let ok = Data(
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"pong"}]}"#.utf8)
        let outcome = await AIProviderConnectionTester(client: client { _ in (200, ok) }).test()
        XCTAssertEqual(outcome, .success)
    }

    func test401ReportsBadToken() async {
        let outcome = await AIProviderConnectionTester(
            client: client { _ in (401, Data("{}".utf8)) }
        ).test()
        XCTAssertEqual(outcome, .badToken)
    }

    func test429ReportsRateLimitedNotFailure() async {
        let outcome = await AIProviderConnectionTester(client: client { _ in (429, Data()) })
            .test()
        XCTAssertEqual(outcome, .rateLimited)
    }

    func testWrongPathReportsBadStatus() async {
        let outcome = await AIProviderConnectionTester(client: client { _ in (404, Data()) })
            .test()
        XCTAssertEqual(outcome, .badStatus(404))
    }

    func testUnreachableHostReportsUnreachable() async {
        StubURLProtocol.reset()
        StubURLProtocol.transportError = URLError(.cannotFindHost)
        defer { StubURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let tester = AIProviderConnectionTester(
            client: AnthropicMessagesClient(
                apiKey: "sk", session: URLSession(configuration: config)))
        let outcome = await tester.test()
        guard case .unreachable = outcome else {
            return XCTFail("expected .unreachable, got \(outcome)")
        }
    }

    func testEmptyContentReportsUnexpectedResponse() async {
        let empty = Data(#"{"stop_reason":"end_turn","content":[]}"#.utf8)
        let outcome = await AIProviderConnectionTester(client: client { _ in (200, empty) })
            .test()
        XCTAssertEqual(outcome, .unexpectedResponse)
    }

    func testEveryOutcomeHasANonEmptyUserMessage() {
        let outcomes: [AIProviderConnectionOutcome] = [
            .success, .badToken, .rateLimited, .unreachable("x"), .badStatus(500),
            .unexpectedResponse,
        ]
        for outcome in outcomes {
            XCTAssertFalse(outcome.message.isEmpty)
        }
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `cannot find 'AIProviderConnectionTester' in scope`.

- [ ] Create `Shared/Services/AI/AIProviderConnectionTester.swift` (Foundation-only, automatic membership everywhere):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of Settings' Test Connection, with a user-facing message per case.
nonisolated enum AIProviderConnectionOutcome: Equatable, Sendable {
    case success
    case badToken
    case rateLimited
    case unreachable(String)
    case badStatus(Int)
    case unexpectedResponse

    var message: String {
        switch self {
        case .success:
            return "Connection OK — the provider replied."
        case .badToken:
            return "The provider rejected this token (401). Check the token."
        case .rateLimited:
            return "Reachable but rate-limited (429) — the token works."
        case .unreachable(let detail):
            return "Could not reach the endpoint: \(detail). Check the base URL."
        case .badStatus(let code):
            return "Unexpected HTTP status \(code) — check the base URL and model."
        case .unexpectedResponse:
            return "The endpoint replied, but not with a Messages API response."
        }
    }
}

/// Runs a minimal Messages call (`client.ping()`, tiny max_tokens) and classifies
/// the outcome using the client's existing error classification. Doubles as the
/// spec's key validation — a 401 proves the token is bad, a 200/429 proves it works.
nonisolated struct AIProviderConnectionTester: Sendable {
    let client: AnthropicMessagesClient

    func test() async -> AIProviderConnectionOutcome {
        do {
            try await client.ping()
            return .success
        } catch let error as AnthropicClientError {
            switch error {
            case .unauthorized: return .badToken
            case .rateLimited: return .rateLimited
            case .transport(let detail): return .unreachable(detail)
            case .badStatus(let code): return .badStatus(code)
            case .refusal, .emptyContent, .invalidJSON: return .unexpectedResponse
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
```

- [ ] Verify SPDX is line 1. Build once, run the suite (plus the client suites once more since `StubURLProtocol` changed):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/AIProviderConnectionTesterTests
make test-only FILTER=EchoTests/AnthropicMessagesClientTests
```

Expected: **TEST SUCCEEDED** (7 new tests; existing client tests unaffected).

- [ ] Commit:

```bash
git add Shared/Services/AI/AIProviderConnectionTester.swift EchoTests/StudyDeck/StubURLProtocol.swift EchoTests/StudyDeck/AIProviderConnectionTesterTests.swift
git commit -m "feat(ai): Test Connection tester classifying provider endpoint outcomes"
```

---

## Task 7 — Light-model brief client in `AnthropicStudyDeckGenerator`

**Files:**
- Modify: `Shared/Services/AI/AnthropicStudyDeckGenerator.swift` (properties/init at lines 35–46; `bookBrief` at lines 91–104)
- Test: `EchoTests/StudyDeck/AnthropicStudyDeckGeneratorTests.swift` (append one test)

**Interfaces:**
- Consumes: `AnthropicMessagesClient` (Task 5); `URLRequest.stubBodyJSON` (Task 5 test support); `Mutex` (`import Synchronization`, already imported in the test file); existing helpers `source(_:)`, `ok(_:)` in the test file.
- Produces: `init(client: AnthropicMessagesClient, briefClient: AnthropicMessagesClient? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil)` — nil `briefClient` means "reuse `client`", so every existing call site keeps compiling.

**Steps:**

- [ ] Append the failing test inside `nonisolated final class AnthropicStudyDeckGeneratorTests` (after the existing two-pass helpers at the bottom of the class):

```swift
    // MARK: - Light-model brief client (AI provider expansion)

    /// Pass 1 (book brief) must go out on the brief client — the provider config's
    /// cheaper light model — while Pass 2 batches use the primary client.
    @MainActor
    func testBookBriefUsesBriefClient() async {
        StubURLProtocol.reset()
        let models = Mutex<[String]>([])
        StubURLProtocol.handler = { request in
            let model = request.stubBodyJSON?["model"] as? String ?? "?"
            models.withLock { $0.append(model) }
            let text =
                model == "light-model"
                ? #"{"summary":"s","themes":[],"keyConcepts":[]}"#
                : #"{"cards":[]}"#
            return self.ok(text)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let primary = AnthropicMessagesClient(
            apiKey: "sk", model: "primary-model", session: session)
        let brief = AnthropicMessagesClient(
            apiKey: "sk", model: "light-model", session: session)

        let gen = AnthropicStudyDeckGenerator(client: primary, briefClient: brief)
        _ = await gen.generate(sources: [source("epub-bk-s0-b0")], settings: .init())

        XCTAssertEqual(models.withLock { $0 }, ["light-model", "primary-model"])
    }
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `extra argument 'briefClient' in call`.

- [ ] In `Shared/Services/AI/AnthropicStudyDeckGenerator.swift`, replace the stored properties + init (lines 35–46):

```swift
    let client: AnthropicMessagesClient
    /// `(completedBatches, totalBatches)`, called after each batch completes.
    private let progress: (@Sendable (Int, Int) -> Void)?
    private let logger = Logger(category: "AnthropicStudyDeckGenerator")

    init(
        client: AnthropicMessagesClient,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.client = client
        self.progress = progress
    }
```

with:

```swift
    let client: AnthropicMessagesClient
    /// Pass-1 book-brief client — the provider config's cheaper light model when one
    /// is set. Defaults to `client` so single-model providers behave as before.
    let briefClient: AnthropicMessagesClient
    /// `(completedBatches, totalBatches)`, called after each batch completes.
    private let progress: (@Sendable (Int, Int) -> Void)?
    private let logger = Logger(category: "AnthropicStudyDeckGenerator")

    init(
        client: AnthropicMessagesClient,
        briefClient: AnthropicMessagesClient? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.client = client
        self.briefClient = briefClient ?? client
        self.progress = progress
    }
```

- [ ] In the same file, `bookBrief(sources:)` (lines 91–104): change `try await client.complete(` to `try await briefClient.complete(`. Nothing else in the method changes.

- [ ] Verify SPDX is line 1. Build once, run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/AnthropicStudyDeckGeneratorTests
```

Expected: **TEST SUCCEEDED** (all existing generator tests + the new one).

- [ ] Commit:

```bash
git add Shared/Services/AI/AnthropicStudyDeckGenerator.swift EchoTests/StudyDeck/AnthropicStudyDeckGeneratorTests.swift
git commit -m "feat(ai): route Pass-1 book brief through the provider's light model"
```

---

## Task 8 — `StudyDeckDraftDeduplicator`

**Files:**
- Create: `Shared/Services/StudyDeckDraftDeduplicator.swift`
- Test: `EchoTests/StudyDeck/StudyDeckDraftDeduplicatorTests.swift`

**Interfaces:**
- Consumes: `GeneratedStudyDeckDraft` / `GeneratedStudyDeckCardDraft` (existing, `Shared/Services/StudyDeckGenerationTypes.swift`); GRDB `DatabaseWriter` + the `flashcard` table (`audiobook_id`, `source_block_id`, `front_text` columns — see `Shared/Database/Schema_V1.swift` lines 84–110); `DatabaseService(inMemory: ())` in tests.
- Produces:
  - `struct StudyDeckDraftDeduplicator { let db: DatabaseWriter; struct Result { let draft: GeneratedStudyDeckDraft; let skippedCount: Int }; func deduplicate(_ draft: GeneratedStudyDeckDraft, audiobookID: String) throws -> Result; static func normalizedFront(_ text: String) -> String }`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeck/StudyDeckDraftDeduplicatorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckDraftDeduplicatorTests {
    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'T', 100)")
            // One accepted card anchored to block-1.
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp, source_block_id
                    ) VALUES ('f1', 'book', 'What  is retrieval practice?', 'A', 0, 'block-1')
                    """)
        }
        return service
    }

    private func draft(_ cards: [GeneratedStudyDeckCardDraft]) -> GeneratedStudyDeckDraft {
        GeneratedStudyDeckDraft(cards: cards, validSourceBlockIDs: Set(cards.map(\.sourceBlockID)))
    }

    @Test func skipsAcceptedDuplicateByBlockAndNormalizedFront() throws {
        let service = try seededService()
        let duplicate = GeneratedStudyDeckCardDraft(
            id: "ai-1", sourceBlockID: "block-1",
            frontText: "what is Retrieval   practice?", backText: "B")
        let freshFront = GeneratedStudyDeckCardDraft(
            id: "ai-2", sourceBlockID: "block-1", frontText: "A different question?", backText: "B")
        let otherBlock = GeneratedStudyDeckCardDraft(
            id: "ai-3", sourceBlockID: "block-2",
            frontText: "What is retrieval practice?", backText: "B")

        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([duplicate, freshFront, otherBlock]), audiobookID: "book")

        #expect(result.skippedCount == 1)
        #expect(result.draft.cards.map(\.id) == ["ai-2", "ai-3"])
    }

    @Test func otherBooksCardsDoNotCauseSkips() throws {
        let service = try seededService()
        let card = GeneratedStudyDeckCardDraft(
            id: "ai-1", sourceBlockID: "block-1",
            frontText: "What is retrieval practice?", backText: "B")

        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([card]), audiobookID: "another-book")

        #expect(result.skippedCount == 0)
        #expect(result.draft.cards.count == 1)
    }

    @Test func passesThroughWhenNoAcceptedCards() throws {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'T', 100)")
        }
        let card = GeneratedStudyDeckCardDraft(
            id: "ai-1", sourceBlockID: "block-1", frontText: "Q?", backText: "A")
        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([card]), audiobookID: "book")
        #expect(result.skippedCount == 0)
        #expect(result.draft.cards.count == 1)
    }

    @Test func normalizationLowercasesTrimsAndCollapsesWhitespace() {
        #expect(StudyDeckDraftDeduplicator.normalizedFront("  What\n IS   x? ") == "what is x?")
        #expect(StudyDeckDraftDeduplicator.normalizedFront("plain") == "plain")
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `cannot find 'StudyDeckDraftDeduplicator' in scope`.

- [ ] Create `Shared/Services/StudyDeckDraftDeduplicator.swift` (Foundation + GRDB only, automatic membership everywhere):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Drops draft cards that duplicate an already-accepted flashcard for the same book:
/// same `sourceBlockID` AND same normalized front text (lowercased, trimmed,
/// whitespace-collapsed). Regenerating a deck therefore only proposes genuinely new
/// cards; the count of skipped duplicates is surfaced in the generation sheet.
struct StudyDeckDraftDeduplicator {
    let db: DatabaseWriter

    struct Result {
        let draft: GeneratedStudyDeckDraft
        let skippedCount: Int
    }

    func deduplicate(
        _ draft: GeneratedStudyDeckDraft, audiobookID: String
    ) throws -> Result {
        let existing = try existingCardKeys(audiobookID: audiobookID)
        guard !existing.isEmpty else { return Result(draft: draft, skippedCount: 0) }

        var kept: [GeneratedStudyDeckCardDraft] = []
        var skipped = 0
        for card in draft.cards {
            let key = Self.key(sourceBlockID: card.sourceBlockID, frontText: card.frontText)
            if existing.contains(key) {
                skipped += 1
            } else {
                kept.append(card)
            }
        }
        // Kept cards already passed draft validation; rebuilding with their own IDs
        // as the valid set passes them through unchanged.
        return Result(
            draft: GeneratedStudyDeckDraft(
                cards: kept, validSourceBlockIDs: Set(kept.map(\.sourceBlockID))),
            skippedCount: skipped)
    }

    static func normalizedFront(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func key(sourceBlockID: String, frontText: String) -> String {
        sourceBlockID + "|" + normalizedFront(frontText)
    }

    private func existingCardKeys(audiobookID: String) throws -> Set<String> {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_block_id, front_text FROM flashcard
                    WHERE audiobook_id = ? AND source_block_id IS NOT NULL
                    """,
                arguments: [audiobookID])
            return Set(
                rows.map { row in
                    Self.key(sourceBlockID: row["source_block_id"], frontText: row["front_text"])
                })
        }
    }
}
```

- [ ] Verify SPDX is line 1. Build once, run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyDeckDraftDeduplicatorTests
```

Expected: **TEST SUCCEEDED** (4 tests).

- [ ] Commit:

```bash
git add Shared/Services/StudyDeckDraftDeduplicator.swift EchoTests/StudyDeck/StudyDeckDraftDeduplicatorTests.swift
git commit -m "feat(study): dedup generated drafts against accepted flashcards"
```

---

## Task 9 — `StudyDeckGenerationViewModel`: no-provider state, progress sink, dedup

**Files:**
- Modify: `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` (full rewrite; the file is included in iOS, macOS, echo-cli and Widget targets — it stays SwiftUI-free, so membership is unchanged)
- Test: `EchoTests/StudyDeckGenerationViewModelTests.swift` (append three tests; existing tests must keep passing — the old `generator:` init is preserved as a convenience wrapper)

**Interfaces:**
- Consumes: `StudyDeckDraftDeduplicator` (Task 8); `StudyDeckGenerating` / `FixtureStudyDeckGenerator` / `StudyDeckSourceBuilder` / `StudyDeckAcceptanceService` / `StudyDeckGenerationSettings` (existing).
- Produces:
  - `init(audiobookID: String, bookTitle: String, db: DatabaseWriter, makeGenerator: @escaping (@escaping @Sendable (Int, Int) -> Void) -> (any StudyDeckGenerating)?)` — the closure receives the MainActor-bridged progress sink and returns the resolved generator, or **nil when no AI provider is configured**.
  - `init(audiobookID: String, bookTitle: String, db: DatabaseWriter, generator: any StudyDeckGenerating = FixtureStudyDeckGenerator())` — kept for tests/echo-cli-style fixed generators; wraps the closure init.
  - New observable state: `var noProviderConfigured: Bool`, `var duplicatesSkipped: Int` (plus all existing state unchanged).

**Steps:**

- [ ] Append the failing tests inside `@MainActor @Suite struct StudyDeckGenerationViewModelTests` (before the `private static let fixedNow` line; they reuse the existing `seededService()`, `StubGenerator`, and `ProgressGenerator` helpers already in the file):

```swift
    // MARK: - AI provider expansion (no-provider state, progress sink, dedup)

    @Test func nilGeneratorShowsExplicitNoProviderState() async throws {
        let service = try seededService()
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            makeGenerator: { _ in nil }
        )

        await viewModel.load()

        #expect(viewModel.noProviderConfigured)
        #expect(viewModel.cards.isEmpty)
        #expect(viewModel.errorMessage == nil)  // a state, not an error
        #expect(!viewModel.isLoading)
    }

    @Test func makeGeneratorReceivesTheProgressSink() async throws {
        let service = try seededService()
        let captured = Mutex<[(Int, Int)]>([])
        let card = GeneratedStudyDeckCardDraft(
            id: "stub-card", sourceBlockID: "block-1", frontText: "Q", backText: "A")
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            makeGenerator: { sink in
                // The VM hands its MainActor-bridged sink to the builder; wiring it
                // into the generator's progress callback is exactly what the sheet
                // host does with AnthropicStudyDeckGenerator(progress:).
                ProgressGenerator(cards: [card]) { done, total in
                    captured.withLock { $0.append((done, total)) }
                    sink(done, total)
                }
            }
        )

        await viewModel.load()

        #expect(captured.withLock { $0.map(\.0) } == [1, 2])
        #expect(viewModel.progress == nil)  // reset once the load finishes
        #expect(viewModel.cards.map(\.id) == ["stub-card"])
        #expect(!viewModel.noProviderConfigured)
    }

    @Test func loadSkipsAlreadyAcceptedDuplicatesAndReportsCount() async throws {
        let service = try seededService()
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp, source_block_id
                    ) VALUES ('f1', 'book', 'Q', 'A', 0, 'block-1')
                    """)
        }
        let duplicate = GeneratedStudyDeckCardDraft(
            id: "stub-dup", sourceBlockID: "block-1", frontText: "Q", backText: "A2")
        let fresh = GeneratedStudyDeckCardDraft(
            id: "stub-new", sourceBlockID: "block-2", frontText: "Q2", backText: "A2")
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            generator: StubGenerator(cards: [duplicate, fresh])
        )

        await viewModel.load()

        #expect(viewModel.duplicatesSkipped == 1)
        #expect(viewModel.cards.map(\.id) == ["stub-new"])
        #expect(viewModel.selectedCardIDs == ["stub-new"])
    }
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — no `makeGenerator:` init, no `noProviderConfigured` / `duplicatesSkipped` members.

- [ ] Replace the entire contents of `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudyDeckGenerationViewModel {
    var cards: [GeneratedStudyDeckCardDraft] = []
    var selectedCardIDs: Set<String> = []
    var isLoading = false
    var isAccepting = false
    var errorMessage: String?
    var acceptedCount = 0
    /// `(done, total)` batch progress while a generation run is in flight; `nil` otherwise.
    var progress: (done: Int, total: Int)?
    /// True when `makeGenerator` resolved no provider (no cloud config + no FM):
    /// the sheet shows an explicit "No AI Provider Configured" state — never a
    /// silent fixture fallback.
    var noProviderConfigured = false
    /// Drafts dropped because an accepted card with the same sourceBlockID +
    /// normalized front text already exists (dedup on regenerate).
    var duplicatesSkipped = 0

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    /// Receives the MainActor-bridged progress sink; returns the resolved generator,
    /// or nil when no AI provider is configured.
    @ObservationIgnored private let makeGenerator:
        (@escaping @Sendable (Int, Int) -> Void) -> (any StudyDeckGenerating)?
    @ObservationIgnored private let logger = Logger(category: "StudyDeckGenerationViewModel")
    @ObservationIgnored private var draft: GeneratedStudyDeckDraft?
    /// The in-flight load, owned here so `cancelLoad()` (e.g. the sheet's Cancel button) can cancel it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedCardCount: Int {
        selectedCardIDs.count
    }

    var canAccept: Bool {
        !isLoading && !isAccepting && !cards.isEmpty && !selectedCardIDs.isEmpty
    }

    var isShowingError: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    /// Fixed-generator convenience for tests (the fixture default is exercised only
    /// by tests; production goes through the `makeGenerator:` initializer below so
    /// the factory can report an explicit no-provider state).
    init(
        audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter,
        generator: any StudyDeckGenerating = FixtureStudyDeckGenerator()
    ) {
        self.init(
            audiobookID: audiobookID,
            bookTitle: bookTitle,
            db: db,
            makeGenerator: { _ in generator }
        )
    }

    init(
        audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter,
        makeGenerator: @escaping (@escaping @Sendable (Int, Int) -> Void) ->
            (any StudyDeckGenerating)?
    ) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
        self.makeGenerator = makeGenerator
    }

    /// Runs a cancellable generation. Owns the work in `loadTask` so `cancelLoad()` can stop it,
    /// while keeping the existing `.task { await viewModel.load() }` call site working (we await
    /// the stored task's value).
    func load() async {
        loadTask = Task { await self.runLoad() }
        await loadTask?.value
        loadTask = nil
    }

    /// Cancels an in-flight `load()` (e.g. the sheet's Cancel button).
    func cancelLoad() {
        loadTask?.cancel()
    }

    private func runLoad() async {
        isLoading = true
        defer {
            isLoading = false
            progress = nil
        }

        do {
            errorMessage = nil
            acceptedCount = 0
            progress = nil
            duplicatesSkipped = 0
            noProviderConfigured = false

            guard
                let generator = makeGenerator({ done, total in
                    Task { @MainActor [weak self] in
                        self?.progress = (done, total)
                    }
                })
            else {
                noProviderConfigured = true
                draft = nil
                cards = []
                selectedCardIDs = []
                return
            }

            let sources = try StudyDeckSourceBuilder(db: db).sources(
                audiobookID: audiobookID,
                selection: .wholeBook
            )
            let generatedDraft = await generator.generate(
                sources: sources,
                settings: StudyDeckGenerationSettings()
            )
            let deduped = try StudyDeckDraftDeduplicator(db: db)
                .deduplicate(generatedDraft, audiobookID: audiobookID)

            draft = deduped.draft
            duplicatesSkipped = deduped.skippedCount
            cards = deduped.draft.cards
            selectedCardIDs = Set(deduped.draft.cards.map(\.id))
        } catch {
            draft = nil
            cards = []
            selectedCardIDs = []
            errorMessage = error.localizedDescription
            logger.error("Failed to generate study deck draft: \(error.localizedDescription)")
        }
    }

    func toggleCard(_ card: GeneratedStudyDeckCardDraft) {
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    @discardableResult
    func accept(now: Date = Date()) -> Bool {
        acceptedCount = 0

        guard let draft else {
            errorMessage = "Generate a study deck draft before accepting cards."
            return false
        }
        guard !selectedCardIDs.isEmpty else {
            errorMessage = "Select at least one card to accept."
            return false
        }

        isAccepting = true
        defer { isAccepting = false }

        do {
            errorMessage = nil
            let acceptedCards = try StudyDeckAcceptanceService(db: db).accept(
                draft,
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                selectedCardIDs: selectedCardIDs,
                now: now
            )
            guard !acceptedCards.isEmpty else {
                errorMessage = "No cards were accepted."
                return false
            }

            acceptedCount = acceptedCards.count
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID]
            )
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to accept generated study deck: \(error.localizedDescription)")
            return false
        }
    }
}
```

Why a builder closure instead of injecting the generator directly? The progress sink must write `self.progress`, but the generator is constructed in `BookSettingsView`'s host *before* the VM exists. Handing the VM a builder inverts that: the VM creates its own MainActor-bridged sink, passes it to the builder, and the builder threads it into `AnthropicStudyDeckGenerator(progress:)`. The same closure returning nil is how "no provider configured" reaches the UI without a sentinel generator.

- [ ] Verify SPDX is line 1. Build once, run the suite:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyDeckGenerationViewModelTests
```

Expected: **TEST SUCCEEDED** (all 8 pre-existing tests + 3 new ones).

- [ ] Commit:

```bash
git add EchoCore/ViewModels/StudyDeckGenerationViewModel.swift EchoTests/StudyDeckGenerationViewModelTests.swift
git commit -m "feat(study): no-provider state, progress sink, and dedup in generation view model"
```

---

## Task 10 — Factory `makeForUI` + sheet host rewire + no-provider/dedup UI

This task moves as one unit because deleting the legacy factory overloads breaks the `BookSettingsView` host until it is rewired, and the sheet's new states render VM fields added in Task 9.

**Files:**
- Modify: `Shared/Services/StudyDeckGenerating.swift` (replace the `StudyDeckGeneratorFactory` body, lines 26–75; the protocol and `StudyDeckGeneratorPreference` above it are untouched)
- Modify: `EchoCore/Views/BookSettingsView.swift` (`StudyDeckGenerationSheetHost`, lines 360–392)
- Modify: `EchoCore/Views/StudyDeckGenerationSheet.swift` (body branches, lines 10–46)
- Test: `EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift` (full rewrite)
- Delete: `EchoTests/StudyDeck/StudyDeckGeneratorFactoryTests.swift` (tested only the deleted `make(hasKey:anthropic:)` overload)

**Interfaces:**
- Consumes: `AIProviderSettingsStore` (Task 3); `AnthropicMessagesClient.clients(config:token:)` (Task 5); `AnthropicStudyDeckGenerator(client:briefClient:progress:)` (Task 7); `StudyDeckGenerationViewModel(makeGenerator:)` + `noProviderConfigured`/`duplicatesSkipped` (Task 9); `StudyDeckFMAvailability.isAvailable` (existing); `FoundationModelsStudyDeckGenerator` (existing, unchanged).
- Produces:
  - `nonisolated static func makeForUI(preference: StudyDeckGeneratorPreference, fmAvailable: Bool, cloud: (@Sendable () -> any StudyDeckGenerating)?) -> (any StudyDeckGenerating)?` — `cloud == nil` means "no configured cloud provider"; a nil **result** means "no AI provider at all" (explicit empty state). `FixtureStudyDeckGenerator` remains referenced only by echo-cli (`Tools/echo-cli/GenerateDeckCommand.swift` constructs it directly), `FoundationModelsStudyDeckGenerator`'s internal runtime fallback, and tests.

**Steps:**

- [ ] Delete the legacy factory test file:

```bash
git rm EchoTests/StudyDeck/StudyDeckGeneratorFactoryTests.swift
```

- [ ] Replace the entire contents of `EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift` with the failing tests:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class StudyDeckGeneratorFactoryMatrixTests: XCTestCase {
    // Stand-in for the cloud builder — lets us assert cloud-path selection by type identity.
    private struct CloudSentinel: StudyDeckGenerating {
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: [])
        }
    }

    private func make(
        _ p: StudyDeckGeneratorPreference,
        cloud: Bool,
        fm: Bool
    ) -> (any StudyDeckGenerating)? {
        StudyDeckGeneratorFactory.makeForUI(
            preference: p, fmAvailable: fm, cloud: cloud ? { CloudSentinel() } : nil)
    }

    // MARK: - Matrix tests

    func testAutoConfiguredCloudWins() {
        XCTAssertTrue(make(.auto, cloud: true, fm: true) is CloudSentinel)
    }

    // Tolerant: fmAvailable=true resolves to the FM generator when the iOS 26 SDK is
    // available, or nil on an older sim. Must never be CloudSentinel or the fixture.
    func testAutoNoCloudFmAvailableUsesOnDeviceNeverFixture() {
        let generator = make(.auto, cloud: false, fm: true)
        XCTAssertFalse(generator is CloudSentinel)
        XCTAssertFalse(generator is FixtureStudyDeckGenerator)
    }

    func testAutoNoCloudNoFmIsExplicitlyNil() {
        XCTAssertNil(make(.auto, cloud: false, fm: false))
    }

    func testCloudPreferenceWithoutProviderIsNilNotFixture() {
        XCTAssertNil(make(.cloud, cloud: false, fm: true))
    }

    func testCloudPreferenceUsesCloud() {
        XCTAssertTrue(make(.cloud, cloud: true, fm: false) is CloudSentinel)
    }

    func testOnDeviceWithoutFmIsNilEvenWithCloudConfigured() {
        XCTAssertNil(make(.onDevice, cloud: true, fm: false))
    }
}
```

- [ ] Run and confirm compile failure:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: **BUILD FAILED** — `type 'StudyDeckGeneratorFactory' has no member 'makeForUI'`.

- [ ] In `Shared/Services/StudyDeckGenerating.swift`, replace the whole `enum StudyDeckGeneratorFactory { … }` block (lines 26–75 — both legacy `make` overloads AND the private `onDevice` helper) with:

```swift
enum StudyDeckGeneratorFactory {
    /// UI-facing provider resolution. `cloud` is nil when no cloud provider is
    /// configured (no config, no token, or no consent — see
    /// `AIProviderSettingsStore.hasConfiguredCloudProvider`). A nil RESULT means
    /// "no AI provider available": the generation sheet shows an explicit
    /// "No AI Provider Configured" state instead of silently falling back to
    /// `FixtureStudyDeckGenerator` (which remains for echo-cli and tests only).
    /// Selection matrix:
    ///   .auto     + cloud    → cloud()
    ///   .auto     + no cloud → on-device FM when available, else nil
    ///   .cloud               → cloud(), else nil
    ///   .onDevice            → on-device FM when available, else nil
    nonisolated static func makeForUI(
        preference: StudyDeckGeneratorPreference,
        fmAvailable: Bool,
        cloud: (@Sendable () -> any StudyDeckGenerating)?
    ) -> (any StudyDeckGenerating)? {
        switch preference {
        case .cloud:
            return cloud?()
        case .onDevice:
            return onDevice(ifAvailable: fmAvailable)
        case .auto:
            if let cloud { return cloud() }
            return onDevice(ifAvailable: fmAvailable)
        }
    }

    /// Returns a `FoundationModelsStudyDeckGenerator` when `ifAvailable` is true AND the
    /// current SDK/OS supports Foundation Models; otherwise `nil`.
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

Also update the factory doc comment above `StudyDeckGeneratorPreference` if it still references the deleted overloads (the `/// Kept for the existing call site in BookSettingsView` sentence goes away with them).

- [ ] In `EchoCore/Views/BookSettingsView.swift`, replace the whole `StudyDeckGenerationSheetHost` struct (lines 360–392) with:

```swift
private struct StudyDeckGenerationSheetHost: View {
    @State private var viewModel: StudyDeckGenerationViewModel

    init(presentation: StudyDeckGenerationSheetPresentation) {
        // Resolve the provider on the MainActor (View.init is @MainActor). Capture
        // only Sendable values (preference/availability/client pair) so the @Sendable
        // cloud builder never crosses actor boundaries with a @MainActor object.
        let store = AIProviderSettingsStore()
        let preference = store.generatorPreference
        let fmAvailable = StudyDeckFMAvailability.isAvailable
        let clients: (primary: AnthropicMessagesClient, brief: AnthropicMessagesClient)?
        if store.hasConfiguredCloudProvider,
            let config = store.config,
            let token = store.token(for: config.preset)
        {
            clients = AnthropicMessagesClient.clients(config: config, token: token)
        } else {
            clients = nil
        }

        _viewModel = State(
            wrappedValue: StudyDeckGenerationViewModel(
                audiobookID: presentation.audiobookID,
                bookTitle: presentation.bookTitle,
                db: presentation.db,
                makeGenerator: { progress in
                    let cloud: (@Sendable () -> any StudyDeckGenerating)? = clients.map { pair in
                        {
                            AnthropicStudyDeckGenerator(
                                client: pair.primary,
                                briefClient: pair.brief,
                                progress: progress)
                        }
                    }
                    return StudyDeckGeneratorFactory.makeForUI(
                        preference: preference, fmAvailable: fmAvailable, cloud: cloud)
                }
            )
        )
    }

    var body: some View {
        StudyDeckGenerationSheet(viewModel: viewModel)
    }
}
```

- [ ] In `EchoCore/Views/StudyDeckGenerationSheet.swift`, update the body's Form. Replace (lines 10–35):

```swift
            Form {
                if viewModel.isLoading {
                    Section {
                        if let progress = viewModel.progress {
                            ProgressView(
                                "Generating cards… (\(progress.done) of \(progress.total))",
                                value: Double(progress.done),
                                total: Double(progress.total)
                            )
                        } else {
                            ProgressView("Generating Study Deck")
                        }
                    }
                } else if viewModel.cards.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Eligible Blocks",
                            systemImage: "rectangle.stack.badge.questionmark",
                            description: Text(
                                "This book does not have visible EPUB text blocks for a study deck."
                            )
                        )
                    }
                } else {
                    StudyDeckDraftCardsSection(viewModel: viewModel)
                }
```

with:

```swift
            Form {
                if viewModel.isLoading {
                    Section {
                        if let progress = viewModel.progress {
                            ProgressView(
                                "Generating cards… (\(progress.done) of \(progress.total))",
                                value: Double(progress.done),
                                total: Double(progress.total)
                            )
                        } else {
                            ProgressView("Generating Study Deck")
                        }
                    }
                } else if viewModel.noProviderConfigured {
                    Section {
                        ContentUnavailableView(
                            "No AI Provider Configured",
                            systemImage: "sparkles",
                            description: Text(
                                "Add a provider token under Settings › AI Card Generation, or enable Apple Intelligence for on-device generation."
                            )
                        )
                    }
                } else if viewModel.cards.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Eligible Blocks",
                            systemImage: "rectangle.stack.badge.questionmark",
                            description: Text(
                                "This book does not have visible EPUB text blocks for a study deck."
                            )
                        )
                    }
                } else {
                    StudyDeckDraftCardsSection(viewModel: viewModel)
                }

                if viewModel.duplicatesSkipped > 0 {
                    Section {
                        Label(
                            "\(viewModel.duplicatesSkipped) duplicates skipped",
                            systemImage: "rectangle.on.rectangle.slash"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
```

(The `acceptedCount` section, toolbar, alert, `.onDisappear`, and `.task` below stay exactly as they are.)

- [ ] Verify SPDX is line 1 in all three modified Swift files. Build once, run the factory suite plus the VM suite (the host/sheet changes are UI-only — the iOS test build IS their build verification, since `BookSettingsView` is excluded from the macOS and echo-cli targets):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyDeckGeneratorFactoryMatrixTests
make test-only FILTER=EchoTests/StudyDeckGenerationViewModelTests
```

Expected: **TEST SUCCEEDED** twice (6 matrix tests; 11 VM tests).

- [ ] `Shared/Services/StudyDeckGenerating.swift` also compiles into macOS/echo-cli/watchOS — verify the two desktop targets now, serially, after the iOS run finished (UI-only build verification, stated explicitly):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet
```

Expected: **BUILD SUCCEEDED** twice (echo-cli's `GenerateDeckCommand` constructs `FixtureStudyDeckGenerator()` directly and never touched the factory).

- [ ] Commit:

```bash
git add Shared/Services/StudyDeckGenerating.swift EchoCore/Views/BookSettingsView.swift EchoCore/Views/StudyDeckGenerationSheet.swift EchoTests/StudyDeck/StudyDeckGeneratorFactoryMatrixTests.swift
git commit -m "feat(study): config-driven generator factory with explicit no-provider state and dedup UI"
```

---

## Task 11 — Settings UI: provider dropdown, named consent, Test Connection

**Files:**
- Modify: `EchoCore/Views/AICardGenerationSettingsView.swift` (full rewrite; this also **deletes** the legacy `AICardGenerationSettings` enum declared at the top of that file — its last consumer, the `BookSettingsView` host, was rewired in Task 10)
- Modify: `Shared/Services/APIKeyStore.swift` (remove the now-dead `hasKey` / `clear()`)
- Delete: `EchoTests/StudyDeck/AICardGenerationSettingsProviderTests.swift` (tested the retired `ai.cardgen.provider` key; `AIProviderSettingsStoreTests` covers its successor)

This is a UI-only task: **no new unit test cycle — the iOS test build plus the macOS build are the explicit verification** (the view is included in the iOS, macOS, and Widget targets; it is already excluded from echo-cli in the pbxproj, so no membership change). All persistence/consent/test-connection *logic* it calls was TDD'd in Tasks 3, 5, and 6.

**Interfaces:**
- Consumes: `AIProviderSettingsStore` (Task 3); `AIProviderConfig`/`AIProviderPreset` (Task 1); `AnthropicMessagesClient.clients(config:token:)` (Task 5); `AIProviderConnectionTester`/`AIProviderConnectionOutcome.message` (Task 6); `StudyDeckFMAvailability.statusMessage` (existing).
- Produces: `struct AICardGenerationSettingsView: View` (same name — the `SettingsView` NavigationLink at `EchoCore/Views/SettingsView.swift:76` and the `MacSettingsView` AI tab at `Echo macOS/Views/MacSettingsView.swift:29` keep working untouched).

**Steps:**

- [ ] Delete the legacy test file:

```bash
git rm EchoTests/StudyDeck/AICardGenerationSettingsProviderTests.swift
```

- [ ] Replace the entire contents of `EchoCore/Views/AICardGenerationSettingsView.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Cross-platform settings pane for AI card generation: provider preset dropdown,
/// per-provider endpoint/token/model fields, capability toggles (editable on Custom),
/// per-provider NAMED consent (App Store 5.1.2(i) requires naming the specific
/// provider), and a Test Connection button.
///
/// Non-secret config persists via `AIProviderSettingsStore` (Codable JSON in
/// UserDefaults); the token goes to the Keychain under a per-provider account.
/// No iOS-only modifiers — compiles on macOS alike.
struct AICardGenerationSettingsView: View {
    @State private var config: AIProviderConfig = .defaults(for: .anthropic)
    @State private var token = ""
    @State private var lightModel = ""
    @State private var consented = false
    @State private var preference: StudyDeckGeneratorPreference = .auto
    @State private var saved = false
    @State private var isTesting = false
    @State private var testResult: String?

    // `AIProviderSettingsStore` is @MainActor; the View is also @MainActor so this is fine.
    private let store = AIProviderSettingsStore()

    var body: some View {
        Form {
            Section("Generator") {
                Picker("Generator", selection: $preference) {
                    Text("Automatic").tag(StudyDeckGeneratorPreference.auto)
                    Text("On-device only").tag(StudyDeckGeneratorPreference.onDevice)
                    Text("Cloud only").tag(StudyDeckGeneratorPreference.cloud)
                }
                .onChange(of: preference) { _, new in
                    store.generatorPreference = new
                }
                Text(StudyDeckFMAvailability.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Cloud Provider") {
                Picker("Provider", selection: $config.preset) {
                    ForEach(AIProviderPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: config.preset) { _, new in
                    switchPreset(to: new)
                }

                TextField("Base URL", text: $config.baseURL)
                    .autocorrectionDisabled()
                SecureField("API token", text: $token)
                    .textContentType(.password)
                TextField("Model", text: $config.primaryModel)
                    .autocorrectionDisabled()
                TextField("Light model (book brief, optional)", text: $lightModel)
                    .autocorrectionDisabled()

                // Static per preset; editable starting points on Custom only.
                Toggle(
                    "Structured output",
                    isOn: $config.capabilities.supportsStructuredOutput
                )
                .disabled(config.preset != .custom)
                Toggle("Extended thinking", isOn: $config.capabilities.supportsThinking)
                    .disabled(config.preset != .custom)
            }

            Section {
                Toggle(
                    "I understand this book's text is sent to \(config.preset.displayName) using my token",
                    isOn: $consented
                )

                Button(saved ? "Saved" : "Save") { save() }
                    .disabled(
                        token.isEmpty || !consented
                            || config.baseURL.isEmpty || config.primaryModel.isEmpty)

                if store.token(for: config.preset) != nil {
                    Button("Remove Token", role: .destructive) { removeToken() }
                }
            }

            Section {
                Button(isTesting ? "Testing…" : "Test Connection") { runConnectionTest() }
                    .disabled(isTesting || token.isEmpty || config.baseURL.isEmpty)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    "Generating cards sends this book's text to \(config.preset.displayName) over HTTPS, billed to your own account. Echo's other features (narration, alignment, playback) remain fully on-device."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadStoredState() }
    }

    private func loadStoredState() {
        preference = store.generatorPreference
        if let stored = store.config {
            config = stored
            consented = stored.consented
        } else {
            config = .defaults(for: .anthropic)
            consented = false
        }
        lightModel = config.lightModel ?? ""
        token = store.token(for: config.preset) ?? ""
    }

    /// Switching provider loads that provider's stored config when it is the active
    /// one, or the preset defaults otherwise — and consent never carries across
    /// providers: generation requires THIS provider's named consent (5.1.2(i)).
    private func switchPreset(to preset: AIProviderPreset) {
        if let stored = store.config, stored.preset == preset {
            config = stored
            consented = stored.consented
        } else {
            config = .defaults(for: preset)
            consented = false
        }
        lightModel = config.lightModel ?? ""
        token = store.token(for: preset) ?? ""
        testResult = nil
        saved = false
    }

    private func save() {
        guard consented else { return }
        var toSave = config
        let trimmedLight = lightModel.trimmingCharacters(in: .whitespacesAndNewlines)
        toSave.lightModel = trimmedLight.isEmpty ? nil : trimmedLight
        toSave.consented = true
        store.config = toSave
        store.setToken(token, for: toSave.preset)
        config = toSave
        saved = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }

    private func removeToken() {
        store.setToken(nil, for: config.preset)
        token = ""
        consented = false
        if var stored = store.config, stored.preset == config.preset {
            stored.consented = false
            store.config = stored
        }
    }

    private func runConnectionTest() {
        var draft = config
        let trimmedLight = lightModel.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.lightModel = trimmedLight.isEmpty ? nil : trimmedLight
        guard let clients = AnthropicMessagesClient.clients(config: draft, token: token) else {
            testResult = "Invalid base URL — enter a full https:// endpoint."
            return
        }
        isTesting = true
        testResult = nil
        Task { @MainActor in
            let outcome = await AIProviderConnectionTester(client: clients.primary).test()
            testResult = outcome.message
            isTesting = false
        }
    }
}
```

- [ ] In `Shared/Services/APIKeyStore.swift`, delete the two now-dead members (their last callers were the old settings view and the pre-Task-10 host):

```swift
    var hasKey: Bool { anthropicKey != nil }

    func clear() { removeData(.anthropicAPIKey, service) }
```

Keep `anthropicKey` — `AIProviderSettingsStore.migrateLegacyIfNeeded()` still reads and clears it.

- [ ] Confirm nothing references the retired API anywhere (expected: no output from all three):

```bash
grep -rn "AICardGenerationSettings\b" --include="*.swift" EchoCore Shared "Echo macOS" EchoTests Tools
grep -rn "\.hasKey" --include="*.swift" EchoCore Shared "Echo macOS" EchoTests Tools
grep -rn "ai\.cardgen\." --include="*.swift" EchoCore Shared "Echo macOS" EchoTests Tools | grep -v AIProviderSettingsStore
```

(`AIProviderSettingsStore` legitimately keeps the `ai.cardgen.*` strings as its legacy-migration constants.)

- [ ] Verify SPDX is line 1 in both modified files. Build verification (UI-only task, stated explicitly): iOS test build, then macOS, serially:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet
```

Expected: **BUILD SUCCEEDED** for both (the view compiles into iOS, macOS, and Widget; echo-cli excludes it).

- [ ] Run the two suites closest to the deleted code to catch stragglers:

```bash
make test-only FILTER=EchoTests/APIKeyStoreTests
make test-only FILTER=EchoTests/AIProviderSettingsStoreTests
```

Expected: **TEST SUCCEEDED** twice.

- [ ] Commit:

```bash
git add EchoCore/Views/AICardGenerationSettingsView.swift Shared/Services/APIKeyStore.swift
git commit -m "feat(ai): provider settings UI with named consent, per-provider fields, and Test Connection"
```

---

## Task 12 — Final verification

**Files:** none created/modified (fixes only, if something fails).

**Interfaces:** n/a.

**Steps:**

- [ ] Full iOS unit-test suite (serial, capped jobs — this is the canonical gate):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
```

Expected: **TEST SUCCEEDED**, zero failures. Known environmental flake: `ABSTokenStore`/auth-refresh Keychain tests can fail run-to-run under `CODE_SIGNING_ALLOWED=NO` — a failure ONLY there, unrelated to this plan's files, may be re-run once to confirm.

- [ ] macOS build (Shared + EchoCore changes all compile into it):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet
```

Expected: **BUILD SUCCEEDED**.

- [ ] echo-cli build (Shared changes compile into it; CI ordering masks CLI breaks behind test steps, so build it locally):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5 -quiet
```

Expected: **BUILD SUCCEEDED**.

- [ ] SPDX audit — every file this plan created must still have the license on line 1 (expected: 7 lines of identical SPDX output):

```bash
head -1 Shared/Services/AI/AIProviderConfig.swift Shared/Services/AI/AIProviderSettingsStore.swift Shared/Networking/LooseJSONExtractor.swift Shared/Services/AI/AIProviderConnectionTester.swift Shared/Services/StudyDeckDraftDeduplicator.swift EchoTests/StudyDeck/URLRequestBodyJSON.swift EchoTests/StudyDeck/AIProviderConfigTests.swift
```

- [ ] Retired-surface audit (expected: no output):

```bash
grep -rn "AICardGenerationSettings\b\|StudyDeckGeneratorFactory.make(hasKey\|StudyDeckGeneratorFactory.make(preference" --include="*.swift" EchoCore Shared "Echo macOS" EchoTests Tools
```

- [ ] Manual verification checklist (owner, on device/simulator — record outcomes in the final report):
  - [ ] **Migration:** on a build that previously had an Anthropic key saved, open Settings ▸ AI Card Generation → the Anthropic preset appears pre-filled with the legacy model, consent ON, token present (masked); generating still works with no re-entry.
  - [ ] **Provider switch:** pick DeepSeek → base URL/models pre-fill, consent toggle resets OFF and names "DeepSeek"; Save stays disabled until token + consent.
  - [ ] **Test Connection:** with a bad token expect the 401 message; with a nonsense host expect "Could not reach the endpoint"; (optional, real token) expect "Connection OK".
  - [ ] **No-provider state:** with no token saved, preference Automatic, on a non-FM device: Generate Study Deck shows "No AI Provider Configured" — not fixture cards.
  - [ ] **Progress:** on a multi-chapter EPUB with a real provider, the sheet shows "Generating cards… (i of N)" advancing.
  - [ ] **Dedup:** accept some cards, regenerate → "N duplicates skipped" appears and previously-accepted fronts are not re-proposed.
  - [ ] **macOS:** the AI tab in Settings renders the new pane; provider switch + Save behave as on iOS (macOS still has no generation entry point — settings parity only, per the recorded scope).
- [ ] No commit for this task unless a fix was needed (fix commits follow Conventional Commits, e.g. `fix(ai): …`). Doc-sync (README/ARCHITECTURE — new provider settings + retired `ai.cardgen.*` keys) and the PR are handled outside this plan per the global constraints.

---

## Execution order & dependency notes

- Tasks 1 → 2 → 3 are strictly sequential (types → Keychain accounts → store).
- Task 4 depends only on Task 1's file existing (same suite folder); Tasks 5–6 depend on 1+4; Task 7 depends on 5; Task 8 is independent of 4–7 (needs only Task 1's plan context, none of its types) but keep the order for review sanity.
- Task 9 depends on 8; Task 10 depends on 3, 5, 7, 9; Task 11 depends on 3, 5, 6, 10.
- Never run two xcodebuild invocations concurrently; every `make build-tests`/`make test` and each macOS/echo-cli build goes through `xcode-build-gate.sh --wait` first and runs serially.

