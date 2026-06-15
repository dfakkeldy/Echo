# Echo Pro Paywall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Echo's cosmetic "Pro Transcripts" IAP into a real, enforced freemium paywall — a free player + read-along tier with metered tastes (20 flashcards, 1 narrated chapter/book), and an **Echo Pro** unlock (subscription + lifetime + founders) that gates the study/AI/ABS-offline features.

**Architecture:** Extend the existing StoreKit 2 `StoreManager` (don't greenfield). Entitlement collapses to one computed `isPro` (lifetime non-consumable **or** founders non-consumable **or** an active subscription). A pure `ProEntitlement` rule + a `ProEntitlementProviding` protocol make gating unit-testable. Free-tier meters **derive counts from existing data** (flashcards via `FlashcardDAO`, narrated chapters via existing `TrackRecord`s) — **no new DB tables**. A reusable `PaywallView` is presented from cap-hit sites and replaces the Settings "Pro Transcripts" row.

**Tech Stack:** StoreKit 2, SwiftUI, `@Observable`, GRDB, Swift Testing. Deployment target **iOS 18.0** / macOS 15 / watchOS 11 — so use `product.purchase()` (not `purchase(confirmIn:)`, 18.2+); `Product.SubscriptionInfo.status(for:)` and intro-offer eligibility are 15+ and fine; a **custom** `PaywallView` (not `SubscriptionStoreView`) to handle the sub+lifetime+founders mix.

> **Pre-req decisions (locked, see `PRICING.md`):** Monthly $3.99 / Annual $24.99 (featured) / Lifetime $49.99 regular (periodic $29.99 sales via scheduled ASC price changes — **render `product.displayPrice`, never hardcode**) / Founders Lifetime $39.99 (limited window) / 7-day free trial. Free tier: read-along + ABS connect/browse/stream free; 20-flashcard + 1-narrated-chapter meters; Pro = unlimited flashcards+SRS, Insights, export, unlimited AI narration, ABS offline/sync, transcripts.

---

## File Structure

**New files:**
- `Echo.storekit` (repo root, added to the `Echo` scheme) — local StoreKit test catalog.
- `EchoCore/Services/Store/ProductIDs.swift` — product-ID + subscription-group constants (one source of truth).
- `EchoCore/Services/Store/ProEntitlement.swift` — pure entitlement rule + `ProEntitlementProviding` protocol.
- `EchoCore/Services/Store/FreeTierGate.swift` — meter logic (counts + `canCreate…` / `canRender…`).
- `EchoCore/Views/Paywall/PaywallView.swift` — reusable paywall sheet.
- `EchoCore/Views/Paywall/PaywallContext.swift` — small enum describing what triggered the paywall (for the contextual subheadline).
- `EchoTests/StoreEntitlementTests.swift`, `EchoTests/FreeTierGateTests.swift` — unit tests.

**Modified files:**
- `EchoCore/Services/StoreManager.swift` — add subscription products, broaden to `isPro`, sub status, intro-offer eligibility; conform to `ProEntitlementProviding`.
- `EchoCore/Services/Narration/NarrationService.swift:37` — narration cap guard.
- `EchoCore/Services/DAO/FlashcardDAO.swift` (wherever `FlashcardDAO` lives) — add `count()`.
- `EchoCore/Views/Components/FlashcardCreationSheet.swift:70` — flashcard cap guard + present paywall.
- `EchoCore/Views/CardInboxView.swift:109` — flashcard cap guard + present paywall.
- `EchoCore/Services/TranscriptService.swift:17,67,87` + the enable path — gate transcripts on `isPro`.
- `EchoCore/Views/SettingsView.swift:96-97,532-627` — replace "Pro Transcripts" row with "Echo Pro"; retire `ProTranscriptsSettingsView` (or repoint it at `PaywallView`).
- `EchoCore/EchoCoreApp.swift` — inject `FreeTierGate` alongside `StoreManager` (`:14`, `:60`).

> **Note (test framework):** examples use Swift Testing (`import Testing`, `@Test`, `#expect`). If an Echo test target still uses XCTest, wrap each `@Test` body in an `XCTestCase` method with `XCTAssert…`.

---

## Phase 0 — StoreKit config (do this FIRST, before code)

### Task 1: Create `Echo.storekit` and attach it to the scheme

**Files:** Create `Echo.storekit` (repo root); modify the `Echo` scheme.

- [ ] **Step 1: Create the config**

In Xcode: **File → New → File → StoreKit Configuration File** → name `Echo` → save at repo root (`Echo.storekit`). Choose "None (use local products)" (not synced to App Store Connect yet).

- [ ] **Step 2: Add the products** (click `+`)

| Type | Product ID | Reference Name | Price | Group |
|---|---|---|---|---|
| Non-Consumable | `com.echo.pro.unlock` | Echo Pro — Lifetime | $49.99 | — |
| Non-Consumable | `com.echo.pro.founders` | Echo Pro — Founders | $39.99 | — |
| Auto-Renewable | `com.echo.pro.monthly` | Echo Pro — Monthly | $3.99 | `Echo Pro` |
| Auto-Renewable | `com.echo.pro.yearly` | Echo Pro — Annual | $24.99 | `Echo Pro` |

On **both** subscriptions, add an **Introductory Offer → Free → 1 week**.

- [ ] **Step 3: Attach to the scheme**

**Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration → `Echo.storekit`**. (Do the same for the `Echo macOS` scheme if present.)

- [ ] **Step 4: Verify**

Run the app on a simulator, open the existing **Settings → Pro Transcripts** screen → confirm a price (`$49.99`) renders for `com.echo.pro.unlock` (proves the config + existing `StoreManager.requestProducts()` load it).

- [ ] **Step 5: Commit**

```bash
git add Echo.storekit Echo.xcodeproj/xcshareddata/xcschemes/Echo.xcscheme
git commit -m "build(iap): add Echo.storekit local test catalog (pro unlock, founders, monthly, yearly + 7-day trial)"
```

---

## Phase 1 — Entitlement model

### Task 2: Product-ID constants + `StoreManaging` request expansion

**Files:** Create `EchoCore/Services/Store/ProductIDs.swift`; Modify `EchoCore/Services/StoreManager.swift:8,34`.

- [ ] **Step 1: Create the constants**

```swift
// EchoCore/Services/Store/ProductIDs.swift
import Foundation

/// Single source of truth for StoreKit product identifiers + subscription group.
enum ProductIDs {
    static let lifetime  = "com.echo.pro.unlock"   // existing non-consumable
    static let founders  = "com.echo.pro.founders" // limited-window non-consumable
    static let monthly   = "com.echo.pro.monthly"  // auto-renewable
    static let yearly    = "com.echo.pro.yearly"   // auto-renewable

    static let subscriptionGroupID = "Echo Pro"

    static let all: [String] = [lifetime, founders, monthly, yearly]
    static let nonConsumables: Set<String> = [lifetime, founders]
    static let subscriptions:  Set<String> = [monthly, yearly]
}
```

- [ ] **Step 2: Request all four products**

In `StoreManager.requestProducts()` (`StoreManager.swift:34`), replace the single-ID request:

```swift
// was: try await Product.products(for: [Self.proUnlockProductID])
let requestedProducts = try await Product.products(for: ProductIDs.all)
products = requestedProducts
proUnlockProduct = requestedProducts.first { $0.id == ProductIDs.lifetime }
```

Keep `static let proUnlockProductID` as `ProductIDs.lifetime` (back-compat for the existing Settings view until Task 10 retires it):

```swift
static let proUnlockProductID = ProductIDs.lifetime
```

- [ ] **Step 3: Build & smoke-test** — run app, confirm all four prices load in a debug print (`products.map(\.displayPrice)`).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Store/ProductIDs.swift EchoCore/Services/StoreManager.swift
git commit -m "feat(iap): centralize product IDs and request all four Echo Pro products"
```

### Task 3: Broaden entitlement to `isPro` (pure rule + protocol + sub status)

**Files:** Create `EchoCore/Services/Store/ProEntitlement.swift`, `EchoTests/StoreEntitlementTests.swift`; Modify `StoreManager.swift`.

- [ ] **Step 1: Write the failing test for the pure rule**

```swift
// EchoTests/StoreEntitlementTests.swift
import Testing
@testable import EchoCore

struct StoreEntitlementTests {
    @Test func lifetimeOwnerIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: true, foundersOwned: false, subscriptionActive: false))
    }
    @Test func foundersOwnerIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: false, foundersOwned: true, subscriptionActive: false))
    }
    @Test func activeSubscriberIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: false, foundersOwned: false, subscriptionActive: true))
    }
    @Test func nothingOwnedIsNotPro() {
        #expect(!ProEntitlement.isPro(lifetimeOwned: false, foundersOwned: false, subscriptionActive: false))
    }
    @Test func subscriptionActiveStates() {
        #expect(ProEntitlement.isActive(.subscribed))
        #expect(ProEntitlement.isActive(.inGracePeriod))
        #expect(ProEntitlement.isActive(.inBillingRetryPeriod))
        #expect(!ProEntitlement.isActive(.expired))
        #expect(!ProEntitlement.isActive(.revoked))
    }
}
```

- [ ] **Step 2: Run it — verify it fails** (`ProEntitlement` undefined).

Run: `xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:EchoTests/StoreEntitlementTests`
Expected: FAIL — "cannot find 'ProEntitlement' in scope".

- [ ] **Step 3: Implement the pure rule + provider protocol**

```swift
// EchoCore/Services/Store/ProEntitlement.swift
import StoreKit

