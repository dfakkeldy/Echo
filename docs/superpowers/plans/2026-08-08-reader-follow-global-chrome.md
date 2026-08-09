# Reliable Reader Follow and Global Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sidecar word timing refresh reliably in an already-open Reader, keep the spoken line magnetically centered only while following playback, preserve manual exploration until an explicit return, expose the folder control across the main app hierarchy without overlap, and make the dock's passage action report an honest result.

**Architecture:** `RootTabView` owns a two-state `ReaderFollowState`, the return request, and transient dock feedback. `ReaderTab` owns timing-cache reload and active-text resolution. `ReaderFeedCollectionView.Coordinator` is the only component allowed to mutate the Reader viewport and validates every scheduled mutation against a generation plus the follow state. Small pure policies cover state transitions, centering math, and passage-result mapping; existing concrete SwiftUI/UIKit, GRDB, Observation, and closure injection patterns remain in place.

**Tech Stack:** Swift 6, SwiftUI, UIKit `UICollectionView`, Observation, GRDB, Swift Testing, iOS 18.

## Global Constraints

- Implement from the approved design at `docs/superpowers/specs/2026-08-08-reader-follow-global-chrome-design.md`; do not change the audiobook skill, renderer, sidecar format, macOS UI, watchOS UI, schema, deployment floors, or dependencies.
- Execute the implementation with a `gpt-5.6-terra` worker. After all implementation checks, give the complete diff and test evidence to an independent `gpt-5.6-sol` reviewer. The implementation worker must address valid review findings and obtain a final clean review before publication.
- Work only on `feature/reader-follow-global-chrome`. Preserve the unrelated untracked `docs/superpowers/plans/2026-08-02-macos-performance-remediation.md` and `file.txt` exactly as found.
- Follow test-driven development: add the focused failing test, observe the red result, make the smallest production change, rerun the focused test, then commit that task.
- Every Apple build or test command must run through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh --` followed by the concrete command shown in each task. Do not use `XBG_ALLOW_NOW=1` unless the user separately requests an immediate off-hours build.
- Use `make build-tests` to compile new test files and each task's concrete `make test-only FILTER=EchoTests/ReaderFollowStateTests`-style command for focused loops. Run the full `make test` gate at the end, also through the build-slot wrapper.
- Keep user-facing controls localizable, at least 44 points, Dynamic Type safe, VoiceOver-labelled, and Reduce Motion aware.
- Do not add a protocol. The only new seams are value types and closures with a current production use and direct tests.
- Use Conventional Commits. Do not push or open a PR until the Sol review is clean and the final verification gate passes.

---

### Task 1: Model follow, exploration, and queued-scroll validity as pure state

**Files:**
- Create: `EchoCore/ViewModels/ReaderFollowState.swift`
- Create: `EchoTests/ReaderFollowStateTests.swift`

**Interfaces:**
- Produces: `ReaderFollowState`, `ReaderScrollIntent`, `ReaderScrollPermission.allows(intent:followState:scheduledGeneration:currentGeneration:)`.
- Consumes: no app state; this is a pure, `Sendable` policy used by the Reader root and collection coordinator.

- [ ] **Step 1: Add the failing state-transition and generation tests**

```swift
// EchoTests/ReaderFollowStateTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderFollowStateTests {
    @Test func manualExplorationDetachesUntilResolvedReturn() {
        var state = ReaderFollowState.following
        state.detachForExploration()
        #expect(state == .exploring)

        #expect(state.completeReturn(targetResolved: false) == false)
        #expect(state == .exploring)

        #expect(state.completeReturn(targetResolved: true))
        #expect(state == .following)
    }

    @Test func queuedPlaybackScrollIsRejectedAfterDetachment() {
        #expect(
            ReaderScrollPermission.allows(
                intent: .followPlayback,
                followState: .following,
                scheduledGeneration: 7,
                currentGeneration: 7
            )
        )
        #expect(
            ReaderScrollPermission.allows(
                intent: .followPlayback,
                followState: .exploring,
                scheduledGeneration: 7,
                currentGeneration: 8
            ) == false
        )
    }

    @Test func explicitReturnMayMoveWhileExploringButStillHonorsCancellation() {
        #expect(
            ReaderScrollPermission.allows(
                intent: .returnToCurrent,
                followState: .exploring,
                scheduledGeneration: 3,
                currentGeneration: 3
            )
        )
        #expect(
            ReaderScrollPermission.allows(
                intent: .returnToCurrent,
                followState: .exploring,
                scheduledGeneration: 3,
                currentGeneration: 4
            ) == false
        )
    }
}
```

- [ ] **Step 2: Run the new suite and observe the expected compile failure**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: `ReaderFollowState`, `ReaderScrollIntent`, and `ReaderScrollPermission` are undefined.

- [ ] **Step 3: Implement the pure state and permission policy**

```swift
// EchoCore/ViewModels/ReaderFollowState.swift
// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated enum ReaderFollowState: Equatable, Sendable {
    case following
    case exploring

    var allowsPlaybackMovement: Bool { self == .following }

    mutating func detachForExploration() {
        self = .exploring
    }

    @discardableResult
    mutating func completeReturn(targetResolved: Bool) -> Bool {
        guard targetResolved else { return false }
        self = .following
        return true
    }
}

nonisolated enum ReaderScrollIntent: Equatable, Sendable {
    case followPlayback
    case returnToCurrent
}

nonisolated enum ReaderScrollPermission {
    static func allows(
        intent: ReaderScrollIntent,
        followState: ReaderFollowState,
        scheduledGeneration: UInt,
        currentGeneration: UInt
    ) -> Bool {
        guard scheduledGeneration == currentGeneration else { return false }
        switch intent {
        case .followPlayback:
            return followState.allowsPlaybackMovement
        case .returnToCurrent:
            return true
        }
    }
}
```

- [ ] **Step 4: Build and run the focused suite**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFollowStateTests
```

Expected: all three tests pass.

- [ ] **Step 5: Commit the pure follow contract**

```bash
git add EchoCore/ViewModels/ReaderFollowState.swift EchoTests/ReaderFollowStateTests.swift
git commit -m "feat(reader): model follow and exploration state"
```

---

### Task 2: Replace the broad readable band with magnetic line-centering math

**Files:**
- Modify: `EchoCore/ViewModels/ReaderWordFollowScroll.swift`
- Modify: `EchoTests/ReaderWordFollowScrollTests.swift`

