# Cover Tonal Themes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace extract-then-rescue accent theming with OKLCH tone-recipe construction so every cover (including pale/yellow ones like Company of One) yields a legible, designed theme.

**Architecture:** `DominantColorExtractor` keeps its histogram but emits a `CoverSignature` (identity hues + weights) instead of finished colors. A new pure `CoverThemeBuilder` constructs role colors (accent, onAccent, chip, background ramp) from per-scheme tone recipes — pale ramps in light mode, immersive deep tones in dark mode — with contrast guaranteed by construction and proven by a 360-hue property test. The existing `artworkAccentColor: Color?` facade keeps all call sites working; `AccentSafetyNet` and the two-gate legibility check are deleted at the end.

**Tech Stack:** Swift 6, SwiftUI, XCTest (`@testable import Echo`), Xcode synchronized folders (new files need no pbxproj edits).

**Spec:** `docs/superpowers/specs/2026-06-10-cover-tonal-theme-design.md` — read it first.

**Verification commands** (used throughout; adjust simulator name if `xcrun simctl list devices available` shows no iPhone 17 Pro):

```bash
# Full test suite (~minutes; the gate before every commit)
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
# Targeted test class (faster while iterating)
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/OKLCHTests 2>&1 | tail -5
```

Expected success marker in both: `** TEST SUCCEEDED **`.

**Migration safety:** Tasks 1–3 are purely additive (old pipeline keeps running). Task 4 swaps the engine behind the facade. Tasks 5–6 adopt the new roles in views. Task 7 deletes the legacy code. Every task ends with the full suite green — the project compiles and tests pass after each commit.

## File structure

| File | Status | Responsibility |
|---|---|---|
| `EchoCore/Utilities/OKLCH.swift` | create | sRGB ↔ OKLCH math + gamut clamp; no platform imports |
| `EchoCore/Services/DominantColorExtractor.swift` | modify | adds `CoverSignature` + `signature(from:)`; legacy API removed in Task 7 |
| `EchoCore/Services/CoverThemeBuilder.swift` | create | `CoverTheme` struct + tone-recipe construction + safety valve |
| `EchoCore/ViewModels/PlayerModel.swift` | modify | `coverTheme` cache, facade, Watch hex (lines ~192–265) |
| `EchoCore/Views/Components/AdaptiveBackground.swift` | rewrite | two-stop tonal ramp |
| `EchoCore/Views/TransportControlsView.swift` | modify | chip fills + accent glyphs on nav circles |
| `EchoCore/Views/Components/CircularProgressPlayButton.swift` | modify | accent-filled hero button + onAccent glyph |
| `EchoCore/Views/Components/UnifiedTopHeader.swift` | modify | chip fill for header pills on Now Playing |
| `EchoCore/Services/AccentSafetyNet.swift` | delete (Task 7) | superseded |
| `EchoCore/Utilities/ColorMetrics.swift` | trim (Task 7) | keep RGB + WCAG + Color bridge only |
| `EchoCore/Utilities/UIImage+Color.swift` | delete (Task 7) | dead code (only docs/design-notes reference it) |
| `EchoTests/OKLCHTests.swift` | create | conversion + gamut tests |
| `EchoTests/CoverThemeBuilderTests.swift` | create | 360-hue property sweep + role rules |
| `EchoTests/DominantColorExtractorTests.swift` | modify | signature tests; legacy tests removed in Task 7 |
| `EchoTests/PlayerModelAccentTests.swift` | modify | theme cache + facade tests |
| `EchoTests/ColorMetricsTests.swift` | trim (Task 7) | keep WCAG + bridge tests |
| `EchoTests/AccentSafetyNetTests.swift` | delete (Task 7) | superseded |

---

### Task 1: OKLCH color utilities

**Files:**
- Create: `EchoCore/Utilities/OKLCH.swift`
- Create: `EchoTests/OKLCHTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/OKLCHTests.swift`:

```swift
import XCTest
@testable import Echo

final class OKLCHTests: XCTestCase {

    func testWhiteHasFullLightnessAndZeroChroma() {
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(lch.L, 1.0, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.0, accuracy: 0.001)
    }

    func testBlackHasZeroLightnessAndZeroChroma() {
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(lch.L, 0.0, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.0, accuracy: 0.001)
    }

    func testPureRedMatchesCSSColor4Reference() {
        // CSS Color 4 reference: color(srgb 1 0 0) == oklch(0.627955 0.257683 29.2339)
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(lch.L, 0.627955, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.257683, accuracy: 0.001)
        XCTAssertEqual(lch.H, 29.2339, accuracy: 0.1)
    }

    func testRoundTripPreservesInGamutColor() {
        let original = ColorMetrics.RGB(r: 0.91, g: 0.76, b: 0.17)
        let back = OKLCH.toSRGB(OKLCH.fromSRGB(original))
        XCTAssertEqual(back.r, original.r, accuracy: 0.001)
        XCTAssertEqual(back.g, original.g, accuracy: 0.001)
        XCTAssertEqual(back.b, original.b, accuracy: 0.001)
    }

    func testClampedChromaReturnsInputWhenAlreadyInGamut() {
        XCTAssertEqual(OKLCH.clampedChroma(L: 0.5, C: 0.05, H: 200), 0.05, accuracy: 1e-9)
    }

    func testClampedChromaReducesOutOfGamutChromaAndPreservesLightness() {
        // Near-white yellow at C 0.30 is far outside sRGB.
        let clamped = OKLCH.clampedChroma(L: 0.97, C: 0.30, H: 95)
        XCTAssertLessThan(clamped, 0.30)
        let rgb = OKLCH.toSRGB(OKLCH.LCH(L: 0.97, C: clamped, H: 95))
        XCTAssertEqual(OKLCH.fromSRGB(rgb).L, 0.97, accuracy: 0.01)
    }

    func testHueSweepStaysInGamutAfterClamp() {
        for hue in stride(from: 0.0, to: 360.0, by: 7.0) {
            let c = OKLCH.clampedChroma(L: 0.47, C: 0.13, H: hue)
            let rgb = OKLCH.toSRGB(OKLCH.LCH(L: 0.47, C: c, H: hue))
            for v in [rgb.r, rgb.g, rgb.b] {
                XCTAssertGreaterThanOrEqual(v, 0, "hue \(hue) below gamut")
                XCTAssertLessThanOrEqual(v, 1, "hue \(hue) above gamut")
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/OKLCHTests 2>&1 | tail -5
```