/// Pure, dependency-free entitlement rules — unit-testable without StoreKit.
enum ProEntitlement {
    static func isPro(lifetimeOwned: Bool, foundersOwned: Bool, subscriptionActive: Bool) -> Bool {
        lifetimeOwned || foundersOwned || subscriptionActive
    }

    /// A subscription state that should grant access (active, or Apple is still trying to bill).
    static func isActive(_ state: Product.SubscriptionInfo.RenewalState) -> Bool {
        switch state {
        case .subscribed, .inGracePeriod, .inBillingRetryPeriod: return true
        case .expired, .revoked:                                  return false
        default:                                                  return false
        }
    }
}

/// What gating code depends on — mockable in tests.
@MainActor
protocol ProEntitlementProviding {
    var isPro: Bool { get }
}
```

- [ ] **Step 4: Run the test — verify it passes.**

- [ ] **Step 5: Wire the real entitlement into `StoreManager`**

Replace the single `hasUnlockedPro` derivation. In `StoreManager.swift`, add state and conform:

```swift
// add near the other observable properties (replaces the role of hasUnlockedPro)
private(set) var isPro = false
@ObservationIgnored private var lifetimeOwned = false
@ObservationIgnored private var foundersOwned = false
@ObservationIgnored private var subscriptionActive = false

