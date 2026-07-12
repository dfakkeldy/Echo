# Watch Progress and Smart Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cover-accented rectangular Smart Stack card, make the circular complication and Pomodoro rings bolder, and replace the Watch Pomodoro's small clock text with an accessible adaptive two-digit countdown.

**Architecture:** Keep the existing WatchConnectivity and App Group pipeline. Add platform-neutral ring metrics and widget-accent selection in `Shared/`, a pure Pomodoro presentation value in the Watch app, then split the widget's circular and rectangular SwiftUI presentations behind the existing timeline provider. Exact cover colour is selected only when WidgetKit reports full-colour rendering; system-coloured modes retain semantic tint.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, Observation, Swift Testing, watchOS 11+, Xcode 26, WatchConnectivity/App Group state already present in Echo.

## Global Constraints

- Work only in `/Users/dfakkeldy/Developer/Echo/.claude/worktrees/dreamy-torvalds-9f6fdb` on `codex/watch-progress-smart-stack`; preserve the detached dirty Codex checkout.
- Keep the branch based on current `origin/nightly`; the final PR target is `nightly`, never `main`.
- Build on merged PR #436 (`fix: keep Now Playing and Watch state current`). Do not reopen its iPhone Lock Screen/Now Playing or Watch state pipeline unless verification exposes a regression; the Lock Screen surface is system Now Playing, not this watch-only widget extension.
- Preserve watchOS 11, iOS 18, macOS 15, and Swift 6 deployment/language settings.
- Do not add third-party dependencies or watchOS 26-only RelevanceKit/configuration APIs.
- Follow strict TDD: add a focused failing test, observe the expected failure, implement the minimum behaviour, then rerun focused and neighbouring tests.
- Before every `xcodebuild`, wait on `"$HOME/.claude/bin/xcode-build-gate.sh" --wait`; keep parallel testing disabled and use private DerivedData directories.
- `Shared/` compiles into iOS, watchOS, the widget, macOS, and `echo-cli`; keep shared types platform-neutral with no SwiftUI, WidgetKit, UIKit, or WatchKit imports.
- Filesystem-synchronized groups automatically include new files under `Shared/`, `Echo Watch App/`, `Echo Watch AppTests/`, `Echo Widget/`, and `EchoTests/`; do not edit `project.pbxproj` for membership.
- The circular complication must remain semantically tinted. Only the rectangular full-colour appearance may use the exact cover-derived RGB.
- Keep visible Pomodoro text to exactly two digits. The approved hour display rounds upward and is deliberately coarse.
- Keep all existing Pomodoro timing, persistence, haptics, picker limits, tap behaviour, and physical long-press behaviour.
- Add comments only where a platform constraint or boundary is not obvious from the code.
- Use Conventional Commits at each task boundary and preserve the already-committed design/specification history.

## File Structure

| File | Responsibility |
|---|---|
| `Shared/WatchProgressRingMetrics.swift` | Platform-neutral approved stroke, marker, inset, artwork, and gauge dimensions shared by the Watch app and widget. |
| `Shared/WidgetAccentColor.swift` | Existing `HexRGB` parsing plus the pure full-colour-versus-system-tint decision. |
| `Echo Watch App/Models/PomodoroTimePresentation.swift` | Pure two-digit unit selection, upward rounding, saturation, and localized accessibility value/hint copy. |
| `Echo Watch App/Views/Components/PomodoroButton.swift` | Existing button interaction with the bolder ring, larger digits, accessibility action, and real-size previews. |
| `Echo Widget/Views/Echo_Widget.swift` | Existing timeline provider, extended entry data, and two-family widget configuration. |
| `Echo Widget/Views/EchoWidgetEntryView.swift` | Widget-family routing, shared deep link, clamped progress, and combined VoiceOver semantics. |
| `Echo Widget/Views/EchoWidgetArtworkView.swift` | Reusable thumbnail decoding and music-note fallback without duplicating view-builder properties. |
| `Echo Widget/Views/EchoCircularWidgetView.swift` | Safely inset, system-tinted circular progress presentation. |
| `Echo Widget/Views/EchoRectangularWidgetView.swift` | Smart Stack/rectangular card and rendering-mode-aware gauge colour. |
| `Echo Widget/Views/EchoWidgetPreviews.swift` | Circular/rectangular, progress-state, fallback, and rendering-mode preview matrix. |
| `Echo Watch AppTests/PomodoroTimePresentationTests.swift` | Boundary, fractional tick, saturation, invalid-state, and accessibility-copy tests. |
| `EchoTests/WatchProgressRingMetricsTests.swift` | Approved ring/gauge geometry contract. |
| `EchoTests/WidgetAccentColorTests.swift` | Valid/invalid/cleared accent and rendering-policy tests. |
| `EchoTests/WatchPomodoroAccessibilitySourceTests.swift` | Watch view integration contract for digits and accessibility modifiers. |
| `EchoTests/WatchWidgetPresentationSourceTests.swift` | Widget provider, family, router, rendering-policy, and metric integration contracts. |

## Verification Setup

Create or reuse one named Watch simulator for every Watch build/test command in this plan:

```bash
if ! xcrun simctl list devices available | rg -q 'EchoProgress-Watch'; then
  xcrun simctl create \
    EchoProgress-Watch \
    'Apple Watch Series 11 (46mm)' \
    'com.apple.CoreSimulator.SimRuntime.watchOS-26-5'
fi
```

Use these private build directories consistently:

| Purpose | DerivedData path |
|---|---|
| Watch tests | `/tmp/Echo-watch-progress-dd` |
| iOS tests | `/tmp/Echo-watch-progress-ios-dd` |
| Widget builds | `/tmp/Echo-widget-progress-dd` |
| macOS builds | `/tmp/Echo-watch-progress-mac-dd` |
| CLI builds | `/tmp/Echo-watch-progress-cli-dd` |

Do not delete the named simulator between tasks; remove it only after final verification if it was created by this plan.

---

### Task 1: Platform-Neutral Ring Metrics and Widget Accent Policy

**Files:**
- Create: `Shared/WatchProgressRingMetrics.swift`
- Modify: `Shared/WidgetAccentColor.swift:4-17`
- Create: `EchoTests/WatchProgressRingMetricsTests.swift`
- Modify: `EchoTests/WidgetAccentColorTests.swift:6-17`