Expected: `** TEST FAILED **` (or build failure) — `cannot find 'OKLCH' in scope`.

- [ ] **Step 3: Implement OKLCH**

Create `EchoCore/Utilities/OKLCH.swift`. The gamut check runs in **linear** space — out-of-gamut colors produce negative linear channels, and the sRGB transfer function would destroy that sign information.

```swift
import Foundation

/// Conversions between sRGB and the OKLCH cylindrical form of OKLab.
///
/// OKLab lightness is perceptually uniform across hues — unlike HSL, where
/// "lightness 0.55" is near-white for yellow but dark for blue. The tone
/// recipes in `CoverThemeBuilder` rely on this to guarantee contrast for
/// every hue.
///
/// Reference: Björn Ottosson, "A perceptual color space for image
/// processing" (bottosson.github.io/posts/oklab). Matrix constants are his
/// published sRGB D65 values.
enum OKLCH {

    struct LCH: Equatable {
        var L: Double   // 0…1 perceptual lightness
        var C: Double   // chroma; ≲0.37 inside sRGB
        var H: Double   // hue angle, degrees, 0…<360
    }

    // MARK: - Public API

    static func fromSRGB(_ rgb: ColorMetrics.RGB) -> LCH {
        let (L, a, b) = oklab(fromSRGB: rgb)
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180.0 / .pi
        if h < 0 { h += 360 }
        return LCH(L: L, C: c, H: h)
    }

    /// Converts to sRGB, clamping each channel into 0…1. Callers that need
    /// gamut fidelity should reduce chroma via `clampedChroma` first.
    static func toSRGB(_ lch: LCH) -> ColorMetrics.RGB {
        let lin = linearSRGB(lch)
        return ColorMetrics.RGB(
            r: delinearize(min(max(lin.r, 0), 1)),
            g: delinearize(min(max(lin.g, 0), 1)),
            b: delinearize(min(max(lin.b, 0), 1))
        )
    }

    /// Largest chroma ≤ `C` that stays inside sRGB at the given L and H.
    static func clampedChroma(L: Double, C: Double, H: Double) -> Double {
        if inGamut(LCH(L: L, C: C, H: H)) { return C }
        var lo = 0.0
        var hi = C
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if inGamut(LCH(L: L, C: mid, H: H)) { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: - Internals

    private static let gamutTolerance = 1e-4

    private static func inGamut(_ lch: LCH) -> Bool {
        let lin = linearSRGB(lch)
        let lo = -gamutTolerance
        let hi = 1 + gamutTolerance
        return lin.r >= lo && lin.r <= hi
            && lin.g >= lo && lin.g <= hi
            && lin.b >= lo && lin.b <= hi
    }

    private static func linearSRGB(_ lch: LCH) -> (r: Double, g: Double, b: Double) {
        let hRad = lch.H * .pi / 180.0
        let a = lch.C * cos(hRad)
        let b = lch.C * sin(hRad)

        let lp = lch.L + 0.3963377774 * a + 0.2158037573 * b
        let mp = lch.L - 0.1055613458 * a - 0.0638541728 * b
        let sp = lch.L - 0.0894841775 * a - 1.2914855480 * b

        let l = lp * lp * lp
        let m = mp * mp * mp
        let s = sp * sp * sp

        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func oklab(fromSRGB rgb: ColorMetrics.RGB) -> (L: Double, a: Double, b: Double) {
        let r = linearize(rgb.r)
        let g = linearize(rgb.g)
        let b = linearize(rgb.b)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let lp = cbrt(l)
        let mp = cbrt(m)
        let sp = cbrt(s)

        return (
            0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
            1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
            0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
        )
    }

    private static func linearize(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func delinearize(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }
}
```

- [ ] **Step 4: Run the targeted tests to verify they pass**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/OKLCHTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Utilities/OKLCH.swift EchoTests/OKLCHTests.swift
git commit -m "feat: add OKLCH color space utilities with gamut clamping"
```

---

### Task 2: CoverSignature extraction (additive — legacy API untouched)

**Files:**
- Modify: `EchoCore/Services/DominantColorExtractor.swift`
- Test: `EchoTests/DominantColorExtractorTests.swift`

The old `extractPalette`/`extract`/`extractColors` stay until Task 7 so `PlayerModel` keeps compiling between commits.

- [ ] **Step 1: Write the failing tests**

Add to `EchoTests/DominantColorExtractorTests.swift` (keep the existing tests and the `solidImage` helper):

```swift
private func twoToneImage(left: UIColor, right: UIColor, leftFraction: CGFloat,
                          size: CGSize = CGSize(width: 40, height: 40)) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { ctx in
        left.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * leftFraction, height: size.height))
        right.setFill()
        ctx.fill(CGRect(x: size.width * leftFraction, y: 0,
                        width: size.width * (1 - leftFraction), height: size.height))
    }
}

func testSignatureOfVividCoverIsNotNeutral() {
    let sig = DominantColorExtractor.signature(from: solidImage(.systemRed))
    XCTAssertFalse(sig.isNeutral)
    XCTAssertFalse(sig.candidates.isEmpty)
    // sRGB reds sit near hue 29° in OKLCH
    XCTAssertEqual(sig.candidates[0].hue, 29.0, accuracy: 15.0)
    XCTAssertGreaterThan(sig.candidates[0].chroma, 0.05)
}

func testSignatureOfGreyscaleCoverIsNeutral() {
    let sig = DominantColorExtractor.signature(from: solidImage(.gray))
    XCTAssertTrue(sig.isNeutral)
    XCTAssertTrue(sig.candidates.isEmpty)
}

func testSparseVividPixelsFallBelowCoverageFloor() {
    // One vivid 1×1 patch on a 40×40 grey field — far below the 2% floor.
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
        UIColor.gray.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        UIColor.systemRed.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    XCTAssertTrue(DominantColorExtractor.signature(from: image).isNeutral)
}

func testTwoToneCoverRanksLargerRegionFirst() {
    // 75% blue / 25% red → the blue family must rank first.
    let sig = DominantColorExtractor.signature(
        from: twoToneImage(left: .systemBlue, right: .systemRed, leftFraction: 0.75)
    )
    XCTAssertGreaterThanOrEqual(sig.candidates.count, 2)
    XCTAssertEqual(sig.candidates[0].hue, 258.0, accuracy: 25.0)
}