// keep hasUnlockedPro as an alias so existing views still compile until Task 10:
var hasUnlockedPro: Bool { isPro }
```

Rewrite `refreshPurchasedProducts()` (`StoreManager.swift:93-107`):

```swift
private func refreshPurchasedProducts() async {
    var lifetime = false
    var founders = false
    for await result in Transaction.currentEntitlements {
        guard let txn = try? checkVerified(result), txn.revocationDate == nil else { continue }
        if txn.productID == ProductIDs.lifetime { lifetime = true }
        if txn.productID == ProductIDs.founders { founders = true }
    }
    lifetimeOwned = lifetime
    foundersOwned = founders
    subscriptionActive = await isSubscriptionActive()
    recomputeIsPro()
}

private func isSubscriptionActive() async -> Bool {
    guard let statuses = try? await Product.SubscriptionInfo.status(for: ProductIDs.subscriptionGroupID)
    else { return false }
    // Active if ANY status in the group is an access-granting state with a verified transaction.
    return statuses.contains { status in
        (try? checkVerified(status.transaction)) != nil && ProEntitlement.isActive(status.state)
    }
}

private func recomputeIsPro() {
    isPro = ProEntitlement.isPro(
        lifetimeOwned: lifetimeOwned, foundersOwned: foundersOwned, subscriptionActive: subscriptionActive)
}
```

Replace `updateProUnlockState(from:)` (`:109-112`) so any product refreshes the whole picture:

```swift
private func updateProUnlockState(from transaction: Transaction) async {
    await refreshPurchasedProducts()
}
```

Add the conformance at the type declaration:

```swift
final class StoreManager: ProEntitlementProviding {  // (keep @MainActor @Observable)
```

- [ ] **Step 6: Build, run, manually verify** — buy the lifetime in the sim → `isPro` true; with StoreKit config, cancel the sub → `isPro` false. Confirm the existing Settings "Unlocked/Locked" label still works (it reads `hasUnlockedPro`, now aliased to `isPro`).

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Store/ProEntitlement.swift EchoTests/StoreEntitlementTests.swift EchoCore/Services/StoreManager.swift
git commit -m "feat(iap): real isPro entitlement (lifetime/founders/active-sub) + pure testable rule"
```

### Task 4: Generic purchase + intro-offer eligibility (for trial copy)

**Files:** Modify `StoreManager.swift`.

- [ ] **Step 1: Add a generic purchase** (the existing `purchaseProUnlock()` is lifetime-only):

```swift
@discardableResult
func purchase(_ product: Product) async throws -> Bool {
    let result = try await product.purchase()
    switch result {
    case .success(let verification):
        let txn = try checkVerified(verification)
        await updateProUnlockState(from: txn)
        await txn.finish()
        return true
    case .userCancelled, .pending:
        return false
    @unknown default:
        return false
    }
}
```

- [ ] **Step 2: Expose intro-offer eligibility**

```swift
/// True when the user can still get the 7-day free trial on the subscription group.
func isEligibleForFreeTrial() async -> Bool {
    guard let sub = products.first(where: { $0.id == ProductIDs.yearly })?.subscription else { return false }
    return await sub.isEligibleForIntroOffer
}
```

- [ ] **Step 3: Build** (no behavior change yet — consumed by the paywall in Task 9).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/StoreManager.swift
git commit -m "feat(iap): generic purchase(_:) + free-trial eligibility helper"
```

---

## Phase 2 — Free-tier meters (derive from existing data)

### Task 5: `FreeTierGate` service + `FlashcardDAO.count()`

**Files:** Create `EchoCore/Services/Store/FreeTierGate.swift`, `EchoTests/FreeTierGateTests.swift`; Modify `FlashcardDAO` and `EchoCoreApp.swift`.

- [ ] **Step 1: Add a count to `FlashcardDAO`** (find it: `grep -rn "struct FlashcardDAO\|class FlashcardDAO" EchoCore`):

```swift
// in FlashcardDAO
func count() throws -> Int {
    try db.read { try Flashcard.fetchCount($0) }
}
```
(`Flashcard` is already a GRDB `PersistableRecord` — it's used with `dao.insert(card)` — so `fetchCount` is available.)

- [ ] **Step 2: Write the failing test**

```swift
// EchoTests/FreeTierGateTests.swift
import Testing
@testable import EchoCore

@MainActor
struct FreeTierGateTests {
    private final class FakeEntitlement: ProEntitlementProviding {
        var isPro: Bool
        init(_ v: Bool) { isPro = v }
    }

