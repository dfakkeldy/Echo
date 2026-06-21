# Now Playing — Sleep-Timer Tint Fix (+ bottom-toolbar finding) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

> **Status:** PLAN ONLY — no code changed in the introducing PR.

**Goal:** Make the top-of-player sleep-timer icon use the cover-derived accent color like its sibling buttons. Document that the bottom toolbar's "grey" is intentional, not a bug.

**Architecture:** Echo derives a per-cover accent (`PlayerModel.artworkAccentColor`, from `CoverThemeBuilder`) and every player button applies it locally with `.foregroundStyle(model.artworkAccentColor ?? .accentColor)`. The sleep-timer pill's **inactive** branch hardcodes `.secondary` instead. One-line fix, iOS-only.

**Tech Stack:** SwiftUI, OKLCH cover-theme builder, Swift Testing.

## Root cause (verified)

- **Source of truth:** `PlayerModel.artworkAccentColor: Color?` → `coverTheme.accent`, `nil` on neutral covers so callers' `?? .accentColor` engages ([PlayerModel.swift:307-310](EchoCore/ViewModels/PlayerModel.swift)). Built by `CoverThemeBuilder.resolve(...)` ([CoverThemeBuilder.swift:83](EchoCore/Services/CoverThemeBuilder.swift)).
- **The idiom working buttons use:** `.foregroundStyle(model.artworkAccentColor ?? .accentColor)` — folder chip ([UnifiedTopHeader.swift:53](EchoCore/Views/Components/UnifiedTopHeader.swift)), ellipsis chip (`:94`), transport ([TransportControlsView.swift:79,100]), scrubber, play button. There is **no** environment-propagated tint for player chrome; each button re-applies the accent itself.
- **The bug:** the sleep-timer pill has two branches. **Active** (timer armed) correctly uses the accent ([SleepTimerPill.swift:42](EchoCore/Views/Components/SleepTimerPill.swift)). **Inactive** (no timer — the usual state) hardcodes `.foregroundStyle(.secondary)` ([SleepTimerPill.swift:44-48](EchoCore/Views/Components/SleepTimerPill.swift)) — the only Row-1 control that reads grey while its neighbors read the cover color.
- **Bottom toolbar — NOT a bug (user's point 2 refuted):** dock + toolbar *are* wired to the accent, but gated on each item's **active** state; inactive items are `.secondary` by a deliberate "Audit B2: active state is carried by a filled chip (shape), not color alone" decision ([BottomToolbarView.swift:54-86](EchoCore/Views/BottomToolbarView.swift); dock wash [UnifiedBottomDock.swift:99]). Mark-passage and Add-bookmark never tint by design; Speed/Timeline tint only when active. The grey the user noticed is the inactive state, intentional.
- **Contrast is safe:** `CoverThemeBuilder` floors the accent at ≥3:1 vs backgrounds / ≥2.5:1 vs chip ([CoverThemeBuilder.swift:62-65, 177-218]); the folder/ellipsis chips already use the identical accent over the identical background, so tinting the moon glyph cannot make it invisible. It's a *stronger* contrast guarantee than the current `.secondary`.

## Decisions made while you slept (override freely)

- **Apply the one-line fix:** change `SleepTimerPill.swift:48` from `.foregroundStyle(.secondary)` to `.foregroundStyle(model.artworkAccentColor ?? Color.accentColor)`, matching the active branch (`:42`) and the sibling chips. The armed/disarmed distinction is still carried by shape (bare glyph vs filled chip + countdown) and glyph (`moon.zzz` vs `moon.zzz.fill`), so tinting the inactive glyph doesn't erase state.
- **Do NOT retint inactive bottom-toolbar items.** That's a documented design choice; flag it to Dan rather than silently overriding it.
- **iOS-only.** macOS sleep timer is a native menu row inside `MacPlayerMoreMenu` ([MacPlayerMoreMenu.swift:105-120](Echo macOS/Views/MacPlayerMoreMenu.swift)) — no standalone chrome button; keeping it native is correct. Watch uses its own palette/hex (`artworkAccentColorHex`) — no change.
- **(Optional) DRY helper:** the `artworkAccentColor ?? .accentColor` literal repeats ~15×; a `PlayerModel.chromeAccent` computed property would centralize it. Refactor, not part of the bugfix — defer unless you want it.

## Open questions for Dan
1. **Bottom toolbar:** leave inactive chips `.secondary` (recommended — deliberate "shape not color"), or give inactive chips a muted cover tint? You *thought* it was a bug; it currently isn't.
2. **Pill state distinction:** after the fix, inactive + active are both cover-tinted (differing by shape/glyph). OK, or keep inactive slightly de-emphasized (e.g. `.opacity(0.7)`)?
3. **macOS/watch:** confirm you do NOT want the macOS More-menu sleep row or the watch control tinted (keeping them native is the recommended default).

## Global Constraints
- Branch target **`nightly`**. iOS-only change; no macOS/watch parity edit needed (documented why).
- Color rendering can't be unit-tested in SwiftUI — rely on the existing `CoverThemeBuilderTests` (sweeps hues for contrast) and a `PlayerModel.artworkAccentColor` nil-contract test; final check is on-device/visual.
- Tests via `make build-tests` + `make test-only FILTER=…`.

## File Structure
- `EchoCore/Views/Components/SleepTimerPill.swift:48` — **modify**: the one-line tint fix.
- `EchoTests/` — confirm/add a `PlayerModel.artworkAccentColor` nil-fallback test (protects the `?? .accentColor` path).

---

### Task 1: Tint the inactive sleep-timer glyph

**Files:**
- Modify: `EchoCore/Views/Components/SleepTimerPill.swift:48`.
- Test: `EchoTests/` — `artworkAccentColor` nil contract (if not already covered).

**Interfaces:**
- Consumes: `model.artworkAccentColor` (already in the view's environment via `@Environment(PlayerModel.self)`).
- Produces: inactive moon glyph tinted with the cover accent (fallback `.accentColor`).

- [ ] **Step 1: Logic guard test (the testable part).** Assert `PlayerModel.artworkAccentColor == nil` for a neutral cover (so the `?? .accentColor` fallback is exercised) and non-nil for a vivid cover. Add to the relevant `PlayerModel`/cover-theme test if not present:

```swift
@Test func neutralCoverYieldsNilAccentSoFallbackEngages() {
    let model = PlayerModel(/* neutral/greyscale cover fixture */)
    #expect(model.artworkAccentColor == nil)   // callers fall back to .accentColor
}
```

- [ ] **Step 2:** Run → should pass (documents the contract the fix relies on). If no such test exists, this adds coverage.
- [ ] **Step 3: Apply the one-line fix** at `SleepTimerPill.swift:48`:

```swift
// inactive branch (no timer armed)
Image(systemName: "moon.zzz")
    .font(.body.bold())
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())
    .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)  // was: .secondary
```

- [ ] **Step 4:** `make test` — ensure nothing regressed (this is a pure view-modifier change; existing `CoverThemeBuilderTests` continue to prove contrast).
- [ ] **Step 5: On-device/visual check (Dan):** open Now Playing with a vividly-colored cover and no sleep timer armed → the moon glyph now matches the folder/ellipsis chip color; arm a timer → the active chip is unchanged.
- [ ] **Step 6: Commit:**

```bash
git add EchoCore/Views/Components/SleepTimerPill.swift
git commit -m "fix(player): tint the inactive sleep-timer icon with the cover accent"
```

### Task 2 (optional): DRY the chrome-accent literal
- Add `var chromeAccent: Color { artworkAccentColor ?? .accentColor }` to `PlayerModel`; replace the ~15 repeated `artworkAccentColor ?? .accentColor` call sites. Pure refactor — only if Dan wants it; do as a separate commit so the bugfix stays minimal.

---

## Self-review notes
- **Spec coverage:** sleep-timer icon not tinted → Task 1 (the real bug). Bottom toolbar → investigated and **refuted** as a bug (documented as deliberate design + an Open Question), so no code change there unless Dan decides otherwise.
- **No placeholders:** exact line (`SleepTimerPill.swift:48`), exact before/after, contrast guarantee cited.
- **Risk:** minimal — one foregroundStyle change; contrast is already guaranteed by `CoverThemeBuilder` and proven by the sibling chips using the same color over the same background.
- **Cross-platform:** iOS-only by design; macOS sleep row is a native menu, watch uses its own palette — both intentionally unchanged.