func testSyntheticCompanyOfOneCover() {
    // Spec §7: cream field (filtered as near-white), gold band, navy shapes.
    // Expect: not neutral, a warm primary (sat² favors the vivid gold), and
    // a navy-family candidate available for the secondary role.
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
        UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()   // cream
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        UIColor(red: 0.91, green: 0.76, blue: 0.17, alpha: 1).setFill()   // gold band
        ctx.fill(CGRect(x: 0, y: 30, width: 40, height: 10))
        UIColor(red: 0.16, green: 0.28, blue: 0.39, alpha: 1).setFill()   // navy shapes
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 30))
    }
    let sig = DominantColorExtractor.signature(from: image)
    XCTAssertFalse(sig.isNeutral)
    XCTAssertEqual(sig.candidates[0].hue, 95.0, accuracy: 25.0)  // warm gold leads
    XCTAssertTrue(
        sig.candidates.contains { $0.hue > 230 && $0.hue < 290 },
        "expected a navy-family candidate for the secondary role"
    )
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/DominantColorExtractorTests 2>&1 | tail -5
```

Expected: failure — `type 'DominantColorExtractor' has no member 'signature'`.

- [ ] **Step 3: Add CoverSignature and signature(from:)**

In `EchoCore/Services/DominantColorExtractor.swift`, add a top-level struct above the enum:

```swift
/// What a cover IS — its identity hues — with no opinion about how the UI
/// should look. `CoverThemeBuilder` owns appearance.
struct CoverSignature: Equatable {
    struct HueCandidate: Equatable {
        let hue: Double      // OKLCH hue angle, degrees
        let chroma: Double   // mean OKLCH chroma of the bucket
        let weight: Double   // saturation² × centre-bias coverage score
    }
    /// Ranked by weight, descending. Empty for neutral covers.
    let candidates: [HueCandidate]
    /// True when vivid pixels cover < 2% of the sample (or none at all).
    let isNeutral: Bool

    static let neutral = CoverSignature(candidates: [], isNeutral: true)
}
```

Inside `DominantColorExtractor`, add the coverage constant next to the other configuration constants:

```swift
/// Minimum fraction of sampled pixels that must be vivid for the cover to
/// count as colourful — below this, a stray pixel could theme a book.
private static let minVividCoverage: Double = 0.02
```

And the new entry point (below `extractPalette`):

```swift
/// Single downsample + histogram pass emitting identity hues only.
static func signature(from image: UIImage) -> CoverSignature {
    guard let cgImage = image.cgImage,
          let pixelData = downsampleAndRead(cgImage) else {
        return .neutral
    }

    var weights = [Float](repeating: 0, count: hueBuckets)
    var rSums = [Float](repeating: 0, count: hueBuckets)
    var gSums = [Float](repeating: 0, count: hueBuckets)
    var bSums = [Float](repeating: 0, count: hueBuckets)
    var vividCount = 0

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
        vividCount += 1

        let saturationWeight = s * s
        let x = Float(i % sampleSize)
        let y = Float(i / sampleSize)
        let dx = x - Float(centre)
        let dy = y - Float(centre)
        let distance = sqrt(dx * dx + dy * dy)
        let centreWeight = 1.0 - (distance / maxDistance) * 0.4
        let weight = saturationWeight * centreWeight

        let bucket = min(Int(h * Float(hueBuckets)), hueBuckets - 1)
        weights[bucket] += weight
        rSums[bucket] += r * weight
        gSums[bucket] += g * weight
        bSums[bucket] += b * weight
    }

    let coverage = Double(vividCount) / Double(pixelCount)
    guard coverage >= minVividCoverage else { return .neutral }

    let candidates = (0..<hueBuckets)
        .filter { weights[$0] > 0 }
        .sorted { weights[$0] > weights[$1] }
        .map { bucket -> CoverSignature.HueCandidate in
            let w = weights[bucket]
            let mean = ColorMetrics.RGB(
                r: Double(rSums[bucket] / w),
                g: Double(gSums[bucket] / w),
                b: Double(bSums[bucket] / w)
            )
            let lch = OKLCH.fromSRGB(mean)
            return CoverSignature.HueCandidate(hue: lch.H, chroma: lch.C, weight: Double(w))
        }

    guard !candidates.isEmpty else { return .neutral }
    return CoverSignature(candidates: candidates, isNeutral: false)
}
```

- [ ] **Step 4: Run extractor tests (old + new) to verify all pass**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/DominantColorExtractorTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (legacy palette tests still pass — nothing was removed).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/DominantColorExtractor.swift EchoTests/DominantColorExtractorTests.swift
git commit -m "feat: extract CoverSignature identity hues from artwork"
```

---

### Task 3: CoverThemeBuilder with contrast-guaranteed recipes

**Files:**
- Create: `EchoCore/Services/CoverThemeBuilder.swift`
- Create: `EchoTests/CoverThemeBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/CoverThemeBuilderTests.swift`. The 360-hue sweep IS the spec's "by construction" guarantee — if a recipe change ever breaks a floor, this fails in CI.