    @Test func proCanAlwaysCreate() {
        let gate = FreeTierGate(entitlement: FakeEntitlement(true), flashcardCount: { 999 })
        #expect(gate.canCreateFlashcards(adding: 100))
    }
    @Test func freeUserCappedAtTwenty() {
        let gate = FreeTierGate(entitlement: FakeEntitlement(false), flashcardCount: { 19 })
        #expect(gate.canCreateFlashcards(adding: 1))   // 19+1 = 20, allowed (the 20th)
        let full = FreeTierGate(entitlement: FakeEntitlement(false), flashcardCount: { 20 })
        #expect(!full.canCreateFlashcards(adding: 1))  // would be 21, blocked
    }
    @Test func freeNarrationOneChapterPerBook() {
        let none = FreeTierGate(entitlement: FakeEntitlement(false), narratedChapters: { _ in 0 })
        #expect(none.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: false))
        let one = FreeTierGate(entitlement: FakeEntitlement(false), narratedChapters: { _ in 1 })
        #expect(!one.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: false))
        // re-rendering an already-narrated chapter (voice change) is always allowed:
        #expect(one.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: true))
    }
}
```

- [ ] **Step 3: Run — verify it fails** (`FreeTierGate` undefined).

- [ ] **Step 4: Implement `FreeTierGate`**

```swift
// EchoCore/Services/Store/FreeTierGate.swift
import Foundation

@MainActor
@Observable
final class FreeTierGate {
    static let freeFlashcardCap = 20
    static let freeNarrationChaptersPerBook = 1