**Interfaces:**
- Consumes: Existing `HexRGB.init?(hex:)` from `Shared/WidgetAccentColor.swift`.
- Produces: `WatchProgressRingMetrics`, `WidgetProgressAccentStyle`, and `WidgetProgressAccentPolicy.style(accentHex:preservesExactCoverColor:)` for Tasks 3 and 5.

- [ ] **Step 1: Write the failing ring-metric tests**

Create `EchoTests/WatchProgressRingMetricsTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct WatchProgressRingMetricsTests {
    @Test("Pomodoro rings use the approved proportional weights")
    func pomodoroRingWidths() {
        #expect(WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: false) == 5)
        #expect(WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: true) == 6)
    }

    @Test("The complication geometry stays bold and safely inset")
    func complicationGeometry() {
        #expect(WatchProgressRingMetrics.complicationLineWidth == 6)
        #expect(WatchProgressRingMetrics.complicationMarkerDiameter == 8)
        #expect(WatchProgressRingMetrics.complicationInset == 4)
        #expect(WatchProgressRingMetrics.complicationArtworkPadding == 8)
        #expect(WatchProgressRingMetrics.rectangularGaugeHeight == 5)
    }
}
```

- [ ] **Step 2: Extend the accent-policy tests before adding the policy**

Insert these methods before `WidgetAccentColorTests`' closing brace:

```swift
    @Test("exact cover RGB is selected only when the surface preserves it")
    func selectsCoverAccentOnlyForFullColor() throws {
        let rgb = try #require(HexRGB(hex: "#FF8000"))

        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#FF8000",
                preservesExactCoverColor: true
            ) == .cover(rgb)
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#FF8000",
                preservesExactCoverColor: false
            ) == .systemTint
        )
    }

    @Test("missing cleared and malformed accents use system tint")
    func invalidAccentsUseSystemTint() {
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: nil,
                preservesExactCoverColor: true
            ) == .systemTint
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "",
                preservesExactCoverColor: true
            ) == .systemTint
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#GG0000",
                preservesExactCoverColor: true
            ) == .systemTint
        )
    }
```

- [ ] **Step 3: Run the focused tests and verify the expected RED state**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchProgressRingMetricsTests \
  -only-testing:EchoTests/WidgetAccentColorTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `WatchProgressRingMetrics` and `WidgetProgressAccentPolicy` do not exist. Confirm there are no unrelated failures.

- [ ] **Step 4: Add the minimum platform-neutral implementations**

Create `Shared/WatchProgressRingMetrics.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum WatchProgressRingMetrics {
    static let pomodoroStandardLineWidth: CGFloat = 5
    static let pomodoroCenterLineWidth: CGFloat = 6
    static let complicationLineWidth: CGFloat = 6
    static let complicationMarkerDiameter: CGFloat = 8
    static let complicationInset: CGFloat = 4
    static let complicationArtworkPadding: CGFloat = 8
    static let rectangularGaugeHeight: CGFloat = 5

    static func pomodoroLineWidth(hasSeparateRing: Bool) -> CGFloat {
        hasSeparateRing ? pomodoroCenterLineWidth : pomodoroStandardLineWidth
    }
}
```

First replace `HexRGB`'s existing doc comment with:

```swift
/// Platform-neutral RGB components used by the Watch app and widget colour bridges.
```

Then append:

```swift
nonisolated enum WidgetProgressAccentStyle: Equatable, Sendable {
    case systemTint
    case cover(HexRGB)
}

nonisolated enum WidgetProgressAccentPolicy {
    static func style(
        accentHex: String?,
        preservesExactCoverColor: Bool
    ) -> WidgetProgressAccentStyle {
        guard preservesExactCoverColor,
              let accentHex,
              let rgb = HexRGB(hex: accentHex)
        else {
            return .systemTint
        }
        return .cover(rgb)
    }
}
```

- [ ] **Step 5: Run focused tests and verify GREEN**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchProgressRingMetricsTests \
  -only-testing:EchoTests/WidgetAccentColorTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both suites pass with no failures.

- [ ] **Step 6: Format, lint, and rerun the shared tests**

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  Shared/WatchProgressRingMetrics.swift \
  Shared/WidgetAccentColor.swift \
  EchoTests/WatchProgressRingMetricsTests.swift \
  EchoTests/WidgetAccentColorTests.swift

xcrun swift-format lint --strict --configuration .swift-format \
  Shared/WatchProgressRingMetrics.swift \
  Shared/WidgetAccentColor.swift \
  EchoTests/WatchProgressRingMetricsTests.swift \
  EchoTests/WidgetAccentColorTests.swift
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchProgressRingMetricsTests \
  -only-testing:EchoTests/WidgetAccentColorTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both suites remain green after formatting.

- [ ] **Step 7: Commit the shared contracts**

```bash
git add \
  Shared/WatchProgressRingMetrics.swift \
  Shared/WidgetAccentColor.swift \
  EchoTests/WatchProgressRingMetricsTests.swift \
  EchoTests/WidgetAccentColorTests.swift
git diff --cached --check
git commit -m 'feat(watch): define progress presentation policies'
```

---

### Task 2: Adaptive Two-Digit Pomodoro Presentation

**Files:**
- Create: `Echo Watch App/Models/PomodoroTimePresentation.swift`
- Create: `Echo Watch AppTests/PomodoroTimePresentationTests.swift`

**Interfaces:**
- Consumes: `TimeInterval` only; the type remains independent of `WatchViewModel` and SwiftUI.
- Produces: `PomodoroDisplayUnit`, `PomodoroTimePresentation.make(remaining:)`, `.digits`, `.accessibilityValue(isRunning:)`, and `.accessibilityHint(isRunning:)` for Task 3.

- [ ] **Step 1: Write the failing boundary and accessibility tests**