```swift
import XCTest
import SwiftUI
@testable import Echo

final class CoverThemeBuilderTests: XCTestCase {

    /// Fixed stand-in so tests don't depend on the asset-catalog brand color.
    private let brand = ColorMetrics.RGB(r: 1.0, g: 0.36, b: 0.0)

    private func signature(hue: Double, chroma: Double = 0.12) -> CoverSignature {
        CoverSignature(
            candidates: [.init(hue: hue, chroma: chroma, weight: 100)],
            isNeutral: false
        )
    }

    func testEveryHueClearsContrastFloorsInBothSchemes() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for hue in 0..<360 {
                let r = CoverThemeBuilder.resolve(
                    signature(hue: Double(hue)), scheme: scheme, brand: brand
                )
                for bg in [r.backgroundTop, r.backgroundBottom] {
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.accent, bg),
                        CoverThemeBuilder.accentFloor,
                        "accent vs background at hue \(hue), \(scheme)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.secondaryAccent, bg),
                        CoverThemeBuilder.accentFloor,
                        "secondary vs background at hue \(hue), \(scheme)"
                    )
                }
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, r.chip),
                    CoverThemeBuilder.chipFloor,
                    "accent vs chip at hue \(hue), \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.onAccent, r.accent),
                    CoverThemeBuilder.onAccentFloor,
                    "onAccent vs accent at hue \(hue), \(scheme)"
                )
            }
        }
    }

    func testCompanyOfOneYellowYieldsLegibleWarmTheme() {
        // The original bug case: extractor golds sit near OKLCH hue ~97.
        let r = CoverThemeBuilder.resolve(signature(hue: 97), scheme: .light, brand: brand)
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.backgroundTop), 3.0
        )
        // The hue family is kept (bronze), not swapped for the brand color.
        XCTAssertEqual(OKLCH.fromSRGB(r.accent).H, 97, accuracy: 20)
        XCTAssertFalse(r.isNeutralFallback)
    }

    func testSecondaryHuePicksDistinctCandidate() {
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),  // gold
                .init(hue: 100, chroma: 0.10, weight: 60),  // near-duplicate — skipped
                .init(hue: 260, chroma: 0.10, weight: 40),  // navy — distinct + heavy enough
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 260, accuracy: 20)
    }

    func testSecondaryFallsBackToHueSiblingWhenNoDistinctCandidate() {
        let r = CoverThemeBuilder.resolve(signature(hue: 95), scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)  // 95 + 30
    }

    func testWeakSecondCandidateIsIgnored() {
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),
                .init(hue: 260, chroma: 0.10, weight: 5),   // distinct but < 15% of primary
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)
    }

    func testNeutralSignatureProducesNeutralFallback() {
        let r = CoverThemeBuilder.resolve(.neutral, scheme: .light, brand: brand)
        XCTAssertTrue(r.isNeutralFallback)
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(r.backgroundTop).C, 0.02)  // near-grey ramp
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.backgroundTop), 3.0     // brand still legible
        )
    }

    func testDarkSchemeProducesDeepBackgrounds() {
        let r = CoverThemeBuilder.resolve(signature(hue: 40), scheme: .dark, brand: brand)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundTop).L, 0.35)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundBottom).L, 0.30)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/CoverThemeBuilderTests 2>&1 | tail -5
```

Expected: failure — `cannot find 'CoverThemeBuilder' in scope`.

- [ ] **Step 3: Implement CoverThemeBuilder**

Create `EchoCore/Services/CoverThemeBuilder.swift`:

```swift
import SwiftUI

/// Role-based theme derived from one cover's `CoverSignature`.
struct CoverTheme: Equatable {
    let accent: Color           // interactive tint — ≥3:1 vs backgrounds and ≥2.5:1 vs chip
    let onAccent: Color         // glyphs inside accent-filled controls — ≥4.5:1 vs accent
    let secondaryAccent: Color  // gradients, secondary indicators
    let backgroundTop: Color    // AdaptiveBackground ramp
    let backgroundBottom: Color
    let chip: Color             // pills and control circles
    let isNeutralFallback: Bool // drives artworkAccentColor's nil contract
}

/// Constructs `CoverTheme`s from tone recipes: the hue comes from the cover,
/// lightness and chroma come from per-role constants chosen so the contrast
/// floors hold for every hue. `CoverThemeBuilderTests` sweeps all 360 hues
/// in both schemes to prove it ("correct by construction").
enum CoverThemeBuilder {

    /// RGB-typed result used by the property tests; `build` wraps it in Colors.
    struct Resolved: Equatable {
        let accent: ColorMetrics.RGB
        let onAccent: ColorMetrics.RGB
        let secondaryAccent: ColorMetrics.RGB
        let backgroundTop: ColorMetrics.RGB
        let backgroundBottom: ColorMetrics.RGB
        let chip: ColorMetrics.RGB
        let isNeutralFallback: Bool
    }

    private struct Recipe {
        let backgroundTop: (l: Double, c: Double)
        let backgroundBottom: (l: Double, c: Double)
        let chip: (l: Double, c: Double)
        let accent: (l: Double, c: Double)
        let onAccent: (l: Double, c: Double)
    }

    /// Pale tonal ramp (spec §4, light column).
    private static let light = Recipe(
        backgroundTop: (0.96, 0.025),
        backgroundBottom: (0.93, 0.040),
        chip: (0.89, 0.050),
        accent: (0.47, 0.130),
        onAccent: (0.97, 0.020)
    )

    /// Immersive deep tones (spec §4, dark column).
    private static let dark = Recipe(
        backgroundTop: (0.26, 0.045),
        backgroundBottom: (0.21, 0.050),
        chip: (0.32, 0.060),
        accent: (0.78, 0.120),
        onAccent: (0.22, 0.040)
    )

    /// Warm-grey ramp hue for neutral (greyscale / no-artwork) covers.
    private static let neutralHue: Double = 80.0
    private static let neutralRampChroma: Double = 0.010

    /// Contrast floors the construction must clear (spec §7).
    static let accentFloor: Double = 3.0
    static let chipFloor: Double = 2.5
    static let onAccentFloor: Double = 4.5

    // MARK: - Public API

    static func build(from signature: CoverSignature, scheme: ColorScheme) -> CoverTheme {
        let r = resolve(signature, scheme: scheme, brand: ColorMetrics.rgb(Color.accentColor))
        return CoverTheme(
            accent: ColorMetrics.color(r.accent),
            onAccent: ColorMetrics.color(r.onAccent),
            secondaryAccent: ColorMetrics.color(r.secondaryAccent),
            backgroundTop: ColorMetrics.color(r.backgroundTop),
            backgroundBottom: ColorMetrics.color(r.backgroundBottom),
            chip: ColorMetrics.color(r.chip),
            isNeutralFallback: r.isNeutralFallback
        )
    }

    /// Pure core. `brand` is injected so tests don't depend on the asset catalog.
    static func resolve(_ signature: CoverSignature,
                        scheme: ColorScheme,
                        brand: ColorMetrics.RGB) -> Resolved {
        let recipe = scheme == .dark ? dark : light

        guard !signature.isNeutral, let primary = signature.candidates.first else {
            return neutralResolved(recipe: recipe, brand: brand)
        }

        let primaryHue = primary.hue
        let backgroundTop = roleColor(recipe.backgroundTop, hue: primaryHue)
        let backgroundBottom = roleColor(recipe.backgroundBottom, hue: primaryHue)
        let chip = roleColor(recipe.chip, hue: primaryHue)

        let accent = enforcedAccent(
            roleColor(recipe.accent, hue: primaryHue), hue: primaryHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )
        let onAccent = enforced(
            roleColor(recipe.onAccent, hue: primaryHue), hue: primaryHue,
            floor: onAccentFloor, against: [accent]
        )

        let secondHue = secondaryHue(for: signature, primary: primary)
        let secondary = enforcedAccent(
            roleColor(recipe.accent, hue: secondHue), hue: secondHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )

        return Resolved(
            accent: accent,
            onAccent: onAccent,
            secondaryAccent: secondary,
            backgroundTop: backgroundTop,
            backgroundBottom: backgroundBottom,
            chip: chip,
            isNeutralFallback: false
        )
    }

    // MARK: - Role construction

    private static func roleColor(_ role: (l: Double, c: Double), hue: Double) -> ColorMetrics.RGB {
        let c = OKLCH.clampedChroma(L: role.l, C: role.c, H: hue)
        return OKLCH.toSRGB(OKLCH.LCH(L: role.l, C: c, H: hue))
    }

    /// First candidate ≥60° (circular) from the primary with ≥15% of its
    /// weight; otherwise a +30° sibling of the primary (spec §4).
    private static func secondaryHue(for signature: CoverSignature,
                                     primary: CoverSignature.HueCandidate) -> Double {
        for candidate in signature.candidates.dropFirst() {
            let delta = abs(candidate.hue - primary.hue)
            let circular = min(delta, 360 - delta)
            if circular >= 60, candidate.weight >= primary.weight * 0.15 {
                return candidate.hue
            }
        }
        return (primary.hue + 30).truncatingRemainder(dividingBy: 360)
    }

    private static func neutralResolved(recipe: Recipe, brand: ColorMetrics.RGB) -> Resolved {
        let backgroundTop = roleColor((recipe.backgroundTop.l, neutralRampChroma), hue: neutralHue)
        let backgroundBottom = roleColor((recipe.backgroundBottom.l, neutralRampChroma), hue: neutralHue)
        let chip = roleColor((recipe.chip.l, neutralRampChroma), hue: neutralHue)

        let brandHue = OKLCH.fromSRGB(brand).H
        let accent = enforcedAccent(
            brand, hue: brandHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )
        let onAccent = enforced(
            roleColor(recipe.onAccent, hue: brandHue), hue: brandHue,
            floor: onAccentFloor, against: [accent]
        )

        return Resolved(
            accent: accent,
            onAccent: onAccent,
            secondaryAccent: accent,
            backgroundTop: backgroundTop,
            backgroundBottom: backgroundBottom,
            chip: chip,
            isNeutralFallback: true
        )
    }

    // MARK: - Safety valve (spec §4)

    private static func enforcedAccent(_ color: ColorMetrics.RGB,
                                       hue: Double,
                                       backgrounds: [ColorMetrics.RGB],
                                       chip: ColorMetrics.RGB) -> ColorMetrics.RGB {
        var result = enforced(color, hue: hue, floor: accentFloor, against: backgrounds)
        result = enforced(result, hue: hue, floor: chipFloor, against: [chip])
        // The chip pass moves L the same direction, but re-verify the backgrounds.
        return enforced(result, hue: hue, floor: accentFloor, against: backgrounds)
    }

    /// Steps lightness away from `surfaces` in 0.01 increments (re-clamping
    /// chroma each step) until every surface clears `floor`. Bounded by L
    /// reaching 0 or 1 — at the bound it returns the max-contrast candidate.
    private static func enforced(_ color: ColorMetrics.RGB,
                                 hue: Double,
                                 floor: Double,
                                 against surfaces: [ColorMetrics.RGB]) -> ColorMetrics.RGB {
        func clears(_ rgb: ColorMetrics.RGB) -> Bool {
            surfaces.allSatisfy { ColorMetrics.contrastRatio(rgb, $0) >= floor }
        }
        if clears(color) { return color }

        let meanSurfaceLuminance = surfaces
            .map(ColorMetrics.relativeLuminance)
            .reduce(0, +) / Double(surfaces.count)
        let step: Double = meanSurfaceLuminance > 0.5 ? -0.01 : 0.01

        var lch = OKLCH.fromSRGB(color)
        var candidate = color
        while lch.L > 0 && lch.L < 1 {
            lch.L = min(max(lch.L + step, 0), 1)
            let c = OKLCH.clampedChroma(L: lch.L, C: lch.C, H: hue)
            candidate = OKLCH.toSRGB(OKLCH.LCH(L: lch.L, C: c, H: hue))
            if clears(candidate) { return candidate }
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run the builder tests to verify they pass**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/CoverThemeBuilderTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. If a hue fails a floor, the failure message names the hue and scheme — adjust the recipe constant or the valve, not the test.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/CoverThemeBuilder.swift EchoTests/CoverThemeBuilderTests.swift
git commit -m "feat: add CoverThemeBuilder with contrast-guaranteed tone recipes"
```