    private let entitlement: ProEntitlementProviding
    private let flashcardCount: () -> Int
    private let narratedChapters: (_ audiobookID: String) -> Int

    /// Production init wires counts to the live DB; tests inject closures.
    init(entitlement: ProEntitlementProviding,
         flashcardCount: @escaping () -> Int = { 0 },
         narratedChapters: @escaping (_ audiobookID: String) -> Int = { _ in 0 }) {
        self.entitlement = entitlement
        self.flashcardCount = flashcardCount
        self.narratedChapters = narratedChapters
    }

    var isPro: Bool { entitlement.isPro }

    func canCreateFlashcards(adding count: Int) -> Bool {
        isPro || (flashcardCount() + count) <= Self.freeFlashcardCap
    }

    func remainingFreeFlashcards() -> Int {
        isPro ? .max : max(0, Self.freeFlashcardCap - flashcardCount())
    }

    /// `alreadyRenderedThisChapter` = the chapter already has a synthesized TrackRecord
    /// (idempotent re-render / voice change) — never blocked.
    func canRenderNarration(audiobookID: String, alreadyRenderedThisChapter: Bool) -> Bool {
        isPro || alreadyRenderedThisChapter
            || narratedChapters(audiobookID) < Self.freeNarrationChaptersPerBook
    }
}
```

- [ ] **Step 5: Run the tests — verify they pass.**

- [ ] **Step 6: Wire the production `FreeTierGate` in `EchoCoreApp.swift`** (after `:14`):

```swift
@State private var storeManager = StoreManager()
@State private var freeTierGate: FreeTierGate
// in init (or a computed factory after db + storeManager exist):
// freeTierGate = FreeTierGate(
//     entitlement: storeManager,
//     flashcardCount: { (try? FlashcardDAO(db: db.writer).count()) ?? 0 },
//     narratedChapters: { id in NarrationFileNaming.narratedChapterCount(audiobookID: id, db: db.writer) })
```
…and inject it next to the others (`:60`): `.environment(freeTierGate)`.

(`narratedChapterCount` is added in Task 7.)

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Store/FreeTierGate.swift EchoTests/FreeTierGateTests.swift EchoCore/Services/DAO/FlashcardDAO.swift EchoCore/EchoCoreApp.swift
git commit -m "feat(paywall): FreeTierGate (20-card + 1-narration meters) deriving from existing data"
```

### Task 6: Enforce the flashcard cap at the two creation sites

**Files:** Modify `FlashcardCreationSheet.swift:70-94`, `CardInboxView.swift:109-113`.

- [ ] **Step 1: Gate `FlashcardCreationSheet.saveFlashcard()`** — read the gate from the environment and guard before insert (`:74-94`):

```swift
@Environment(FreeTierGate.self) private var freeTierGate
@State private var showPaywall = false
...
private func saveFlashcard() {
    guard freeTierGate.canCreateFlashcards(adding: 1) else { showPaywall = true; return }
    // ... existing build-the-card + try FlashcardDAO(db: db.writer).insert(card) ...
}
```
Add `.sheet(isPresented: $showPaywall) { PaywallView(context: .flashcardCap) }` to the view body (PaywallView lands in Task 9 — until then, stub the sheet with `Text("Echo Pro")`).

- [ ] **Step 2: Gate `CardInboxView.convertToFlashcard(_:)`** (`:109`) — same guard before the `Flashcard(` insert; present `PaywallView(context: .flashcardCap)`.

- [ ] **Step 3: Manual test** — with StoreKit config, create 20 cards as a free user → the 21st presents the paywall; existing 20 stay usable.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/Components/FlashcardCreationSheet.swift EchoCore/Views/CardInboxView.swift
git commit -m "feat(paywall): cap free users at 20 flashcards at both creation sites"
```

### Task 7: Enforce the narration cap in `NarrationService.renderChapter`

**Files:** Modify `NarrationService.swift:37`; add a count helper.

- [ ] **Step 1: Add the persistent per-book narrated-chapter count** (synthesized chapters are `TrackRecord`s with id `syn-<audiobookID>-ch<n>`). Add to `NarrationFileNaming` (or a small helper):

```swift
static func narratedChapterCount(audiobookID: String, db: DatabaseWriter) -> Int {
    (try? db.read { db in
        try TrackRecord.filter(sql: "id LIKE ?", arguments: ["syn-\(audiobookID)-ch%"]).fetchCount(db)
    }) ?? 0
}
```

- [ ] **Step 2: Guard `renderChapter`** — inject the gate (or an `isPro` + count closure) into `NarrationService.init`, then at the top of `renderChapter` (`:38`, before `state.update`):

```swift
let trackID = "syn-\(audiobookID)-ch\(chapterIndex)"
let alreadyRendered = (try? db.read { db in try TrackRecord.exists(db, key: trackID) }) ?? false
guard freeTierGate.canRenderNarration(audiobookID: audiobookID, alreadyRenderedThisChapter: alreadyRendered) else {
    throw NarrationError.proRequired
}
```
Add the case to `NarrationError` (`:5`): `case proRequired`. Whatever presents narration must catch `.proRequired` and show `PaywallView(context: .narrationCap)`.

- [ ] **Step 3: Manual test** — free user narrates chapter 1 of a book (works), chapter 2 throws `.proRequired` → paywall; re-narrating chapter 1 with a different voice still works (idempotent re-render).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift
git commit -m "feat(paywall): cap free AI narration to 1 chapter per book"
```

---

## Phase 3 — Enforce pure-Pro features

### Task 8: Fold "Pro Transcripts" into Echo Pro (rewire onto `isPro`)

**Files:** Modify `TranscriptService.swift:17,67,87`; the enable path in `PlaybackState.swift:72` / `PlayerModel.swift:400-402`.

- [ ] **Step 1: Pass entitlement into `TranscriptService`** — give it an `isPro` source (inject `ProEntitlementProviding`, or set a `var isPro` updated from `StoreManager`). Then change the three guards (`:17,67,87`) from:

```swift
guard state.isTranscriptProcessingEnabled else { return }
```
to:
```swift
guard isPro, state.isTranscriptProcessingEnabled else { return }
```

- [ ] **Step 2: Make the Settings toggle that flips `isTranscriptProcessingEnabled` present the paywall when `!isPro`** instead of silently enabling — so a free user tapping "Transcripts" sees `PaywallView(context: .transcripts)`.

- [ ] **Step 3: Manual test** — free user: transcripts do not render and the toggle routes to the paywall; Pro user: transcripts render as before.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/TranscriptService.swift EchoCore/Models/PlaybackState.swift EchoCore/ViewModels/PlayerModel.swift
git commit -m "feat(paywall): enforce transcripts as a real Pro feature (was a cosmetic gate)"
```

> **Other pure-Pro gates** (Insights, Study export, SM-2 review entry, ABS **offline download / sync**) follow the **identical pattern**: at the feature's entry action, `guard freeTierGate.isPro else { showPaywall = true; return }` with the matching `PaywallContext`. ABS **connect/browse/stream stays free** — gate only the download/sync action. Add each gate as those features land; they are listed in `PRICING.md` §3–4.

---

## Phase 4 — Paywall UI

### Task 9: Build the reusable `PaywallView`

**Files:** Create `EchoCore/Views/Paywall/PaywallContext.swift`, `EchoCore/Views/Paywall/PaywallView.swift`.

- [ ] **Step 1: Context enum**

```swift
// EchoCore/Views/Paywall/PaywallContext.swift
enum PaywallContext {
    case flashcardCap, narrationCap, transcripts, insights, export, absSync, settings

