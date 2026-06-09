# Accent Contrast Safety Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rescue artwork-derived accent colours that would render player controls illegible (e.g. The Programmer's Brain gold in light mode), while leaving every cover that already works untouched.

**Architecture:** Two new pure value-type modules — `ColorMetrics` (WCAG contrast, ΔE, HSL nudge) and `AccentSafetyNet` (a two-gate trigger + an A→B→C rescue ladder) — feed a single source of truth: `PlayerModel.artworkAccentColor` becomes the *safe* colour, so all ~15 consumers and the Watch hex inherit the fix. One cached extraction pass (`DominantColorExtractor.extractPalette`) supplies both the rescued accent and the background gradient.

**Tech Stack:** Swift, SwiftUI, UIKit (colour bridging only), Swift Testing (`import Testing`), Xcode 16 synchronized folders (new files auto-compile).

**Design spec:** `docs/superpowers/specs/2026-06-09-accent-contrast-safety-design.md`

---

## Conventions for every task

**Test command** (a single suite). Adjust the simulator name if `iPhone 16` is unavailable — list yours with `xcrun simctl list devices available`:

```bash
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:EchoTests/<SuiteName> 2>&1 | xcbeautify || true
```

(If `xcbeautify` isn't installed, drop the pipe — raw `xcodebuild` output is fine.)

**Swift TDD note:** A test that references a not-yet-created type fails by **failing to compile** ("cannot find 'X' in scope"). That is the valid "red" state. Implement the type, then the same run goes green.

**Commits:** Conventional Commits. End every commit with the repo trailer (shown via a second `-m`):
`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

**Branch:** Work on `feat/accent-contrast-safety` (already created; the design spec is its first commit).

---

## File Structure

| File | Responsibility |
|---|---|
| `EchoCore/Utilities/ColorMetrics.swift` *(create)* | Pure colour math: `RGB` value type, WCAG luminance/contrast, CIELAB/ΔE76, HSL conversions, the legibility two-gate, the lightness nudge, and a `Color`↔`RGB` bridge. Tunable constants live here. |
| `EchoCore/Services/AccentSafetyNet.swift` *(create)* | The A→B→C rescue ladder (`resolve`) + surface estimation (`representativeSurface`). Operates on `ColorMetrics.RGB`; no UIKit. |
| `EchoCore/Services/DominantColorExtractor.swift` *(modify)* | Add `ArtworkPalette` + `extractPalette(from:)`; refactor the histogram into one shared `rankedVividColors` pass. |
| `EchoCore/ViewModels/PlayerModel.swift` *(modify)* | Cache `artworkPalette`; add observable `uiColorScheme`; make `artworkAccentColor` the rescued colour (cached by version+scheme, nil-contract preserved); point `artworkAccentColorHex` at the **raw** accent (Watch). |
| `EchoCore/Views/Components/AdaptiveBackground.swift` *(modify)* | Read `model.artworkPalette.background` instead of re-extracting each redraw. |
| `EchoCore/Views/RootTabView.swift` *(modify)* | Feed the live `colorScheme` into `model.uiColorScheme`. |
| `EchoTests/ColorMetricsTests.swift` *(create)* | Unit tests for the metric core. |
| `EchoTests/AccentSafetyNetTests.swift` *(create)* | Behavioural contract for the rescue ladder. |
| `EchoTests/PlayerModelAccentTests.swift` *(create)* | Nil-contract + colour-scheme plumbing. |
| `ARCHITECTURE.md` *(modify)* | Regenerate the tree + add a hand-written "Accent Contrast Safety" subsection. |

---

## Task 1: `ColorMetrics` — RGB, luminance, WCAG contrast

**Files:**
- Create: `EchoCore/Utilities/ColorMetrics.swift`
- Test: `EchoTests/ColorMetricsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ColorMetricsTests.swift`:

```swift
import Testing
import SwiftUI
@testable import Echo

struct ColorMetricsTests {

    /// Build an `RGB` from a 0xRRGGBB literal for readable fixtures.
    private func rgb(_ hex: UInt32) -> ColorMetrics.RGB {
        ColorMetrics.RGB(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    @Test("Black vs white is the maximum 21:1 contrast")
    func blackWhiteContrast() {
        let c = ColorMetrics.contrastRatio(rgb(0x000000), rgb(0xFFFFFF))
        #expect(abs(c - 21.0) < 0.1)
    }

    @Test("Gold on beige reproduces the diagnosed 1.78:1")
    func goldOnBeigeContrast() {
        let c = ColorMetrics.contrastRatio(rgb(0xC9A23C), rgb(0xE9DCC8))
        #expect(abs(c - 1.78) < 0.05)
    }

    @Test("Contrast is symmetric in its arguments")
    func contrastSymmetry() {
        let a = ColorMetrics.contrastRatio(rgb(0xC9A23C), rgb(0xE9DCC8))
        let b = ColorMetrics.contrastRatio(rgb(0xE9DCC8), rgb(0xC9A23C))
        #expect(abs(a - b) < 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests` (see Conventions)
Expected: **FAIL** — build error "cannot find 'ColorMetrics' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `EchoCore/Utilities/ColorMetrics.swift`:

```swift
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pure colour math for the accent contrast safety net.
///
/// The metric core works on `RGB` (sRGB, 0…1 `Double`s) so it is fully
/// unit-testable without UIKit. Only the `Color`↔`RGB` bridge (added later)
/// touches the platform.
enum ColorMetrics {

    /// sRGB triple, components in 0…1.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    // MARK: WCAG relative luminance + contrast

    static func relativeLuminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests`
Expected: **PASS** (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Utilities/ColorMetrics.swift EchoTests/ColorMetricsTests.swift
git commit -m "feat(color): add ColorMetrics WCAG luminance and contrast" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `ColorMetrics` — CIELAB, ΔE76, and the two-gate `isLegible`

**Files:**
- Modify: `EchoCore/Utilities/ColorMetrics.swift`
- Test: `EchoTests/ColorMetricsTests.swift`

- [ ] **Step 1: Add failing tests**

Append inside `ColorMetricsTests`:

```swift
    @Test("ΔE76 is zero for identical colours")
    func deltaEZero() {
        #expect(ColorMetrics.deltaE76(rgb(0x808080), rgb(0x808080)) < 0.0001)
    }

    @Test("Two-gate: vivid orange on peach stays legible (chroma gate saves it)")
    func twoGateSavesVividOrange() {
        // Emotional Design: WCAG ~1.86 (fails) but ΔE ~57 (passes) → legible
        #expect(ColorMetrics.isLegible(rgb(0xE5821C), on: rgb(0xF1CCB5)) == true)
    }

    @Test("Two-gate: muddy gold on beige is flagged (fails both gates)")
    func twoGateFlagsMuddyGold() {
        // Programmer's Brain: WCAG ~1.78 and ΔE ~49 → not legible
        #expect(ColorMetrics.isLegible(rgb(0xC9A23C), on: rgb(0xE9DCC8)) == false)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests`
Expected: **FAIL** — "cannot find 'deltaE76'/'isLegible'".

- [ ] **Step 3: Implement**

Add to `enum ColorMetrics` (after `contrastRatio`):

```swift
    // MARK: Tunable constants
    // Tuned from a 5-cover sample. Bias toward leaving accents untouched;
    // revisit as the library grows.

    /// WCAG ratio that clears the luminance gate on its own.
    static let luminanceGate: Double = 2.4
    /// ΔE76 that clears the chroma gate on its own.
    static let chromaGate: Double = 52.0
    /// Minimum WCAG ratio a rescued accent must reach (UI-control grade).
    static let contrastFloor: Double = 3.0
    /// Largest HSL lightness shift Tier A may apply before escalating to B.
    static let distortionBudget: Double = 0.22

    // MARK: CIELAB + ΔE76

    static func lab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.r), g = lin(c.g), bl = lin(c.b)
        var x = r * 0.4124 + g * 0.3576 + bl * 0.1805
        let y = r * 0.2126 + g * 0.7152 + bl * 0.0722
        var z = r * 0.0193 + g * 0.1192 + bl * 0.9505
        x /= 0.95047
        z /= 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE76(_ a: RGB, _ b: RGB) -> Double {
        let la = lab(a), lb = lab(b)
        let dL = la.L - lb.L
        let dA = la.a - lb.a
        let dB = la.b - lb.b
        return (dL * dL + dA * dA + dB * dB).squareRoot()
    }

    // MARK: Two-gate legibility (the rescue trigger)

    /// An accent is legible if it clears EITHER the luminance gate OR the
    /// chroma gate against `surface`. Failing both = the "invisible" corner.
    static func isLegible(_ accent: RGB, on surface: RGB) -> Bool {
        contrastRatio(accent, surface) >= luminanceGate
            || deltaE76(accent, surface) >= chromaGate
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests`
Expected: **PASS** (6 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Utilities/ColorMetrics.swift EchoTests/ColorMetricsTests.swift
git commit -m "feat(color): add CIELAB ΔE76 and two-gate legibility check" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `ColorMetrics` — HSL conversions + the lightness nudge

**Files:**
- Modify: `EchoCore/Utilities/ColorMetrics.swift`
- Test: `EchoTests/ColorMetricsTests.swift`

- [ ] **Step 1: Add failing tests**

Append inside `ColorMetricsTests`:

```swift
    @Test("Nudge darkens a light-surface accent until it clears the floor")
    func nudgeDarkensOnLightSurface() {
        let surface = rgb(0xE9DCC8)
        let out = ColorMetrics.nudged(rgb(0xC9A23C), toClear: ColorMetrics.contrastFloor, against: surface)
        #expect(ColorMetrics.contrastRatio(out.color, surface) >= ColorMetrics.contrastFloor)
        #expect(out.color.r < rgb(0xC9A23C).r)      // moved darker
        #expect(out.lightnessShift > 0)
    }

    @Test("Nudge lightens an accent on a dark surface")
    func nudgeLightensOnDarkSurface() {
        let surface = rgb(0x1C1A16)
        let out = ColorMetrics.nudged(rgb(0x232018), toClear: ColorMetrics.contrastFloor, against: surface)
        #expect(ColorMetrics.contrastRatio(out.color, surface) >= ColorMetrics.contrastFloor)
        #expect(out.color.r > rgb(0x232018).r)      // moved lighter
    }

    @Test("Nudge is a no-op when already above the floor")
    func nudgeNoopWhenLegible() {
        let surface = rgb(0xE9DCC8)
        let out = ColorMetrics.nudged(rgb(0x34459B), toClear: ColorMetrics.contrastFloor, against: surface)
        #expect(out.lightnessShift == 0)
        #expect(out.color == rgb(0x34459B))
    }

    @Test("RGB↔Color bridge round-trips within tolerance")
    func colorBridgeRoundTrips() {
        let original = rgb(0xC9A23C)
        let back = ColorMetrics.rgb(ColorMetrics.color(original))
        #expect(abs(back.r - original.r) < 0.02)
        #expect(abs(back.g - original.g) < 0.02)
        #expect(abs(back.b - original.b) < 0.02)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests`
Expected: **FAIL** — "cannot find 'nudged'/'color'/'rgb'".

- [ ] **Step 3: Implement**

Add to `enum ColorMetrics` (after `isLegible`):

```swift
    // MARK: HSL conversions

    static func toHSL(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = max(c.r, max(c.g, c.b))
        let mn = min(c.r, min(c.g, c.b))
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0.0001 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == c.r { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    static func fromHSL(h: Double, s: Double, l: Double) -> RGB {
        guard s > 0.0001 else { return RGB(r: l, g: l, b: l) }
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return RGB(r: hue2rgb(p, q, h + 1.0 / 3),
                   g: hue2rgb(p, q, h),
                   b: hue2rgb(p, q, h - 1.0 / 3))
    }

    // MARK: Lightness nudge

    /// Moves lightness (hue + saturation fixed) until `floor` contrast is met
    /// against `surface`, or a bound is hit. Darkens on a light surface,
    /// lightens on a dark one. Returns the result and the |Δlightness| moved.
    static func nudged(_ color: RGB,
                       toClear floor: Double,
                       against surface: RGB) -> (color: RGB, lightnessShift: Double) {
        if contrastRatio(color, surface) >= floor { return (color, 0) }
        let hsl = toHSL(color)
        let step = relativeLuminance(surface) > 0.5 ? -0.02 : 0.02   // darken on light
        var l = hsl.l
        var guardCount = 0
        while guardCount < 60 {
            l = min(max(l + step, 0), 1)
            let candidate = fromHSL(h: hsl.h, s: hsl.s, l: l)
            if contrastRatio(candidate, surface) >= floor {
                return (candidate, abs(hsl.l - l))
            }
            if l == 0 || l == 1 { break }     // hit the bound
            guardCount += 1
        }
        let boundL: Double = step < 0 ? 0 : 1
        return (fromHSL(h: hsl.h, s: hsl.s, l: boundL), abs(hsl.l - boundL))
    }

    // MARK: Color bridge (the only platform-touching part)

    #if canImport(UIKit)
    static func rgb(_ color: Color) -> RGB {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: Double(r), g: Double(g), b: Double(b))
    }

    static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }
    #endif
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test ... -only-testing:EchoTests/ColorMetricsTests`
Expected: **PASS** (10 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Utilities/ColorMetrics.swift EchoTests/ColorMetricsTests.swift
git commit -m "feat(color): add HSL nudge and Color bridge to ColorMetrics" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `AccentSafetyNet` — the A→B→C ladder + surface estimate

**Files:**
- Create: `EchoCore/Services/AccentSafetyNet.swift`
- Test: `EchoTests/AccentSafetyNetTests.swift`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AccentSafetyNetTests.swift`:

```swift
import Testing
import SwiftUI
@testable import Echo

struct AccentSafetyNetTests {

    private func rgb(_ hex: UInt32) -> ColorMetrics.RGB {
        ColorMetrics.RGB(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    @Test("Legible accent passes through untouched (no over-correction)")
    func legiblePassesThrough() {
        // Emotional Design orange on peach — saved by the chroma gate.
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xE5821C),
                                        candidates: [],
                                        surface: rgb(0xF1CCB5),
                                        brand: rgb(0xF0982C))
        #expect(r.tier == .original)
        #expect(r.color == rgb(0xE5821C))
    }

    @Test("Muddy gold is nudged in place (Tier A)")
    func muddyGoldNudged() {
        let surface = rgb(0xE9DCC8)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xC9A23C),
                                        candidates: [rgb(0xC9A23C)],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        #expect(r.tier == .nudged)
        #expect(ColorMetrics.contrastRatio(r.color, surface) >= ColorMetrics.contrastFloor)
    }

    @Test("Un-nudgeable winner escalates to a safe cover hue (Tier B)")
    func escalatesToRepick() {
        let surface = rgb(0xE9DCC8)
        // Near-white winner needs a huge shift (> budget); navy candidate is already safe.
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xF0EAD8),
                                        candidates: [rgb(0xF0EAD8), rgb(0x34459B)],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        #expect(r.tier == .repicked)
        #expect(r.color == rgb(0x34459B))
    }

    @Test("No usable cover hue falls back to the nudged brand (Tier C)")
    func fallsBackToBrand() {
        let surface = rgb(0xE9DCC8)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xF0EAD8),
                                        candidates: [],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        #expect(r.tier == .brand)
        #expect(ColorMetrics.contrastRatio(r.color, surface) >= ColorMetrics.contrastFloor)
    }

    @Test("Dark scheme leaves a light accent alone")
    func darkSchemeLeavesLightAccentAlone() {
        let surface = AccentSafetyNet.representativeSurface(background: [rgb(0xC9A23C)], scheme: .dark)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xC9A23C),
                                        candidates: [],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        #expect(r.tier == .original)
    }

    @Test("Light-scheme surface estimate stays light")
    func lightSurfaceEstimateIsLight() {
        let surface = AccentSafetyNet.representativeSurface(background: [rgb(0xC9A23C)], scheme: .light)
        #expect(ColorMetrics.relativeLuminance(surface) > 0.5)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:EchoTests/AccentSafetyNetTests`
Expected: **FAIL** — "cannot find 'AccentSafetyNet'".

- [ ] **Step 3: Implement**

Create `EchoCore/Services/AccentSafetyNet.swift`:

```swift
import SwiftUI

/// Rescues an artwork-derived accent that would be illegible against the
/// player surface, using a progressive A→B→C ladder. Operates entirely on
/// `ColorMetrics.RGB` so it is pure and unit-testable.
enum AccentSafetyNet {

    /// Which rung of the ladder produced the result (for debug + tests).
    enum Tier: Equatable { case original, nudged, repicked, brand }

    struct Resolution: Equatable {
        let color: ColorMetrics.RGB
        let tier: Tier
    }

    /// Two stacked `.ultraThinMaterial` layers pull the surface strongly
    /// toward the scheme base; only a faint artwork tint survives.
    static let materialWeight: Double = 0.70

    static func resolve(rawAccent: ColorMetrics.RGB,
                        candidates: [ColorMetrics.RGB],
                        surface: ColorMetrics.RGB,
                        brand: ColorMetrics.RGB) -> Resolution {
        // Gate — most covers exit here, byte-for-byte unchanged.
        if ColorMetrics.isLegible(rawAccent, on: surface) {
            return Resolution(color: rawAccent, tier: .original)
        }

        // Tier A — nudge the winner in place.
        let a = ColorMetrics.nudged(rawAccent, toClear: ColorMetrics.contrastFloor, against: surface)
        if a.lightnessShift <= ColorMetrics.distortionBudget {
            return Resolution(color: a.color, tier: .nudged)
        }

        // Tier B — fall to the next cover hue that's already (or nearly) safe.
        for candidate in candidates where candidate != rawAccent {
            if ColorMetrics.isLegible(candidate, on: surface) {
                return Resolution(color: candidate, tier: .repicked)
            }
            let b = ColorMetrics.nudged(candidate, toClear: ColorMetrics.contrastFloor, against: surface)
            if b.lightnessShift <= ColorMetrics.distortionBudget {
                return Resolution(color: b.color, tier: .repicked)
            }
        }

        // Tier C — brand tint, nudged to clear the floor. Always legible.
        let c = ColorMetrics.nudged(brand, toClear: ColorMetrics.contrastFloor, against: surface)
        return Resolution(color: c.color, tier: .brand)
    }

    /// Estimated colour behind the controls: the cover's average background
    /// colour blended toward the scheme base by `materialWeight`.
    static func representativeSurface(background: [ColorMetrics.RGB],
                                      scheme: ColorScheme) -> ColorMetrics.RGB {
        let base: ColorMetrics.RGB = scheme == .dark
            ? ColorMetrics.RGB(r: 0.11, g: 0.11, b: 0.12)   // ≈ systemBackground (dark)
            : ColorMetrics.RGB(r: 0.95, g: 0.95, b: 0.94)   // ≈ systemBackground (light)
        guard !background.isEmpty else { return base }
        let n = Double(background.count)
        let avg = ColorMetrics.RGB(
            r: background.map(\.r).reduce(0, +) / n,
            g: background.map(\.g).reduce(0, +) / n,
            b: background.map(\.b).reduce(0, +) / n
        )
        let w = materialWeight
        return ColorMetrics.RGB(
            r: avg.r * (1 - w) + base.r * w,
            g: avg.g * (1 - w) + base.g * w,
            b: avg.b * (1 - w) + base.b * w
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test ... -only-testing:EchoTests/AccentSafetyNetTests`
Expected: **PASS** (6 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/AccentSafetyNet.swift EchoTests/AccentSafetyNetTests.swift
git commit -m "feat(color): add AccentSafetyNet A→B→C rescue ladder" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `DominantColorExtractor` — `extractPalette` (one cached pass)

**Files:**
- Modify: `EchoCore/Services/DominantColorExtractor.swift`
- Test: `EchoTests/ColorMetricsTests.swift` (extractor fixtures live alongside; or a new `DominantColorExtractorTests.swift`)

> **Why:** `extract` and `extractColors` each scan pixels separately, and Tier B needs ranked candidates. Refactor the histogram into one `rankedVividColors` pass and expose `extractPalette` returning `{ rawAccent, candidates, background }`. `rankedVividColors` returns **only real vivid colours** (no default/padding), so an empty result cleanly means "no vivid colour" → `rawAccent == nil`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/DominantColorExtractorTests.swift`:

```swift
import Testing
import SwiftUI
import UIKit
@testable import Echo

struct DominantColorExtractorTests {

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 16, height: 16)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("Vivid cover yields a non-nil accent and a 3-colour background")
    func vividCoverHasAccent() {
        let palette = DominantColorExtractor.extractPalette(from: solidImage(.systemRed))
        #expect(palette.rawAccent != nil)
        #expect(palette.background.count == 3)
        #expect(!palette.candidates.isEmpty)
    }

    @Test("Greyscale cover yields a nil accent (nil-contract source)")
    func greyscaleCoverHasNoAccent() {
        let palette = DominantColorExtractor.extractPalette(from: solidImage(.gray))
        #expect(palette.rawAccent == nil)
        #expect(palette.candidates.isEmpty)
    }

    @Test("extractColors still returns the requested count")
    func extractColorsCountUnchanged() {
        let colors = DominantColorExtractor.extractColors(from: solidImage(.systemBlue), count: 3)
        #expect(colors.count == 3)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:EchoTests/DominantColorExtractorTests`
Expected: **FAIL** — "cannot find 'extractPalette'" / "ArtworkPalette".

- [ ] **Step 3: Implement**

In `EchoCore/Services/DominantColorExtractor.swift`, add the palette type and a shared ranked-colours pass, and route the existing entry points through it.

Add near the top of the `enum DominantColorExtractor` body:

```swift
    /// Result of a single extraction pass.
    struct ArtworkPalette {
        let rawAccent: Color?      // most vivid hue, or nil if none
        let candidates: [Color]    // all vivid hues, ranked (may be empty)
        let background: [Color]    // 3 colours for the gradient (defaults if no vivid)
    }

    private static let backgroundDefaults: [Color] = [.blue, .purple, .indigo]

    /// Single downsample + histogram pass shared by every public entry point.
    static func extractPalette(from image: UIImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage,
              let pixelData = downsampleAndRead(cgImage) else {
            return ArtworkPalette(rawAccent: nil, candidates: [], background: backgroundDefaults)
        }
        let vivid = rankedVividColors(pixelData: pixelData)
        let background = vivid.isEmpty ? backgroundDefaults : pad(vivid, to: 3)
        return ArtworkPalette(rawAccent: vivid.first, candidates: vivid, background: background)
    }

    /// Pads `colors` up to `count` by repeating the dominant one.
    private static func pad(_ colors: [Color], to count: Int) -> [Color] {
        guard let first = colors.first else { return [] }
        var out = colors
        while out.count < count { out.append(first) }
        return Array(out.prefix(count))
    }
```

Add `rankedVividColors` — the histogram loop from `analyseMultiple`, but returning **only** genuine vivid colours (no defaults, no padding):

```swift
    /// Returns the vivid colours found in `pixelData`, ranked by weight.
    /// Empty when the artwork has no colour vivid enough to serve as a tint.
    private static func rankedVividColors(pixelData: [UInt8]) -> [Color] {
        var histogram = [BucketStats](repeating: BucketStats(), count: hueBuckets)
        let centre = sampleSize / 2
        let maxDistance = Float(sqrt(Double(centre * centre + centre * centre)))

        let pixelCount = sampleSize * sampleSize
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(pixelData[offset])     / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0
            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            guard l > minLightness && l < maxLightness else { continue }
            guard s > minSaturation else { continue }
            let saturationWeight = s * s
            let x = Float(i % sampleSize)
            let y = Float(i / sampleSize)
            let dx = x - Float(centre)
            let dy = y - Float(centre)
            let distance = sqrt(dx * dx + dy * dy)
            let centreWeight = 1.0 - (distance / maxDistance) * 0.4
            let weight = saturationWeight * centreWeight
            let bucket = min(Int(h * Float(hueBuckets)), hueBuckets - 1)
            histogram[bucket].weight += weight
            histogram[bucket].saturationSum += s * weight
            histogram[bucket].lightnessSum += l * weight
        }

        let sorted = histogram.enumerated()
            .filter { $0.element.weight > 0 }
            .sorted { $0.element.weight > $1.element.weight }

        return sorted.map { entry in
            let stats = entry.element
            let avgSaturation = stats.saturationSum / stats.weight
            let avgLightness = stats.lightnessSum / stats.weight
            let finalS = max(avgSaturation, saturationFloor)
            let finalL = min(max(avgLightness, lightnessTargetMin), lightnessTargetMax)
            let finalH = Float(entry.offset) / Float(hueBuckets)
            let (cr, cg, cb) = hslToRGB(h: finalH, s: finalS, l: finalL)
            return Color(red: Double(cr), green: Double(cg), blue: Double(cb))
        }
    }
```

Now route the existing public methods through it. Replace the body of `extract(from:)` with:

```swift
    static func extract(from image: UIImage) -> Color? {
        extractPalette(from: image).rawAccent
    }
```

Replace the body of `extractColors(from:count:)` with:

```swift
    static func extractColors(from image: UIImage, count: Int = 3) -> [Color] {
        guard let cgImage = image.cgImage,
              let pixelData = downsampleAndRead(cgImage) else {
            return backgroundDefaults
        }
        let vivid = rankedVividColors(pixelData: pixelData)
        return vivid.isEmpty ? backgroundDefaults : pad(vivid, to: count)
    }
```

Then **delete** the now-unused private `analyse(pixelData:)` and `analyseMultiple(pixelData:count:)` methods (their logic now lives in `rankedVividColors`). Keep `BucketStats`, `downsampleAndRead`, `rgbToHSL`, `hslToRGB`.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test ... -only-testing:EchoTests/DominantColorExtractorTests`
Expected: **PASS** (3 tests). Also re-run `EchoTests/NowPlayingLayoutTests` to confirm no regression in source-shape assertions:
Run: `xcodebuild test ... -only-testing:EchoTests/NowPlayingLayoutTests` → **PASS**.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/DominantColorExtractor.swift EchoTests/DominantColorExtractorTests.swift
git commit -m "refactor(color): add extractPalette and share one histogram pass" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: `PlayerModel` — cached palette, colour scheme, safe accent, raw hex

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (the accent section is around lines 192–229)
- Test: `EchoTests/PlayerModelAccentTests.swift`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/PlayerModelAccentTests.swift`:

```swift
import Testing
import SwiftUI
@testable import Echo

@MainActor
struct PlayerModelAccentTests {

    @Test("No artwork → accent is nil (nil-contract preserved)")
    func nilWithoutArtwork() {
        let model = PlayerModel()
        #expect(model.artworkAccentColor == nil)
        #expect(model.artworkAccentColorHex == nil)
    }

    @Test("uiColorScheme defaults to light and is settable")
    func colorSchemePlumbing() {
        let model = PlayerModel()
        #expect(model.uiColorScheme == .light)
        model.uiColorScheme = .dark
        #expect(model.uiColorScheme == .dark)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:EchoTests/PlayerModelAccentTests`
Expected: **FAIL** — "value of type 'PlayerModel' has no member 'uiColorScheme'".

- [ ] **Step 3: Implement**

Ensure `import SwiftUI` is present at the top of `PlayerModel.swift` (it is — the file vends `Color`).

Replace the entire "Dynamic accent colour from artwork" section (the `cachedArtworkAccent` fields plus `artworkAccentColor` and `artworkAccentColorHex`, ~lines 192–229) with:

```swift
    // MARK: - Dynamic accent colour from artwork

    /// Current UI colour scheme, fed from `RootTabView`. Drives surface-aware
    /// contrast so the rescued accent recomputes on light/dark switches.
    var uiColorScheme: ColorScheme = .light

    @ObservationIgnored private var cachedPalette: DominantColorExtractor.ArtworkPalette?
    @ObservationIgnored private var cachedPaletteVersion: Int = -1

    @ObservationIgnored private var cachedSafeAccent: Color?
    @ObservationIgnored private var cachedSafeAccentVersion: Int = -1
    @ObservationIgnored private var cachedSafeAccentScheme: ColorScheme = .light

    /// One cached extraction pass for the current cover (or thumbnail).
    var artworkPalette: DominantColorExtractor.ArtworkPalette {
        let version = currentDisplayArtworkVersion
        if version != cachedPaletteVersion || cachedPalette == nil {
            if let image = currentDisplayArtwork ?? thumbnailImage {
                cachedPalette = DominantColorExtractor.extractPalette(from: image)
            } else {
                cachedPalette = DominantColorExtractor.ArtworkPalette(
                    rawAccent: nil, candidates: [], background: []
                )
            }
            cachedPaletteVersion = version
        }
        return cachedPalette!
    }

    /// The contrast-safe accent for the current cover and colour scheme, or
    /// `nil` when the cover has no vivid colour (greyscale / no image).
    var artworkAccentColor: Color? {
        let palette = artworkPalette
        guard let raw = palette.rawAccent else { return nil }   // nil-contract

        let version = currentDisplayArtworkVersion
        if version == cachedSafeAccentVersion,
           uiColorScheme == cachedSafeAccentScheme,
           let cached = cachedSafeAccent {
            return cached
        }

        let surface = AccentSafetyNet.representativeSurface(
            background: palette.background.map(ColorMetrics.rgb),
            scheme: uiColorScheme
        )
        let resolution = AccentSafetyNet.resolve(
            rawAccent: ColorMetrics.rgb(raw),
            candidates: palette.candidates.map(ColorMetrics.rgb),
            surface: surface,
            brand: ColorMetrics.rgb(Color.accentColor)
        )
        let safe = ColorMetrics.color(resolution.color)
        cachedSafeAccent = safe
        cachedSafeAccentVersion = version
        cachedSafeAccentScheme = uiColorScheme
        return safe
    }

    /// RAW (un-rescued) accent hex for the Watch, whose surface is always dark.
    var artworkAccentColorHex: String? {
        guard let color = artworkPalette.rawAccent else { return nil }
        let uiColor = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let r = Int(round(red * 255.0))
            let g = Int(round(green * 255.0))
            let b = Int(round(blue * 255.0))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return nil
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test ... -only-testing:EchoTests/PlayerModelAccentTests`
Expected: **PASS** (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoTests/PlayerModelAccentTests.swift
git commit -m "feat(player): make artworkAccentColor contrast-safe at the source" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Wire the surface — `AdaptiveBackground` + `RootTabView`

**Files:**
- Modify: `EchoCore/Views/Components/AdaptiveBackground.swift`
- Modify: `EchoCore/Views/RootTabView.swift`

> No unit test — this is SwiftUI wiring, verified by build + the manual check in Task 9. (Avoid brittle snapshot mocking for a two-line binding.)

- [ ] **Step 1: Point `AdaptiveBackground` at the cached palette**

Replace the `colors` computation in `AdaptiveBackground.body` (lines ~7–16) with:

```swift
        let background = model.artworkPalette.background
        let colors: [Color] = background.isEmpty
            ? [Color.blue.opacity(0.2), Color.purple.opacity(0.2), Color.indigo.opacity(0.2)]
            : background
```

Leave the rest of the view (the `ZStack`, gradients, blur, material) unchanged. `background` is either empty (no artwork → pastel fallback) or exactly 3 colours, so the existing `colors[0]`, `colors[1]`, `colors[2]` accesses remain safe.

- [ ] **Step 2: Feed `colorScheme` into the model from `RootTabView`**

In `EchoCore/Views/RootTabView.swift`, add the environment read near the other `@Environment` / `@State` properties:

```swift
    @Environment(\.colorScheme) private var colorScheme
```

Then attach this modifier to the outermost view in `body` (the `NavigationStack { … }`), e.g. directly after it:

```swift
        .onChange(of: colorScheme, initial: true) { _, newScheme in
            model.uiColorScheme = newScheme
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build \
  -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/Components/AdaptiveBackground.swift EchoCore/Views/RootTabView.swift
git commit -m "feat(player): feed colour scheme and cached palette into the UI" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Full test pass

**Files:** none (verification)

- [ ] **Step 1: Run the entire EchoTests suite**

Run:
```bash
xcodebuild test \
  -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:EchoTests 2>&1 | xcbeautify || true
```
Expected: all suites **PASS**, including the new `ColorMetricsTests`, `AccentSafetyNetTests`, `DominantColorExtractorTests`, `PlayerModelAccentTests`, and the pre-existing tests.

- [ ] **Step 2: If anything fails, fix before continuing.** Do not proceed to docs/manual verification with red tests.

---

## Task 9: Documentation + manual device verification

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Regenerate the auto-generated source tree**

The new files must appear in the tree; content below `<!-- MANUAL BELOW -->` is preserved.

Run:
```bash
make architecture
```
Expected: ARCHITECTURE.md's tree now lists `Services/AccentSafetyNet.swift` and `Utilities/ColorMetrics.swift`.

- [ ] **Step 2: Add the hand-written subsection**

In `ARCHITECTURE.md`, **below** the `<!-- MANUAL BELOW -->` marker (after the existing "Tools & Pipeline" section), add:

```markdown
## UI Theming

### Accent Contrast Safety

Artwork-derived accent colours are made legible against the player surface by a
two-stage pipeline, fixed at the source so all consumers inherit it:

1. **One extraction pass:** `DominantColorExtractor.extractPalette(from:)` returns
   `{ rawAccent, candidates, background }` from a single downsampled histogram
   scan (shared by `extract`, `extractColors`, and the background gradient).
2. **Two-gate trigger:** `ColorMetrics.isLegible(_:on:)` flags an accent only
   when it fails **both** a WCAG luminance gate (`luminanceGate`) **and** a
   CIELAB ΔE chroma gate (`chromaGate`) against the estimated surface. Covers
   that clear either gate are left untouched.
3. **A→B→C rescue:** `AccentSafetyNet.resolve(...)` escalates progressively —
   **A** nudge the winning hue's lightness to `contrastFloor` (within
   `distortionBudget`), **B** re-pick the next safe cover hue, **C** fall back to
   the nudged brand tint. Returns a `Tier` for debug/telemetry, mirroring the
   `AutoAlignmentService` progressive-tier convention.

`PlayerModel.artworkAccentColor` is the single source of truth (the rescued
colour, cached by artwork version + `uiColorScheme`, which `RootTabView` feeds
in). `artworkAccentColorHex` stays **raw** for the Watch, whose surface is
always dark.

**Key types:**

- `ColorMetrics` — Pure colour math: `RGB` value type, WCAG luminance/contrast,
  CIELAB ΔE76, HSL conversions, the `isLegible` two-gate, and the `nudged`
  lightness adjustment. Tunable constants (`luminanceGate`, `chromaGate`,
  `contrastFloor`, `distortionBudget`) tuned from a 5-cover sample.
- `AccentSafetyNet` — The A→B→C rescue ladder (`resolve`) plus
  `representativeSurface(background:scheme:)`, which blends the cover's average
  background colour toward the scheme base by `materialWeight`.
- `DominantColorExtractor.ArtworkPalette` — `{ rawAccent, candidates, background }`
  from one extraction pass.
```

- [ ] **Step 3: Commit the docs**

```bash
git add ARCHITECTURE.md
git commit -m "docs(architecture): document accent contrast safety pipeline" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Manual device/simulator verification**

Build and run the **Echo** app. With a light appearance set on the device:

1. Load **The Programmer's Brain** (navy/white/gold cover). Confirm the transport
   controls, scrubber, and toolbar icons are now clearly legible (a deeper
   antique-gold), not washed-out.
2. Switch the device to **Dark Mode** while on the player. Confirm the accent
   returns to the vivid gold (the rescue should disengage).
3. Load a cover that already worked — e.g. **The Clean Coder** (blue) or
   **Emotional Design** (orange). Confirm its accent is **unchanged** in light
   mode (no over-correction).
4. Load a book with **no cover / greyscale cover**. Confirm controls fall back to
   the app accent and nothing crashes.

Expected: case 1 fixed, cases 2–4 unchanged from prior behaviour.

---

## Self-Review

**Spec coverage:**
- Two-gate trigger → Task 2 (`isLegible`) + tests. ✓
- A→B→C ladder → Task 4 (`resolve`) + tests. ✓
- Nudge primitive → Task 3 (`nudged`). ✓
- Surface estimate → Task 4 (`representativeSurface`). ✓
- Single cached extraction / `extractPalette` → Task 5. ✓
- Source-of-truth safe `artworkAccentColor`, cached by version+scheme, nil-contract, raw Watch hex → Task 6. ✓
- `AdaptiveBackground` dedupe + `RootTabView` scheme feed → Task 7. ✓
- Thresholds as named constants → Task 2 (constants block). ✓
- Tests (ColorMetrics, AccentSafetyNet, extractor, PlayerModel) → Tasks 1–6. ✓
- Docs (ARCHITECTURE.md regenerate + manual subsection) → Task 9. ✓

**Placeholder scan:** No TODO/TBD; every code step shows complete code; every command shows expected output. ✓

**Type consistency:** `ColorMetrics.RGB`, `ColorMetrics.{relativeLuminance,contrastRatio,lab,deltaE76,isLegible,toHSL,fromHSL,nudged,rgb,color}`, `ColorMetrics.{luminanceGate,chromaGate,contrastFloor,distortionBudget}`, `AccentSafetyNet.{Tier,Resolution,resolve,representativeSurface,materialWeight}`, `DominantColorExtractor.{ArtworkPalette,extractPalette,rankedVividColors,pad,backgroundDefaults}`, `PlayerModel.{uiColorScheme,artworkPalette,artworkAccentColor,artworkAccentColorHex}` — names are consistent across all tasks. ✓