---

### Task 4: PlayerModel — swap the engine behind the facade

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift:192-265` (the "Dynamic accent colour from artwork" section)
- Test: `EchoTests/PlayerModelAccentTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `EchoTests/PlayerModelAccentTests.swift` (keep both existing tests — they must still pass afterward):

```swift
func testCoverThemeWithoutArtworkIsNeutralFallback() {
    let model = PlayerModel()
    XCTAssertTrue(model.coverTheme.isNeutralFallback)
    XCTAssertNil(model.artworkAccentColor)
}

func testCoverThemeChangesWithScheme() {
    let model = PlayerModel()
    model.uiColorScheme = .light
    let light = model.coverTheme
    model.uiColorScheme = .dark
    let dark = model.coverTheme
    XCTAssertNotEqual(light, dark)
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/PlayerModelAccentTests 2>&1 | tail -5
```

Expected: failure — `value of type 'PlayerModel' has no member 'coverTheme'`.

- [ ] **Step 3: Replace the accent section in PlayerModel**

IMPORTANT — keep `artworkPalette`, `cachedPalette`, and `cachedPaletteVersion` untouched in this task: `AdaptiveBackground` still consumes `artworkPalette.background` until Task 5 rewrites it, and deleting the property here would break the build mid-plan. They are removed in Task 7.

In `EchoCore/ViewModels/PlayerModel.swift` (section starting at the `// MARK: - Dynamic accent colour from artwork` comment, currently lines 192–265): keep `uiColorScheme`, `cachedPalette`, `cachedPaletteVersion`, and `artworkPalette` exactly as they are; delete ONLY `cachedSafeAccent`, `cachedSafeAccentVersion`, `cachedSafeAccentScheme`, the old `artworkAccentColor`, and the old `artworkAccentColorHex`; then insert the following immediately after the `artworkPalette` property:

