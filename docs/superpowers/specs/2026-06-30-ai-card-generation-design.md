# Native AI Card Generation in Echo — Design

**Date:** 2026-06-30
**Status:** Approved (design); implementation pending plan
**Scope:** macOS implemented first (M1–M3); iOS planned (M4). One coherent subsystem.

## 1. Goal

Replace Echo's deterministic stub study-deck generator with a real AI generator that turns a book's EPUB text into anchored flashcards, reusing the proven pipeline already prototyped in the EchoDeckBuilder companion. The AI calls Anthropic's Messages API over HTTPS using the **user's own API key** (BYO-key), mirroring Echo's existing bring-your-own-server (Audiobookshelf) philosophy.

This is the "AI integration" gap: today Echo's in-app "Generate Study Deck" feature is fully wired end-to-end (UI → review → accept → persist → FSRS) but the card text is produced by `FixtureStudyDeckGenerator`, a canned template. All real AI generation currently lives only in the separate EchoDeckBuilder app, on unmerged `codex/*` branches.

### Decisions locked (from brainstorming)
- **macOS AI path:** BYO Anthropic API key over HTTPS. (The Claude *CLI* approach is blocked: Echo macOS is App-Sandboxed and Mac-App-Store-only — `Echo macOS/Echo_macOS.entitlements:5`, `fastlane/Fastfile:188` `export_method "app-store"` — and a sandboxed App Store app cannot spawn an arbitrary user-installed binary like `claude`. HTTPS over the existing `com.apple.security.network.client` entitlement is App-Store-legal and needs no entitlement change.)
- **Scope:** Full pipeline port — book-brief context pass, chapter batching, cloze cards, card metadata, dedupe-against-existing.
- **Gating:** Key-only. Not Pro-gated; does not consume the free-tier flashcard cap. Cleanest App Review posture (the user pays Anthropic; Echo is not selling AI).

## 2. Non-goals

