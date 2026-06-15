# PRICING.md — Echo Monetization & Paywall Spec

> **Status:** Draft for implementation. Numbers tagged `recommend — confirm` are recommended price points pending final confirmation (see §9).
> **App:** Echo — *Audiobook Study Player*. App Store ID `6779836394`. Open-source (MIT), privacy-first, neurodivergent-first, solo-dev, pre-1.0 in TestFlight.
> **Audience for this doc:** the solo developer implementing against StoreKit 2.

---

## 1. Summary

Echo is **freemium with a hybrid paid tier**. The **free tier is a genuinely great, fully private audiobook player** — including the read-along reader, the feature most apps would charge for — plus a *metered taste* of the study moat. **Echo Pro** is one unlock that removes the meters and turns on the differentiators (unlimited SRS flashcards, on-device AI narration, Insights, study export, AudiobookShelf sync), sold as **both an auto-renewable subscription and a one-time lifetime purchase**.

We **feature the annual subscription** because recurring revenue is the explicit goal — it funds the multi-year roadmap and the ongoing AudiobookShelf-sync service ("if sales dry up there's no reason to keep developing"). **Lifetime — $49.99 regular, with periodic $29.99 sales** — is the buy-once escape hatch (~2× the annual), so the annual sub stays the day-to-day default while the privacy-and-ownership crowd still gets a permanent option. Entitlement is checked **on-device** via StoreKit 2 (no server, no analytics) — consistent with the privacy model; open-source users *can* bypass the gate, and that is an accepted trade-off because the mainstream pays.

---

## 2. Tiers

| Tier | One-line positioning |
|------|---------------------|
| **Free** | *A private, beautiful, no-account audiobook + read-along player — yours forever, with a taste of the study tools.* |
| **Echo Pro** | *Turn your listening into learning: unlimited spaced-repetition flashcards, on-device AI narration, insights, study export, and AudiobookShelf sync.* |

---

## 3. Free vs Pro feature matrix

Everything not explicitly Pro is Free.

### Player & listening core — **Free**

| Feature | Free | Pro | Notes |
|---|:--:|:--:|---|
| Import & play DRM-free **M4B / MP3 / M4A** (files + folders) | ✅ | ✅ | |
| **Pitch-corrected speed** | ✅ | ✅ | |
| **Sleep timer** | ✅ | ✅ | |
| **Chapters** | ✅ | ✅ | |
| **Background audio** | ✅ | ✅ | |
| **Lock screen / Control Center** controls | ✅ | ✅ | |
| **CarPlay** playback | ✅ | ✅ | |
| **Apple Watch remote** | ✅ | ✅ | |
| **Bookmarks** — plain / voice / photo | ✅ | ✅ | |
| **Chapter & bookmark looping** | ✅ | ✅ | |
| **Focus soundscapes** | ✅ | ✅ | |
| **Audio visualizer** | ✅ | ✅ | |
| **Pomodoro** | ✅ | ✅ | |
| **Dyslexia fonts + accessibility** | ✅ | ✅ | Never paywalled — accessibility is core identity |

### The "wow" — given away **Free**

| Feature | Free | Pro | Notes |
|---|:--:|:--:|---|
| **Synced read-along reader (EPUB / PDF)** | ✅ | ✅ | Deliberately free — the headline differentiator and goodwill driver |
| **Full-text search** | ✅ | ✅ | |
| **Tap-to-seek** (tap text → jump audio) | ✅ | ✅ | |

### Metered tastes — **Free (limited) → Pro (unlimited)**

| Feature | Free | Pro | Notes |
|---|:--:|:--:|---|
| **Flashcards** | ⚠️ ~20 total | ✅ Unlimited | Hard cap of **20 flashcards total** for free users |
| **AI narration** (on-device Kokoro) | ⚠️ 1-chapter preview / book | ✅ Unlimited | Free = **one chapter per book**; ships **"Coming in 1.0"** — see §7 |

### Echo Pro — exclusive unlocks

| Feature | Free | Pro | Notes |
|---|:--:|:--:|---|
| **Unlimited flashcards** | ❌ | ✅ | |
| **SM-2 spaced-repetition scheduling** | ❌ | ✅ | The retention engine |
| **Hands-free Apple Watch review** | ❌ | ✅ | |
| **Insights / stats dashboard** | ❌ | ✅ | |
| **Study export** — Markdown / Anki / JSON | ❌ | ✅ | |
| **Unlimited on-device AI narration** | ❌ | ✅ | Flagship Pro feature; gated **live** only after the build produces real audio |
| **AudiobookShelf — connect / browse / stream** | ✅ | ✅ | **Free** — connect your self-hosted server, browse, and stream (the ABS niche is $0-baselined; gating connection would look worse than free clients) |
| **AudiobookShelf — offline downloads & background sync** | ❌ | ✅ | **Pro** — the niche-standard paywall line (Prologue/Plappa/BookPlayer all gate offline); the ongoing service that justifies the sub |