```swift
@ObservationIgnored private var cachedSignature: CoverSignature?
@ObservationIgnored private var cachedSignatureVersion: Int = -1

@ObservationIgnored private var cachedTheme: CoverTheme?
@ObservationIgnored private var cachedThemeVersion: Int = -1
@ObservationIgnored private var cachedThemeScheme: ColorScheme = .light

/// One cached extraction pass for the current cover (or thumbnail).
/// Nil ONLY while no artwork is loaded, so the next access retries —
/// the same retry contract the old palette cache had.
private var currentSignature: CoverSignature? {
    let version = currentDisplayArtworkVersion
    if version != cachedSignatureVersion || cachedSignature == nil {
        guard let image = currentDisplayArtwork ?? thumbnailImage else { return nil }
        cachedSignature = DominantColorExtractor.signature(from: image)
        cachedSignatureVersion = version
    }
    return cachedSignature
}

/// The role-based theme for the current cover and colour scheme.
/// Never nil: missing artwork gets the designed neutral theme.
var coverTheme: CoverTheme {
    guard let signature = currentSignature else {
        return CoverThemeBuilder.build(from: .neutral, scheme: uiColorScheme)
    }
    let version = currentDisplayArtworkVersion
    if version == cachedThemeVersion,
       uiColorScheme == cachedThemeScheme,
       let theme = cachedTheme {
        return theme
    }
    let theme = CoverThemeBuilder.build(from: signature, scheme: uiColorScheme)
    cachedTheme = theme
    cachedThemeVersion = version
    cachedThemeScheme = uiColorScheme
    return theme
}

/// Artwork accent facade. Nil when the cover has no vivid colour
/// (greyscale / no image) so callers' `?? .accentColor` fallbacks engage.
var artworkAccentColor: Color? {
    let theme = coverTheme
    return theme.isNeutralFallback ? nil : theme.accent
}

/// Accent hex for the Watch, built with the DARK recipe — Watch surfaces
/// are always dark regardless of the phone's scheme.
var artworkAccentColorHex: String? {
    guard let signature = currentSignature, !signature.isNeutral else { return nil }
    let resolved = CoverThemeBuilder.resolve(
        signature,
        scheme: .dark,
        brand: ColorMetrics.rgb(Color.accentColor)
    )
    let a = resolved.accent
    return String(format: "#%02X%02X%02X",
                  Int((a.r * 255).rounded()),
                  Int((a.g * 255).rounded()),
                  Int((a.b * 255).rounded()))
}
```

Note what is NOT changing: `EchoCoreApp.resolvedAccentColor`, `BottomToolbarView`, `SettingsView`, `PlayerModel+WatchState`, and the Watch target all consume the facade and keep working untouched.

- [ ] **Step 4: Run the FULL suite (the facade touches everything)**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` — including the untouched `AccentSafetyNetTests` (its service still exists until Task 7; it just has no production callers now).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoTests/PlayerModelAccentTests.swift
git commit -m "feat: drive PlayerModel theming through CoverThemeBuilder"
```

---

### Task 5: AdaptiveBackground tonal ramp

**Files:**
- Rewrite: `EchoCore/Views/Components/AdaptiveBackground.swift`

No new unit test — this is a 15-line declarative view with no logic to assert; correctness is covered by the builder's property tests plus the build. (Snapshot infrastructure doesn't exist in this repo and adding it is out of scope.)

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI

