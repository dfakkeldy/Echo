# Watch Pomodoro Time Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the Echo Watch Pomodoro's largest two-digit time style from `.title2` to `.headline` while preserving semantic fitting and all existing behavior.

**Architecture:** Keep the existing `PomodoroButton` and `PomodoroDigits` structure. Tighten only the ordered `ViewThatFits` typography candidates, then protect the decision with the existing source-contract test and verify the unchanged time-presentation model and Watch build.

**Tech Stack:** Swift 6.0, SwiftUI, watchOS 11.0+, Swift Testing, Xcode 26.6.

## Global Constraints

- Preserve iOS 18.0, macOS 15.0, and watchOS 11.0 deployment targets.
- Do not add dependencies or change timer state, persistence, haptics, gestures, picker limits, ring geometry, title scrolling, or VoiceOver semantics.
- Keep rounded bold monospaced digits and semantic Dynamic Type styles; do not introduce a fixed point size.
- Run all `xcodebuild` commands through `$HOME/.claude/bin/xcode-build-gate.sh --wait` and keep parallel testing disabled.

---

### Task 1: Reduce the Watch Pomodoro Time

**Files:**
- Modify: `EchoTests/WatchPomodoroAccessibilitySourceTests.swift:6-15`
- Modify: `Echo Watch App/Views/Components/PomodoroButton.swift:59-64`

**Interfaces:**
- Consumes: `PomodoroDigits.init(_:textStyle:)` and the existing `ViewThatFits` candidate order.
- Produces: A `.headline`-first Pomodoro time with `.subheadline` and `.caption` fitting fallbacks.

- [ ] **Step 1: Change the source contract to describe the approved typography**

Replace the typography expectations in `pomodoroAccessibilityContract()` with:

```swift
        #expect(source.contains("ViewThatFits"))
        #expect(source.contains("textStyle: .headline"))
        #expect(source.contains("textStyle: .subheadline"))
        #expect(source.contains("textStyle: .caption"))
        #expect(!source.contains("textStyle: .title2"))
        #expect(source.contains(".system(textStyle"))
        #expect(!source.contains(".system(size:"))
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
  -derivedDataPath /tmp/Echo-watch-pomodoro-size-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `PomodoroButton.swift` still contains `textStyle: .title2`.

- [ ] **Step 3: Implement the minimal typography change**

Replace the Pomodoro `ViewThatFits` block with:

```swift
                ViewThatFits {
                    PomodoroDigits(presentation.digits, textStyle: .headline)
                    PomodoroDigits(presentation.digits, textStyle: .subheadline)
                    PomodoroDigits(presentation.digits, textStyle: .caption)
                }
```

Do not change the surrounding foreground style, frame, ring layers, button modifiers, or `PomodoroDigits` helper.

- [ ] **Step 4: Format, lint, and verify the focused tests GREEN**

Run:

```bash
xcrun swift-format format --in-place --configuration .swift-format \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift

xcrun swift-format lint --strict --configuration .swift-format \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift
```

Then run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:EchoTests/WatchPomodoroAccessibilitySourceTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-pomodoro-size-ios-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the formatter and lint commands are silent and successful; the focused source-contract suite passes.

- [ ] **Step 5: Verify unchanged Pomodoro presentation behavior**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'platform=watchOS Simulator,name=EchoProgress-Watch,OS=26.5' \
  -only-testing:'Echo Watch AppTests/PomodoroTimePresentationTests' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Echo-watch-pomodoro-size-watch-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all `PomodoroTimePresentationTests` pass, confirming that unit selection, rounding, and accessibility descriptions are unchanged.

- [ ] **Step 6: Build the Watch app and inspect the real-size preview**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme 'Echo Watch App' \
  -destination 'generic/platform=watchOS Simulator' \
  -parallelizeTargets NO \
  -derivedDataPath /tmp/Echo-watch-pomodoro-size-build-dd \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

Inspect the existing `Pomodoro size and unit matrix` preview's 40-point, 25-minute case. Confirm the `25` is centered and unclipped, with visibly more clearance from the ring than the prior `.title2` treatment.

- [ ] **Step 7: Commit the implementation**

```bash
git add \
  'Echo Watch App/Views/Components/PomodoroButton.swift' \
  EchoTests/WatchPomodoroAccessibilitySourceTests.swift
git diff --cached --check
git commit -m 'fix(watch): reduce Pomodoro time size'
```