Create `Echo Watch AppTests/PomodoroTimePresentationTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo_Watch_App

@Suite struct PomodoroTimePresentationTests {
    @Test("hours round upward until the exact sixty-minute boundary")
    func hoursPhase() {
        let twoHours = PomodoroTimePresentation.make(remaining: 2 * 60 * 60)
        let oneHourTwenty = PomodoroTimePresentation.make(remaining: 80 * 60)
        let boundary = PomodoroTimePresentation.make(remaining: 60 * 60)

        #expect(twoHours.digits == "02")
        #expect(twoHours.value == 2)
        #expect(twoHours.unit == .hours)
        #expect(oneHourTwenty.digits == "02")
        #expect(oneHourTwenty.unit == .hours)
        #expect(boundary.digits == "60")
        #expect(boundary.unit == .minutes)
    }

    @Test("minutes hand off to seconds at exactly one minute")
    func minuteAndSecondPhases() {
        let minuteFraction = PomodoroTimePresentation.make(remaining: 60.1)
        let boundary = PomodoroTimePresentation.make(remaining: 60)
        let fractionalSecond = PomodoroTimePresentation.make(remaining: 59.1)

        #expect(minuteFraction.digits == "02")
        #expect(minuteFraction.unit == .minutes)
        #expect(boundary.digits == "60")
        #expect(boundary.unit == .seconds)
        #expect(fractionalSecond.digits == "60")
        #expect(fractionalSecond.unit == .seconds)
    }

    @Test("invalid and completed values become zero")
    func invalidValues() {
        let invalidValues: [TimeInterval] = [0, -1, .infinity, -.infinity, .nan]
        for value in invalidValues {
            let presentation = PomodoroTimePresentation.make(remaining: value)
            #expect(presentation.digits == "00")
            #expect(presentation.isComplete)
        }
    }

    @Test("picker maximum and overflow stay within two digits")
    func maximumAndOverflow() {
        let pickerMaximum = PomodoroTimePresentation.make(remaining: 23 * 3600 + 59 * 60 + 59)
        let ninetyNineHours = PomodoroTimePresentation.make(remaining: 99 * 3600)
        let overflow = PomodoroTimePresentation.make(remaining: 99 * 3600 + 0.1)

        #expect(pickerMaximum.digits == "24")
        #expect(pickerMaximum.unit == .hours)
        #expect(ninetyNineHours.digits == "99")
        #expect(!ninetyNineHours.isOverflow)
        #expect(overflow.digits == "99")
        #expect(overflow.isOverflow)
    }

    @Test("accessibility includes state unit and overflow semantics")
    func accessibilityCopy() {
        let running = PomodoroTimePresentation.make(remaining: 25 * 60)
        let stopped = PomodoroTimePresentation.make(remaining: 59)
        let complete = PomodoroTimePresentation.make(remaining: 0)
        let overflow = PomodoroTimePresentation.make(remaining: 100 * 3600)

        #expect(running.accessibilityValue(isRunning: true) == "Running, 25 minutes remaining")
        #expect(stopped.accessibilityValue(isRunning: false) == "Stopped, 59 seconds remaining")
        #expect(complete.accessibilityValue(isRunning: false) == "Timer complete")
        #expect(overflow.accessibilityValue(isRunning: true) == "Running, More than 99 hours remaining")
        #expect(running.accessibilityHint(isRunning: true) == "Double-tap to stop the timer")
        #expect(stopped.accessibilityHint(isRunning: false) == "Double-tap to start the timer")
    }
}
```

- [ ] **Step 2: Run the focused Watch test and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `PomodoroTimePresentation` does not exist.

- [ ] **Step 3: Implement the pure presentation value**

Create `Echo Watch App/Models/PomodoroTimePresentation.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum PomodoroDisplayUnit: Equatable, Sendable {
    case hours
    case minutes
    case seconds
    case complete
}

nonisolated struct PomodoroTimePresentation: Equatable, Sendable {
    let digits: String
    let value: Int
    let unit: PomodoroDisplayUnit
    let isComplete: Bool
    let isOverflow: Bool

    static func make(remaining: TimeInterval) -> Self {
        guard remaining.isFinite, remaining > 0 else {
            return Self(digits: "00", value: 0, unit: .complete, isComplete: true, isOverflow: false)
        }

        let maximumVisibleHours = 99
        if remaining > TimeInterval(maximumVisibleHours * 3600) {
            return Self(
                digits: "99",
                value: maximumVisibleHours,
                unit: .hours,
                isComplete: false,
                isOverflow: true
            )
        }

        let value: Int
        let unit: PomodoroDisplayUnit
        if remaining > 3600 {
            value = Int(ceil(remaining / 3600))
            unit = .hours
        } else if remaining > 60 {
            value = Int(ceil(remaining / 60))
            unit = .minutes
        } else {
            value = Int(ceil(remaining))
            unit = .seconds
        }

        return Self(
            digits: value < 10 ? "0\(value)" : "\(value)",
            value: value,
            unit: unit,
            isComplete: false,
            isOverflow: false
        )
    }

    func accessibilityValue(isRunning: Bool) -> String {
        if isComplete {
            return String(localized: "Timer complete")
        }
        let state = isRunning ? String(localized: "Running") : String(localized: "Stopped")
        return "\(state), \(remainingDescription)"
    }

    func accessibilityHint(isRunning: Bool) -> String {
        isRunning
            ? String(localized: "Double-tap to stop the timer")
            : String(localized: "Double-tap to start the timer")
    }

    private var remainingDescription: String {
        if isOverflow {
            return String(localized: "More than 99 hours remaining")
        }
        switch unit {
        case .hours:
            return value == 1
                ? String(localized: "1 hour remaining")
                : String(localized: "\(value) hours remaining")
        case .minutes:
            return value == 1
                ? String(localized: "1 minute remaining")
                : String(localized: "\(value) minutes remaining")
        case .seconds:
            return value == 1
                ? String(localized: "1 second remaining")
                : String(localized: "\(value) seconds remaining")
        case .complete:
            return String(localized: "Timer complete")
        }
    }
}
```

- [ ] **Step 4: Run the focused Watch test and verify GREEN**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `PomodoroTimePresentationTests` passes with no failures.

- [ ] **Step 5: Format, lint, and rerun the timer tests**

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  'Echo Watch App/Models/PomodoroTimePresentation.swift' \
  'Echo Watch AppTests/PomodoroTimePresentationTests.swift'

xcrun swift-format lint --strict --configuration .swift-format \
  'Echo Watch App/Models/PomodoroTimePresentation.swift' \
  'Echo Watch AppTests/PomodoroTimePresentationTests.swift'
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the suite remains green after formatting.

- [ ] **Step 6: Commit the pure timer semantics**

```bash
git add \
  'Echo Watch App/Models/PomodoroTimePresentation.swift' \
  'Echo Watch AppTests/PomodoroTimePresentationTests.swift'
git diff --cached --check
git commit -m 'feat(watch): add adaptive Pomodoro display model'
```

---

### Task 3: Bolder Pomodoro UI, Accessibility, and Preview Matrix

**Files:**
- Modify: `Echo Watch App/Views/Components/PomodoroButton.swift:4-80`
- Create: `EchoTests/WatchPomodoroAccessibilitySourceTests.swift`