**Interfaces:**
- Produces: `ReaderWordFollowScroll.preferredRange(wordLine:paragraph:)` and `targetOffsetY(currentOffsetY:viewportHeight:contentHeight:targetRange:topInset:bottomInset:tolerance:)`.
- Consumes: collection-coordinate line or paragraph bounds and adjusted content insets.

- [ ] **Step 1: Replace the existing readable-band expectations with magnetic-centering tests**

```swift
// EchoTests/ReaderWordFollowScrollTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderWordFollowScrollTests {
    @Test func centersLineEvenWhenItIsAlreadyVisible() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 100,
                viewportHeight: 500,
                contentHeight: 2_000,
                targetRange: 240 ... 270,
                topInset: 64,
                bottomInset: 120
            )
        )
        #expect(abs(target - 33) < 0.001)
    }

    @Test func repeatedWordOnSameRenderedLineDoesNotMoveAgain() {
        let target = ReaderWordFollowScroll.targetOffsetY(
            currentOffsetY: 33,
            viewportHeight: 500,
            contentHeight: 2_000,
            targetRange: 240 ... 270,
            topInset: 64,
            bottomInset: 120
        )
        #expect(target == nil)
    }

    @Test func clampsAtBothContentEdges() throws {
        let start = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 300,
                viewportHeight: 500,
                contentHeight: 2_000,
                targetRange: 5 ... 25,
                topInset: 64,
                bottomInset: 120
            )
        )
        let end = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 900,
                viewportHeight: 500,
                contentHeight: 1_600,
                targetRange: 1_560 ... 1_590,
                topInset: 64,
                bottomInset: 120
            )
        )
        #expect(start == -64)
        #expect(end == 1_220)
    }

    @Test func wordLineWinsOverParagraphFallback() {
        #expect(
            ReaderWordFollowScroll.preferredRange(
                wordLine: 420 ... 450,
                paragraph: 300 ... 800
            ) == (420 ... 450)
        )
        #expect(
            ReaderWordFollowScroll.preferredRange(
                wordLine: nil,
                paragraph: 300 ... 800
            ) == (300 ... 800)
        )
    }
}
```

- [ ] **Step 2: Run the focused suite and observe the signature mismatch**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: the new `targetRange`, `topInset`, `bottomInset`, and `preferredRange` API does not exist.

- [ ] **Step 3: Implement usable-viewport centering and edge clamping**

```swift
// EchoCore/ViewModels/ReaderWordFollowScroll.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum ReaderWordFollowScroll {
    static func preferredRange(
        wordLine: ClosedRange<Double>?,
        paragraph: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        wordLine ?? paragraph
    }

    static func targetOffsetY(
        currentOffsetY: Double,
        viewportHeight: Double,
        contentHeight: Double,
        targetRange: ClosedRange<Double>,
        topInset: Double,
        bottomInset: Double,
        tolerance: Double = 0.5
    ) -> Double? {
        guard viewportHeight > 0, contentHeight > 0 else { return nil }

        let safeTopInset = max(0, topInset)
        let safeBottomInset = max(0, bottomInset)
        let usableHeight = max(1, viewportHeight - safeTopInset - safeBottomInset)
        let usableCenter = safeTopInset + usableHeight / 2
        let targetCenter = (targetRange.lowerBound + targetRange.upperBound) / 2
        let desiredOffset = targetCenter - usableCenter
        let minimumOffset = -safeTopInset
        let maximumOffset = max(
            minimumOffset,
            contentHeight - viewportHeight + safeBottomInset
        )
        let clampedOffset = min(maximumOffset, max(minimumOffset, desiredOffset))

        guard abs(clampedOffset - currentOffsetY) >= tolerance else { return nil }
        return clampedOffset
    }
}
```