> **"Pro Transcripts" reconciliation (audit flag):** the existing `ProTranscriptsSettingsView` paywall shell is **not** an enforced gate — transcript rendering currently keys off the unrelated `isTranscriptProcessingEnabled` Bool (`PlaybackState.swift:72`), and `hasUnlockedPro` is never read by any feature. **Decision: fold "Pro Transcripts" into Echo Pro** (transcript overlays become a Pro feature) and wire `TranscriptService` to the new `isPro` entitlement. Do **not** ship a second standalone "Pro Transcripts" SKU.

---

## 4. Metering & upgrade triggers

Two meters in the free tier. Both must be **durably persisted** (no usage counters exist today — `NarrationService.renderedChapterCount` at `NarrationService.swift:92` is telemetry only, and flashcard code has no cap). Persist in GRDB (`Shared/Database/DatabaseService.swift`) or `SettingsManager`; the count must survive relaunch and ideally ride iCloud.

| Meter | Free limit | Enforcement site | Trigger that surfaces the paywall |
|---|---|---|---|
| **Flashcards** | **20 total** (lifetime count, app-wide) | Block create/generate when `!isPro && flashcardCount >= 20`. Gate at `DailyReviewViewModel`, `FlashcardOverlayView`, `InlineFlashcardTriggerController` | User attempts to create / auto-generate flashcard #21 |
| **AI narration** | **1 chapter per book** | Guard `NarrationService.renderChapter` (`:37`): allow when `isPro || renderedChaptersForBook(bookID) < 1` | User taps "Narrate" on a 2nd chapter of any book |

**Additional paywall entry points** (no meter — feature is fully Pro): tapping **SM-2 review / scheduling**, **Insights dashboard**, **Study export**, or **downloading an AudiobookShelf book for offline / enabling ABS background sync** while `!isPro` (connecting + streaming ABS is free); plus a persistent **"Echo Pro" row** in Settings (replaces the current "Pro Transcripts" `NavigationLink`, `SettingsView.swift:96-97`).

**Metering UX rules:**
- Count toward the cap only on **successful creation**, not on view.
- When the cap is hit, **do not delete or hide** existing free content — the 20 cards and the 1 narrated chapter stay fully usable. Only *new* creation is blocked.
- Show a **non-blocking, friendly** paywall sheet ("You've filled your 20 free cards — Echo Pro makes them unlimited"), never an error alert.
- Free narration preview must say **"Preview"** in the UI so the 1-chapter limit is expected, not a surprise.

---

## 5. Pricing

### Recommended price points — `recommend — confirm`

| Product | Price | Billing | Featured? | Role |
|---|---|---|:--:|---|
| **Echo Pro — Monthly** | **$3.99 / mo** | auto-renewable | — | Low-commitment / trial funnel; deliberately unattractive vs. annual |
| **Echo Pro — Annual** | **$24.99 / yr** | auto-renewable | ⭐ **Featured** | The funding engine — recurring revenue for ongoing dev + ABS sync |
| **Echo Pro — Lifetime** | **$49.99** regular *(periodic sales to $29.99 — see sale note below)* | one-time non-consumable | — | Buy-once escape hatch |
| **Founders Lifetime** | **$39.99** | one-time non-consumable, limited window | Launch-only | Early-supporter reward; retires after the founders window |
| **Free Pro trial** | **7 days** | intro offer on the sub | — | Attached to monthly + annual |

> **DECIDED — Lifetime $49.99 regular, with periodic sales down to $29.99.** This reconciles both poles: $49.99 (≈2× annual) keeps the annual sub attractive day-to-day, while occasional $29.99 sales capture the AnkiMobile-anchored buy-once crowd and create promotional urgency without permanently undercutting recurring revenue.
>
> **Sale mechanism (non-consumable):** there is no native "sale price" object for one-time purchases — run sales by **scheduling a temporary price change to $29.99** in App Store Connect for the sale window (it auto-reverts to $49.99). **The app must render `product.displayPrice` dynamically and never hardcode the price**, so a scheduled sale "just works" everywhere (paywall, Settings, marketing). The Founders $39.99 SKU is separate and unaffected.