**Interfaces:**
- Consumes: `WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing:)` from Task 1 and `PomodoroTimePresentation` from Task 2.
- Produces: A visually larger two-digit Pomodoro button, localized state/value/hint semantics, and named `Set duration` accessibility action. No call-site changes are required.

- [ ] **Step 1: Write the failing source contract for the visible and accessibility changes**

Create `EchoTests/WatchPomodoroAccessibilitySourceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchPomodoroAccessibilitySourceTests {
    @Test("Pomodoro exposes large digits and a discoverable duration action")
    func pomodoroAccessibilityContract() throws {
        let source = try Self.source()

        #expect(source.contains("PomodoroTimePresentation.make"))
        #expect(source.contains("controlSize * 0.38"))
        #expect(source.contains(".accessibilityLabel(\"Pomodoro timer\")"))
        #expect(source.contains(".accessibilityValue("))
        #expect(source.contains("presentation.accessibilityHint"))
        #expect(source.contains(".accessibilityAction(named: \"Set duration\")"))
    }

    private static func source() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appending(
                path: "Echo Watch App/Views/Components/PomodoroButton.swift"
            ),
            encoding: .utf8
        )
    }
}
```

- [ ] **Step 2: Run the source contract and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchPomodoroAccessibilitySourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the assertions for the presentation model, 0.38 font multiplier, and accessibility modifiers fail against the old button.

- [ ] **Step 3: Replace the old clock formatter with the pure presentation**

In `PomodoroButton`, replace `strokeWidth` and `timeString` with:

```swift
    private var strokeWidth: CGFloat {
        WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: ringSize != nil)
    }

    private var ringProgress: Double {
        guard viewModel.pomodoroDuration.isFinite,
              viewModel.pomodoroDuration > 0,
              viewModel.pomodoroRemaining.isFinite
        else {
            return 0
        }
        return min(1, max(0, viewModel.pomodoroRemaining / viewModel.pomodoroDuration))
    }

    private var presentation: PomodoroTimePresentation {
        PomodoroTimePresentation.make(remaining: viewModel.pomodoroRemaining)
    }
```

Delete the `String(format:)`-based `timeString` property.

- [ ] **Step 4: Make the visible text larger and add exact accessibility semantics**

Replace the text block with:

```swift
                Text(presentation.digits)
                    .font(.system(size: controlSize * 0.38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: controlSize, height: controlSize)
                    .background {
                        WatchControlBackground(shape: Circle())
                    }
                    .clipShape(.circle)
```

Add these modifiers to the `Button`, after `.buttonStyle(.plain)` and before the existing simultaneous long press:

```swift
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pomodoro timer")
        .accessibilityValue(
            Text(presentation.accessibilityValue(isRunning: viewModel.pomodoroActive))
        )
        .accessibilityHint(
            Text(presentation.accessibilityHint(isRunning: viewModel.pomodoroActive))
        )
        .accessibilityAction(named: "Set duration") {
            onLongPress()
        }
```

Keep the existing `LongPressGesture(minimumDuration: 0.5)` unchanged.

- [ ] **Step 5: Add a preview helper and the real size-pair matrix**

Replace the single existing preview with:

```swift
#if DEBUG
    @MainActor
    private struct PomodoroButtonPreview: View {
        private let viewModel: WatchViewModel
        private let controlSize: CGFloat
        private let ringSize: CGFloat?

        init(
            controlSize: CGFloat,
            ringSize: CGFloat?,
            duration: TimeInterval,
            remaining: TimeInterval
        ) {
            let viewModel = WatchViewModel()
            viewModel.pomodoroDuration = duration
            viewModel.pomodoroRemaining = remaining
            viewModel.pomodoroActive = true
            self.viewModel = viewModel
            self.controlSize = controlSize
            self.ringSize = ringSize
        }

        var body: some View {
            PomodoroButton(
                viewModel: viewModel,
                controlSize: controlSize,
                ringSize: ringSize
            ) {}
        }
    }

    #Preview("Pomodoro size and unit matrix") {
        ScrollView {
            VStack(spacing: 12) {
                PomodoroButtonPreview(
                    controlSize: 38,
                    ringSize: nil,
                    duration: 2 * 3600,
                    remaining: 80 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 40,
                    ringSize: nil,
                    duration: 25 * 60,
                    remaining: 25 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 42,
                    ringSize: nil,
                    duration: 2 * 60,
                    remaining: 59
                )
                PomodoroButtonPreview(
                    controlSize: 40,
                    ringSize: 48,
                    duration: 25 * 60,
                    remaining: 12 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 42,
                    ringSize: 52,
                    duration: 2 * 3600,
                    remaining: 2 * 3600
                )
            }
        }
    }
#endif
```

- [ ] **Step 6: Run focused Watch and source tests and verify GREEN**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchPomodoroAccessibilitySourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both focused suites pass. The Watch build compiles the preview-only code in Debug without changing runtime behaviour.

- [ ] **Step 7: Format, lint, and rerun the Pomodoro tests**

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift

xcrun swift-format lint --strict --configuration .swift-format \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchPomodoroAccessibilitySourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both suites remain green after formatting.

- [ ] **Step 8: Commit the Pomodoro UI slice**

```bash
git add \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift
git diff --cached --check
git commit -m 'feat(watch): improve Pomodoro glanceability'
```

---

### Task 4: Carry the Cover Accent into Widget Timeline Entries

**Files:**
- Modify: `Echo Widget/Views/Echo_Widget.swift:7-71`
- Create: `EchoTests/WatchWidgetPresentationSourceTests.swift`

**Interfaces:**
- Consumes: The existing shared App Group key `artworkAccentColorHex` and the existing explicit-clear semantics from `WatchViewModel`.
- Produces: `SimpleEntry.artworkAccentColorHex: String?` for the rectangular view in Task 5.

- [ ] **Step 1: Write the failing provider/entry source contract**

Create `EchoTests/WatchWidgetPresentationSourceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchWidgetPresentationSourceTests {
    @Test("widget timeline entries carry the persisted cover accent")
    func widgetEntryCarriesAccent() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")

        #expect(source.contains("let artworkAccentColorHex: String?"))
        #expect(source.contains("defaults.string(forKey: \"artworkAccentColorHex\")"))
        #expect(source.contains("artworkAccentColorHex: artworkAccentColorHex"))
    }

    static func sourceIfPresent(at relativePath: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8
        )) ?? ""
    }
}
```