    var subheadline: String {
        switch self {
        case .flashcardCap: return "You've filled your 20 free cards — Echo Pro makes them unlimited."
        case .narrationCap: return "Free narration covers one chapter per book. Echo Pro unlocks the whole library."
        case .transcripts:  return "Transcript overlays are part of Echo Pro."
        case .insights:     return "Insights are part of Echo Pro."
        case .export:       return "Study export is part of Echo Pro."
        case .absSync:      return "Offline downloads & sync are part of Echo Pro."
        case .settings:     return "Turn listening into learning."
        }
    }
}
```

- [ ] **Step 2: PaywallView** (dynamic `displayPrice`, plan picker, trial copy, restore, Terms/Privacy). Reads `StoreManager` + eligibility:

```swift
// EchoCore/Views/Paywall/PaywallView.swift
import SwiftUI
import StoreKit

struct PaywallView: View {
    let context: PaywallContext
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var trialEligible = false
    @State private var purchasing = false

    private func product(_ id: String) -> Product? { store.products.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Echo Pro — turn listening into learning").font(.title2.bold())
                    Text(context.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    benefits

                    // Plan options — ALWAYS render product.displayPrice (sale-safe), never hardcode.
                    if let yearly = product(ProductIDs.yearly)   { planButton(yearly, badge: "Best value") }
                    if let monthly = product(ProductIDs.monthly) { planButton(monthly) }
                    if let lifetime = product(ProductIDs.lifetime) { planButton(lifetime, oneTime: true) }
                    if FoundersWindow.isOpen, let founders = product(ProductIDs.founders) {
                        planButton(founders, oneTime: true, badge: "Founders — limited time")
                    }

                    if trialEligible { Text("7 days free, then renews. Cancel anytime in Settings.").font(.footnote).foregroundStyle(.secondary) }

                    Button("Restore Purchases") { Task { await store.restorePurchases(); if store.isPro { dismiss() } } }
                        .font(.footnote)

                    HStack(spacing: 16) {
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link("Privacy", destination: URL(string: "https://kinnokilabs.com/apps/echo/privacy")!)
                    }.font(.caption).foregroundStyle(.secondary)

                    Text("Open source — you can build it yourself.").font(.caption2).foregroundStyle(.tertiary)
                    if let err = store.lastStoreError { Text(err).font(.caption).foregroundStyle(.red) }
                }.padding()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                if store.products.isEmpty { await store.requestProducts() }
                trialEligible = await store.isEligibleForFreeTrial()
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("♾️", "Unlimited flashcards with SM-2 spaced repetition")
            label("🗣️", "Unlimited on-device AI narration (coming in 1.0)")
            label("📊", "Insights — listening & study streaks")
            label("📤", "Study export — Markdown, Anki, JSON")
            label("🔗", "AudiobookShelf offline & sync")
            label("🔒", "No account, no servers, no tracking")
        }
    }
    private func label(_ e: String, _ t: String) -> some View {
        HStack(alignment: .top) { Text(e); Text(t) }
    }