### Comp-based rationale (verified June 2026)

Echo uniquely spans **three** comp clusters; price must respect all three.

- **Players / ABS-clients = the floor, brutally cheap.** Official Audiobookshelf app **$0/FOSS**; **Plappa** $4.99 lifetime / $1.99/yr; **ShelfPlayer** $5.99 one-time; **Prologue** $9.99 one-time (gates offline download); **BookPlayer** gives full local playback free, Pro at $4.99/mo–$49.99/yr. → **Echo's free tier must match BookPlayer-level generosity** or it looks worse than free alternatives. We cannot price the *player surface* like SaaS.
- **TTS / narration = the ceiling, subscription territory.** **Speechify** $139/yr; **NaturalReader** ~$119/yr; **Voice Dream** now $79.99/yr. These justify subs via **cloud-voice compute cost**. Echo's narration is **on-device (zero server cost)**, so we **cannot** credibly charge Speechify-level subs — but on-device narration *does* justify sitting **above the bare $5 player tier**.
- **SRS / study = the legitimacy anchor.** **AnkiMobile $24.99 one-time** is the key data point: serious learners pay ~$25 once, *specifically because it funds a free open-source ecosystem* — almost exactly Echo's positioning. **Readwise** ($9.99/mo annual, no lifetime, trial-only) proves pure-SaaS retention works but with **no permanent free tier** — a model Echo deliberately rejects.

Echo's annual **$24.99/yr** sits **well below** every TTS sub (correct — no server cost to justify $79–$139) and bundles SRS + on-device AI narration + read-along that **no single comp offers together**, which is what lets Echo escape the $5 player ceiling.

> **RISK — the Voice Dream cautionary tale:** Voice Dream's forced migration from lifetime to subscription **disabled lifetime users' apps** and triggered severe backlash. For Echo's privacy-/open-source-aligned audience: **keep lifetime genuinely permanent, and NEVER retroactively paywall existing buyers.** Honoring purchased lifetime forever is non-negotiable.

---

## 6. StoreKit implementation plan

**Framework:** StoreKit 2 (already in use). **Extend** the existing `StoreManager` and the `com.echo.pro.unlock` IAP — **do not greenfield.** Follow the Axiom `axiom-integration` references (`skills/in-app-purchases.md`, `skills/storekit-ref.md`) during implementation, and confirm `IPHONEOS_DEPLOYMENT_TARGET` before adopting any newer StoreKit API.

### Product IDs (proposed concrete)

| Product ID | Type | Maps to |
|---|---|---|
| `com.echo.pro.unlock` | Non-consumable (**existing — reuse as Lifetime**) | Echo Pro Lifetime |
| `com.echo.pro.monthly` | Auto-renewable subscription | Echo Pro Monthly $3.99 |
| `com.echo.pro.yearly` | Auto-renewable subscription | Echo Pro Annual $24.99 |
| `com.echo.pro.founders` | Non-consumable | Founders Lifetime $39.99 (limited window) |

- **Subscription group:** `Echo Pro` (one group). `monthly` + `yearly` are two levels so users can crossgrade and only ever hold one active sub.
- **Founders** as a **separate non-consumable** (cleanest: stop loading/showing the ID after the window; existing owners keep it forever). *Alternative (§9):* a **promo/intro price on `com.echo.pro.unlock`** — avoids a permanent dead product but complicates "is this the founders price?" display. **Recommend the separate non-consumable.**

### Introductory offer (7-day free trial)

- Configure a **free 7-day Introductory Offer** on **both** subscription products in the `Echo Pro` group.
- StoreKit enforces **one intro offer per subscription group per Apple ID** — no custom anti-abuse needed, but the UI must **check eligibility** (`Product.SubscriptionInfo.isEligibleForIntroOffer`) and only show "7 days free" when eligible; otherwise show plain price.

### On-device entitlement model

Replace the single cosmetic `hasUnlockedPro` Bool with a **real, enforced** entitlement:

```
isPro = lifetimeOwned || foundersOwned || subscriptionActive
```