- [ ] **Step 4: Run the focused suite**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderWordFollowScrollTests
```

Expected: all four magnetic-centering tests pass.

- [ ] **Step 5: Commit the centering policy**

```bash
git add EchoCore/ViewModels/ReaderWordFollowScroll.swift EchoTests/ReaderWordFollowScrollTests.swift
git commit -m "feat(reader): center the active spoken line"
```

---

### Task 3: Refresh stale word caches and gate chapter expansion on following

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Modify: `EchoTests/ReaderFeedViewModelAccordionTests.swift`
- Create: `EchoTests/ReaderTimingRefreshTests.swift`

**Interfaces:**
- Produces: `PlayerModel.documentIngestionTrigger` and the `allowsPlaybackFollowing` argument on `ReaderFeedViewModel.updateActiveBlock`.
- Removes: `ReaderFeedViewModel`'s private notification observer; `ReaderTab` becomes the single reload/coalescing owner in Task 5.
- Consumes: the existing `PlaybackState.documentIngestionTrigger`, `WordTimingDAO`, and `ReaderActiveBlockResolver`.

- [ ] **Step 1: Add a regression test proving reload turns a stale paragraph highlight into a word highlight**

```swift
// EchoTests/ReaderTimingRefreshTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderTimingRefreshTests {
    @Test func reloadPicksUpWordsInsertedAfterInitialReaderLoad() throws {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)"
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                        (id, audiobook_id, spine_href, spine_index, block_index,
                         sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES
                        ('b1', 'book', 'chapter.xhtml', 0, 0, 0,
                         'paragraph', 'One tool remains', 0, 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                        (id, audiobook_id, item_type, title, audio_start_time,
                         audio_end_time, epub_block_id, alignment_status)
                    VALUES
                        ('t1', 'book', 'paragraph', 'Paragraph', 0, 4, 'b1', 'auto')
                    """
            )
        }

        let viewModel = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        viewModel.reload()
        viewModel.updateActiveBlock(time: 1.25, currentTrackChapterIndices: nil)
        #expect(viewModel.activeBlockID == "b1")
        #expect(viewModel.activeWord == nil)

        try WordTimingDAO(db: service.writer).insert([
            WordTimingRecord(
                audiobookID: "book",
                epubBlockID: "b1",
                wordIndex: 0,
                word: "One",
                audioStartTime: 1,
                audioEndTime: 1.5,
                confidence: 1,
                source: "sidecar"
            )
        ])

        viewModel.reload()
        viewModel.updateActiveBlock(time: 1.25, currentTrackChapterIndices: nil)
        #expect(viewModel.activeWord?.blockID == "b1")
        #expect(viewModel.activeWord?.index == 0)
    }
}
```

- [ ] **Step 2: Extend the accordion suite with the exploration invariant**

Append to `ReaderFeedViewModelAccordionTests`:

```swift
@Test func playbackDoesNotExpandAChapterWhileExploring() throws {
    let db = try seed()
    let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
    vm.reload()

    vm.updateActiveBlock(
        time: 100,
        currentTrackChapterIndices: nil,
        isPlaying: true,
        allowsPlaybackFollowing: false
    )

    #expect(vm.activeBlockID == "c1-p")
    #expect(vm.openChapterKey == nil)
}
```

- [ ] **Step 3: Build tests and observe the missing argument and durable trigger API**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: `allowsPlaybackFollowing` is not accepted. The new timing test should compile against existing DAO APIs and fail only if the cache does not refresh.

- [ ] **Step 4: Expose the durable generation and gate auto-expansion**

Add near the existing `hasEPUB` computed property in `PlayerModel.swift`:

```swift
var documentIngestionTrigger: Int {
    state.documentIngestionTrigger
}
```

Add `allowsPlaybackFollowing: Bool = true` after the existing `isPlaying` argument on `ReaderFeedViewModel.updateActiveBlock`. Replace the final expansion gate with:

```swift
if isPlaying && allowsPlaybackFollowing {
    let playingChapterKey = foundBlockID.flatMap { chapterIndexByBlockID[$0] ?? nil }
    let nextOpen = FeedAccordion.autoExpand(
        current: openChapterKey,
        playingChapterKey: playingChapterKey,
        lastPlayingChapterKey: lastPlayingChapterKey
    )
    lastPlayingChapterKey = playingChapterKey
    if nextOpen != openChapterKey {
        openChapterKey = nextOpen
        rebuildDisplaySections()
    }
}
```

Delete `ObserverTokenBox`, `timelineObserverToken`, observer setup in `init`, and the `deinit` observer removal from `ReaderFeedViewModel.swift`. This prevents an immediate model reload from racing the coalesced Reader reload.

- [ ] **Step 5: Run both focused suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderTimingRefreshTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
```

Expected: the late word becomes active after `reload()`, existing playback expansion still passes, and exploration prevents expansion.

- [ ] **Step 6: Commit cache refresh and expansion behavior**

```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoCore/ViewModels/ReaderFeedViewModel.swift EchoTests/ReaderFeedViewModelAccordionTests.swift EchoTests/ReaderTimingRefreshTests.swift
git commit -m "fix(reader): refresh late word timing data"
```

---

### Task 4: Make the collection coordinator the cancellable viewport authority

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`
- Modify: `EchoCore/Views/Cells/HeadingCardCell.swift`
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`
- Create: `EchoTests/ReaderFeedFollowCoordinatorTests.swift`

**Interfaces:**
- Replaces: `@Binding var autoScrollEnabled: Bool` with `@Binding var followState: ReaderFollowState`.
- Adds: `reduceMotion`, `onReturnTargetResolved`, coordinator `scrollGeneration`, and `scheduleReturnToCurrentText` behavior.
- Produces: `lineRectForWord(at:)` in paragraph and heading cells.
- Consumes: `ReaderScrollPermission` and `ReaderWordFollowScroll` from Tasks 1 and 2.

- [ ] **Step 1: Add a direct coordinator test for drag detachment and invalidation**

```swift
// EchoTests/ReaderFeedFollowCoordinatorTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct ReaderFeedFollowCoordinatorTests {
    @Test func dragDetachesAndInvalidatesQueuedPlaybackScroll() {
        let followState = MutableBox(ReaderFollowState.following)
        let headerVisible = MutableBox(true)
        let part = MutableBox<String?>(nil)
        let chapter = MutableBox<String?>(nil)
        let section = MutableBox<String?>(nil)
        let theme = MutableBox<String?>(nil)

        let coordinator = ReaderFeedCollectionView.Coordinator(
            onTapBlock: nil,
            onTapWord: nil,
            onContextMenu: nil,
            onAccessibilityActions: nil,
            isHeaderVisible: binding(headerVisible),
            followState: binding(followState),
            topPartTitle: binding(part),
            topChapterTitle: binding(chapter),
            topSectionTitle: binding(section),
            topChapterThemeColor: binding(theme)
        )
        let scheduledGeneration = coordinator.scrollGeneration

        coordinator.scrollViewWillBeginDragging(UIScrollView())

        #expect(followState.value == .exploring)
        #expect(coordinator.scrollGeneration == scheduledGeneration &+ 1)
        #expect(
            coordinator.mayApplyScroll(
                intent: .followPlayback,
                scheduledGeneration: scheduledGeneration
            ) == false
        )
    }

    private func binding<Value>(_ box: MutableBox<Value>) -> Binding<Value> {
        Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
    }
}

@MainActor
private final class MutableBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
```

- [ ] **Step 2: Build and observe the old Boolean coordinator API fail**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: coordinator has `autoScrollEnabled`, no `followState`, no `scrollGeneration`, and no `mayApplyScroll`.

- [ ] **Step 3: Add line-rectangle lookup to both text cells**

In both `ParagraphCardCell` and `HeadingCardCell`, add this beside `rectForWord(at:)`, using each cell's existing `label` and `wordRanges`:

```swift
func lineRectForWord(at wordIndex: Int) -> CGRect? {
    guard wordIndex >= 0, wordIndex < wordRanges.count else { return nil }
    label.layoutManager.ensureLayout(for: label.textContainer)
    let glyphRange = label.layoutManager.glyphRange(
        forCharacterRange: wordRanges[wordIndex],
        actualCharacterRange: nil
    )
    guard glyphRange.length > 0 else { return nil }
    var rect = label.layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphRange.location,
        effectiveRange: nil
    )
    rect.origin.x += label.textContainerInset.left
    rect.origin.y += label.textContainerInset.top
    return label.convert(rect, to: contentView)
}
```

- [ ] **Step 4: Replace Boolean following with a binding plus generation**

In `ReaderFeedCollectionView` and its coordinator:

```swift
@Binding var followState: ReaderFollowState
var reduceMotion = false
var onReturnTargetResolved: ((Bool) -> Void)?
```

```swift
var followState: Binding<ReaderFollowState>
private(set) var scrollGeneration: UInt = 0

func mayApplyScroll(
    intent: ReaderScrollIntent,
    scheduledGeneration: UInt
) -> Bool {
    ReaderScrollPermission.allows(
        intent: intent,
        followState: followState.wrappedValue,
        scheduledGeneration: scheduledGeneration,
        currentGeneration: scrollGeneration
    )
}

func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    followState.wrappedValue.detachForExploration()
    scrollGeneration &+= 1
    collectionViewLayerAnimationsToFinish(in: scrollView)
}

private func collectionViewLayerAnimationsToFinish(in scrollView: UIScrollView) {
    scrollView.layer.removeAllAnimations()
    scrollView.setContentOffset(scrollView.contentOffset, animated: false)
}
```

Update `makeCoordinator` and `updateUIView` to refresh the binding, Reduce Motion value, and completion closure on every SwiftUI update.

- [ ] **Step 5: Guard every asynchronous viewport mutation immediately before it runs**

Remove viewport movement from `updateActiveBlock`; it should only update visible block styling. After active-word state is synchronized in `updateUIView`, schedule one `followActiveText` operation for the current block. If an active word exists, scroll the block into visibility only as a provisional layout step, resolve its line rectangle, and use that line as the final magnetic target. Use the paragraph frame only when there is no active-word line. This prevents independent block and word tasks from competing.

For the single active-text scroll operation, capture the generation and re-check inside the main-actor task:

```swift
let scheduledGeneration = scrollGeneration
Task { @MainActor [weak collectionView] in
    guard let collectionView,
        self.mayApplyScroll(
            intent: .followPlayback,
            scheduledGeneration: scheduledGeneration
        )
    else { return }
    collectionView.scrollToItem(
        at: indexPath,
        at: .centeredVertically,
        animated: !self.reduceMotion
    )
}
```

For word movement, use `lineRectForWord`, convert it to collection coordinates, and call the Task 2 policy with `adjustedContentInset.top` and `adjustedContentInset.bottom`. Re-check `mayApplyScroll` immediately before `setContentOffset`. Only run paragraph fallback when no word-line rectangle exists.

- [ ] **Step 6: Preserve the exploration anchor across diffable snapshots**

Before `dataSource.apply`, capture the first visible item identifier and the distance between its layout attributes' `minY` and `contentOffset.y`. In the snapshot completion, restore that distance only when still exploring and the item still exists:

```swift
private struct ViewportAnchor {
    let itemID: String
    let distanceFromContentOffset: CGFloat
}

private func viewportAnchor(in collectionView: UICollectionView) -> ViewportAnchor? {
    guard followState.wrappedValue == .exploring,
        let indexPath = collectionView.indexPathsForVisibleItems.sorted().first,
        let itemID = dataSource?.itemIdentifier(for: indexPath),
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
    else { return nil }
    return ViewportAnchor(
        itemID: itemID,
        distanceFromContentOffset: attributes.frame.minY - collectionView.contentOffset.y
    )
}
```

The completion must call `layoutIfNeeded()`, resolve the new index path and attributes, re-check `.exploring`, and set a non-animated offset that recreates `distanceFromContentOffset`.

- [ ] **Step 7: Implement explicit return as a force-scroll intent**

Reuse `forceScrollBlockID` and `forceScrollTrigger`, but make their task use `.returnToCurrent`. Resolve the expanded block's index path, scroll it into view, lay out, then prefer the active word line over the block frame. Invoke `onReturnTargetResolved(true)` only after either target is applied. Invoke `false` when the block ID or index path cannot resolve. A user drag during the task changes the generation, so the completion reports `false` and leaves exploration active.

- [ ] **Step 8: Run the coordinator, state, and centering suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedFollowCoordinatorTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFollowStateTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderWordFollowScrollTests
```

Expected: manual drag enters exploration, invalidates the queued scroll, and line-centering tests remain green.

- [ ] **Step 9: Commit the collection authority**

```bash
git add EchoCore/Views/Cells/ParagraphCardCell.swift EchoCore/Views/Cells/HeadingCardCell.swift EchoCore/Views/ReaderFeedCollectionView.swift EchoTests/ReaderFeedFollowCoordinatorTests.swift
git commit -m "feat(reader): make follow scrolling cancellable"
```

---

### Task 5: Own follow state at root, reload on durable ingestion, and add the return pill

**Files:**
- Modify: `EchoCore/Views/RootTabView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`
- Modify: `EchoCore/Views/PDFReadingSurface.swift`
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Create: `EchoTests/ReaderFollowWiringTests.swift`

**Interfaces:**
- Root produces: `readerFollowState`, `readerReturnRequest`, and `readerReturnStatus`.
- `ReaderTab` consumes: `Binding<ReaderFollowState>`, an integer return request, and `(Bool) -> Void` resolution closure.
- `PDFReadingSurface` forwards the same three values to its reflow `ReaderTab`.
- Removes: `PlayerModel.readerChromeHidden` and `PlayerModel.epubScrollToActiveTrigger`; neither remains a global communication channel.

- [ ] **Step 1: Add source-level wiring guards for durable refresh and the single return affordance**

```swift
// EchoTests/ReaderFollowWiringTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderFollowWiringTests {
    @Test func readerObservesDurableIngestionAndHasNoLocalJumpButton() throws {
        let source = try Self.source("ReaderTab.swift")
        #expect(source.contains(".onChange(of: model.documentIngestionTrigger)"))
        #expect(source.contains("reloadReaderAfterTimelineIngestion"))
        #expect(source.contains("updateActiveReaderBlockForCurrentTrack()"))
        #expect(source.contains("arrow.down.to.line") == false)
    }

    @Test func rootOwnsExplorationAndResetsOnlyForAnotherBook() throws {
        let source = try Self.source("RootTabView.swift")
        #expect(source.contains("@State private var readerFollowState"))
        #expect(source.contains(".onChange(of: model.bookIdentityURL)"))
        #expect(source.contains("Return to current text"))
        #expect(source.contains(".onChange(of: model.selectedTab)") == false)
    }

    private static func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] **Step 2: Build and observe the wiring tests fail**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: root has no follow state or return pill, Reader does not observe the durable trigger, and the local arrow button still exists.

- [ ] **Step 3: Add root-owned follow and return state**

Add to `RootTabView` state:

```swift
@State private var readerFollowState = ReaderFollowState.following
@State private var readerReturnRequest = 0
@State private var readerReturnStatus: String?
```

Pass `$readerFollowState`, `readerReturnRequest`, and a completion closure into both `ReaderTab` construction paths. Forward them through `PDFReadingSurface` to the reflow `ReaderTab`.

Reset only when the book identity changes:

```swift
.onChange(of: model.bookIdentityURL) { oldValue, newValue in
    guard oldValue != newValue else { return }
    readerFollowState = .following
    readerReturnStatus = nil
}
```

- [ ] **Step 4: Add a root overlay for the persistent return control**

Place this above the root-owned bottom dock and only on the Read tab while exploring:

```swift
if model.selectedTab == .read && readerFollowState == .exploring {
    Button {
        readerReturnStatus = nil
        readerReturnRequest &+= 1
    } label: {
        Label(
            readerReturnStatus ?? String(localized: "Return to current text"),
            systemImage: "scope"
        )
        .font(.headline)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityHint(Text("Returns to the spoken text and resumes following playback"))
    .padding(.bottom, model.bottomInset + 12)
}
```

The completion closure must run:

```swift
let resolved = readerFollowState.completeReturn(targetResolved: targetResolved)
readerReturnStatus = resolved ? nil : String(localized: "Finding current text…")
```

Do not hide the pill merely because playback pauses, timing reloads, or the user visits another primary tab.

- [ ] **Step 5: Rewire Reader and delete the local jump control**

Give `ReaderTab` these stored inputs and initializer parameters:

```swift
@Binding private var followState: ReaderFollowState
let returnRequest: Int
let onReturnTargetResolved: (Bool) -> Void

init(
    folderURL: URL,
    bookURL: URL? = nil,
    followState: Binding<ReaderFollowState>,
    returnRequest: Int,
    onReturnTargetResolved: @escaping (Bool) -> Void
) {
    self.folderURL = folderURL
    self.bookURL = bookURL ?? folderURL
    _followState = followState
    self.returnRequest = returnRequest
    self.onReturnTargetResolved = onReturnTargetResolved
}
```

Pass the binding, Reduce Motion environment value, and completion into `ReaderFeedCollectionView`. Delete `autoScrollEnabled`, the `arrow.down.to.line` local utility button, `model.epubScrollToActiveTrigger` observation, and `scrollReaderToActiveBlock()`.

Observe the root return request:

```swift
.onChange(of: returnRequest) { _, _ in
    guard let activeID = viewModel?.activeBlockID else {
        onReturnTargetResolved(false)
        return
    }
    viewModel?.expandChapter(containingBlockID: activeID)
    forceScrollBlockID = activeID
    forceScrollTrigger &+= 1
}
```

Pass `followState.allowsPlaybackMovement` into `allowsPlaybackFollowing` in every call to `updateActiveBlock`.

- [ ] **Step 6: Observe the durable generation and fix cancellation-aware coalescing**

Keep the notification as a filtered low-latency hint, and add:

```swift
.onChange(of: model.documentIngestionTrigger) { _, _ in
    scheduleReaderReload()
}
```

Route both the notification handler and generation observer through:

```swift
private func scheduleReaderReload() {
    readerReloadToken &+= 1
}

private func reloadReaderAfterTimelineIngestion() async {
    guard readerReloadToken > 0 else { return }
    do {
        try await Task.sleep(for: .milliseconds(250))
    } catch {
        return
    }
    guard Task.isCancelled == false else { return }
    viewModel?.reload()
    updateActiveReaderBlockForCurrentTrack()
}
```

Do not use `try?` for the quiet-window sleep: cancellation must stop the superseded task rather than execute another full-book reload.

- [ ] **Step 7: Remove obsolete global reader chrome/jump state**

Delete `readerChromeHidden` and `epubScrollToActiveTrigger` from `PlayerModel`, the `isHeaderVisible` write into global chrome, and teardown resetting `readerChromeHidden`. Reader's local header may still animate independently.

- [ ] **Step 8: Run follow, timing, accordion, and wiring suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFollowWiringTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderTimingRefreshTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedFollowCoordinatorTests
```

Expected: late timing resolves without recreating Reader, exploration survives ordinary state updates, and only a resolved return resumes following.

- [ ] **Step 9: Commit root follow ownership and durable reload**

```bash
git add EchoCore/Views/RootTabView.swift EchoCore/Views/ReaderTab.swift EchoCore/Views/PDFReadingSurface.swift EchoCore/ViewModels/ReaderFeedViewModel.swift EchoCore/ViewModels/PlayerModel.swift EchoTests/ReaderFollowWiringTests.swift
git commit -m "feat(reader): preserve exploration until explicit return"
```

---

### Task 6: Make the folder control global and reserve its row once

**Files:**
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift`
- Modify: `EchoCore/Views/RootTabView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift`
- Modify: `EchoCore/Views/Library/LibraryShelfGrid.swift`
- Modify: `EchoTests/PlayerMoreMenuTests.swift`
- Modify: `EchoTests/UnifiedChromeLayoutTests.swift`

**Interfaces:**
- `UnifiedTopHeader` always renders the folder chip and timer pill in the root hierarchy.
- The primary navigation-stack `Group` receives one `UnifiedTopHeader.rowOneHeight` top safe-area inset.
- Reader keeps only its local self-measuring chapter-header inset; modal sheets remain outside the global row.

- [ ] **Step 1: Change the existing header expectation to require an unconditional folder**

In `PlayerMoreMenuTests.topHeaderNoLongerOwnsGlobalMoreMenu`, replace the final expectation with:

```swift
#expect(
    header.contains("model.selectedTab == .library") == false
        && header.contains("Button(action: onFolderTap)")
        && header.contains("SleepTimerPill()"),
    "UnifiedTopHeader should always show the folder chip and sleep-timer pill."
)
```

Update the source fallback string to `"Button(action: onFolderTap) SleepTimerPill()"`.

- [ ] **Step 2: Add source guards against duplicated top reservations**

Append this test to the existing `UnifiedChromeLayoutTests` suite, reusing its `source(named:)` helper:

```swift
@Test func rootOwnsTheOnlyGlobalHeaderReservation() throws {
    let root = try Self.source(named: "RootTabView.swift")
    let reader = try Self.source(named: "ReaderTab.swift")
    let nowPlaying = try Self.source(named: "NowPlayingTab.swift")
    let shelf = try Self.source(named: "Library/LibraryShelfGrid.swift")

    #expect(root.contains("Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)"))
    #expect(reader.contains("UnifiedTopHeader.rowOneHeight") == false)
    #expect(nowPlaying.contains("UnifiedTopHeader.rowOneHeight") == false)
    #expect(shelf.contains("UnifiedTopHeader.rowOneHeight") == false)
}
```

- [ ] **Step 3: Build and observe both layout tests fail**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: folder is conditional and the three per-screen reservations still exist.

- [ ] **Step 4: Make the folder chip unconditional**

Remove `if model.selectedTab == .library` and its transition wrapper from `UnifiedTopHeader`. Keep the existing 48-point frame, cover-derived tint, `Open book or folder` accessibility label, and `SleepTimerPill` unchanged.

- [ ] **Step 5: Move the global top reservation to the root content boundary**

Apply this modifier to the `Group` that contains the three primary navigation stacks, before its full-size frame:

```swift
.safeAreaInset(edge: .top, spacing: 0) {
    Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)
}
```

Render `UnifiedTopHeader` without opacity, offset, hit-testing, or `topChromeHidden` modifiers. Delete `topChromeHidden` from `RootTabView`.

- [ ] **Step 6: Remove the three local global-row reservations**

Delete only the `UnifiedTopHeader.rowOneHeight` safe-area inset and its stale comments from:

- `ReaderTab.readerLoadedContent`
- `NowPlayingTab`
- `LibraryShelfGrid`

Keep Reader's local chapter-header inset and all bottom-dock insets. Do not add the row to modal sheets.

- [ ] **Step 7: Run the header and layout suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerMoreMenuTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/UnifiedChromeLayoutTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ChromeConsolidationTests
```

Expected: unconditional folder, one root reservation, and no return of the global More menu.

- [ ] **Step 8: Commit global chrome ownership**

```bash
git add EchoCore/Views/Components/UnifiedTopHeader.swift EchoCore/Views/RootTabView.swift EchoCore/Views/ReaderTab.swift EchoCore/Views/NowPlayingTab.swift EchoCore/Views/Library/LibraryShelfGrid.swift EchoTests/PlayerMoreMenuTests.swift EchoTests/UnifiedChromeLayoutTests.swift
git commit -m "fix(chrome): keep the folder control globally visible"
```

---

### Task 7: Return a testable result from passage capture

**Files:**
- Create: `EchoCore/ViewModels/MarkedPassageCapture.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+MarkedPassages.swift`
- Create: `EchoTests/MarkedPassageCaptureTests.swift`

**Interfaces:**
- Produces: `MarkPassageResult`, `MarkedPassageCaptureRequest`, and `MarkedPassageCapture.capture(bookID:isItemLoaded:time:snippet:persist:onFailure:)`.
- `PlayerModel.markPassageAtCurrentTime()` returns `MarkPassageResult` and adds `canMarkPassage`.
- Existing Watch, CarPlay, transport, and long-press callers may ignore the returned value.

- [ ] **Step 1: Add result-path tests with closure injection**

```swift
// EchoTests/MarkedPassageCaptureTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MarkedPassageCaptureTests {
    private struct PersistenceFailure: Error {}

    @Test func savedBuildsTheExpectedTwentySecondWindow() throws {
        var captured: MarkedPassageCaptureRequest?
        let result = MarkedPassageCapture.capture(
            bookID: "book",
            isItemLoaded: true,
            time: 42,
            snippet: "Chapter: Five"
        ) { request in
            captured = request
        }

        #expect(result == .saved)
        #expect(captured?.audiobookID == "book")
        #expect(captured?.mediaTimestamp == 27)
        #expect(captured?.endTimestamp == 47)
        #expect(captured?.transcriptSnippet == "Chapter: Five")
    }

    @Test func missingBookLoadedItemOrFiniteTimeIsUnavailable() {
        #expect(
            MarkedPassageCapture.capture(
                bookID: nil,
                isItemLoaded: true,
                time: 2,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
        #expect(
            MarkedPassageCapture.capture(
                bookID: "book",
                isItemLoaded: false,
                time: 2,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
        #expect(
            MarkedPassageCapture.capture(
                bookID: "book",
                isItemLoaded: true,
                time: .infinity,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
    }

    @Test func persistenceErrorReturnsFailedAndReportsTheError() {
        var reported = false
        let result = MarkedPassageCapture.capture(
            bookID: "book",
            isItemLoaded: true,
            time: 10,
            snippet: nil,
            persist: { _ in throw PersistenceFailure() },
            onFailure: { _ in reported = true }
        )
        #expect(result == .failed)
        #expect(reported)
    }
}
```

- [ ] **Step 2: Build and observe the missing result types**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: capture result, request, and helper do not exist.

- [ ] **Step 3: Implement the pure capture helper**

```swift
// EchoCore/ViewModels/MarkedPassageCapture.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum MarkPassageResult: Equatable, Sendable {
    case saved
    case unavailable
    case failed
}

nonisolated struct MarkedPassageCaptureRequest: Equatable, Sendable {
    let audiobookID: String
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval
    let transcriptSnippet: String?
}

nonisolated enum MarkedPassageCapture {
    static func capture(
        bookID: String?,
        isItemLoaded: Bool,
        time: TimeInterval,
        snippet: String?,
        persist: (MarkedPassageCaptureRequest) throws -> Void,
        onFailure: (Error) -> Void = { _ in }
    ) -> MarkPassageResult {
        guard let bookID, bookID.isEmpty == false, isItemLoaded, time.isFinite else {
            return .unavailable
        }
        let request = MarkedPassageCaptureRequest(
            audiobookID: bookID,
            mediaTimestamp: max(0, time - 15),
            endTimestamp: time + 5,
            transcriptSnippet: snippet
        )
        do {
            try persist(request)
            return .saved
        } catch {
            onFailure(error)
            return .failed
        }
    }
}
```

- [ ] **Step 4: Route PlayerModel through the helper and preserve private logging**

```swift
var canMarkPassage: Bool {
    databaseService != nil
        && bookIdentityURL != nil
        && audioEngine.isItemLoaded
}

@discardableResult
func markPassageAtCurrentTime() -> MarkPassageResult {
    guard let db = databaseService else { return .unavailable }
    let time = audioEngine.currentTime
    return MarkedPassageCapture.capture(
        bookID: bookIdentityURL?.absoluteString,
        isItemLoaded: audioEngine.isItemLoaded,
        time: time,
        snippet: time.isFinite ? resolveSnippet(at: time) : nil,
        persist: { request in
            _ = try MarkedPassageDAO(db: db.writer).insert(
                audiobookID: request.audiobookID,
                mediaTimestamp: request.mediaTimestamp,
                endTimestamp: request.endTimestamp,
                transcriptSnippet: request.transcriptSnippet,
                note: nil
            )
        },
        onFailure: { error in
            Self.markedPassagesLogger.error(
                "Failed to save marked passage: \(error.localizedDescription, privacy: .public)"
            )
        }
    )
}
```

Do not log the captured snippet or private book text.

- [ ] **Step 5: Run the capture and DAO suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MarkedPassageCaptureTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MarkedPassageDAOTests
```

Expected: saved, unavailable, and failed are distinct; the existing inbox persistence test remains green.

- [ ] **Step 6: Commit the honest capture result**

```bash
git add EchoCore/ViewModels/MarkedPassageCapture.swift EchoCore/ViewModels/PlayerModel+MarkedPassages.swift EchoTests/MarkedPassageCaptureTests.swift
git commit -m "fix(player): report passage capture results"
```

---

### Task 8: Surface passage success or failure in the dock, haptics, and VoiceOver

**Files:**
- Modify: `EchoCore/Views/Components/Haptic.swift`
- Modify: `EchoCore/Views/BottomToolbarView.swift`
- Modify: `EchoCore/Views/Components/UnifiedBottomDock.swift`
- Modify: `EchoCore/Views/RootTabView.swift`
- Create: `EchoCore/Views/Components/DockStatusFeedback.swift`
- Create: `EchoTests/DockStatusFeedbackTests.swift`
- Modify: `EchoCore/Localizable.xcstrings`

**Interfaces:**
- Produces: `DockStatusFeedback`, `Haptic.notify(_:)`, and `UnifiedBottomDock.onMarkPassageResult`.
- Consumes: `MarkPassageResult` from Task 7.
- Root owns the transient status capsule and stacks it above the Reader return pill.

- [ ] **Step 1: Add the pure result-to-presentation mapping tests**

```swift
// EchoTests/DockStatusFeedbackTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct DockStatusFeedbackTests {
    @Test func savedUsesSuccessPresentation() {
        let feedback = DockStatusFeedback(result: .saved)
        #expect(feedback.message == "Passage marked")
        #expect(feedback.systemImage == "checkmark.circle.fill")
        #expect(feedback.isSuccess)
    }

    @Test func unavailableAndFailedUseFailurePresentation() {
        for result in [MarkPassageResult.unavailable, .failed] {
            let feedback = DockStatusFeedback(result: result)
            #expect(feedback.message == "Couldn't mark passage")
            #expect(feedback.systemImage == "exclamationmark.circle.fill")
            #expect(feedback.isSuccess == false)
        }
    }
}
```

- [ ] **Step 2: Build and observe the missing mapping type**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected red result: `DockStatusFeedback` is undefined.

- [ ] **Step 3: Implement the mapping and status capsule**

```swift
// EchoCore/Views/Components/DockStatusFeedback.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

nonisolated struct DockStatusFeedback: Equatable, Sendable {
    let message: String
    let systemImage: String
    let isSuccess: Bool

    init(result: MarkPassageResult) {
        switch result {
        case .saved:
            message = String(localized: "Passage marked")
            systemImage = "checkmark.circle.fill"
            isSuccess = true
        case .unavailable, .failed:
            message = String(localized: "Couldn't mark passage")
            systemImage = "exclamationmark.circle.fill"
            isSuccess = false
        }
    }
}

struct DockStatusFeedbackCapsule: View {
    let feedback: DockStatusFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.systemImage)
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 4: Add notification haptics and consume the result in the toolbar**

Add to `Haptic`:

```swift
static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    guard isEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(type)
}
```

Add `var onMarkPassageResult: (MarkPassageResult) -> Void` to `BottomToolbarView` and `UnifiedBottomDock`. Change the button action to:

```swift
let result = model.markPassageAtCurrentTime()
switch result {
case .saved:
    Haptic.notify(.success)
case .unavailable, .failed:
    Haptic.notify(.error)
}
onMarkPassageResult(result)
```

Keep `@State private var recentMarkResult: MarkPassageResult?` in `BottomToolbarView` and display the mapped checkmark or exclamation icon for 1.5 seconds before returning to `rectangle.stack.badge.plus`. Disable the button with `!model.canMarkPassage`, not merely `model.tracks.isEmpty`.

- [ ] **Step 5: Present, announce, stack, and clear root feedback**

Add root state:

```swift
@State private var dockStatusFeedback: DockStatusFeedback?
@State private var dockStatusFeedbackTask: Task<Void, Never>?
```

Wire the dock callback to:

```swift
private func showDockStatus(for result: MarkPassageResult) {
    let feedback = DockStatusFeedback(result: result)
    dockStatusFeedbackTask?.cancel()
    dockStatusFeedback = feedback
    UIAccessibility.post(notification: .announcement, argument: feedback.message)
    dockStatusFeedbackTask = Task { @MainActor in
        do {
            try await Task.sleep(for: .seconds(1.5))
        } catch {
            return
        }
        dockStatusFeedback = nil
    }
}
```

Import UIKit in `RootTabView`. Replace the standalone return overlay with one bottom-aligned status stack so large Dynamic Type grows upward and the two controls cannot overlap:

```swift
VStack(spacing: 8) {
    if let dockStatusFeedback {
        DockStatusFeedbackCapsule(feedback: dockStatusFeedback)
    }
    if model.selectedTab == .read && readerFollowState == .exploring {
        readerReturnButton
    }
}
.padding(.bottom, model.bottomInset + 12)
```

Use `@Environment(\.accessibilityReduceMotion)` in `RootTabView` and `BottomToolbarView`. Suppress status transitions and temporary-icon animation when Reduce Motion is enabled; do not change their timing or state transitions.

- [ ] **Step 6: Add localization keys**

Add English source entries to `EchoCore/Localizable.xcstrings` for:

- `Return to current text`
- `Returns to the spoken text and resumes following playback`
- `Finding current text…`
- `Passage marked`
- `Couldn't mark passage`

Preserve valid JSON and the repository's existing catalog ordering convention.

- [ ] **Step 7: Run feedback, capture, and accessibility suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/DockStatusFeedbackTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MarkedPassageCaptureTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedAccessibilityTests
```

Expected: result mapping is correct, capture paths remain green, and existing Dynamic Type/accessibility behavior is intact.

- [ ] **Step 8: Commit dock feedback**

```bash
git add EchoCore/Views/Components/Haptic.swift EchoCore/Views/BottomToolbarView.swift EchoCore/Views/Components/UnifiedBottomDock.swift EchoCore/Views/RootTabView.swift EchoCore/Views/Components/DockStatusFeedback.swift EchoTests/DockStatusFeedbackTests.swift EchoCore/Localizable.xcstrings
git commit -m "feat(player): show passage capture feedback"
```

---

### Task 9: Run integrated verification, complete independent Sol review, and publish

**Files:**
- Modify if needed: only files already listed in Tasks 1–8
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: all implemented Reader, chrome, timing, and passage-feedback behavior.
- Produces: a verified clean branch, a Sol review receipt, one changelog entry, push, and ready PR to `nightly`.

- [ ] **Step 1: Inspect the complete implementation diff and remove residue**

```bash
git status --short --branch
git diff origin/nightly...HEAD --check
git diff --stat origin/nightly...HEAD
rg -n "autoScrollEnabled|readerChromeHidden|epubScrollToActiveTrigger|topChromeHidden" EchoCore EchoTests
```

Expected: no whitespace errors; the obsolete Boolean and global chrome/jump state have no remaining references. Preserve the two unrelated untracked files.

- [ ] **Step 2: Run all focused regression suites together**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFollowStateTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderWordFollowScrollTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderTimingRefreshTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFeedFollowCoordinatorTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderFollowWiringTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/UnifiedChromeLayoutTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MarkedPassageCaptureTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/DockStatusFeedbackTests
```

Expected: all focused suites pass.

- [ ] **Step 3: Run the full repository unit-test gate**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

Expected: the complete Echo test suite passes. Record the command, exit status, test count, and any skipped tests.

- [ ] **Step 4: Perform manual iOS acceptance when an app build is available**

Use a sidecar-backed book and verify each item independently:

1. Open Reader before finalization completes; word highlighting becomes live without leaving the screen.
2. While playing, manually scroll away and cross a paragraph plus chapter boundary; viewport and open chapter remain stable.
3. Tap **Return to current text**; current word line centers, the pill disappears only after resolution, and subsequent spoken lines remain centered.
4. Repeat with Reduce Motion enabled; movement is immediate and state behavior is unchanged.
5. Verify folder control on Library, Reader, Now Playing, and a pushed destination; verify it is absent from Book Settings.
6. Verify Books, Inbox, and Anthologies are unobscured at default and accessibility Dynamic Type sizes.
7. Mark a passage successfully and verify icon, capsule, haptic, VoiceOver announcement, and inbox row. Exercise an unavailable state and verify failure feedback.

Report simulator/device acceptance separately from unit-test status. If device acceptance cannot run, state that explicitly rather than treating unit tests as device proof.

- [ ] **Step 5: Hand the exact diff and evidence to an independent `gpt-5.6-sol` reviewer**

The reviewer receives:

- approved design spec;
- this implementation plan;
- `git diff origin/nightly...HEAD`;
- focused and full test outputs;
- manual acceptance evidence or the explicit reason it is unavailable.

Ask Sol to review for:

- missed viewport mutations that bypass generation/follow checks;
- incorrect return-state transitions;
- reload duplication or cancellation bugs;
- snapshot offset changes while exploring;
- Dynamic Type, VoiceOver, and Reduce Motion regressions;
- duplicated or missing header safe-area ownership;
- dishonest passage result or haptic paths;
- Swift 6 isolation and retain-cycle problems.

- [ ] **Step 6: Address every valid Sol finding test-first, then request a clean re-review**

For each accepted finding, add or strengthen a failing regression test before changing production code. Rerun the narrow suite and the full gate. Do not publish with unresolved severity-1 or severity-2 findings. Record rejected suggestions with concrete code or test evidence.

- [ ] **Step 7: Add a concise changelog entry after the implementation is stable**

Under the current unreleased section in `CHANGELOG.md`, add:

```markdown
- Fixed Reader word-timing refresh and follow mode: spoken lines stay centered while following, manual exploration stays put until **Return to current text**, the folder control remains globally available without covering Library tabs, and passage marking now reports success or failure.
```

- [ ] **Step 8: Commit review fixes and changelog**

```bash
git add CHANGELOG.md
git add EchoCore EchoTests
git commit -m "docs: record reader follow and chrome fixes"
```

If `git status --short` shows no review fixes and only `CHANGELOG.md` is new, stage and commit only `CHANGELOG.md`.

- [ ] **Step 9: Push and open a ready PR to `nightly`**

```bash
git push -u origin feature/reader-follow-global-chrome
gh pr create --base nightly --head feature/reader-follow-global-chrome --title "feat(reader): make follow mode explicit and reliable" --body-file /tmp/echo-reader-follow-pr.md
```

The PR body must summarize behavior, link the design and plan paths, list focused/full test evidence, record Sol review as clean, and distinguish unit tests from simulator/device acceptance. After opening, inspect hosted CI and report it as passing, failing, pending, or blocked.

---

## Final Acceptance Checklist

- [ ] Late-arriving sidecar words become active in a visible Reader without navigation away and back.
- [ ] Active word highlighting continues while exploring, but no word, block, chapter, reload, seek, tab switch, or queued task moves the viewport.
- [ ] Spoken rendered lines are magnetically centered while following, with word-line targeting preferred over paragraph fallback and correct edge clamps.
- [ ] **Return to current text** is persistent above the dock while exploring and resumes following only after a real target resolves.
- [ ] The local Reader jump button is gone; there is one return action.
- [ ] Passage marking shows accurate success or failure icon, capsule, haptic, and VoiceOver feedback and is disabled without a playable book.
- [ ] Folder control is visible throughout the main navigation hierarchy, absent from modal sheets, and does not overlap Library modes.
- [ ] Dynamic Type and Reduce Motion acceptance pass.
- [ ] All focused tests and full `make test` pass through the build-slot wrapper.
- [ ] `gpt-5.6-sol` review is clean after any remediation.
- [ ] Branch is pushed and a ready PR targets `nightly`; hosted CI state is reported separately.