- Shipping the local `claude`/`codex` CLI generator inside Echo macOS (sandbox-blocked; remains an EchoDeckBuilder-only capability).
- iOS "login to Claude/Codex" or "developer sells tokens" monetization — no viable iOS implementation today; explicitly deferred (§9).
- Image generation for cards (EDB's `imageMode` only emits prompt metadata; out of scope here).
- Changing Echo's persistence/FSRS/Anki-import infrastructure — it is reused unchanged.

## 3. Architecture

### 3.1 The injection seam (mirrors the shipped narration-QA pattern)

The generator call is one hard-coded line:
`FixtureStudyDeckGenerator().generate(sources:)` at `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift:58`.

Introduce a protocol seam — a near-verbatim clone of the shipped `DivergenceClassifier` / `FoundationModelsDivergenceClassifier` / `DivergenceClassifierFactory` trio (`EchoCore/Services/Narration/QA/`):

```swift
protocol StudyDeckGenerating: Sendable {
    func generate(
        sources: [StudyDeckSource],
        settings: StudyDeckGenerationSettings
    ) async -> GeneratedStudyDeckDraft
}

struct FixtureStudyDeckGenerator: StudyDeckGenerating { /* existing logic, now async */ }   // fallback
struct AnthropicStudyDeckGenerator: StudyDeckGenerating { /* NEW */ }

enum StudyDeckGeneratorFactory {
    static func make(hasKey: Bool, /* deps */) -> any StudyDeckGenerating
    // returns AnthropicStudyDeckGenerator when a key is present, else FixtureStudyDeckGenerator
}
```

`FixtureStudyDeckGenerator` is a **genuine second implementation** (offline / CI / no-key fallback), so the protocol is not speculative DI theater — it satisfies the project's "add the seam when the second caller actually arrives" rule.

`generate` becomes `async`. `StudyDeckGenerationViewModel.load()` (`:46`) converts from a synchronous `defer { isLoading = false }` body to an async `Task` body with progress reporting and cancellation.

**Downstream is unchanged.** `GeneratedStudyDeckDraft.init` (`Shared/Services/StudyDeckGenerationTypes.swift:31`) already discards any card with an unknown `sourceBlockID` or oversized text, and `StudyDeckAcceptanceService` (`Shared/Services/StudyDeckAcceptanceService.swift:8`) already maps drafts to `Flashcard` rows via `FlashcardDAO.insert`. The AI generator inherits this safety net for free; it cannot corrupt the deck even on malformed model output.

### 3.2 New components

Cross-platform unless noted (so iOS reuses them as-is — see §9):

| Component | Responsibility | Notes |
|---|---|---|
| `AnthropicMessagesClient` | Raw HTTPS to `POST /v1/messages` | Swift has **no** official Anthropic SDK → `URLSession`. Default model `claude-opus-4-8`; `x-api-key` + `anthropic-version: 2023-06-01`; structured output via `output_config.format` (JSON schema); adaptive thinking only (no `temperature`/`top_p`); handles `stop_reason == "refusal"`, 401, 429; caches the stable book-brief+instructions prefix (`cache_control`) to cut the user's token cost. |
| `APIKeyStore` | Keychain storage of the user's Anthropic key | Mirrors `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift`. |
| `AIPromptPackageBuilder` | Build book-brief + per-batch prompts | **Ported from EDB `codex/ai-generation-cli`**, provider-agnostic. XML-delimited, untrusted-source escaping (`&<>"'`), source framed as quoted material not instructions (prompt-injection mitigation). Produces the JSON schema for `output_config.format`. |
| `AIModelOutputValidator` | Deterministic validation of model output | **Ported from EDB.** Rejects: empty brief, malformed anchor (`^s[0-9]+-b[0-9]+$`), anchor outside current batch, empty front/back, unsupported kind, invalid cloze, long verbatim source quotation. |
| `GenerationBatcher` | Group sections into spine-bounded chapter batches | **Ported from EDB.** New batch when spine index changes or batch size cap (default 12) reached. One brief call + one call per batch. |
| `GenerationSettings`, `AIModelOutput` | Settings + raw wire struct | Ported from EDB, adapted to Echo types. |
| Settings UI (macOS) | Key entry, model picker, availability indicator, one-time consent | Not cross-platform (iOS gets its own; see §9). |

### 3.3 Model & API contract (grounded in the `claude-api` skill)

- **Model:** default `claude-opus-4-8`. A picker also offers `claude-sonnet-4-6` and `claude-haiku-4-5` because the *user* pays per token and a book-length run can be large; opus stays the code default (we don't downgrade for cost on the user's behalf).
- **Structured output:** `output_config: {format: {type: "json_schema", schema: <EDB outputSchemaData()>}}` guarantees parseable JSON. EDB's schema ports directly; structured-output limitations (no `maxLength`/numeric constraints) are fine because `AIModelOutputValidator` already enforces those deterministically.
- **Thinking/effort:** adaptive thinking; `output_config.effort` low/medium for card generation. No sampling params (they 400 on opus-4-8).
- **Caching:** the book-brief + instructions form a stable prefix across all per-batch calls in a run — cache it; vary only the per-batch source after the breakpoint.
- **Auth/entitlement:** `x-api-key` header; existing `com.apple.security.network.client` entitlement suffices.

## 4. Data flow

```
book ─▶ StudyDeckSourceBuilder ─▶ [StudyDeckSource]            (existing, DB-backed)
      ─▶ GenerationBatcher ─▶ chapter batches
      ─▶ AnthropicMessagesClient:
            (1) book-brief call (book-level context)
            (2) one call per batch, constrained to that batch's anchors
      ─▶ AIModelOutput (per batch)
      ─▶ AIModelOutputValidator ─▶ validated cards (anchor-in-batch enforced)
      ─▶ GeneratedStudyDeckDraft (cloze-aware)                 (existing type, extended)
      ─▶ review sheet ─▶ accept ─▶ StudyDeckAcceptanceService  (existing, unchanged)
      ─▶ FlashcardDAO.insert (card_type / cloze_index populated)
```

The two-pass design (one brief, then per-batch restricted to in-batch anchors) is the key product decision preserved from EDB: it gives book-level context without letting the model invent out-of-scope anchors, and the validator hard-enforces the constraint.

## 5. Cloze + metadata (the "full port" delta) — no migration expected

`card_type` and `cloze_index` columns **already exist** on the `flashcard` table (`Shared/Database/Flashcard.swift:42-43`, `cardType: String? = "normal"`, `clozeIndex: Int?`); they are simply never populated by either importer today. Therefore cloze is **code, not schema**:

1. Extend `EchoCore/Models/FlashcardDeckImport.swift` `ImportedCard` and `GeneratedStudyDeckDraft`/accept path with `kind` (basic|cloze), optional cloze text, and `tags`.
2. Wire the **already-present-but-unused** `Shared/Database/ClozeParser.swift` into the acceptance/persist path to expand `{{cN::answer}}` into per-deletion cards.
3. Populate the existing `card_type` / `cloze_index` columns.
4. Card metadata (importance/confidence/rationale) is used transiently to rank/select cards during review, then folded into the existing `tags` column — no new column.

**No new GRDB migration is expected.** The plan's first task confirms the `card_type`/`cloze_index` columns exist in the shipped schema (latest is V30, `v30_narration_quality_issue`) before relying on them. In the unlikely event a column is struct-only, a V31 migration enters here and must go through `schema-migration-reviewer`.

## 6. Privacy, gating, docs

- **Gating:** key-only. No `isPro` requirement; does not call `FreeTierGate`. AI cards do not consume the 20-card free cap.
- **Privacy / consent:** opt-in consent sheet the first time generation is used — "Generating cards sends this book's text to Anthropic using your own API key." Key in Keychain.
- **Doc reconcile (required, via `doc-sync`, not silent):** BYO-key sends EPUB text off-device, which contradicts the live paywall line "No account, no servers, no tracking" (`EchoCore/Views/Paywall/PaywallView.swift:97`) — scope that claim to the on-device features. Separately, the "one-time only, no subscription" positioning is already stale (monthly/yearly subscriptions are live in `ProductIDs`/`PaywallView`); reconcile alongside. Update `ARCHITECTURE.md` (new AI-generation subsystem), `README.md`, `CHANGELOG.md`.

## 7. Error handling

- Missing / invalid key → 401 → surface, prompt for key; fall back to fixture.
- Rate limit → 429 → backoff/retry (honor `retry-after`).
- `stop_reason == "refusal"` → surface to the user; do not blindly retry.
- Per-batch failure isolation → a failed batch is skipped with a warning; already-validated cards are preserved (no whole-run abort — fixes a known EDB gap).
- Offline / no key → `FixtureStudyDeckGenerator` fallback (always available).
- Cancellation → cooperative `Task.checkCancellation()` between batches.
- JSON: structured output guarantees a JSON object, but still guard the decode (tolerant extraction) — fixes the EDB brittle-decode gap.

## 8. Testing (TDD; no live API in CI)

- Port EDB's `AIModelOutputValidator` / `GenerationBatcher` / `AIPromptPackageBuilder` tests (deterministic, no network).
- `AnthropicStudyDeckGenerator` tested against a `URLProtocol`-stubbed `AnthropicMessagesClient` (fake responses, refusal, 401, 429, partial-batch) — no real network.
- Cloze-expansion tests through `ClozeParser` into `GeneratedStudyDeckDraft` and persisted `card_type`/`cloze_index`.
- Seam test: with no key, `StudyDeckGeneratorFactory.make` returns the fixture generator and the existing path is unchanged.
- `APIKeyStore` Keychain round-trip — marked for the known iOS-sim flakiness under `CODE_SIGNING_ALLOWED=NO` (writes can no-op → reads nil; environmental, not a code bug).

## 9. iOS plan (M4 — plan only)

The leverage of the HTTPS choice: **every component in §3.2 except the macOS settings UI is cross-platform Swift** — `AnthropicMessagesClient`, `APIKeyStore`, `AIPromptPackageBuilder`, `AIModelOutputValidator`, `GenerationBatcher`, the seam. So the macOS work *is* most of the iOS work. iOS adds:

1. **Ship the same BYO-key Anthropic generator** — works identically on iOS; no platform blocker. iOS needs only the key-entry UI + consent.
2. **Add on-device Apple Foundation Models** as an opportunistic provider behind the same `StudyDeckGenerating` seam: port EDB `codex/foundation-models-card-generation` (the cleanest seam in that repo), **fixing its compile bug** — `FoundationModelAvailability.swift:36` calls `model.supportsLocale()`, which is not a real `SystemLanguageModel` API; use `SystemLanguageModel.default.supportedLanguages` (or drop the locale pre-check and rely on the already-handled `unsupportedLanguageOrLocale` error). Widen availability gates to `@available(iOS 26, macOS 26, *)` + `SystemLanguageModel.default.availability`. Result: Apple-Intelligence-capable devices get a no-key, on-device, fully-private path; everyone else uses BYO-key; the deterministic fixture remains the universal floor.
3. **Defer login / sell-tokens** — no consumer OAuth mints API credit for third-party apps; selling tokens needs a first-party backend + consumable IAP + Apple's 30% + a privacy-policy change. Revisit only if AI becomes a flagship paid differentiator and on-device FM proves insufficient.

iOS deployment target is currently 18.0, so Foundation Models is opportunistic/feature-gated, never a baseline.

## 10. Milestones

Each milestone is a green checkpoint (builds + tests pass) and can ship independently.

- **M1 (macOS):** seam + async refactor of `load()`/`generate`; `AnthropicMessagesClient`; `APIKeyStore`; settings key entry + model picker + consent; single-batch Q&A happy path; fixture fallback. → working basic AI generation.
- **M2 (macOS):** `GenerationBatcher` + book-brief two-pass + `AIModelOutputValidator` port; progress + cancel; per-batch partial recovery; dedupe-against-accepted.
- **M3 (macOS):** cloze + metadata — extend `ImportedCard`/draft types, wire `ClozeParser`, populate existing `card_type`/`cloze_index`, fold metadata into `tags`.
- **M4 (iOS):** plan-only in this spec; its own spec → plan → implementation cycle, reusing the cross-platform components above.

## 11. Key file references

- Seam call site: `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift:58` (and `load()` at `:46`)
- Fixture generator (fallback): `Shared/Services/FixtureStudyDeckGenerator.swift:8`
- Draft validation / input types: `Shared/Services/StudyDeckGenerationTypes.swift:31` (`StudyDeckSource` at `:4`, tags at `:56`)
- Persistence: `Shared/Services/StudyDeckAcceptanceService.swift:8` → `Shared/Database/DAOs/FlashcardDAO.swift:115`
- Import contract: `EchoCore/Models/FlashcardDeckImport.swift:26`; importer `EchoCore/Services/DeckImportService.swift:16`
- Anchor resolver: `EchoCore/Services/EPUBSourceAnchorResolver.swift:43`; portability `EchoCore/Services/AlignmentSidecar.swift:41`
- Cloze parser (unused today): `Shared/Database/ClozeParser.swift:15`
- Cloze columns (exist): `Shared/Database/Flashcard.swift:42`
- FM template to clone (shipped): `EchoCore/Services/Narration/QA/FoundationModelsDivergenceClassifier.swift:29`, `DivergenceClassifierFactory.swift:9`
- Key-store template: `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift`
- Network entitlement (present): macOS app already has `com.apple.security.network.client`
- EDB reference (read via `git -C ~/Developer/EchoDeckBuilder show codex/ai-generation-cli:<path>`): `Sources/EchoDeckBuilder/Services/{AIPromptPackageBuilder,AIModelOutputValidator,GenerationBatcher,LocalClaudeCLIGenerator}.swift`, `Models/{AIModelOutput,GenerationSettings,SourceAnchor}.swift`; design `docs/superpowers/specs/2026-06-26-ai-generation-cli-design.md`
- EDB FM reference (`codex/foundation-models-card-generation`): `Sources/EchoDeckBuilder/Services/{FoundationModelCardGenerator,FoundationModelAvailability,FoundationModelCardPrompt,GeneratedCardDraft}.swift` (note the `supportsLocale()` compile bug)

## 12. Risks

- **Privacy-claim reconcile** (real but bounded): disclosure + paywall copy edit; handled via `doc-sync`.
- **App Review BYO-key posture** (moderate): mitigated by key-only gating — AI is a convenience the user pays their own provider for, not a paid Echo unlock.
- **EDB FM compile bug** (`supportsLocale()`): one-line fix; applies only to the iOS M4 milestone.
- **Sim keychain flakiness** under `CODE_SIGNING_ALLOWED=NO`: known environmental test flake on `APIKeyStore` round-trip; mark accordingly, do not chase as a code bug.
- **EDB schema drift** (informational): the AI branch's `EchoDeckCardDocument` dropped `startTime`/`endTime` vs the MVP branch; irrelevant here since we feed Echo's native draft path, not the `.echo-deck.json` file contract.