- [ ] **Step 2: Run the focused source test and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all three new assertions fail because the provider and entry do not yet carry the accent.

- [ ] **Step 3: Extend `SimpleEntry` and every initializer call site**

Update the entry definition to:

```swift
struct SimpleEntry: TimelineEntry {
    let date: Date
    let title: String
    let isPlaying: Bool
    let progressFraction: Double
    let thumbnailData: Data?
    let artworkAccentColorHex: String?

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: isPlaying ? 100.0 : 0.0)
    }
}
```

Update `Provider.placeholder(in:)` to pass `artworkAccentColorHex: "#FF8000"` so previews exercise a valid accent.

- [ ] **Step 4: Read the shared accent in `currentEntry()`**

Add:

```swift
        let artworkAccentColorHex = defaults.string(forKey: "artworkAccentColorHex")
```

Then pass it into the returned entry:

```swift
        return SimpleEntry(
            date: Date(),
            title: title,
            isPlaying: isPlaying,
            progressFraction: progressFraction,
            thumbnailData: thumbnailData,
            artworkAccentColorHex: artworkAccentColorHex
        )
```

- [ ] **Step 5: Run the focused source test and widget build**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Then run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo WidgetExtension' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -derivedDataPath /tmp/Echo-widget-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: source test passes and the widget extension builds successfully.

- [ ] **Step 6: Format, lint, and rerun the timeline checks**

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  'Echo Widget/Views/Echo_Widget.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift

xcrun swift-format lint --strict --configuration .swift-format \
  'Echo Widget/Views/Echo_Widget.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo WidgetExtension' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -derivedDataPath /tmp/Echo-widget-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the source test and widget build remain green after formatting.

- [ ] **Step 7: Commit the timeline-data slice**

```bash
git add \
  'Echo Widget/Views/Echo_Widget.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift
git diff --cached --check
git commit -m 'feat(watch): carry cover accent into widget timeline'
```

---

### Task 5: Circular and Rectangular Widget Presentations

**Files:**
- Modify: `Echo Widget/Views/Echo_Widget.swift:73-132`
- Create: `Echo Widget/Views/EchoWidgetEntryView.swift`
- Create: `Echo Widget/Views/EchoWidgetArtworkView.swift`
- Create: `Echo Widget/Views/EchoCircularWidgetView.swift`
- Create: `Echo Widget/Views/EchoRectangularWidgetView.swift`
- Create: `Echo Widget/Views/EchoWidgetPreviews.swift`
- Modify: `EchoTests/WatchWidgetPresentationSourceTests.swift`

**Interfaces:**
- Consumes: `SimpleEntry.artworkAccentColorHex` from Task 4, `WidgetProgressAccentPolicy` and `WatchProgressRingMetrics` from Task 1.
- Produces: `.accessoryCircular` and `.accessoryRectangular` presentations under one `Echo_Widget` configuration, with shared deep-link and accessibility semantics.

- [ ] **Step 1: Extend the source contract before creating the new views**