    @ViewBuilder
    private func planButton(_ p: Product, oneTime: Bool = false, badge: String? = nil) -> some View {
        Button {
            Task { purchasing = true; defer { purchasing = false }
                if (try? await store.purchase(p)) == true, store.isPro { dismiss() } }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(p.displayName)
                    if let badge { Text(badge).font(.caption2).foregroundStyle(.tint) }
                }
                Spacer()
                Text(oneTime ? "\(p.displayPrice) once" : p.displayPrice).bold()
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(purchasing)
    }
}
```

- [ ] **Step 3: Founders window flag** — create `FoundersWindow` (start simple; a hardcoded end date is fine for v1):

```swift
// EchoCore/Services/Store/FoundersWindow.swift
import Foundation
enum FoundersWindow {
    /// Founders pricing offered until this date (UTC). Adjust at launch.
    static let endsAt = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
    static var isOpen: Bool { Date() < endsAt }
}
```

- [ ] **Step 4: Build & manual test** — present `PaywallView(context:.flashcardCap)` from Task 6; confirm all prices render from `displayPrice`, trial line shows when eligible, buying flips `isPro` and dismisses.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/Paywall/ EchoCore/Services/Store/FoundersWindow.swift
git commit -m "feat(paywall): reusable PaywallView (sub + lifetime + founders, dynamic price, trial, restore)"
```

### Task 10: Replace the Settings entry; retire `ProTranscriptsSettingsView`

**Files:** Modify `SettingsView.swift:96-97,532-627`.

- [ ] **Step 1: Replace the row** (`:96-97`):