/// Full-screen tonal ramp from the current cover's theme: a pale wash in
/// light mode, an immersive deep room in dark mode. Replaces the old
/// blurred three-hue gradient + material stack (spec §5) — one designed
/// hue with tonal depth instead of a pastel soup, and no 50pt blur pass.
struct AdaptiveBackground: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let theme = model.coverTheme
        LinearGradient(
            colors: [theme.backgroundTop, theme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 2: Build and run the full suite**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/Components/AdaptiveBackground.swift
git commit -m "feat: replace AdaptiveBackground blur stack with tonal ramp"
```

---

### Task 6: Chip and onAccent roles in Now Playing controls

**Files:**
- Modify: `EchoCore/Views/TransportControlsView.swift` (4 nav-circle buttons)
- Modify: `EchoCore/Views/Components/CircularProgressPlayButton.swift`
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift` (3 header chips)

These are the surfaces that produced the washed-out screenshot: accent glyphs on material chips over a same-hue background. No unit tests (pure view styling); the full suite must stay green and the build must succeed.

- [ ] **Step 1: TransportControlsView — chip fills + accent glyphs on the four nav circles**

In each of the four cases `previousTrack`, `nextTrack`, `previousSection`, `nextSection`, the button label currently reads (icon name varies — `backward.end.fill`, `forward.end.fill`, `backward.fill`, `forward.fill`):

```swift
Image(systemName: "backward.end.fill")
    .font(.system(size: isCompact ? 26 : 30, weight: .semibold))
    .foregroundStyle(.primary)
    .frame(width: isCompact ? 60 : 72, height: isCompact ? 60 : 72)
    .background(Circle().fill(Color.primary.opacity(0.1)))
    .contentShape(Rectangle())
```

Change `.foregroundStyle(.primary)` → `.foregroundStyle(model.artworkAccentColor ?? .accentColor)` and `.background(Circle().fill(Color.primary.opacity(0.1)))` → `.background(Circle().fill(model.coverTheme.chip))` in all four, e.g.:

```swift
Image(systemName: "backward.end.fill")
    .font(.system(size: isCompact ? 26 : 30, weight: .semibold))
    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
    .frame(width: isCompact ? 60 : 72, height: isCompact ? 60 : 72)
    .background(Circle().fill(model.coverTheme.chip))
    .contentShape(Rectangle())
```

Leave the other action buttons (skip, loop, speed, sleep, bookmark) untouched — they have no circle backgrounds and `.primary` is correct on the dock material.

- [ ] **Step 2: CircularProgressPlayButton — accent-filled hero with onAccent glyph**

In `EchoCore/Views/Components/CircularProgressPlayButton.swift`:

Ring background (line ~37): `Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3.5)` →

```swift
Circle()
    .stroke(model.coverTheme.chip, lineWidth: 3.5)
```

Hero button fill + glyph (lines ~58–64):

```swift
ZStack {
    Circle()
        .fill(model.artworkAccentColor ?? .accentColor)
        .frame(width: 74, height: 74)

    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 34, weight: .bold))
        .foregroundStyle(model.coverTheme.onAccent)
}
```

The ring's progress stroke (`Color.accentColor`) stays — it already resolves to the artwork accent via the app-wide `.tint`/`.accentColor` in `EchoCoreApp.swift:64-65`.

- [ ] **Step 3: UnifiedTopHeader — chip fill on Now Playing only**

In `EchoCore/Views/Components/UnifiedTopHeader.swift`, add below the `headerBackground` property:

```swift
/// On Now Playing the header chips sit on the tonal ramp, where a solid
/// chip tone reads as designed; on other tabs they float over scrolling
/// content, where material blur is still the right call.
private var chipFill: AnyShapeStyle {
    model.selectedTab == .nowPlaying
        ? AnyShapeStyle(model.coverTheme.chip)
        : AnyShapeStyle(.ultraThinMaterial)
}
```

Replace all four `.background(.ultraThinMaterial, in: ...)` occurrences (folder button, ellipsis menu label, both branches of `remainingTimeView`):

- `.background(.ultraThinMaterial, in: Circle())` → `.background(chipFill, in: Circle())` (2×)
- `.background(.ultraThinMaterial, in: Capsule())` → `.background(chipFill, in: Capsule())` (2×)

- [ ] **Step 4: Build and run the full suite**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual visual check (the point of the whole feature)**

Run the app in the simulator, load a book with a pale/yellow cover if available, and verify: ramp background (no pastel blur), legible accent on every control, chip circles one tone off the background, accent-filled play button with readable glyph, both color schemes. The Company of One acceptance: every glyph readable at arm's length.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/TransportControlsView.swift \
        "EchoCore/Views/Components/CircularProgressPlayButton.swift" \
        "EchoCore/Views/Components/UnifiedTopHeader.swift"
git commit -m "feat: adopt chip and on-accent roles in Now Playing controls"
```

---

### Task 7: Delete the superseded rescue pipeline

**Files:**
- Delete: `EchoCore/Services/AccentSafetyNet.swift`, `EchoTests/AccentSafetyNetTests.swift`
- Delete: `EchoCore/Utilities/UIImage+Color.swift`
- Modify: `EchoCore/Services/DominantColorExtractor.swift` (remove legacy API)
- Modify: `EchoCore/Utilities/ColorMetrics.swift` (keep RGB + WCAG + bridge)
- Modify: `EchoTests/DominantColorExtractorTests.swift`, `EchoTests/ColorMetricsTests.swift`

- [ ] **Step 1: Verify nothing still references the legacy API**

```bash
rg -n "ArtworkPalette|extractPalette|extractColors|AccentSafetyNet|isLegible|deltaE76|nudged|averageColor|bottomAreaAverageColor|topAreaAverageColor" \
  --type swift -g '!docs/*'
```

Expected: hits ONLY in the files this task deletes/trims (`AccentSafetyNet.swift`, `AccentSafetyNetTests.swift`, `ColorMetrics.swift`, `ColorMetricsTests.swift`, `DominantColorExtractor.swift`, `DominantColorExtractorTests.swift`, `UIImage+Color.swift`) plus the `PlayerModel.swift` legacy members that Step 3 removes. If anything else appears, STOP and migrate that caller first.

- [ ] **Step 2: Remove the legacy palette members from PlayerModel**

In `EchoCore/ViewModels/PlayerModel.swift`, delete the now-unconsumed `artworkPalette` computed property and its backing `cachedPalette` / `cachedPaletteVersion` members (kept alive through Task 4 only because `AdaptiveBackground` consumed them until Task 5). Also update the stale doc comment on `uiColorScheme` — it still mentions the "rescued accent":

```swift
/// Current UI colour scheme, fed from `RootTabView`. Drives theme
/// construction so light/dark switches rebuild the theme.
var uiColorScheme: ColorScheme = .light
```

- [ ] **Step 2b: Delete the dead files**

```bash
git rm EchoCore/Services/AccentSafetyNet.swift \
       EchoTests/AccentSafetyNetTests.swift \
       EchoCore/Utilities/UIImage+Color.swift
```

- [ ] **Step 3: Remove legacy extractor API**

In `EchoCore/Services/DominantColorExtractor.swift` delete: the `ArtworkPalette` struct, `backgroundDefaults`, `extractPalette(from:)`, `extract(from:)`, `extractColors(from:count:)`, `pad(_:to:)`, `rankedVividColors(pixelData:)`, the `saturationFloor`/`lightnessTargetMin`/`lightnessTargetMax` constants, and `hslToRGB(h:s:l:)`. Keep: `CoverSignature`, `signature(from:)`, `minVividCoverage`, `hueBuckets`, `sampleSize`, `minLightness`, `maxLightness`, `minSaturation`, `downsampleAndRead(_:)`, `rgbToHSL(r:g:b:)`.

In `EchoTests/DominantColorExtractorTests.swift` delete the five legacy tests: `testVividCoverYieldsNonNilAccentAndThreeColorBackground`, `testGreyscaleCoverYieldsNilAccent`, `testExtractColorsReturnsRequestedCount`, `testExistingExtractAPIStillWorks`, `testGreyscaleReturnsNilFromExtract`. Keep `solidImage`, `twoToneImage`, and the four signature tests.

- [ ] **Step 4: Trim ColorMetrics to what the new pipeline uses**

In `EchoCore/Utilities/ColorMetrics.swift` delete: `luminanceGate`, `chromaGate`, `contrastFloor`, `distortionBudget`, `lab(_:)`, `deltaE76(_:_:)`, `isLegible(_:on:)`, `toHSL(_:)`, `fromHSL(h:s:l:)`, `nudged(_:toClear:against:)`, and update the header doc comment:

```swift
/// Pure colour math shared by the cover-theme pipeline.
///
/// The metric core works on `RGB` (sRGB, 0…1 `Double`s) so it is fully
/// unit-testable without UIKit. Only the `Color`↔`RGB` bridge touches the
/// platform. WCAG luminance/contrast lives here; perceptual conversions
/// live in `OKLCH`.
```

Keep: `RGB`, `relativeLuminance(_:)`, `contrastRatio(_:_:)`, and the `rgb(_:)`/`color(_:)` bridge.

In `EchoTests/ColorMetricsTests.swift` delete: `testDeltaE76IsZeroForIdenticalColors`, `testTwoGateSavesVividOrange`, `testTwoGateFlagsMuddyGold`, `testNudgeDarkensOnLightSurface`, `testNudgeLightensOnDarkSurface`, `testNudgeNoopWhenAlreadyLegible`. Keep: the `rgb` helper, `testBlackWhiteMaximumContrast`, `testGoldOnBeigeReproducesDiagnosedContrast`, `testContrastIsSymmetric`, `testColorBridgeRoundTripsWithinTolerance`.

- [ ] **Step 5: Full suite + reference re-check**

```bash
xcodebuild test -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
rg -n "ArtworkPalette|extractPalette|AccentSafetyNet|isLegible|deltaE76" --type swift -g '!docs/*'
```

Expected: `** TEST SUCCEEDED **` and zero ripgrep hits.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove AccentSafetyNet rescue pipeline and legacy extraction API"
```

---

### Task 8: Documentation

**Files:**
- Modify: `ARCHITECTURE.md` (replace the "Accent Contrast Safety (June 2026)" section; update the extraction bullets under "Artwork Accent Color (June 2026)")
- Modify: `CHANGELOG.md` (`[Unreleased]`)
- Modify: `CODE_AUDIT.md` (post-audit addendum)

- [ ] **Step 1: ARCHITECTURE.md**

The tree at the top regenerates from source; the prose below the `<!-- MANUAL BELOW -->` marker is hand-maintained. First refresh the tree:

```bash
make architecture
```

Then, in the "Artwork Accent Color (June 2026)" section, replace the extraction-pipeline bullet list with:

```markdown
**Extraction pipeline (`DominantColorExtractor`):**
- Downsamples the cover image to 100×100px for fast analysis.
- Converts pixels to HSL and discards near-grey, near-white, and near-black pixels.
- Builds a saturation²-weighted hue histogram with centre-distance biasing (cover subjects tend to be centred).
- Emits a `CoverSignature` — ranked identity hues (OKLCH hue + chroma + weight) with an `isNeutral` flag (vivid coverage < 2%, so a stray pixel can't theme a book). The extractor reports what the cover IS; it has no opinion about how the UI looks.
```

Replace the entire "### Accent Contrast Safety (June 2026)" section (heading through its thresholds table) with:

```markdown
### Cover Tonal Themes (June 2026)

Cover colors are no longer used directly in the UI. The pipeline is
construct-don't-rescue:

`UIImage → DominantColorExtractor.signature(from:) → CoverSignature → CoverThemeBuilder.build(from:scheme:) → CoverTheme`

**`CoverThemeBuilder`** converts the cover's primary hue to OKLCH and builds
role colors from per-scheme tone recipes — pale ramps in light mode
(background L≈0.93–0.96), immersive deep tones in dark mode (L≈0.21–0.26),
accent at L 0.47 (light) / 0.78 (dark) with gamut-clamped chroma. Contrast is
guaranteed by construction: `CoverThemeBuilderTests` sweeps all 360 hues in
both schemes asserting accent ≥3:1 vs backgrounds, ≥2.5:1 vs chip, and
onAccent ≥4.5:1 vs accent. A bounded lightness-stepping safety valve covers
extreme gamut corners. Roles: `accent`, `onAccent`, `secondaryAccent`
(first candidate ≥60° away with ≥15% of the primary's weight, else a +30°
sibling), `backgroundTop`/`backgroundBottom` (the `AdaptiveBackground` ramp),
and `chip` (pills/control circles). Neutral covers (greyscale or `isNeutral`)
get a warm-grey ramp with the brand accent.

**Why OKLCH:** HSL lightness is not perceptual — yellow at HSL L 0.55 is
near-white in real luminance while blue at the same L is dark. OKLab
lightness is uniform across hues, which is what makes fixed tone recipes
safe for every cover.

**Integration:** `PlayerModel.coverTheme` (cached per artwork version +
`uiColorScheme`); `PlayerModel.artworkAccentColor` remains the compatibility
facade (nil for neutral covers so `?? .accentColor` fallbacks engage);
`artworkAccentColorHex` sends the **dark-recipe** accent to the Watch, whose
surface is always dark.

**History:** this replaced the `AccentSafetyNet` two-gate rescue ladder. Its
ΔE76 chroma gate passed high-chroma/equal-luminance accents (bright gold on
beige at 1.06:1 WCAG) because chromatic distance alone cannot carry small
glyphs — see CODE_AUDIT.md §13.
```

- [ ] **Step 2: CHANGELOG.md**

Under `## [Unreleased]`, add a `### Changed` section (after `### Added` if none exists yet):

```markdown
### Changed
- **Cover-derived theming rebuilt on OKLCH tone recipes:** cover artwork now contributes only its identity hues (`CoverSignature`); `CoverThemeBuilder` constructs role colors (accent, on-accent, chip, background ramp) from per-scheme tone recipes — pale tonal ramps in light mode, immersive deep tones in dark mode — with WCAG contrast guaranteed by construction and proven by a 360-hue property test. Fixes illegible accents on pale covers (bright gold on beige measured 1.06:1). Now Playing background is a designed two-stop ramp instead of a blurred three-hue gradient; transport circles and header pills use tone-on-tone chip fills; the play button is accent-filled with a guaranteed-contrast glyph. The Watch now receives a dark-recipe accent (its surface is always dark). `AccentSafetyNet` and the ΔE76 legibility gate were removed.
```

- [ ] **Step 3: CODE_AUDIT.md addendum**

Append at the end of the file:

```markdown
---

## 13. Post-audit addendum

### 13.1 `ColorMetrics.isLegible` ΔE76 chroma gate passed unreadable accents (found 2026-06-10, superseded)

The two-gate legibility check (`WCAG ≥ 2.4 OR ΔE76 ≥ 52`) approved accents with
high chromatic distance but near-zero luminance contrast — extractor gold
`#EEC32B` on the Company of One beige surface measured **1.06:1** WCAG with
ΔE76 65, so the `AccentSafetyNet` rescue ladder never ran. Higher saturation
inflated ΔE76, making the most problematic accents the most likely to bypass
rescue. Root cause: human acuity for fine detail is carried by the luminance
channel; a chroma-only gate cannot certify glyph legibility. Resolved by
replacing extract-then-rescue with constructed OKLCH tone recipes
(`CoverThemeBuilder`, spec `docs/superpowers/specs/2026-06-10-cover-tonal-theme-design.md`);
the gate, ladder, and their tests were deleted.
```

- [ ] **Step 4: Build check and commit**

```bash
xcodebuild build -project Echo.xcodeproj -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3
git add ARCHITECTURE.md CHANGELOG.md CODE_AUDIT.md
git commit -m "docs: document cover tonal theme architecture"
```

Expected: `** BUILD SUCCEEDED **`.

---

## Out of scope (spec "Future work")

Gradient drift while playing, `MeshGradient` variant, accent-gradient progress ring, blurred-artwork backdrop mode, Reader/EPUB theming.