- `lifetimeOwned` / `foundersOwned` — non-consumable in `Transaction.currentEntitlements` with `revocationDate == nil` (today's logic, broadened to both IDs).
- `subscriptionActive` — derive from `Product.SubscriptionInfo.Status` for the `Echo Pro` group: treat `.subscribed`, `.inGracePeriod`, `.inBillingRetryPeriod` as active; treat `.expired` / `.revoked` as **not** Pro. Read `expirationDate` and flip Pro off on lapse.
- Expose **one** computed gate (`var isPro: Bool`, plus optional `canUseProFeature`). Every feature site reads **this**, not `isTranscriptProcessingEnabled`.

### Reuse from existing StoreManager (already correct)

- `Product.products(for:)` loading (`:32-45`) — expand the ID array to all four.
- `purchase()` + `VerificationResult` `checkVerified()` (`:47-65`, `:114-121`).
- `Transaction.updates` listener (`:81-91`); `Transaction.currentEntitlements` scan (`:93-107`) — broaden, don't replace.
- `transaction.finish()`; `restorePurchases()` via `AppStore.sync()` (`:67-75`, already wired to a Restore button at `SettingsView.swift:575-584`).
- Error surfacing `lastStoreError` / `recordStoreError()` (`:13`, `:77-79`).
- Single-instance `@Observable @MainActor StoreManager` injected at `EchoCoreApp.swift:14/60`, read via `@Environment(StoreManager.self)`.

### Gaps to fill (from IAP audit)

1. **No `.storekit` config exists** / no scheme reference. **Create `Echo.storekit`** (lifetime non-consumable + `Echo Pro` group with monthly+yearly + 7-day intro offer + founders) and **attach it to the `Echo` scheme** for Sim/local testing.
2. **Single hardcoded product ID** (`:34`) → request **all four**; match by ID everywhere (`:36, 98, 110`).
3. **Entitlement is a single Bool with no sub semantics** → broaden to the `isPro` model (read `expirationDate`, status, grace/billing-retry).
4. **No subscription status observation** → add `Product.SubscriptionInfo.status` handling so lapse/renewal flips Pro.
5. **No intro-offer eligibility logic** → add the eligibility check + trial-aware copy.
6. **Entitlement never enforced** → introduce the real gate; wire transcript rendering + both meters to it. *This is the app's first real enforcement.*
7. **No metered free-tier accounting** → persisted flashcard count (cap 20) + per-book narration-chapter count (cap 1), enforced before creation/render.
8. **No reusable paywall surface** → build a presentable `PaywallView` sheet.
9. **No `StoreManaging` protocol seam** in the main tree (scratch worktrees have one — ignore those) → extract a protocol so `isPro` + meters are unit-testable; `EchoTests` have no StoreManager tests.
10. **No usage-persistence location chosen** → pick GRDB vs `SettingsManager` + add a migration.

> IAP needs **no special entitlement** — `EchoCore.entitlements` correctly has none. Don't add one.

---

## 7. Paywall UX

### When / where it appears (triggers from §4)
- **Meter cap hit:** flashcard #21; AI-narration chapter #2 of a book.
- **Pure-Pro tap:** SM-2 review, Insights, any Study export, Connect AudiobookShelf.
- **Settings entry:** the persistent **"Echo Pro"** row (replacing the `Pro Transcripts` `NavigationLink`, `SettingsView.swift:96-97`).
- Always a **dismissible sheet**, never modal-trapping. Contextual subheadline matching the trigger.

### Upgrade-screen copy

**Headline:** **Echo Pro — turn listening into learning**

**Bullets:**
- ♾️ **Unlimited flashcards** with **SM-2 spaced repetition** — review hands-free on Apple Watch
- 🗣️ **Unlimited on-device AI narration** *(coming in 1.0)* — your books, read aloud, fully private
- 📊 **Insights** — see your listening & study streaks
- 📤 **Study export** — Markdown, Anki, or JSON
- 🔗 **AudiobookShelf offline & sync** — download from your self-hosted server *(connecting + streaming is free)*
- 🔒 **No account, no servers, no tracking** — entitlement lives on your device

**Plan selector (featured = Annual):**
> **Annual — $24.99/yr** ⭐ *Best value* · Monthly — $3.99/mo · Lifetime — $49.99 (pay once)
> *Founders: Lifetime $39.99 — limited time* (shown only during the founders window)

**Primary CTA:** **Start 7-day free trial** *(when intro-eligible)* → **Subscribe** *(otherwise)*

**Trial line (eligible):** *7 days free, then $24.99/year. Cancel anytime in Settings.*
**Trial line (lifetime selected):** *One-time $49.99. Yours forever — no subscription.*

**Footer affordances:** **Restore Purchases** (reuse `restorePurchases()`); **Manage Subscription** (`showManageSubscriptions`, subscribers only); links to **Terms** + **Privacy** (required by App Review for auto-renewable subs); a short **"Open source — you can build it yourself"** note (on-brand). StoreKit errors surface inline via `lastStoreError`.

> **Trust requirement (AI narration):** the paywall **lists** AI narration but marks it **"Coming in 1.0."** It must not be sold as *live* until the build produces real audio (stub on `main`).

---

## 8. App Store Connect setup

1. **Create subscription group** `Echo Pro`.
2. **Add subscriptions:** `com.echo.pro.monthly` ($3.99/mo) and `com.echo.pro.yearly` ($24.99/yr) with localized name/description + review screenshot.
3. **Add 7-day free Introductory Offer** (type: Free, 1 week) to **both** subscriptions.
4. **Reuse non-consumable** `com.echo.pro.unlock`; set Lifetime price; rename to "Echo Pro — Lifetime."
5. **Create founders non-consumable** `com.echo.pro.founders` at $39.99. *(Or, per §6 alternative, a promo offer on the unlock.)* Remove from the in-app requested-ID list after the window; existing buyers keep it.
6. **Family Sharing:** **ON** for Lifetime + Founders (goodwill, no recurring cost); **OFF** for the monthly/annual subs (sharing a sub undercuts recurring revenue). *Confirm in §9 — Family Sharing is irreversible once enabled.*
7. **Add Privacy Policy + Terms (EULA) URLs** at the app level (required for auto-renewable subs).
8. **Tax & banking / Paid Apps agreement** active before any IAP can be sold.
9. **Submit new IAP products with a build** that presents and can purchase them (App Review rejects unreachable IAPs).

### ⚠️ Required pre-launch action — remove the "no subscription" promise

The **current App Store description says "no subscription."** Adding one after promising none is **classic 1-star bait-and-switch.**
- **Edit the App Store description** to remove every "no subscription" / "no IAP" claim **before** the paywall ships.
- Reposition honestly: *"Free, private audiobook player. Echo Pro (subscription or one-time lifetime) unlocks unlimited study tools."*
- Audit **all marketing surfaces** (website, screenshots, README, TestFlight notes) and reconcile them in the **same release** the sub goes live.

---

## 9. Open decisions to confirm

- [x] **Lifetime price — DECIDED:** **$49.99 regular, periodic sales to $29.99** (scheduled App Store Connect price changes; app shows dynamic `product.displayPrice`).
- [ ] **Confirm monthly $3.99 / annual $24.99.**
- [ ] **Founders price ($39.99) + window length**, and SKU mechanism (separate non-consumable vs. promo offer on the lifetime unlock).
- [ ] **Trial length** — confirm 7 days; whether it applies to monthly, annual, or both.
- [x] **ABS tier — DECIDED:** **free connect / browse / stream; Pro gates offline downloads + background sync.**
- [ ] **Family Sharing on subscriptions** — confirm OFF (irreversible once ON).
- [ ] **Confirm "Pro Transcripts" folds into Echo Pro** and the standalone shell is retired.
- [ ] **AI-narration go-live gate** — confirm the build produces real Kokoro audio before "unlimited AI narration" is sold as live (ships "Coming in 1.0" until then).

---

### File references for implementation

- Store logic: `EchoCore/Services/StoreManager.swift` (`proUnlockProductID:8`, `hasUnlockedPro:12`, request `:32-45`, purchase `:47-65`, restore `:67-75`, updates `:81-91`, entitlements `:93-107`)
- Paywall surface to replace/extend: `SettingsView.swift:96-97` (NavigationLink), `:534-627` (`ProTranscriptsSettingsView`)
- Transcript gate to rewire onto `isPro`: `TranscriptService.swift:17/67/87`, `PlaybackState.swift:72`, `PlayerModel.swift:400-402`
- Narration cap site: `NarrationService.swift:37` (`renderChapter`), counter at `:92`
- Flashcard cap sites: `DailyReviewViewModel.swift`, `FlashcardOverlayView.swift`, `InlineFlashcardTriggerController.swift`
- DI / injection: `EchoCoreApp.swift:14` (`@State`), `:60` (`.environment`)
- Localized strings to extend: `EchoCore/Localizable.xcstrings` (~1984, 2992, 3251, 3782, 4301, 4319, 4337)
- New files: `Echo.storekit` (attach to scheme), `StoreManaging` protocol, reusable `PaywallView`, usage-counter persistence + migration
- Implementation guidance: Axiom `axiom-integration` → `skills/in-app-purchases.md`, `skills/storekit-ref.md`; or launch the `iap-implementation` agent.