Replace `EchoTests/WatchWidgetPresentationSourceTests.swift` with the complete contract:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchWidgetPresentationSourceTests {
    @Test("widget timeline entries carry the persisted cover accent")
    func widgetEntryCarriesAccent() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")

        #expect(source.contains("let artworkAccentColorHex: String?"))
        #expect(source.contains("defaults.string(forKey: \"artworkAccentColorHex\")"))
        #expect(source.contains("artworkAccentColorHex: artworkAccentColorHex"))
    }

    @Test("widget declares both supported Watch families")
    func widgetFamilies() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")
        #expect(
            source.contains(
                ".supportedFamilies([.accessoryCircular, .accessoryRectangular])"
            )
        )
    }

    @Test("entry router selects focused family views")
    func familyRouter() {
        let source = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoWidgetEntryView.swift"
        )
        #expect(source.contains(#"@Environment(\.widgetFamily)"#))
        #expect(source.contains("EchoCircularWidgetView(entry: entry)"))
        #expect(source.contains("EchoRectangularWidgetView(entry: entry)"))
        #expect(source.contains(".accessibilityValue(entry.accessibilityValue)"))
        #expect(source.contains("guard progressFraction.isFinite else { return 0 }"))
    }

    @Test("circular and rectangular views use approved policies")
    func presentationPolicies() {
        let circular = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoCircularWidgetView.swift"
        )
        let rectangular = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoRectangularWidgetView.swift"
        )

        #expect(circular.contains("WatchProgressRingMetrics.complicationLineWidth"))
        #expect(circular.contains("WatchProgressRingMetrics.complicationInset"))
        #expect(circular.contains("EchoWidgetArtworkView"))
        #expect(circular.contains(".widgetAccentable()"))
        #expect(rectangular.contains(#"@Environment(\.widgetRenderingMode)"#))
        #expect(rectangular.contains("renderingMode == .fullColor"))
        #expect(rectangular.contains("WidgetProgressAccentPolicy.style"))
        #expect(rectangular.contains("WatchProgressRingMetrics.rectangularGaugeHeight"))
        #expect(rectangular.contains("EchoWidgetArtworkView"))
    }

    static func sourceIfPresent(at relativePath: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8
        )) ?? ""
    }
}
```

- [ ] **Step 2: Run the focused source test and verify RED**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the family and new-file assertions fail. Missing files resolve to empty strings so this is an assertion failure, not a file-read error.

- [ ] **Step 3: Reduce `Echo_Widget.swift` to provider, entry, and configuration**

Remove the existing `Echo_WidgetEntryView` definition from `Echo_Widget.swift`. Keep `Provider` and `SimpleEntry`, then update the configuration tail to:

```swift
struct Echo_Widget: Widget {
    let kind: String = "Echo_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            Echo_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Echo")
        .description("Current audiobook and progress at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
```

- [ ] **Step 4: Add the family router and common semantics**

Create `Echo Widget/Views/EchoWidgetEntryView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct Echo_WidgetEntryView: View {
    let entry: SimpleEntry

    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        Group {
            if widgetFamily == .accessoryRectangular {
                EchoRectangularWidgetView(entry: entry)
            } else {
                EchoCircularWidgetView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "echoaudio://play"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityValue)
    }
}

extension SimpleEntry {
    var clampedProgress: Double {
        guard progressFraction.isFinite else { return 0 }
        return min(1, max(0, progressFraction))
    }

    var playbackStateText: String {
        isPlaying ? String(localized: "Playing") : String(localized: "Paused")
    }

    var progressPercentageText: String {
        clampedProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    var accessibilityValue: String {
        "\(playbackStateText), \(progressPercentageText)"
    }
}
```

- [ ] **Step 5: Add the shared artwork presentation**

Create `Echo Widget/Views/EchoWidgetArtworkView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct EchoWidgetArtworkView: View {
    enum Presentation {
        case circular
        case rectangular
    }

    let thumbnailData: Data?
    let presentation: Presentation

    var body: some View {
        if let thumbnailData, let image = UIImage(data: thumbnailData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            switch presentation {
            case .circular:
                Image(systemName: "music.note")
            case .rectangular:
                Image(systemName: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
        }
    }
}
```

- [ ] **Step 6: Add the safely inset, bolder circular presentation**

Create `Echo Widget/Views/EchoCircularWidgetView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct EchoCircularWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        ZStack {
            EchoWidgetArtworkView(
                thumbnailData: entry.thumbnailData,
                presentation: .circular
            )
                .clipShape(.circle)
                .padding(WatchProgressRingMetrics.complicationArtworkPadding)

            ZStack {
                Circle()
                    .stroke(
                        .secondary.opacity(0.3),
                        lineWidth: WatchProgressRingMetrics.complicationLineWidth
                    )

                Circle()
                    .trim(from: 0, to: entry.clampedProgress)
                    .stroke(
                        .tint,
                        style: StrokeStyle(
                            lineWidth: WatchProgressRingMetrics.complicationLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()

                GeometryReader { geometry in
                    let radius = min(geometry.size.width, geometry.size.height) / 2
                    let angle = entry.clampedProgress * 2 * .pi - .pi / 2
                    Circle()
                        .fill(.tint)
                        .frame(
                            width: WatchProgressRingMetrics.complicationMarkerDiameter,
                            height: WatchProgressRingMetrics.complicationMarkerDiameter
                        )
                        .position(
                            x: geometry.size.width / 2 + radius * CGFloat(cos(angle)),
                            y: geometry.size.height / 2 + radius * CGFloat(sin(angle))
                        )
                        .widgetAccentable()
                }
            }
            .padding(WatchProgressRingMetrics.complicationInset)
        }
    }
}
```

The inner 4 pt padding provides room for the 3 pt half-stroke and 4 pt marker radius, preventing clipping without changing the complication's external frame.

- [ ] **Step 7: Add the rendering-aware rectangular presentation**

Create `Echo Widget/Views/EchoRectangularWidgetView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct EchoRectangularWidgetView: View {
    let entry: SimpleEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 8) {
            EchoWidgetArtworkView(
                thumbnailData: entry.thumbnailData,
                presentation: .rectangular
            )
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.caption)
                    .bold()
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(entry.playbackStateText)
                    Spacer(minLength: 0)
                    Text(entry.progressPercentageText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.25))
                        Capsule()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * entry.clampedProgress)
                            .widgetAccentable()
                    }
                }
                .frame(height: WatchProgressRingMetrics.rectangularGaugeHeight)
            }
        }
    }

    private var progressColor: Color {
        switch WidgetProgressAccentPolicy.style(
            accentHex: entry.artworkAccentColorHex,
            preservesExactCoverColor: renderingMode == .fullColor
        ) {
        case .systemTint:
            return .accentColor
        case .cover(let rgb):
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
    }
}
```

The custom capsule is intentional: `ProgressView` does not guarantee the approved 5 pt gauge thickness.

- [ ] **Step 8: Add family and rendering-mode previews**

Create `Echo Widget/Views/EchoWidgetPreviews.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

#if DEBUG
    extension SimpleEntry {
        static let previewPaused = SimpleEntry(
            date: .now,
            title: "A Paused Book",
            isPlaying: false,
            progressFraction: 0,
            thumbnailData: nil,
            artworkAccentColorHex: nil
        )

        static let previewPlaying = SimpleEntry(
            date: .now,
            title: "The Current Book",
            isPlaying: true,
            progressFraction: 0.42,
            thumbnailData: nil,
            artworkAccentColorHex: "#FF8000"
        )

        static let previewComplete = SimpleEntry(
            date: .now,
            title: "A Finished Book",
            isPlaying: false,
            progressFraction: 1,
            thumbnailData: nil,
            artworkAccentColorHex: "#GG0000"
        )
    }

    #Preview("Circular", as: .accessoryCircular) {
        Echo_Widget()
    } timeline: {
        SimpleEntry.previewPaused
        SimpleEntry.previewPlaying
        SimpleEntry.previewComplete
    }

    #Preview("Rectangular", as: .accessoryRectangular) {
        Echo_Widget()
    } timeline: {
        SimpleEntry.previewPaused
        SimpleEntry.previewPlaying
        SimpleEntry.previewComplete
    }

    #Preview("Rectangular full colour") {
        EchoRectangularWidgetView(entry: .previewPlaying)
            .environment(\.widgetRenderingMode, .fullColor)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular accented") {
        EchoRectangularWidgetView(entry: .previewPlaying)
            .environment(\.widgetRenderingMode, .accented)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular vibrant") {
        EchoRectangularWidgetView(entry: .previewComplete)
            .environment(\.widgetRenderingMode, .vibrant)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular full-colour fallback") {
        EchoRectangularWidgetView(entry: .previewPaused)
            .environment(\.widgetRenderingMode, .fullColor)
            .frame(width: 170, height: 60)
    }
