# AI Provider Expansion — Anthropic-Compatible Endpoints + Generation UX Debt (Design) — Slice 3

**Date:** 2026-07-01
**Status:** Approved by owner (brainstorming session); ready for implementation planning
**Slice:** 3 of 3 in the study-workflow program. Independent of slices 1–2 except the generation sheet file (slice 2 restructures it; this slice only re-plumbs progress/dedup — land slice 2's sheet changes first if run concurrently).

## 1. Context & goal

Echo's cloud generation path is Anthropic-only: a hand-written Messages API client (`AnthropicMessagesClient`) with a hardcoded host, one Keychain key, and a three-Claude model picker. The owner wants **DeepSeek** (and similar) supported the way Claude Code does it — point the Anthropic-dialect client at a compatible endpoint:

```
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=API_TOKEN
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
```

In Echo this becomes a **provider dropdown + per-provider fields, persisted** — no env vars. Alongside it, this slice pays down the shipped generation-UX debt: progress never wired, no dedup on regenerate, silent fixture fallback, no key validation.

**Provider account login stays excluded** (researched 2026-07-01): Anthropic prohibits and server-enforces against consumer OAuth in third-party apps (Feb 2026 terms; Jan–Apr 2026 enforcement); OpenAI's "Sign in with ChatGPT" is identity-only and not generally available. BYO API token is the compliant path. Native OpenAI wire-format support was considered and **rejected** for this slice (owner decision) — OpenAI users can point the Custom preset at an Anthropic-compatible proxy (e.g. LiteLLM).

## 2. Owner decisions

| Question | Decision |
|---|---|
| Provider scope | **Anthropic-compatible only**: presets Anthropic / DeepSeek / Kimi (Moonshot) / GLM (Z.ai) / Custom (any base URL). One client, per-preset dialect. |
| Model config | **Primary + optional light**: free-form primary model (card generation) + optional cheaper model for the book-brief pass. No three-tier mapping (dead config in Echo). |

## 3. `AIProviderConfig`

One Codable value type (Shared/):

| Field | Notes |
|---|---|
| `preset` | `.anthropic / .deepseek / .kimi / .glm / .custom` |
| `baseURL` | Editable on Custom; preset default otherwise (still editable — endpoints move) |
| `authStyle` | `.xAPIKey` (`x-api-key: <key>` + `anthropic-version`) or `.bearer` (`Authorization: Bearer <token>`); never both — the real API rejects double credentials |
| `primaryModel` | Free-form string, passed to the wire verbatim (`deepseek-v4-pro[1m]` is just an ID) |
| `lightModel?` | Optional; used for the Pass-1 book brief when set |
| `capabilities` | `supportsStructuredOutput`, `supportsThinking` — static per preset, editable on Custom |
| `consented` | Per-provider 5.1.2(i) consent (named provider) |

**Persistence:** non-secret config as Codable JSON in UserDefaults (`ai.provider.config`); the token in the **Keychain under a per-provider account** (`aiProvider.<preset>`, service unchanged). **Migration:** on first run, an existing `anthropicAPIKey` Keychain entry and the legacy `ai.cardgen.model`/`ai.cardgen.provider` defaults migrate into an Anthropic `AIProviderConfig`; legacy keys are then retired. No DB migration.

**Preset defaults** (shipped as editable starting points; exact URLs verified at implementation time): Anthropic → `https://api.anthropic.com`, x-api-key, full capabilities, models claude-opus-4-8 / claude-haiku-4-5 (light); DeepSeek → `https://api.deepseek.com/anthropic`, bearer, conservative capabilities, suggested `deepseek-v4-pro[1m]` / `deepseek-v4-flash`; Kimi and GLM → their documented `/anthropic` endpoints, conservative; Custom → empty URL, conservative.

## 4. Client dialects

`AnthropicMessagesClient` is parameterized by the config; the request shape branches on capabilities:

- **Full (Anthropic):** unchanged — adaptive thinking + `output_config.format` JSON-schema structured output; existing error classification.
- **Conservative (compat endpoints, Custom default):** omit `thinking`/`effort`/`output_config` entirely (compat endpoints implement the request *envelope*, not the feature matrix — these fields 400 or get silently ignored, and ignored structured output returns prose). Instead: append a JSON-only instruction + the schema to the prompt, extract JSON client-side (raw or fenced), **one retry on parse failure**, then feed the existing `StudyDeckOutputValidation` layer unchanged.
- `anthropic-version` header is sent in both dialects (compat endpoints expect it).
- Error classification (401/429/refusal/badStatus/transport) is dialect-independent and stays.

The on-device Foundation Models path and the 3-way factory (`auto`: configured cloud provider wins → FM → none) are unchanged apart from reading `AIProviderConfig` instead of the single key.

## 5. Settings UI

`AICardGenerationSettingsView` (iOS + macOS, already cross-platform) becomes:

1. **Provider dropdown** (the five presets).
2. **Per-provider fields:** base URL (editable; prominent on Custom), token SecureField, primary model, light model, capability toggles (Custom only; presets show them read-only).
3. **Named consent toggle** per provider — "I understand this book's text is sent to **DeepSeek** using my token" (App Store 5.1.2(i) requires naming the specific provider; generic language is insufficient). Switching provider requires that provider's consent before generation.
4. **Test Connection** button — minimal Messages call (tiny `max_tokens`), reporting success / 401 bad token / unreachable URL / unexpected response shape. Doubles as key validation.

## 6. Generation UX debt (fixed in this slice)

| Debt | Fix |
|---|---|
| Progress never wired (`BookSettingsView` passes no progress closure) | Wire the generator's progress callback through `StudyDeckGenerationViewModel` to the sheet's ProgressView (batch i of N) |
| No dedup on regenerate | At draft-building time, skip drafts whose `sourceBlockID` + normalized front text already exist as accepted cards; show a "N duplicates skipped" note |
| Silent fixture fallback when no key + no FM | Replaced with an explicit "No AI provider configured" state linking to settings; the fixture generator remains available **only** to echo-cli and tests |
| No key validation | Test Connection (§5) |

## 7. Out of scope (recorded)

- Native OpenAI wire-format client (rejected — proxy via Custom).
- Provider account login / OAuth (prohibited or unavailable; revisit only if OpenAI ships a public program).
- Streaming generation UI; per-provider rate-limit retry policies beyond the existing classification.
- echo-cli cloud generation (stays fixture-only).

## 8. Testing (TDD)

- Request-body snapshot tests per dialect (full vs conservative; thinking/output_config presence; prompt-embedded schema).
- Auth-header tests (x-api-key vs bearer; never both; anthropic-version always present).
- JSON extraction: raw, fenced, prose-wrapped, parse-failure retry, then validation-layer handoff.
- Preset defaults + Custom conservatism; capability toggles honored.
- Keychain: per-provider accounts; legacy `anthropicAPIKey` + `ai.cardgen.*` migration.
- Factory: `auto` resolution with a configured non-Anthropic provider; explicit no-provider state (no silent fixture).
- Dedup: duplicate drafts skipped by sourceBlockID + normalized front.

## 9. Key existing files

| File | Role |
|---|---|
| `Shared/Networking/AnthropicMessagesClient.swift` | Base URL/auth/dialect parameterization |
| `Shared/Services/APIKeyStore.swift` + `Shared/KeychainStore.swift` | Per-provider token accounts + migration |
| `Shared/Services/StudyDeckGenerating.swift` | Factory reads `AIProviderConfig` |
| `Shared/Services/AI/StudyDeckPromptBuilder.swift` | Conservative-dialect JSON-only prompt variant |
| `Shared/Services/AI/StudyDeckOutputValidation.swift` | Unchanged validation target for extracted JSON |
| `EchoCore/Views/AICardGenerationSettingsView.swift` | Provider dropdown UI + consent + Test Connection |
| `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` + `StudyDeckGenerationSheet.swift` | Progress wiring, dedup notice, no-provider state |