```swift
// was: NavigationLink("Pro Transcripts") { ProTranscriptsSettingsView(...) }
@State private var showPaywall = false
...
Button { showPaywall = true } label: {
    HStack { Text("Echo Pro"); Spacer()
        Text(storeManager.isPro ? "Active" : "Upgrade").foregroundStyle(storeManager.isPro ? .green : .secondary) }
}
.sheet(isPresented: $showPaywall) { PaywallView(context: .settings) }
```

- [ ] **Step 2: Delete `ProTranscriptsSettingsView`** (`:532-627`) and its references. Manage-subscription affordance for subscribers: add `.manageSubscriptionsSheet(isPresented:)` (or a `Link` to `https://apps.apple.com/account/subscriptions`) on the new row when `isPro`.

- [ ] **Step 3: Build — confirm SettingsView compiles** (the `hasUnlockedPro` alias from Task 3 covers any stragglers; grep `grep -rn "hasUnlockedPro\|ProTranscriptsSettingsView" EchoCore` should now be empty except the alias).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/SettingsView.swift
git commit -m "feat(paywall): Settings 'Echo Pro' row opens PaywallView; retire Pro Transcripts shell"
```

---

## Phase 5 — Release (non-code)

### Task 11: App Store Connect product setup

- [ ] Create subscription group **`Echo Pro`**; add `com.echo.pro.monthly` ($3.99) + `com.echo.pro.yearly` ($24.99) with localized name/description + a review screenshot each.
- [ ] Add a **7-day free Introductory Offer** to both subscriptions.
- [ ] Set `com.echo.pro.unlock` price to **$49.99**; rename "Echo Pro — Lifetime".
- [ ] Create `com.echo.pro.founders` at **$39.99**.
- [ ] **Family Sharing: ON** for lifetime + founders; **OFF** for the subscriptions (irreversible once ON).
- [ ] App-level **Privacy Policy + Terms (EULA) URLs** set (required for auto-renewable subs).
- [ ] Tax & banking / Paid Apps agreement active.
- [ ] Attach all IAP products to the version being submitted.

### Task 12: Remove the "no subscription" promise (same release the paywall ships)

- [ ] Edit the App Store **description** (`fastlane/metadata/en-US/description.txt`) — remove every "no subscription / no IAP / free" pricing claim; reposition: *"Free, private audiobook player. Echo Pro (subscription or one-time lifetime) unlocks unlimited study tools."* Then `bundle exec fastlane deliver download_metadata` first (sync), edit, `deliver`.
- [ ] Reconcile the same claim on the **website** (`KinNoKiLabsSite/Content/apps/echo.md`, `Echo/docs/index.html` trust strip ~264-283), **README**, and **TestFlight notes**.
- [ ] Confirm AI-narration copy stays **"coming in 1.0"** until the build produces real audio.

---

## Self-Review

**Spec coverage (PRICING.md → task):** Free/Pro matrix → Tasks 6-8; metering (20 cards / 1 chapter) → Tasks 5-7; pricing + dynamic displayPrice → Task 9; StoreKit product model → Tasks 1-4; paywall UX/copy → Tasks 9-10; ASC setup → Task 11; "no subscription" cleanup → Task 12; "Pro Transcripts" fold-in → Task 8/10. ABS free-connect/Pro-offline → Task 8 note. ✅ All sections mapped.

**Type consistency:** `isPro` is the single gate everywhere (StoreManager, `ProEntitlementProviding`, `FreeTierGate`, views); `FreeTierGate.canCreateFlashcards(adding:)` / `canRenderNarration(audiobookID:alreadyRenderedThisChapter:)` used identically in tests + call sites; `ProductIDs.*` used everywhere a literal would drift; `PaywallContext` shared by every present-site. ✅

**Gaps the engineer must resolve at the call site (not placeholders — located, with the guard given):** exact `FlashcardDAO` path/init, the `NarrationService` init injection of `freeTierGate`, and `TranscriptService`'s `isPro` source — each is named with file:line and the guard code; confirm the local signature when wiring.

---

## Execution Handoff

Implement task-by-task with one of:
1. **Subagent-Driven (recommended)** — a fresh subagent per task with two-stage review between tasks (`superpowers:subagent-driven-development`). Best for keeping each StoreKit change isolated + reviewed.
2. **Inline Execution** — batch in this session with checkpoints (`superpowers:executing-plans`).