#endif
```

- [ ] **Step 9: Run the source contract, shared tests, and widget build**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchProgressRingMetricsTests \
  -only-testing:EchoTests/WidgetAccentColorTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo WidgetExtension' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -derivedDataPath /tmp/Echo-widget-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all focused tests pass and `Echo WidgetExtension` builds for watchOS 11+ with both families.

- [ ] **Step 10: Format changed Swift files and re-run focused verification**

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  'Echo Widget/Views/Echo_Widget.swift' \
  'Echo Widget/Views/EchoWidgetEntryView.swift' \
  'Echo Widget/Views/EchoWidgetArtworkView.swift' \
  'Echo Widget/Views/EchoCircularWidgetView.swift' \
  'Echo Widget/Views/EchoRectangularWidgetView.swift' \
  'Echo Widget/Views/EchoWidgetPreviews.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift

xcrun swift-format lint --strict --configuration .swift-format \
  'Echo Widget/Views/Echo_Widget.swift' \
  'Echo Widget/Views/EchoWidgetEntryView.swift' \
  'Echo Widget/Views/EchoWidgetArtworkView.swift' \
  'Echo Widget/Views/EchoCircularWidgetView.swift' \
  'Echo Widget/Views/EchoRectangularWidgetView.swift' \
  'Echo Widget/Views/EchoWidgetPreviews.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchWidgetPresentationSourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchProgressRingMetricsTests \
  -only-testing:EchoTests/WidgetAccentColorTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo WidgetExtension' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -derivedDataPath /tmp/Echo-widget-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all focused tests and the widget build remain green after formatting.

- [ ] **Step 11: Commit the widget presentation slice**

```bash
git add \
  'Echo Widget/Views/Echo_Widget.swift' \
  'Echo Widget/Views/EchoWidgetEntryView.swift' \
  'Echo Widget/Views/EchoWidgetArtworkView.swift' \
  'Echo Widget/Views/EchoCircularWidgetView.swift' \
  'Echo Widget/Views/EchoRectangularWidgetView.swift' \
  'Echo Widget/Views/EchoWidgetPreviews.swift' \
  EchoTests/WatchWidgetPresentationSourceTests.swift
git diff --cached --check
git commit -m 'feat(watch): add Smart Stack progress card'
```

---

### Task 6: Documentation, Full Verification, Review, and Publication

**Files:**
- Modify: `CHANGELOG.md:5-10`
- Modify: `README.md:128-143,215-229`
- Modify: `ARCHITECTURE.md:1492-1498,1513`
- Verify: every source/test file changed in Tasks 1-5
- External receipt after hosted green: `/Users/dfakkeldy/Developer/knowledge-base/bundle/status/2026-07-11-echo-watch-progress-smart-stack.md` plus the scoped Echo project/status index/log entries in a clean KB worktree

**Interfaces:**
- Consumes: All implementation slices and their green focused tests.
- Produces: User-facing release notes, updated architecture truth, an exact-SHA review, a ready PR to `nightly`, hosted-CI evidence, and a durable KB receipt.

- [ ] **Step 1: Update release and architecture documentation**

Add one `CHANGELOG.md` item under `Unreleased -> Added` that states:

```markdown
- **Richer Apple Watch progress surfaces:** Echo now offers a rectangular Smart Stack/complication card with cover, title, playback state, percentage, and a bold progress gauge. Full-colour Smart Stack rendering uses the current cover-derived accent; system-coloured watch-face appearances retain WidgetKit tint. The circular complication has a thicker safely inset ring, while the Watch Pomodoro uses bolder rings and a larger adaptive two-digit hours/minutes/seconds countdown with complete VoiceOver state and a named Set Duration action.
```

In `README.md`, replace the Overview paragraph beginning `Echo is a full-featured` with:

```markdown
Echo is a full-featured audiobook study application organized as a single Xcode workspace with four distinct targets. It supports bookmarking with optional voice memos, chapter navigation, loop modes, a sleep timer, variable playback speed, and intelligent rewind logic that adapts to pause duration. The iOS and watchOS apps communicate bidirectionally via WatchConnectivity, while the watchOS widget displays current artwork and progress in circular watch-face and rectangular Smart Stack/complication families. iPhone Lock Screen controls come from the system Now Playing integration, not the watch-only widget extension.
```

Replace the `Echo Widget` target-table row with:

```markdown
| **Echo Widget** (`watchOS`) | `Echo_WidgetBundle.swift` → `Echo_Widget.swift` | The watchOS widget extension exposes `.accessoryCircular` and `.accessoryRectangular` families through the Watch App's `AppGroupDefaults`. Circular rendering shows the current thumbnail inside a bold system-tinted progress ring. The rectangular Smart Stack/complication card adds title, playback state, percentage, and a bold gauge; it uses the cover-derived accent only in WidgetKit full-colour rendering and adopts the watch-face palette in accented or vibrant rendering. The source includes an iOS Control Widget implementation behind a platform gate, but the current extension target is watchOS-only. |
```

Replace the existing circular-complication accessibility bullet and add the Pomodoro bullet immediately after it:

```markdown
- Both Watch complication families combine title, playback state, and percentage into one VoiceOver element so colour is never the only signal. The circular ring always joins WidgetKit's system accent group; the rectangular gauge uses the cover-derived accent only in full-colour rendering and otherwise follows the system palette.
- The Watch Pomodoro shows exactly two large digits, changing from upward-rounded hours to minutes at 60 minutes and from minutes to seconds at 60 seconds. VoiceOver announces running/stopped/complete state plus the full unit and exposes a named **Set duration** action alongside the unchanged physical long press.
```

In `ARCHITECTURE.md`, replace the `**Integration:**` paragraph at the end of Cover-Derived Theming with:

```markdown
**Integration:** `PlayerModel.coverTheme` (cached per artwork version + `uiColorScheme`); `PlayerModel.artworkAccentColor` remains the compatibility facade (nil for neutral covers so `?? .accentColor` fallbacks engage). `artworkAccentColorHex` sends the **dark-recipe** accent to the Watch app, which persists the explicit value or clear state in the App Group. The widget provider copies that value into `SimpleEntry`. `WidgetProgressAccentPolicy` permits the rectangular gauge to resolve exact RGB only when `widgetRenderingMode == .fullColor`; missing, cleared, malformed, accented, and vibrant cases use semantic system tint. The `.accessoryCircular` family always joins WidgetKit's system accent group because its shipping appearances do not preserve Echo's exact RGB.

**Pomodoro presentation:** `PomodoroTimePresentation` is a platform-independent Watch value that turns the authoritative remaining interval into exactly two digits plus localized VoiceOver state. It shows upward-rounded hours above 60 minutes, minutes above 60 seconds, seconds through completion, and defensively saturates finite values above 99 hours. `WatchProgressRingMetrics` owns the approved 5 pt side/top and 6 pt centre ring widths. Neither type changes Pomodoro timing, persistence, haptics, picker limits, or interaction handling.
```

- [ ] **Step 2: Commit the release and architecture documentation**

```bash
git add CHANGELOG.md README.md ARCHITECTURE.md
git diff --cached --check
git commit -m 'docs: document Watch progress surfaces'
git status --short --branch
```

Expected: the worktree is clean and the branch contains only the approved spec, this plan, implementation/test commits, and documentation.

- [ ] **Step 3: Rebase onto current `nightly` before final verification**

```bash
git fetch origin nightly
git rebase origin/nightly
git status --short --branch
git diff --check origin/nightly...HEAD
```

Expected: the rebase completes with a clean worktree and the branch remains based on `origin/nightly`. Stop and report rather than forcing a conflict that cannot be resolved cleanly.

- [ ] **Step 4: Run static quality gates**

```bash
git diff --check origin/nightly...HEAD
! rg -n 'String\(format:' \
  'Echo Watch App/Models/PomodoroTimePresentation.swift' \
  'Echo Watch App/Views/Components/PomodoroButton.swift'
```

Expected: both commands are silent and successful; no C-style formatting remains in the two Pomodoro files.

Run one final strict lint across every changed Swift file:

```bash
xcrun swift-format lint --strict --configuration .swift-format \
  Shared/WatchProgressRingMetrics.swift \
  Shared/WidgetAccentColor.swift \
  'Echo Watch App/Models/PomodoroTimePresentation.swift' \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  'Echo Widget/Views/Echo_Widget.swift' \
  'Echo Widget/Views/EchoWidgetEntryView.swift' \
  'Echo Widget/Views/EchoWidgetArtworkView.swift' \
  'Echo Widget/Views/EchoCircularWidgetView.swift' \
  'Echo Widget/Views/EchoRectangularWidgetView.swift' \
  'Echo Widget/Views/EchoWidgetPreviews.swift' \
  'Echo Watch AppTests/PomodoroTimePresentationTests.swift' \
  EchoTests/WatchProgressRingMetricsTests.swift \
  EchoTests/WidgetAccentColorTests.swift \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift \
  EchoTests/WatchWidgetPresentationSourceTests.swift
```

- [ ] **Step 5: Run all Watch unit tests without UI tests**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the complete Watch unit target passes with zero failures.

- [ ] **Step 6: Run the complete iOS test target**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-progress-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: result `Passed`, zero failed tests; existing intentional skips are acceptable and must be counted in the handoff.

- [ ] **Step 7: Build the real widget, macOS, and CLI targets**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo WidgetExtension' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -derivedDataPath /tmp/Echo-widget-progress-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo macOS' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/Echo-watch-progress-mac-dd \
  CODE_SIGNING_ALLOWED=NO
```

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme echo-cli \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/Echo-watch-progress-cli-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all three builds succeed. These builds are required because the new shared files compile into every target.

- [ ] **Step 8: Perform simulator and physical-device visual checks**

Verify on the smallest and largest available Watch layouts:

- side `38/38`, top `40/40` and `42/42`, centre `40/48` and `42/52` Pomodoro combinations;
- 2-hour, 60-minute, 25-minute, 60-second, 59-second, stopped, and complete timer states;
- VoiceOver label/value/hint and the named `Set duration` action;
- circular ring/marker clipping and artwork clearance;
- rectangular full-colour, accented, and vibrant appearances;
- missing thumbnail, missing accent, malformed accent, paused state, and progress 0/42/100 percent; and
- Always On legibility.

If physical hardware is unavailable, report these items as pending rather than treating simulator previews as device proof.

- [ ] **Step 9: Run an independent exact-SHA review**

Record `git rev-parse HEAD`, then dispatch a fresh read-only reviewer against that exact SHA. Require findings grouped as Critical, Important, and Minor. The reviewer must verify:

- the adaptive boundary/rounding table and overflow semantics;
- visible and VoiceOver state consistency;
- physical long press and tap behaviour remain unchanged;
- merged PR #436's iPhone Lock Screen/Now Playing publishing paths remain unchanged and its regression tests still pass;
- circular colour remains system-owned;
- rectangular exact RGB is gated by `.fullColor`;
- explicit empty accent resolves to system tint;
- widget family and target availability remain watchOS 11 compatible;
- source tests do not substitute for building the widget target; and
- no unrelated user changes or deployment-target changes entered the diff.

Fix every Critical/Important finding through a new failing test and rerun proportionate verification. Record justified Minor deferrals explicitly. If the review causes a code or test commit, review the new exact SHA again and do not publish until no Critical or Important finding remains.

- [ ] **Step 10: Publish a ready PR to `nightly`**

```bash
git status --short --branch
git diff --check origin/nightly...HEAD
git push -u origin codex/watch-progress-smart-stack
gh pr create \
  --base nightly \
  --head codex/watch-progress-smart-stack \
  --title 'feat: improve Watch progress surfaces' \
  --body-file /tmp/echo-watch-progress-pr-body.md
```

Before `gh pr create`, use `apply_patch` to create `/tmp/echo-watch-progress-pr-body.md` with these exact sections:

- `## Summary`: the rectangular Smart Stack card, bolder circular/Pomodoro rings, and adaptive two-digit Pomodoro display;
- `## Verification`: the final Watch/iOS test result counts and successful widget/macOS/CLI build commands from Steps 5-7;
- `## Rendering boundary`: exact cover RGB is used only by `.accessoryRectangular` in `.fullColor`; system-coloured modes and the circular family use WidgetKit tint; and
- `## Hardware boundary`: the exact physical checks completed, or an explicit statement that hardware-only checks remain pending.

Do not mark the PR draft. Use `--force-with-lease` only if this branch was previously pushed and the Step 3 rebase rewrote it.

- [ ] **Step 11: Follow hosted CI to a terminal result**

```bash
gh pr checks --watch --interval 30
```

Expected: `Build gate + tests` passes. If it fails, inspect the failing Actions job log, reproduce the concrete failure locally where possible, add or update a regression test, push the fix, and watch the new run. Do not call the PR complete while checks are pending.

- [ ] **Step 12: Publish the durable knowledge-base receipt after hosted green**

In a clean knowledge-base worktree based on current `origin/main`:

1. Create `bundle/status/2026-07-11-echo-watch-progress-smart-stack.md` with the Echo PR/SHA, local test counts, hosted run URL, exact rendering-mode boundary, and physical-device status.
2. Add a concise link to `bundle/status/index.md`.
3. Update the Watch section of `bundle/projects/echo.md` without changing portfolio priority.
4. Add one newest-first entry to `bundle/log.md` noting that MacroMark remains Most Important Now.
5. Run `python3 tools/kb_lint.py` and `git diff --check`.
6. Commit `docs: record Echo Watch progress surfaces`, rebase on `origin/main`, push, open a ready PR to `main`, and follow KB CI/auto-merge to completion.

Final handoff must link both PRs, state the Echo hosted-CI result, list exact local verification, identify any unperformed physical checks, and show clean status for every touched worktree.
