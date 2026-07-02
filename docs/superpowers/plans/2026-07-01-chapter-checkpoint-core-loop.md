# Chapter Checkpoint — Core Study Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a due study chapter finishes playing naturally, Echo pauses, asks for a retention grade (overlay + audio cue + lock-screen buttons + interactive notification), and keeps today's study queue flowing across books hands-free — plus skippable re-listens, a retire-chapter prompt, and macOS study-layer parity.

**Architecture:** Two new concrete services shared by iOS and macOS: `StudyCheckpointCoordinator` (an `@Observable` state machine owned by each platform's player model, constructor/closure-injected in the `SleepTimerManager` style) and `StudyPlaybackQueueService` (a GRDB struct wrapping `StudyQueueBuilder` that materializes today's queue into playable chapter assignments and owns skip/needs-attention bookkeeping). Arming hooks into the exact chapter-transition paths the end-of-chapter sleep timer already uses (`PlaybackController.applyChapterLoopIfNeeded` on iOS, `MacPlayerModel.handleChapterBoundary` on macOS); presentation is a shared SwiftUI panel hosted per platform. No schema migration — grades, skips, auto flags, and retire state ride existing tables and JSON blobs.

**Tech Stack:** Swift 6, SwiftUI, GRDB, Swift Testing (`@Test`/`#expect`, `@testable import Echo`, `DatabaseService(inMemory: ())`)

## Global Constraints

- Worktree/branch: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/pensive-fermi-dae756 on `claude/pensive-fermi-dae756` (already based on origin/nightly). Commit per task with Conventional Commits; do NOT push or open PRs from within a task.
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` as line 1 (a SwiftFormat PostToolUse hook reflows files — after edits verify the SPDX line is still line 1).
- DI style: concrete types + constructor/closure injection, tested against `DatabaseService(inMemory: true)`. NO new protocols or mocks. `@Observable`/@State — never ObservableObject/@Published.
- Concurrency: async/await + @MainActor where UI-adjacent; no DispatchQueue.main.async, no semaphores.
- Logging: os.Logger (match existing subsystem/category conventions); raw print only behind #if DEBUG.
- Tests: run `make build-tests` ONCE after code changes, then `make test-only FILTER=EchoTests/<SuiteName>` per suite (16 GB machine: never two xcodebuild invocations concurrently, never parallel testing). Prefix any full build with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`.
- New files must be added to the Xcode project (project.pbxproj) with correct target membership: Shared/ files → iOS + macOS (+ echo-cli ONLY if free of UIKit/PlayerModel deps); EchoCore/ files → iOS + macOS unless PlayerModel/UIKit-coupled (then iOS-only and EXCLUDED from macOS and echo-cli — broken exclusions surface as CI failures masked behind test steps).
- Simulator Keychain is flaky under unsigned test builds: never unit-test real Keychain round-trips; inject an in-memory store seam instead.
- Do not run macOS builds concurrently with iOS test runs.

### Project-mechanics notes the executor must know

- **Target membership is folder-synchronized.** All targets use `PBXFileSystemSynchronizedRootGroup`s: a new file under `Shared/` automatically joins **every** target that syncs `Shared/` (Echo, Echo macOS, echo-cli, Echo Watch App, Echo WidgetExtension) with **no pbxproj edit**. A new file under `EchoCore/` automatically joins Echo (iOS), Echo macOS, and echo-cli **unless** you add its relative path to the target's `membershipExceptions` list inside `Echo.xcodeproj/project.pbxproj`:
  - echo-cli exception set: `4FEA03AA769144F6DBB2EF55 /* Exceptions for "EchoCore" folder in "echo-cli" target */` (starts at line ~167)
  - Echo macOS exception set: `718DD03F18BB433E7AD362E2 /* Exceptions for "EchoCore" folder in "Echo macOS" target */` (starts at line ~288)
  Entries are kept alphabetical within the list; add entries by editing project.pbxproj as plain text. `ViewModels/PlayerModel.swift` is excluded from BOTH lists, so any new `PlayerModel+*.swift` extension file must also be added to BOTH.
- The Watch and Widget targets do NOT sync `EchoCore/` — new EchoCore files never reach them. New `Shared/` files DO reach them, so keep Shared additions to Foundation + GRDB.
- The SwiftFormat PostToolUse hook reflows the whole file on every Edit; after each edit confirm `// SPDX-License-Identifier: GPL-3.0-or-later` is still line 1.
- Existing test fixtures: `StudyQueueFixtures` (internal enum at `EchoTests/StudyQueueBuilderTests.swift:251`) seeds in-memory DBs with books, epub_blocks, plans, and assignment cards. Its assignment cards are titled `"Book A Chapter 1..3"` (chapterIndex 0..2, audio ranges 0–100/100–200/200–300); `serviceWithPlan()` also seeds a normal due card `"Due Review"` at timestamp 0; `serviceWithTwoPlansIncludingProgress()` marks chapter 0 of both books introduced and seeds NO due cards. `StudyQueueFixtures.mondayNoon` = `Date(timeIntervalSince1970: 1_782_129_600)`.

## File Structure

### Created
| File | Responsibility |
|---|---|
| `Shared/Study/StudyCheckpointTypes.swift` | `CheckpointTimeoutBehavior`, `StudyCheckpointSettings` (+ timeout snapping), `StudyPlayableItem`, checkpoint event-type string constants |
| `Shared/Services/StudyPlaybackQueueService.swift` | Materializes today's queue into `StudyPlayableItem`s; `nextPlayableItem(after:)`, `markSkipped`, `isSkipEligible`, `markNeedsAttention`, `needsAttentionFlashcardIDs` |
| `Shared/Services/StudyChapterRetireService.swift` | Once-per-chapter retire prompt detection + retire write (assignment card & item disable) |
| `EchoCore/Services/StudyCheckpointCoordinator.swift` | The checkpoint state machine: arming, countdown, resolution, auto-grades, sleep-timer/loop interplay |
| `EchoCore/Services/StudyCheckpointAnnouncer.swift` | Instant audio cue: chime + `AVSpeechSynthesizer` one-liner (deliberately not Kokoro) |
| `EchoCore/Services/StudyCheckpointNotificationService.swift` | iOS-only (`#if os(iOS)`) interactive-notification channel: `STUDY_CHECKPOINT` category, GOOD/AGAIN actions |
| `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift` | iOS wiring: coordinator construction, cross-book advance, remote-grade window (excluded from macOS + echo-cli) |
| `EchoCore/Views/StudyCheckpointPanelView.swift` | Shared checkpoint grade card (Again/Good/Skip + countdown) used by iOS overlay and macOS panel (excluded from echo-cli) |
| `EchoTests/StudyCheckpointTypesTests.swift` | Types + snapping tests |
| `EchoTests/FlashcardReviewMetadataTests.swift` | auto/skipped metadata back-compat tests |
| `EchoTests/SettingsManagerCheckpointTests.swift` | Settings defaults/snapping/persistence tests |
| `EchoTests/StudyPlanDAOCheckpointTests.swift` | `checkpointAssignment` lookup tests |
| `EchoTests/StudyPlaybackQueueServiceTests.swift` | Queue service tests |
| `EchoTests/StudyCheckpointCoordinatorTests.swift` | State-machine tests |
| `EchoTests/PlayerModelStudyCheckpointTests.swift` | iOS wiring smoke tests |
| `EchoTests/StudyChapterRetireServiceTests.swift` | Retire prompt tests |

### Modified
| File | Change |
|---|---|
| `Shared/Stats/FlashcardReviewMetadata.swift` | Add optional `auto`/`skipped` fields (backward-compatible Codable) |
| `EchoCore/Services/SettingsManager.swift` | 4 checkpoint settings (Defaults ~L76, Keys ~L142, props ~L337, init loads ~L691, registerDefaults ~L763) |
| `Shared/Database/DAOs/StudyPlanDAO.swift` | `StudyCheckpointAssignment` + `checkpointAssignment(audiobookID:chapterIndex:now:)` (after `setItemEnabled`, ~L188) |
| `EchoCore/Services/PlaybackController.swift` | New `coordinator_handleChapterEndCheckpoint` closure (~L52) + first-claim call in `applyChapterLoopIfNeeded` (~L873) |
| `EchoCore/ViewModels/PlayerModel.swift` | Stored props for coordinator/announcer/notifications/retire prompt (~L499); `databaseService` didSet calls `configureStudyCheckpoint()` (~L623); remote-command closures intercept grades (~L1614) |
| `EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift` | Suspend/resume countdown on AVAudioSession interruption (~L29) |
| `EchoCore/ViewModels/StudySessionViewModel.swift` | `skipCurrent`, `currentEntryIsSkipEligible`, `needsAttentionCardIDs` |
| `EchoCore/Views/StudyAssignmentCardView.swift` | Optional Skip button + needs-attention badge |
| `EchoCore/Views/StudySessionView.swift` | Pass skip/needs-attention into the card view (~L79) |
| `EchoCore/Views/Stats/StatsView.swift` | "Play Assignment" rewired to `model.playStudyAssignment` (~L303) |
| `EchoCore/Views/Components/FlashcardCreationSheet.swift` | Retire-prompt hook after user-card insert (~L200) |
| `EchoCore/Views/RootTabView.swift` | Checkpoint overlay + retire-prompt alert on the root ZStack (~L163) |
| `EchoCore/Views/SettingsView.swift` | "Chapter Checkpoints" NavigationLink + settings subview (in `SettingsStudyRows`, ~L269) |
| `Shared/Study/StudyPlanTypes.swift` | `StudyCardMedia` gains optional `retirePromptShownAt` (~L47) |
| `Echo macOS/Views/MacSettingsView.swift` | New `MacStudySettingsPane` tab (~L29) |
| `Echo macOS/Echo_macOSApp.swift` | "Study Plan…" menu command (~L252) + `.requestStudyPlan` name (~L557) |
| `Echo macOS/Views/MacTriPaneView.swift` | Study-plan sheet host + checkpoint panel overlay |
| `Echo macOS/Views/MacPlayerModel.swift` | Coordinator ownership (`dbService` didSet ~L132) + boundary claim in `handleChapterBoundary` (~L1020) |
| `Echo.xcodeproj/project.pbxproj` | Exclusions: `ViewModels/PlayerModel+StudyCheckpoint.swift` (macOS + echo-cli), `Views/StudyCheckpointPanelView.swift` (echo-cli) |

---

## Task 1: Shared checkpoint types

**Files:**
- Create: `Shared/Study/StudyCheckpointTypes.swift`
- Test: `EchoTests/StudyCheckpointTypesTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces (later tasks rely on these EXACT signatures):
  - `enum CheckpointTimeoutBehavior: String, Codable, Sendable, CaseIterable { case replay, gradeAndAdvance = "grade_and_advance", wait }`
  - `struct StudyCheckpointSettings: Equatable, Sendable` with `var timeoutSeconds: Int`, `var timeoutBehavior: CheckpointTimeoutBehavior`, `var autoAdvance: Bool`, `var remoteGrading: Bool`, `var globalNewChapterLimit: Int? = nil`, `static let allowedTimeoutSeconds = [10, 30, 60, 120]`, `static func snappedTimeoutSeconds(_ value: Int) -> Int`
  - `struct StudyPlayableItem: Identifiable, Equatable, Sendable` with `flashcardID/audiobookID/chapterIndex/planItemID/title/startTime/endTime`
  - `enum StudyCheckpointEventType { static let chapterSkipped; static let needsAttention }`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyCheckpointTypesTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct StudyCheckpointTypesTests {
    @Test func timeoutBehaviorRawValuesAreStable() {
        #expect(CheckpointTimeoutBehavior.replay.rawValue == "replay")
        #expect(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue == "grade_and_advance")
        #expect(CheckpointTimeoutBehavior.wait.rawValue == "wait")
    }

    @Test func snappedTimeoutPicksNearestAllowedValue() {
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(10) == 10)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(29) == 30)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(60) == 60)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(200) == 120)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(0) == 10)
    }

    @Test func playableItemIdentityIsTheFlashcardID() {
        let item = StudyPlayableItem(
            flashcardID: "card-1", audiobookID: "book-a", chapterIndex: 0,
            planItemID: "item-1", title: "Chapter 1", startTime: 0, endTime: 100)
        #expect(item.id == "card-1")
    }

    @Test func eventTypeStringsAreStable() {
        #expect(StudyCheckpointEventType.chapterSkipped == "study_chapter_skipped")
        #expect(StudyCheckpointEventType.needsAttention == "study_item_needs_attention")
    }
}
```

- [ ] Run it (expect compile failure — the types don't exist yet):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected failure: `error: cannot find 'CheckpointTimeoutBehavior' in scope` (and siblings) in StudyCheckpointTypesTests.swift.

- [ ] Create `Shared/Study/StudyCheckpointTypes.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What happens when the checkpoint countdown expires without a tap.
enum CheckpointTimeoutBehavior: String, Codable, Sendable, CaseIterable {
    /// Grade `.again` automatically and replay the chapter (iOS default).
    case replay
    /// Grade `.again` automatically and advance to the next queue item.
    case gradeAndAdvance = "grade_and_advance"
    /// Record no grade; the chapter stays due today and resurfaces in the
    /// queue. No countdown runs at all (macOS default — a Mac screen doesn't
    /// sleep mid-session, so auto-grading an empty desk chair would be
    /// dishonest data).
    case wait
}

/// Snapshot of the checkpoint settings, read through a provider closure so
/// the coordinator always sees current values without owning SettingsManager.
struct StudyCheckpointSettings: Equatable, Sendable {
    /// Allowed countdown durations, in seconds. Settings UI offers exactly these.
    static let allowedTimeoutSeconds = [10, 30, 60, 120]

    var timeoutSeconds: Int
    var timeoutBehavior: CheckpointTimeoutBehavior
    var autoAdvance: Bool
    var remoteGrading: Bool
    /// Mirrors `SettingsManager.studyGlobalNewChapterLimit` for queue builds.
    var globalNewChapterLimit: Int? = nil

    /// Snaps an arbitrary stored value to the nearest allowed duration.
    static func snappedTimeoutSeconds(_ value: Int) -> Int {
        allowedTimeoutSeconds.min { abs($0 - value) < abs($1 - value) } ?? 30
    }
}

/// One playable unit of today's study queue: a chapter listening assignment
/// materialized as (book identity, chapter audio range, flashcard).
struct StudyPlayableItem: Identifiable, Equatable, Sendable {
    /// Stable across queue rebuilds — the assignment flashcard's id.
    var id: String { flashcardID }
    let flashcardID: String
    let audiobookID: String
    let chapterIndex: Int?
    /// The `study_plan_item` id, when the queue entry carried one — used to
    /// mark the chapter introduced when hands-free playback reaches it.
    let planItemID: String?
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

/// `real_time_event.event_type` values written by the checkpoint/queue layer.
/// Deliberately NOT `RealTimeEventType` cases: skips must never pollute the
/// `flashcard_reviewed` grade distribution, and Shared code should not depend
/// on the EchoCore models split.
enum StudyCheckpointEventType {
    nonisolated static let chapterSkipped = "study_chapter_skipped"
    nonisolated static let needsAttention = "study_item_needs_attention"
}
```

No pbxproj edit: `Shared/` is folder-synchronized into every target.

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyCheckpointTypesTests
```

Expected: 4 tests pass.

- [ ] Verify SPDX is still line 1 of the new file, then commit:

```bash
git add Shared/Study/StudyCheckpointTypes.swift EchoTests/StudyCheckpointTypesTests.swift
git commit -m "feat(study): add chapter-checkpoint shared types"
```

---

## Task 2: Review-metadata auto/skip flags

**Files:**
- Modify: `Shared/Stats/FlashcardReviewMetadata.swift` (whole struct, 30 lines)
- Test: `EchoTests/FlashcardReviewMetadataTests.swift`

**Interfaces:**
- Consumes: `Flashcard` (existing).
- Produces: `FlashcardReviewMetadata` gains `let auto: Bool?`, `let skipped: Bool?`; `init(cardID:grade:intervalDays:auto:skipped:)` with `auto`/`skipped` defaulting to nil; `init(card:grade:auto:)` with `auto` defaulting to nil. Existing call sites (`StudySessionViewModel:110`, `DailyReviewViewModel:109`, `StatsRepository:398,433`) keep compiling unchanged.

**Steps:**

- [ ] Write the failing test at `EchoTests/FlashcardReviewMetadataTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct FlashcardReviewMetadataTests {
    @Test func legacyRowsDecodeWithNilFlags() throws {
        let legacy = #"{"cardId":"c1","grade":3,"intervalDays":2}"#
        let decoded = try #require(FlashcardReviewMetadata.decode(legacy))
        #expect(decoded.grade == 3)
        #expect(decoded.auto == nil)
        #expect(decoded.skipped == nil)
    }

    @Test func autoFlagRoundTrips() throws {
        let metadata = FlashcardReviewMetadata(
            cardID: "c1", grade: 1, intervalDays: 4, auto: true)
        let json = try metadata.encodedJSONString()
        let decoded = try #require(FlashcardReviewMetadata.decode(json))
        #expect(decoded.auto == true)
        #expect(decoded.skipped == nil)
    }

    @Test func skipMarkerRoundTrips() throws {
        let metadata = FlashcardReviewMetadata(
            cardID: "c1", grade: 0, intervalDays: nil, skipped: true)
        let json = try metadata.encodedJSONString()
        let decoded = try #require(FlashcardReviewMetadata.decode(json))
        #expect(decoded.skipped == true)
        #expect(decoded.grade == 0)
    }

    @Test func tapGradesOmitTheAutoKeyEntirely() throws {
        let json = try FlashcardReviewMetadata(cardID: "c1", grade: 3, intervalDays: 1)
            .encodedJSONString()
        #expect(!json.contains("auto"))
        #expect(!json.contains("skipped"))
    }
}
```

- [ ] Run it (expect compile failure: `extra argument 'auto' in call`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Replace the body of `Shared/Stats/FlashcardReviewMetadata.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct FlashcardReviewMetadata: Codable, Equatable, Sendable {
    let cardId: String?
    let grade: Int
    let intervalDays: Int?
    /// True when the grade was auto-fired by the checkpoint timeout, not a
    /// deliberate tap — Insights can discount autos, and future scheduler
    /// tuning can too. Optional so rows written before chapter checkpoints
    /// decode unchanged (and tap grades omit the key entirely).
    let auto: Bool?
    /// True when this row records a retention-neutral skip (no FSRS grade;
    /// `grade` is 0 on skip rows, which live under their own event type).
    let skipped: Bool?

    init(
        cardID: String, grade: Int, intervalDays: Int?,
        auto: Bool? = nil, skipped: Bool? = nil
    ) {
        self.cardId = cardID
        self.grade = grade
        self.intervalDays = intervalDays
        self.auto = auto
        self.skipped = skipped
    }

    init(card: Flashcard, grade: Int, auto: Bool? = nil) {
        self.init(cardID: card.id, grade: grade, intervalDays: card.intervalDays, auto: auto)
    }

    nonisolated func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func decode(_ jsonString: String?) -> FlashcardReviewMetadata? {
        guard let jsonString, let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(FlashcardReviewMetadata.self, from: data)
    }
}
```

(JSONEncoder omits nil optionals, so tap grades stay byte-identical to today's rows; `decodeIfPresent` is synthesized for optionals, so legacy rows decode.)

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/FlashcardReviewMetadataTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add Shared/Stats/FlashcardReviewMetadata.swift EchoTests/FlashcardReviewMetadataTests.swift
git commit -m "feat(study): carry auto/skip flags in flashcard review metadata"
```

---

## Task 3: SettingsManager checkpoint settings

**Files:**
- Modify: `EchoCore/Services/SettingsManager.swift` — `Defaults` enum (after `soundscapeVolume`, ~L76), `Keys` enum (after `soundscapeVolume`, ~L142), stored properties (after `reviewNotificationsEnabled`, ~L337), init loads (after the `studyGlobalNewChapterLimit` load, ~L691), `registerDefaults` (after `Keys.reviewNotificationsEnabled` entry, ~L763)
- Test: `EchoTests/SettingsManagerCheckpointTests.swift`

**Interfaces:**
- Consumes: `StudyCheckpointSettings.snappedTimeoutSeconds(_:)`, `CheckpointTimeoutBehavior` (Task 1).
- Produces (used by Tasks 7, 12, 13, 14):
  - `SettingsManager.Defaults.checkpointTimeoutSeconds: Int` (30)
  - `SettingsManager.Defaults.checkpointTimeoutBehavior: String` ("replay" on iOS, "wait" on macOS via `#if os(macOS)`)
  - `SettingsManager.Defaults.checkpointAutoAdvance: Bool` (true), `.checkpointRemoteGrading: Bool` (true)
  - `var checkpointTimeoutSeconds: Int` (snapped in didSet), `var checkpointTimeoutBehavior: String`, `var checkpointAutoAdvance: Bool`, `var checkpointRemoteGrading: Bool`

**Steps:**

- [ ] Write the failing test at `EchoTests/SettingsManagerCheckpointTests.swift`. (EchoTests compiles for iOS, so the platform-conditional default asserts the iOS value; the macOS value is checked by the macOS build in Task 15.)

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct SettingsManagerCheckpointTests {
    private func makeSettings(
        seed: (UserDefaults) -> Void = { _ in }
    ) throws -> (SettingsManager, UserDefaults, String) {
        let suiteName = "checkpoint-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        seed(defaults)
        let appGroupSuiteName = "\(suiteName)-group"
        let appGroupDefaults = try #require(UserDefaults(suiteName: appGroupSuiteName))
        let settings = SettingsManager(
            defaults: defaults,
            appGroupDefaults: appGroupDefaults,
            defaultsDomainName: nil,
            appGroupDefaultsDomainName: nil
        )
        return (settings, defaults, suiteName)
    }

    @Test func defaultsMatchTheSpec() throws {
        let (settings, _, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.checkpointTimeoutSeconds == 30)
        // EchoTests builds for iOS: the platform default is Replay.
        #expect(settings.checkpointTimeoutBehavior == CheckpointTimeoutBehavior.replay.rawValue)
        #expect(settings.checkpointAutoAdvance == true)
        #expect(settings.checkpointRemoteGrading == true)
    }

    @Test func timeoutSnapsToAllowedValuesOnWrite() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.checkpointTimeoutSeconds = 45
        #expect(settings.checkpointTimeoutSeconds == 30)
        #expect(defaults.integer(forKey: "checkpointTimeoutSeconds") == 30)

        settings.checkpointTimeoutSeconds = 120
        #expect(settings.checkpointTimeoutSeconds == 120)
    }

    @Test func tamperedStoredTimeoutLoadsSnapped() throws {
        let (settings, _, suite) = try makeSettings { defaults in
            defaults.set(7, forKey: "checkpointTimeoutSeconds")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.checkpointTimeoutSeconds == 10)
    }

    @Test func togglesPersist() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.checkpointAutoAdvance = false
        settings.checkpointRemoteGrading = false
        settings.checkpointTimeoutBehavior = CheckpointTimeoutBehavior.wait.rawValue

        #expect(defaults.bool(forKey: "checkpointAutoAdvance") == false)
        #expect(defaults.bool(forKey: "checkpointRemoteGrading") == false)
        #expect(defaults.string(forKey: "checkpointTimeoutBehavior") == "wait")
    }
}
```

- [ ] Run it (expect compile failure: `value of type 'SettingsManager' has no member 'checkpointTimeoutSeconds'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Implement in `EchoCore/Services/SettingsManager.swift` — five edits:

**(a)** In `enum Defaults`, after `static let soundscapeVolume: Float = 0.5` (~L76), add:

```swift
        static let checkpointTimeoutSeconds = 30
        #if os(macOS)
            // A Mac screen doesn't sleep mid-session the way a pocketed phone
            // does; auto-Again fired at an empty desk chair would be dishonest
            // data, so macOS defaults to Wait (no countdown).
            static let checkpointTimeoutBehavior = CheckpointTimeoutBehavior.wait.rawValue
        #else
            static let checkpointTimeoutBehavior = CheckpointTimeoutBehavior.replay.rawValue
        #endif
        static let checkpointAutoAdvance = true
        static let checkpointRemoteGrading = true
```

**(b)** In `private enum Keys`, after `static let soundscapeVolume = "soundscapeVolume"` (~L142), add:

```swift
        static let checkpointTimeoutSeconds = "checkpointTimeoutSeconds"
        static let checkpointTimeoutBehavior = "checkpointTimeoutBehavior"
        static let checkpointAutoAdvance = "checkpointAutoAdvance"
        static let checkpointRemoteGrading = "checkpointRemoteGrading"
```

**(c)** In the `// MARK: - Study` section, after the `reviewNotificationsEnabled` property (~L337), add:

```swift
    var checkpointTimeoutSeconds: Int {
        didSet {
            let snapped = StudyCheckpointSettings.snappedTimeoutSeconds(checkpointTimeoutSeconds)
            guard checkpointTimeoutSeconds == snapped else {
                checkpointTimeoutSeconds = snapped
                return
            }
            defaults.set(snapped, forKey: Keys.checkpointTimeoutSeconds)
        }
    }
    var checkpointTimeoutBehavior: String {
        didSet { defaults.set(checkpointTimeoutBehavior, forKey: Keys.checkpointTimeoutBehavior) }
    }
    var checkpointAutoAdvance: Bool {
        didSet { defaults.set(checkpointAutoAdvance, forKey: Keys.checkpointAutoAdvance) }
    }
    var checkpointRemoteGrading: Bool {
        didSet { defaults.set(checkpointRemoteGrading, forKey: Keys.checkpointRemoteGrading) }
    }
```

**(d)** In `init`, immediately after the `studyGlobalNewChapterLimit = ...` load (~L691), add:

```swift
        checkpointTimeoutSeconds = StudyCheckpointSettings.snappedTimeoutSeconds(
            defaults.object(forKey: Keys.checkpointTimeoutSeconds) as? Int
                ?? Defaults.checkpointTimeoutSeconds
        )
        checkpointTimeoutBehavior =
            defaults.string(forKey: Keys.checkpointTimeoutBehavior)
            ?? Defaults.checkpointTimeoutBehavior
        checkpointAutoAdvance =
            defaults.object(forKey: Keys.checkpointAutoAdvance) as? Bool
            ?? Defaults.checkpointAutoAdvance
        checkpointRemoteGrading =
            defaults.object(forKey: Keys.checkpointRemoteGrading) as? Bool
            ?? Defaults.checkpointRemoteGrading
```

**(e)** In `registerDefaults`, after `Keys.reviewNotificationsEnabled: Defaults.reviewNotificationsEnabled,` (~L763), add:

```swift
            Keys.checkpointTimeoutSeconds: Defaults.checkpointTimeoutSeconds,
            Keys.checkpointTimeoutBehavior: Defaults.checkpointTimeoutBehavior,
            Keys.checkpointAutoAdvance: Defaults.checkpointAutoAdvance,
            Keys.checkpointRemoteGrading: Defaults.checkpointRemoteGrading,
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/SettingsManagerCheckpointTests
```

- [ ] Verify SPDX still line 1 of SettingsManager.swift, then commit:

```bash
git add EchoCore/Services/SettingsManager.swift EchoTests/SettingsManagerCheckpointTests.swift
git commit -m "feat(settings): add chapter-checkpoint settings (timeout, 3-way behavior, auto-advance, remote grading)"
```

---

## Task 4: StudyPlanDAO checkpoint-assignment lookup

**Files:**
- Modify: `Shared/Database/DAOs/StudyPlanDAO.swift` — add after `setItemEnabled(itemID:isEnabled:now:)` (~L188)
- Test: `EchoTests/StudyPlanDAOCheckpointTests.swift`

**Interfaces:**
- Consumes: `StudyPlan`, `StudyPlanItem`, `Flashcard`, `StudyPlanItemKind` (all existing), `StudyQueueFixtures` (EchoTests).
- Produces (used by Task 6):
  - `struct StudyCheckpointAssignment: Sendable { let plan: StudyPlan; let item: StudyPlanItem; let card: Flashcard }`
  - `StudyPlanDAO.checkpointAssignment(audiobookID: String, chapterIndex: Int, now: Date = Date()) throws -> StudyCheckpointAssignment?`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyPlanDAOCheckpointTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlanDAOCheckpointTests {
    @Test func introducedInProgressChapterIsCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment?.card.frontText == "Book A Chapter 1")
        #expect(assignment?.item.chapterIndex == 0)
    }

    @Test func unintroducedChapterIsNot() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)

        // Chapter 2 (index 2) was never introduced by the fixture.
        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 2, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func pausedPlanSilencesCheckpoints() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func disabledItemIsNotCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        let item = try #require(try dao.items(for: plan.id).first { $0.chapterIndex == 0 })
        try dao.setItemEnabled(itemID: item.id, isEnabled: false, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func gradedFutureDueChapterIsNotCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let cardID = try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
        try FlashcardDAO(db: service.writer).grade(
            cardID: cardID, grade: 3, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func gradedChapterBecomesCheckpointableAgainWhenDue() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let cardID = try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
        // Grade in the past so next_review_date lands before mondayNoon.
        try FlashcardDAO(db: service.writer).grade(
            cardID: cardID, grade: 3,
            now: StudyQueueFixtures.mondayNoon.addingTimeInterval(-30 * 86_400))

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment?.card.id == cardID)
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'checkpointAssignment'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Implement in `Shared/Database/DAOs/StudyPlanDAO.swift`. First, near the top of the file after `StudyPlanCreationResult` (~L22), add:

```swift
/// The chapter assignment a finished chapter checkpoints against (§3.1).
struct StudyCheckpointAssignment: Sendable {
    let plan: StudyPlan
    let item: StudyPlanItem
    let card: Flashcard
}
```

Then add the lookup after `setItemEnabled` (~L188):

```swift
    /// The assignment a naturally-finished chapter should checkpoint against,
    /// or nil when the chapter is not covered by an active (non-paused) plan,
    /// not yet introduced, or not due/in-progress. Multi-plan overlap on one
    /// chapter: one checkpoint per boundary — the earliest-due assignment wins
    /// (in-progress cards have no due date and sort first); the others stay due.
    func checkpointAssignment(
        audiobookID: String,
        chapterIndex: Int,
        now: Date = Date()
    ) throws -> StudyCheckpointAssignment? {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            let plans = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_paused") == false)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)

            var candidates: [StudyCheckpointAssignment] = []
            for plan in plans {
                let items = try StudyPlanItem
                    .filter(Column("plan_id") == plan.id)
                    .filter(Column("kind") == StudyPlanItemKind.chapter.rawValue)
                    .filter(Column("chapter_index") == chapterIndex)
                    .filter(Column("is_enabled") == true)
                    .filter(Column("introduced_at") != nil)
                    .fetchAll(db)
                for item in items {
                    guard let flashcardID = item.flashcardID,
                        let card = try Flashcard.fetchOne(db, key: flashcardID),
                        card.isEnabled
                    else { continue }
                    let isInProgress = card.repetitions == 0 && card.lastReviewedAt == nil
                    let isDue = card.nextReviewDate.map { $0 <= nowString } ?? false
                    if isInProgress || isDue {
                        candidates.append(
                            StudyCheckpointAssignment(plan: plan, item: item, card: card))
                    }
                }
            }

            return candidates.min { left, right in
                (left.card.nextReviewDate ?? "") < (right.card.nextReviewDate ?? "")
            }
        }
    }
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyPlanDAOCheckpointTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add Shared/Database/DAOs/StudyPlanDAO.swift EchoTests/StudyPlanDAOCheckpointTests.swift
git commit -m "feat(study): add due/introduced checkpoint-assignment lookup to StudyPlanDAO"
```

---

## Task 5: StudyPlaybackQueueService

**Files:**
- Create: `Shared/Services/StudyPlaybackQueueService.swift`
- Test: `EchoTests/StudyPlaybackQueueServiceTests.swift`

**Interfaces:**
- Consumes: `StudyQueueBuilder.build(now:calendar:modeOverride:globalNewChapterLimit:)`, `StudyQueueEntry`, `StudyFlashcardType.listeningAssignment`, `Flashcard`, `RealTimeEventDAO.log(...)`, `FlashcardReviewMetadata` (Task 2), `StudyPlayableItem` / `StudyCheckpointEventType` (Task 1).
- Produces (used by Tasks 6 and 10):
  - `struct StudyPlaybackQueueService { let db: DatabaseWriter }`
  - `struct Advance: Equatable, Sendable { let next: StudyPlayableItem?; let skippedUnplayable: [StudyPlayableItem] }` (nested)
  - `func nextPlayableItem(after flashcardID: String?, now: Date = Date(), calendar: Calendar = .current, globalNewChapterLimit: Int? = nil, isPlayable: (StudyPlayableItem) -> Bool = { _ in true }) throws -> Advance`
  - `func markSkipped(flashcardID: String, now: Date = Date(), calendar: Calendar = .current) throws`
  - `func isSkipEligible(assignmentCardID: String) throws -> Bool`
  - `func markNeedsAttention(item: StudyPlayableItem, reason: String, now: Date = Date()) throws`
  - `func needsAttentionFlashcardIDs(now: Date = Date(), calendar: Calendar = .current) throws -> Set<String>`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyPlaybackQueueServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlaybackQueueServiceTests {
    private func cardID(frontText: String, in service: DatabaseService) throws -> String {
        try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = ?",
                    arguments: [frontText])
            })
    }

    @Test func walksTodaysQueueBookByBookAcrossBooks() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)

        let first = try queue.nextPlayableItem(
            after: nil, now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(first.next?.title == "Book A Chapter 1")
        #expect(first.skippedUnplayable.isEmpty)

        let lastBookACard = try cardID(frontText: "Book A Chapter 2", in: service)
        let crossBook = try queue.nextPlayableItem(
            after: lastBookACard,
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(crossBook.next?.title == "Book B Chapter 1")
        #expect(crossBook.next?.audiobookID == "book-b")
    }

    @Test func endOfQueueReturnsNil() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let lastCard = try cardID(frontText: "Book B Chapter 2", in: service)

        let step = try queue.nextPlayableItem(
            after: lastCard,
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(step.next == nil)
    }

    @Test func unplayableItemsAreSurfacedNeverDropped() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)

        let step = try queue.nextPlayableItem(
            after: nil,
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar,
            isPlayable: { $0.audiobookID != "book-a" }
        )

        #expect(step.next?.audiobookID == "book-b")
        #expect(step.skippedUnplayable.count == 2)
        #expect(step.skippedUnplayable.allSatisfy { $0.audiobookID == "book-a" })
    }

    @Test func markSkippedDefersToTomorrowWithoutAGrade() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let id = try cardID(frontText: "Book A Chapter 1", in: service)

        try queue.markSkipped(
            flashcardID: id, now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar)

        let card = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: id) })
        let tomorrow = StudyQueueFixtures.calendar.date(
            byAdding: .day, value: 1, to: StudyQueueFixtures.mondayNoon)!
        #expect(card.nextReviewDate == tomorrow.ISO8601Format())
        #expect(card.lastGrade == nil)
        #expect(card.repetitions == 0)

        let eventRow = try service.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT metadata_json FROM real_time_event WHERE event_type = ?",
                arguments: [StudyCheckpointEventType.chapterSkipped])
        }
        let metadata = FlashcardReviewMetadata.decode(eventRow?["metadata_json"])
        #expect(metadata?.skipped == true)
    }

    @Test func skipEligibilityRequiresNoUserCardsInChapter() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let assignmentID = try cardID(frontText: "Book A Chapter 1", in: service)

        // No user cards anywhere → eligible.
        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == true)

        // A user card inside the chapter's audio range (0..<100) → not eligible.
        try StudyQueueFixtures.seedDueCard(
            id: "user-1", audiobookID: "book-a", frontText: "My card",
            nextReviewDate: StudyQueueFixtures.mondayNoon, isEnabled: true,
            in: service)
        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == false)
    }

    @Test func userCardOutsideTheChapterRangeKeepsEligibility() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let assignmentID = try cardID(frontText: "Book A Chapter 1", in: service)

        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flashcard
                    (id, audiobook_id, front_text, back_text, media_timestamp, trigger_timing,
                     interval_days, ease_factor, repetitions, is_enabled)
                    VALUES ('user-2', 'book-a', 'Later card', 'Back', 150, 'manualOnly',
                            0, 2.5, 0, 1)
                    """)
        }

        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == true)
    }

    @Test func needsAttentionRoundTrips() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let item = StudyPlayableItem(
            flashcardID: "card-x", audiobookID: "book-a", chapterIndex: 0,
            planItemID: nil, title: "Book A Chapter 1", startTime: 0, endTime: 100)

        try queue.markNeedsAttention(
            item: item, reason: "Book not downloaded", now: StudyQueueFixtures.mondayNoon)

        let ids = try queue.needsAttentionFlashcardIDs(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(ids.contains("card-x"))
    }
}
```

- [ ] Run it (expect compile failure: `cannot find 'StudyPlaybackQueueService' in scope`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Create `Shared/Services/StudyPlaybackQueueService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Materializes today's study queue (`StudyQueueBuilder` owns ordering, daily
/// budgets, catch-up, and queue modes) into an ordered sequence of playable
/// chapter assignments, and owns the retention-neutral skip / needs-attention
/// bookkeeping around hands-free playback (design §3.2, §5.1).
struct StudyPlaybackQueueService {
    let db: DatabaseWriter

    /// The next playable item after a cursor, plus every unplayable item that
    /// was passed over on the way — the caller must surface those (announce +
    /// `markNeedsAttention`), never drop them silently.
    struct Advance: Equatable, Sendable {
        let next: StudyPlayableItem?
        let skippedUnplayable: [StudyPlayableItem]
    }

    /// - Parameter flashcardID: The item just finished (nil = start of queue).
    ///   Cross-book advance is not a special case: the next item may reference
    ///   a different book.
    func nextPlayableItem(
        after flashcardID: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        globalNewChapterLimit: Int? = nil,
        isPlayable: (StudyPlayableItem) -> Bool = { _ in true }
    ) throws -> Advance {
        let queue = try StudyQueueBuilder(db: db).build(
            now: now,
            calendar: calendar,
            globalNewChapterLimit: globalNewChapterLimit
        )
        let playable = queue.entries.compactMap(Self.playableItem)

        var remaining = playable[...]
        if let flashcardID,
            let index = playable.firstIndex(where: { $0.flashcardID == flashcardID })
        {
            remaining = playable[(index + 1)...]
        }

        var skipped: [StudyPlayableItem] = []
        for item in remaining {
            if isPlayable(item) {
                return Advance(next: item, skippedUnplayable: skipped)
            }
            skipped.append(item)
        }
        return Advance(next: nil, skippedUnplayable: skipped)
    }

    /// Only listening assignments carry a chapter audio range; text-only due
    /// reviews stay in the study session and never join hands-free playback.
    private static func playableItem(for entry: StudyQueueEntry) -> StudyPlayableItem? {
        guard entry.flashcard.cardType == StudyFlashcardType.listeningAssignment else {
            return nil
        }
        return StudyPlayableItem(
            flashcardID: entry.flashcard.id,
            audiobookID: entry.flashcard.audiobookID,
            chapterIndex: entry.item?.chapterIndex,
            planItemID: entry.item?.id,
            title: entry.flashcard.frontText,
            startTime: entry.flashcard.mediaTimestamp,
            endTime: entry.flashcard.endTimestamp
        )
    }

    /// Retention-neutral skip (§5.1): NO FSRS grade is written; the due date
    /// moves to tomorrow and a skip marker is logged under its own event type
    /// so Insights can count repeated skips without polluting the
    /// `flashcard_reviewed` grade distribution.
    func markSkipped(
        flashcardID: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard let card = try db.read({ try Flashcard.fetchOne($0, key: flashcardID) }),
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        else { return }

        let nowString = now.ISO8601Format()
        try db.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET next_review_date = ?, modified_at = ? WHERE id = ?",
                arguments: [tomorrow.ISO8601Format(), nowString, flashcardID]
            )
        }

        let metadataJSON = try FlashcardReviewMetadata(
            cardID: card.id, grade: 0, intervalDays: card.intervalDays, skipped: true
        ).encodedJSONString()
        try RealTimeEventDAO(db: db).log(
            eventType: StudyCheckpointEventType.chapterSkipped,
            audiobookID: card.audiobookID,
            mediaTimestamp: card.mediaTimestamp,
            startedAt: now,
            endedAt: now,
            title: card.frontText,
            subtitle: "Skipped",
            metadataJSON: metadataJSON,
            sourceItemID: card.id,
            sourceItemType: "flashcard"
        )
    }

    /// Skip is offered only when the chapter has no user-created cards (§5.1)
    /// — the escape hatch for "I know this chapter; stop scheduling it".
    /// User-created = any enabled card that is not an auto assignment
    /// (`card_type` may be NULL on old rows, which are user cards).
    func isSkipEligible(assignmentCardID: String) throws -> Bool {
        try db.read { db in
            guard let card = try Flashcard.fetchOne(db, key: assignmentCardID) else {
                return false
            }
            let upperBound = card.endTimestamp ?? .greatestFiniteMagnitude
            let userCardCount =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM flashcard
                        WHERE audiobook_id = ?
                          AND id != ?
                          AND is_enabled = 1
                          AND (card_type IS NULL OR card_type NOT IN (?, ?))
                          AND media_timestamp >= ?
                          AND media_timestamp < ?
                        """,
                    arguments: [
                        card.audiobookID, card.id,
                        StudyFlashcardType.listeningAssignment,
                        StudyFlashcardType.imageAssignment,
                        card.mediaTimestamp, upperBound,
                    ]
                ) ?? 0
            return userCardCount == 0
        }
    }

    /// Records that a playable item could not be played (book not downloaded,
    /// narration not rendered) so the study session can badge it — never
    /// silently dropped (§3.2).
    func markNeedsAttention(
        item: StudyPlayableItem,
        reason: String,
        now: Date = Date()
    ) throws {
        try RealTimeEventDAO(db: db).log(
            eventType: StudyCheckpointEventType.needsAttention,
            audiobookID: item.audiobookID,
            mediaTimestamp: item.startTime,
            startedAt: now,
            endedAt: now,
            title: item.title,
            subtitle: reason,
            metadataJSON: nil,
            sourceItemID: item.flashcardID,
            sourceItemType: "flashcard"
        )
    }

    /// Flashcard ids flagged needs-attention today (session badge source).
    func needsAttentionFlashcardIDs(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Set<String> {
        let dayStart = calendar.startOfDay(for: now).ISO8601Format()
        return try db.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT source_item_id FROM real_time_event
                    WHERE event_type = ? AND started_at >= ? AND source_item_id IS NOT NULL
                    """,
                arguments: [StudyCheckpointEventType.needsAttention, dayStart]
            )
            return Set(ids)
        }
    }
}
```

No pbxproj edit (Shared/ syncs everywhere; Foundation + GRDB only, so Watch/Widget stay safe).

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyPlaybackQueueServiceTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add Shared/Services/StudyPlaybackQueueService.swift EchoTests/StudyPlaybackQueueServiceTests.swift
git commit -m "feat(study): add StudyPlaybackQueueService (playable queue, skip, needs-attention)"
```

---

## Task 6: StudyCheckpointCoordinator state machine

**Files:**
- Create: `EchoCore/Services/StudyCheckpointCoordinator.swift`
- Test: `EchoTests/StudyCheckpointCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DatabaseService` (`.writer`, `.read`), `StudyPlanDAO.checkpointAssignment(...)` (Task 4), `StudyPlaybackQueueService` (Task 5), `StudyCheckpointSettings`/`CheckpointTimeoutBehavior`/`StudyPlayableItem` (Task 1), `FlashcardDAO.grade(cardID:grade:now:scheduler:)`, `RealTimeEventDAO.log(...)`, `RealTimeEventType.flashcardReviewed`, `ReviewGrade`, `FlashcardReviewMetadata` (Task 2), `Notification.Name.studyQueueDidChange`, `Logger(category:)`.
- Produces (canonical — slice 2 builds on these EXACT names; used by Tasks 7, 9, 14):
  - `@MainActor @Observable final class StudyCheckpointCoordinator`
  - `enum CheckpointAction { case good, again, skip }` (nested)
  - `struct Context: Equatable, Sendable` (nested: `flashcardID/audiobookID/chapterIndex/chapterTitle/skipEligible/sleepStopRequested`)
  - `enum State: Equatable { case idle; case checkpointActive(Context) }` (nested), `private(set) var state: State`, `private(set) var remainingSeconds: Int`
  - `init(database: DatabaseService, settingsProvider: @escaping () -> StudyCheckpointSettings, replayChapter: @escaping () -> Void, advance: @escaping (StudyPlayableItem) -> Void, announce: @escaping (String) -> Void)`
  - `@discardableResult func handleChapterEnd(audiobookID: String, chapterIndex: Int, naturalEnd: Bool) -> Bool`
  - `func resolve(_ action: CheckpointAction, now: Date = Date())`, `func timeoutFired(now: Date = Date())`, `func cancel()`, `func suspendCountdown()`, `func resumeCountdown()`
  - Post-init wiring closures (SleepTimerManager `onFire` pattern): `pausePlayback`, `isSleepStopRequested`, `fireSleepStop`, `isPlayable`, `onCheckpointActivated`, `onCheckpointResolved`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyCheckpointCoordinatorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Closure-capture harness in the SleepTimerManager ownership style: the
/// coordinator is built with recording closures so every player side effect
/// is observable without a player.
@MainActor
private final class CheckpointHarness {
    let service: DatabaseService
    var settings = StudyCheckpointSettings(
        timeoutSeconds: 30, timeoutBehavior: .replay,
        autoAdvance: true, remoteGrading: true)
    var pauseCount = 0
    var replayCount = 0
    var advanced: [StudyPlayableItem] = []
    var announcements: [String] = []
    var sleepArmed = false
    var sleepFired = 0
    var playableIDs: Set<String>? = nil  // nil = everything playable
    private(set) var coordinator: StudyCheckpointCoordinator!

    init(service: DatabaseService) {
        self.service = service
        coordinator = StudyCheckpointCoordinator(
            database: service,
            settingsProvider: { [weak self] in
                self?.settings
                    ?? StudyCheckpointSettings(
                        timeoutSeconds: 30, timeoutBehavior: .replay,
                        autoAdvance: true, remoteGrading: true)
            },
            replayChapter: { [weak self] in self?.replayCount += 1 },
            advance: { [weak self] item in self?.advanced.append(item) },
            announce: { [weak self] cue in self?.announcements.append(cue) }
        )
        coordinator.pausePlayback = { [weak self] in self?.pauseCount += 1 }
        coordinator.isSleepStopRequested = { [weak self] in self?.sleepArmed ?? false }
        coordinator.fireSleepStop = { [weak self] in self?.sleepFired += 1 }
        coordinator.isPlayable = { [weak self] item in
            self?.playableIDs.map { $0.contains(item.flashcardID) } ?? true
        }
    }
}

@MainActor
struct StudyCheckpointCoordinatorTests {
    private func harness() throws -> CheckpointHarness {
        CheckpointHarness(
            service: try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress())
    }

    private func chapterOneCard(in service: DatabaseService, book: String = "Book A") throws
        -> Flashcard
    {
        let id = try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = ?",
                    arguments: ["\(book) Chapter 1"])
            })
        return try #require(try service.read { db in try Flashcard.fetchOne(db, key: id) })
    }

    @Test func seekAcrossTheBoundaryDoesNotArm() throws {
        let h = try harness()
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: false)
        #expect(claimed == false)
        #expect(h.coordinator.state == .idle)
        #expect(h.pauseCount == 0)
    }

    @Test func nonDueChapterDoesNotArm() throws {
        let h = try harness()
        // Chapter index 2 was never introduced by the fixture.
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 2, naturalEnd: true)
        #expect(claimed == false)
        #expect(h.coordinator.state == .idle)
    }

    @Test func naturalEndOfDueChapterArmsPausesAndAnnounces() throws {
        let h = try harness()
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        #expect(claimed == true)
        #expect(h.pauseCount == 1)
        #expect(h.announcements.count == 1)
        guard case .checkpointActive(let context) = h.coordinator.state else {
            Issue.record("Expected active checkpoint")
            return
        }
        #expect(context.chapterTitle == "Book A Chapter 1")
        #expect(context.skipEligible == true)  // fixture has no user cards
        #expect(h.coordinator.remainingSeconds == 30)
    }

    @Test func waitBehaviorRunsNoCountdown() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .wait
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        #expect(h.coordinator.remainingSeconds == 0)
    }

    @Test func goodGradesAndAdvancesCrossQueue() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 3)
        #expect(graded.repetitions == 1)
        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func goodWithAutoAdvanceOffStaysPut() throws {
        let h = try harness()
        h.settings.autoAdvance = false
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.advanced.isEmpty)
        #expect(h.coordinator.state == .idle)
    }

    @Test func sleepStopIsHonoredAfterTheGradeAndSuppressesAdvance() throws {
        let h = try harness()
        h.sleepArmed = true
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.sleepFired == 1)
        #expect(h.advanced.isEmpty)
        #expect(h.replayCount == 0)
    }

    @Test func sleepStopSuppressesTheAgainReplay() throws {
        let h = try harness()
        h.sleepArmed = true
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 1)
        #expect(h.sleepFired == 1)
        #expect(h.replayCount == 0)
    }

    @Test func tappedAgainReplaysUnderReplayAndWaitBehaviors() throws {
        for behavior in [CheckpointTimeoutBehavior.replay, .wait] {
            let h = try harness()
            h.settings.timeoutBehavior = behavior
            h.coordinator.handleChapterEnd(
                audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
            h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)
            #expect(h.replayCount == 1)
            #expect(h.advanced.isEmpty)
        }
    }

    @Test func tappedAgainAdvancesUnderGradeAndAdvance() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .gradeAndAdvance
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)

        #expect(h.replayCount == 0)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func timeoutReplayGradesAgainWithTheAutoFlag() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 1)
        #expect(h.replayCount == 1)

        let metadataJSON = try h.service.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT metadata_json FROM real_time_event
                    WHERE event_type = 'flashcard_reviewed' AND source_item_id = ?
                    """,
                arguments: [card.id])
        }
        let metadata = FlashcardReviewMetadata.decode(metadataJSON)
        #expect(metadata?.auto == true)
    }

    @Test func tappedGradesCarryNoAutoFlag() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        let metadataJSON = try h.service.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT metadata_json FROM real_time_event
                    WHERE event_type = 'flashcard_reviewed' AND source_item_id = ?
                    """,
                arguments: [card.id])
        }
        #expect(FlashcardReviewMetadata.decode(metadataJSON)?.auto == nil)
    }

    @Test func timeoutWaitRecordsNoGradeAndDefersTheBoundary() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .wait
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)

        let untouched = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(untouched.lastGrade == nil)
        #expect(h.coordinator.state == .idle)

        // The same boundary must NOT re-arm (pressing play would loop forever)…
        let reclaimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        #expect(reclaimed == false)
    }

    @Test func cancelDefersLikeWaitTimeout() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.cancel()
        #expect(h.coordinator.state == .idle)
        #expect(
            h.coordinator.handleChapterEnd(
                audiobookID: "book-a", chapterIndex: 0, naturalEnd: true) == false)
    }

    @Test func skipWritesNoGradeAndAdvances() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.skip, now: StudyQueueFixtures.mondayNoon)

        let skipped = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(skipped.lastGrade == nil)
        #expect(skipped.nextReviewDate != nil)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func unplayableNextItemsAreAnnouncedAndFlagged() throws {
        let h = try harness()
        let bookACh2 = try chapterOneCard(in: h.service)  // graded away below
        // Everything in book-a after the graded chapter is unplayable.
        let bookBCard = try chapterOneCard(in: h.service, book: "Book B")
        h.playableIDs = [bookBCard.id]
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.advanced.map(\.audiobookID) == ["book-b"])
        // 1 arming announcement + 1 per skipped unplayable item.
        #expect(h.announcements.count >= 2)
        let flagged = try StudyPlaybackQueueService(db: h.service.writer)
            .needsAttentionFlashcardIDs(
                now: Date(), calendar: StudyQueueFixtures.calendar)
        #expect(!flagged.isEmpty)
        _ = bookACh2
    }

    @Test func countdownSuspendAndResumeSurviveAnInterruption() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        #expect(h.coordinator.remainingSeconds == 30)

        h.coordinator.suspendCountdown()
        #expect(h.coordinator.remainingSeconds == 30)

        h.coordinator.resumeCountdown()
        #expect(h.coordinator.remainingSeconds == 30)
        guard case .checkpointActive = h.coordinator.state else {
            Issue.record("Checkpoint should survive an interruption")
            return
        }
    }

    @Test func aSecondBoundaryWhileActiveIsIgnored() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        let second = h.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        #expect(second == false)
        #expect(h.pauseCount == 1)
    }
}
```

- [ ] Run it (expect compile failure: `cannot find 'StudyCheckpointCoordinator' in scope`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Create `EchoCore/Services/StudyCheckpointCoordinator.swift` (platform-neutral: Foundation/GRDB/Observation/os.log only — NO UIKit; compiles in iOS, macOS, and echo-cli, so no pbxproj exceptions):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// The end-of-chapter grade checkpoint state machine (design §3.1):
/// `idle → checkpointActive → resolved (idle)`.
///
/// Owned by the player model on each platform, in the SleepTimerManager style:
/// constructor closures supply the required player side effects; the
/// `@ObservationIgnored` closure properties below are wired after construction
/// for the optional interplay seams (sleep timer, playability, notification
/// channel). The armed checkpoint is deliberately NOT persisted: a dead
/// process never writes a grade — on next launch the chapter is simply still
/// due (§8).
@MainActor @Observable
final class StudyCheckpointCoordinator {

    enum CheckpointAction { case good, again, skip }

    /// What the overlay/panel renders while a checkpoint is active.
    struct Context: Equatable, Sendable {
        let flashcardID: String
        let audiobookID: String
        let chapterIndex: Int
        let chapterTitle: String
        /// Skip is offered only when the chapter has no user cards (§5.1).
        let skipEligible: Bool
        /// End-of-chapter sleep timer was armed at this boundary: the user
        /// asked Echo to stop — grade, then stop (replay/advance suppressed).
        let sleepStopRequested: Bool
    }

    enum State: Equatable {
        case idle
        case checkpointActive(Context)
    }

    private(set) var state: State = .idle
    /// Seconds left on the countdown; 0 when no countdown runs (`.wait`).
    private(set) var remainingSeconds: Int = 0

    // MARK: Post-construction wiring (SleepTimerManager onFire/onTick pattern)

    /// Pauses playback at the boundary. Must be wired before the first claim.
    @ObservationIgnored var pausePlayback: (() -> Void)?
    /// Whether the end-of-chapter sleep timer is armed right now.
    @ObservationIgnored var isSleepStopRequested: (() -> Bool)?
    /// Honors the sleep stop after the grade is written.
    @ObservationIgnored var fireSleepStop: (() -> Void)?
    /// Whether an item can actually play (book on disk, narration rendered).
    @ObservationIgnored var isPlayable: ((StudyPlayableItem) -> Bool)?
    /// Parallel-channel hooks — iOS posts/removes the interactive notification.
    @ObservationIgnored var onCheckpointActivated: ((Context) -> Void)?
    @ObservationIgnored var onCheckpointResolved: (() -> Void)?

    @ObservationIgnored private let database: DatabaseService
    @ObservationIgnored private let settingsProvider: () -> StudyCheckpointSettings
    @ObservationIgnored private let replayChapter: () -> Void
    @ObservationIgnored private let advance: (StudyPlayableItem) -> Void
    @ObservationIgnored private let announce: (String) -> Void

    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var countdownSuspended = false
    /// A boundary deferred without a grade (wait timeout / dismissal): never
    /// re-claim it on the next poll tick, or pressing play at the boundary
    /// would re-arm the same checkpoint forever. Cleared on replay/advance or
    /// when a different boundary arrives.
    @ObservationIgnored private var deferredBoundary: DeferredBoundary?

    private struct DeferredBoundary: Equatable {
        let audiobookID: String
        let chapterIndex: Int
    }

    @ObservationIgnored private let logger = Logger(category: "StudyCheckpoint")

    init(
        database: DatabaseService,
        settingsProvider: @escaping () -> StudyCheckpointSettings,
        replayChapter: @escaping () -> Void,
        advance: @escaping (StudyPlayableItem) -> Void,
        announce: @escaping (String) -> Void
    ) {
        self.database = database
        self.settingsProvider = settingsProvider
        self.replayChapter = replayChapter
        self.advance = advance
        self.announce = announce
    }

    deinit {
        // Same rationale as SleepTimerManager: the Timer is scheduled on the
        // main run loop, so invalidate it on the main actor rather than on
        // whatever thread ARC runs the deinit (CODE_AUDIT.md §3.3; not
        // `isolated deinit` — iOS 26.2 sim runtime bug, §3.9).
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
        }
    }

    // MARK: - Arming

    /// Claims a NATURALLY-played chapter end when the finished chapter is a
    /// due/introduced assignment in an active plan. A seek or manual skip
    /// across the boundary must pass `naturalEnd: false` (skipping is not
    /// listening; FSRS grades must follow real exposure). Returns true when
    /// claimed — the caller suppresses its own boundary handling (advance and
    /// end-of-chapter sleep both defer to the checkpoint's resolution).
    @discardableResult
    func handleChapterEnd(audiobookID: String, chapterIndex: Int, naturalEnd: Bool) -> Bool {
        guard naturalEnd, case .idle = state else { return false }
        let boundary = DeferredBoundary(audiobookID: audiobookID, chapterIndex: chapterIndex)
        if deferredBoundary == boundary { return false }
        deferredBoundary = nil

        let assignment: StudyCheckpointAssignment?
        do {
            assignment = try StudyPlanDAO(db: database.writer).checkpointAssignment(
                audiobookID: audiobookID, chapterIndex: chapterIndex)
        } catch {
            logger.error("Checkpoint lookup failed: \(error.localizedDescription)")
            return false
        }
        guard let assignment else { return false }

        let skipEligible =
            (try? StudyPlaybackQueueService(db: database.writer)
                .isSkipEligible(assignmentCardID: assignment.card.id)) ?? false

        pausePlayback?()
        let context = Context(
            flashcardID: assignment.card.id,
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            chapterTitle: assignment.card.frontText,
            skipEligible: skipEligible,
            sleepStopRequested: isSleepStopRequested?() ?? false
        )
        state = .checkpointActive(context)
        announce(String(localized: "Chapter finished. How did it go — good, or again?"))
        startCountdownIfNeeded()
        onCheckpointActivated?(context)
        return true
    }

    // MARK: - Resolution

    func resolve(_ action: CheckpointAction, now: Date = Date()) {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()

        switch action {
        case .good:
            grade(.good, context: context, auto: false, now: now)
            finish(context: context, replay: false)
        case .again:
            grade(.again, context: context, auto: false, now: now)
            // Tapped Again replays unless the user chose "grade and move on".
            finish(context: context, replay: settingsProvider().timeoutBehavior != .gradeAndAdvance)
        case .skip:
            do {
                try StudyPlaybackQueueService(db: database.writer)
                    .markSkipped(flashcardID: context.flashcardID, now: now)
            } catch {
                logger.error("Checkpoint skip failed: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
            finish(context: context, replay: false)
        }
    }

    /// Countdown expiry, per the 3-way setting (§3.1). Public so tests drive
    /// it directly; the Timer only re-invokes this.
    func timeoutFired(now: Date = Date()) {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()

        switch settingsProvider().timeoutBehavior {
        case .replay:
            grade(.again, context: context, auto: true, now: now)
            finish(context: context, replay: true)
        case .gradeAndAdvance:
            grade(.again, context: context, auto: true, now: now)
            finish(context: context, replay: false)
        case .wait:
            // Defensive: `.wait` never starts a countdown. No grade — the
            // chapter stays due today and the queue naturally resurfaces it.
            defer_(context: context)
        }
    }

    /// User dismissed the checkpoint: defer without a grade.
    func cancel() {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()
        defer_(context: context)
    }

    private func defer_(context: Context) {
        deferredBoundary = DeferredBoundary(
            audiobookID: context.audiobookID, chapterIndex: context.chapterIndex)
        state = .idle
        onCheckpointResolved?()
    }

    // MARK: - Countdown

    /// The countdown suspends with playback during an AVAudioSession
    /// interruption (phone call) and resumes with it (§8).
    func suspendCountdown() {
        guard countdownTimer != nil, !countdownSuspended else { return }
        countdownSuspended = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func resumeCountdown() {
        guard case .checkpointActive = state, countdownSuspended else { return }
        countdownSuspended = false
        startTimer(seconds: max(1, remainingSeconds))
    }

    private func startCountdownIfNeeded() {
        let settings = settingsProvider()
        guard settings.timeoutBehavior != .wait else {
            // Wait means wait: no countdown runs at all (§6).
            remainingSeconds = 0
            return
        }
        startTimer(
            seconds: StudyCheckpointSettings.snappedTimeoutSeconds(settings.timeoutSeconds))
    }

    private func startTimer(seconds: Int) {
        countdownTimer?.invalidate()
        remainingSeconds = seconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
                if self.remainingSeconds <= 0 {
                    self.timeoutFired()
                }
            }
        }
        if let countdownTimer {
            RunLoop.main.add(countdownTimer, forMode: .common)
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSuspended = false
        remainingSeconds = 0
    }

    // MARK: - Grading

    /// One grading brain: the exact FlashcardDAO/FSRS path the study session
    /// uses, plus the review event with the `auto` flag when timeout-fired.
    private func grade(_ grade: ReviewGrade, context: Context, auto: Bool, now: Date) {
        do {
            guard
                let card = try database.read({
                    try Flashcard.fetchOne($0, key: context.flashcardID)
                })
            else { return }
            try FlashcardDAO(db: database.writer).grade(
                cardID: card.id, grade: grade.rawValue, now: now)
            let metadataJSON = try FlashcardReviewMetadata(
                card: card, grade: grade.rawValue, auto: auto ? true : nil
            ).encodedJSONString()
            try RealTimeEventDAO(db: database.writer).log(
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: auto ? "Grade: \(grade.rawValue) (auto)" : "Grade: \(grade.rawValue)",
                metadataJSON: metadataJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            logger.error("Checkpoint grade failed: \(error.localizedDescription)")
        }
    }

    /// After the grade/skip is written: honor a sleep stop, replay, or advance.
    private func finish(context: Context, replay: Bool) {
        state = .idle
        onCheckpointResolved?()

        if context.sleepStopRequested {
            // The user asked Echo to stop: grade, then stop (§4).
            fireSleepStop?()
            return
        }
        if replay {
            deferredBoundary = nil
            replayChapter()
            return
        }
        guard settingsProvider().autoAdvance else { return }
        advanceToNextItem(after: context.flashcardID)
    }

    private func advanceToNextItem(after flashcardID: String) {
        let service = StudyPlaybackQueueService(db: database.writer)
        do {
            let step = try service.nextPlayableItem(
                after: flashcardID,
                globalNewChapterLimit: settingsProvider().globalNewChapterLimit,
                isPlayable: { isPlayable?($0) ?? true }
            )
            for unplayable in step.skippedUnplayable {
                try? service.markNeedsAttention(
                    item: unplayable,
                    reason: String(
                        localized: "Couldn't play this chapter — check it in the study session.")
                )
                announce(
                    String(localized: "Skipping \(unplayable.title) — it can't play right now."))
            }
            if let next = step.next {
                deferredBoundary = nil
                if let itemID = next.planItemID {
                    // Hands-free playback introduces the chapter, same as the
                    // study session does (no-op when already introduced).
                    try? StudyPlanDAO(db: database.writer).markIntroduced(itemIDs: [itemID])
                }
                advance(next)
            } else {
                announce(String(localized: "That's the end of today's study queue. Nice work."))
            }
        } catch {
            logger.error("Checkpoint advance failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyCheckpointCoordinatorTests
```

Also re-run the neighbors the coordinator leans on:

```bash
make test-only FILTER=EchoTests/StudyPlaybackQueueServiceTests
make test-only FILTER=EchoTests/StudyPlanDAOCheckpointTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Services/StudyCheckpointCoordinator.swift EchoTests/StudyCheckpointCoordinatorTests.swift
git commit -m "feat(study): add StudyCheckpointCoordinator state machine (arming, timeout, auto flag, sleep/loop interplay)"
```

---

## Task 7: iOS arming + PlayerModel wiring (announcer, cross-book advance, remote-grade window, interruption)

**Files:**
- Create: `EchoCore/Services/StudyCheckpointAnnouncer.swift`
- Create: `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift`
- Modify: `EchoCore/Services/PlaybackController.swift` (closure decl after L52; call site in `applyChapterLoopIfNeeded` at L873)
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (stored props ~L499; `databaseService` didSet ~L623; `configureRemoteCommandsIfNeeded` ~L1614)
- Modify: `EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift` (L29–39)
- Modify: `Echo.xcodeproj/project.pbxproj` (2 exception lists)
- Test: `EchoTests/PlayerModelStudyCheckpointTests.swift`

**Interfaces:**
- Consumes: `StudyCheckpointCoordinator` (Task 6), `StudyCheckpointSettings`/`CheckpointTimeoutBehavior`/`StudyPlayableItem` (Task 1), `SettingsManager` checkpoint props (Task 3), `PlaybackController.seekToChapter(at:)`, `PlayerModel.loadFolder(_:autoplay:)` / `seek(toSeconds:)` / `play()` / `pause()` / `sleepTimerManager` / `sleepTimerMode` / `folderURL` / `currentChapterIndex` / `selectedTab`, `ChimeSound.softChime`, `NowPlayingController.configureRemoteCommands`.
- Produces (used by Tasks 8–10, 14):
  - `PlaybackController.coordinator_handleChapterEndCheckpoint: ((_ chapterIndex: Int) -> Bool)?`
  - `PlayerModel.checkpointCoordinator: StudyCheckpointCoordinator?` (observable stored property)
  - `PlayerModel.configureStudyCheckpoint()`, `PlayerModel.playCheckpointItem(_ item: StudyPlayableItem)`, `PlayerModel.playStudyAssignment(_ card: Flashcard)`, `PlayerModel.consumeRemoteSkipAsCheckpointGrade(_:) -> Bool`
  - `PlayerModel.pendingRetirePrompt` is NOT added here (Task 11)
  - `@MainActor final class StudyCheckpointAnnouncer { func announce(_ line: String) }`

**Steps:**

- [ ] Write the failing test at `EchoTests/PlayerModelStudyCheckpointTests.swift` (smoke-level: the state-machine logic is already covered by Task 6; this pins the wiring):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct PlayerModelStudyCheckpointTests {
    @Test func settingTheDatabaseCreatesTheCoordinator() throws {
        let model = PlayerModel()
        #expect(model.checkpointCoordinator == nil)

        model.databaseService = try DatabaseService(inMemory: ())

        #expect(model.checkpointCoordinator != nil)
    }

    @Test func remoteSkipBecomesAGradeOnlyWhileACheckpointIsActive() throws {
        let model = PlayerModel()
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        model.databaseService = service

        // Idle: the window is closed, commands pass through.
        #expect(model.consumeRemoteSkipAsCheckpointGrade(.good) == false)

        let coordinator = try #require(model.checkpointCoordinator)
        let claimed = coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        #expect(claimed == true)

        // Active + setting default-on: skip-forward means Good.
        #expect(model.consumeRemoteSkipAsCheckpointGrade(.good) == true)
        #expect(coordinator.state == .idle)

        let graded = try #require(
            try service.read { db in
                try Flashcard.fetchOne(
                    db,
                    sql: "SELECT * FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
        #expect(graded.lastGrade == 3)
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'checkpointCoordinator'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Create `EchoCore/Services/StudyCheckpointAnnouncer.swift` (platform-neutral AVFoundation; no pbxproj exceptions):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Speaks checkpoint cues through `AVSpeechSynthesizer` — deliberately NOT the
/// Kokoro narration engine: its model load latency is seconds, and a
/// checkpoint cue must be instant. A short chime precedes the line when the
/// bundled chime asset exists (same lookup as `DefaultChimePlayer`).
@MainActor
final class StudyCheckpointAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var chimePlayer: AVAudioPlayer?

    func announce(_ line: String) {
        playChime()
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func playChime() {
        guard let url = chimeURL() else { return }
        chimePlayer = try? AVAudioPlayer(contentsOf: url)
        chimePlayer?.volume = 0.4
        chimePlayer?.play()
    }

    private func chimeURL() -> URL? {
        for ext in ["caf", "wav", "aiff", "aif", "mp3", "m4a"] {
            if let url = Bundle.main.url(
                forResource: ChimeSound.softChime.rawValue, withExtension: ext)
            {
                return url
            }
        }
        return nil
    }
}
```

- [ ] Modify `EchoCore/Services/PlaybackController.swift`:

**(a)** After the `coordinator_handleChapterEndSleepTimer` declaration (L52), add:

```swift
    @ObservationIgnored var coordinator_handleChapterEndCheckpoint: ((_ chapterIndex: Int) -> Bool)?
```

**(b)** In `applyChapterLoopIfNeeded()` (L862–904), insert the checkpoint claim as the FIRST branch inside `if t >= (c.endSeconds - 0.5) {` — before the existing sleep-timer check:

```swift
        if t >= (c.endSeconds - 0.5) {
            // Chapter checkpoint gets first claim on a naturally played
            // boundary (design §3.1). Loop wins: checkpoints never fire inside
            // an intentional loop (§4), so only `.off` reaches the claim. The
            // end-of-chapter sleep stop is honored by the coordinator AFTER
            // the grade, so its check stays below and is skipped on a claim.
            if loopMode == .off, coordinator_handleChapterEndCheckpoint?(idx) == true {
                return
            }
            if coordinator_handleChapterEndSleepTimer?() == true {
```

(Reaching this line already implies a natural play-through: `applyChapterLoopIfNeeded` bails on `isManualSeeking` and `isSeekingForChapterBoundary`, and manual chapter skips go through `seekToChapter(at:)`, which sets `isManualSeeking`.)

- [ ] Modify `EchoCore/ViewModels/PlayerModel.swift`:

**(a)** Near the other owned services (after `let playerLoadingCoordinator = PlayerLoadingCoordinator()`, ~L503), add:

```swift
    /// Chapter-checkpoint state machine (design §3.1). Created when the
    /// database arrives (see `databaseService` didSet) — an observable stored
    /// property so the overlay re-renders when it is (re)created.
    private(set) var checkpointCoordinator: StudyCheckpointCoordinator?
    @ObservationIgnored let checkpointAnnouncer = StudyCheckpointAnnouncer()
```

(The notification-channel property `checkpointNotifications` is added in Task 8 — this task must build with just coordinator + announcer.)

**(b)** In the `databaseService` setter (L623–634), after `configureContinuousAlignment()`, add:

```swift
            configureStudyCheckpoint()
```

**(c)** In `configureRemoteCommandsIfNeeded()` (L1614–1631), replace the four navigation/skip closures so the lock-screen/CarPlay window reinterprets them while a checkpoint is active (skip-forward/next = Good, skip-back/previous = Again — steering-wheel and headset buttons send next/previous):

```swift
    private func configureRemoteCommandsIfNeeded() {
        nowPlayingController.configureRemoteCommands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextTrack: { [weak self] in
                guard let self else { return }
                if self.consumeRemoteSkipAsCheckpointGrade(.good) { return }
                self.skipForwardNavigation()
            },
            skipBackward: { [weak self] in
                guard let self else { return }
                if self.consumeRemoteSkipAsCheckpointGrade(.again) { return }
                self.skipBackward30()
            },
            skipForward: { [weak self] in
                guard let self else { return }
                if self.consumeRemoteSkipAsCheckpointGrade(.good) { return }
                self.skipForward30()
            },
            previousTrack: { [weak self] in
                guard let self else { return }
                if self.consumeRemoteSkipAsCheckpointGrade(.again) { return }
                self.skipBackwardNavigation()
            },
            seek: { [weak self] position in
                self?.playbackController.seekFromRemoteCommand(positionTime: position)
            },
            skipBackwardInterval: settingsManager?.seekBackwardDuration
                ?? SettingsManager.Defaults.seekBackwardDuration,
            skipForwardInterval: settingsManager?.seekForwardDuration
                ?? SettingsManager.Defaults.seekForwardDuration
        )
    }
```

- [ ] Create `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Chapter checkpoint wiring (iOS player)

extension PlayerModel {
    /// (Re)creates the checkpoint coordinator when the database arrives.
    /// Mirrors `configureContinuousAlignment()` — called from the
    /// `databaseService` didSet.
    func configureStudyCheckpoint() {
        guard let db = databaseService else {
            checkpointCoordinator = nil
            playbackController.coordinator_handleChapterEndCheckpoint = nil
            return
        }
        let coordinator = StudyCheckpointCoordinator(
            database: db,
            settingsProvider: { [weak self] in
                self?.currentCheckpointSettings()
                    ?? StudyCheckpointSettings(
                        timeoutSeconds: SettingsManager.Defaults.checkpointTimeoutSeconds,
                        timeoutBehavior: .replay,
                        autoAdvance: SettingsManager.Defaults.checkpointAutoAdvance,
                        remoteGrading: SettingsManager.Defaults.checkpointRemoteGrading)
            },
            replayChapter: { [weak self] in
                guard let self, let idx = self.currentChapterIndex else { return }
                self.playbackController.seekToChapter(at: idx)
                self.play()
            },
            advance: { [weak self] item in
                self?.playCheckpointItem(item)
            },
            announce: { [weak self] cue in
                self?.checkpointAnnouncer.announce(cue)
            }
        )
        coordinator.pausePlayback = { [weak self] in self?.pause() }
        coordinator.isSleepStopRequested = { [weak self] in
            if case .endOfChapter = self?.sleepTimerMode { return true }
            return false
        }
        coordinator.fireSleepStop = { [weak self] in
            self?.sleepTimerManager.evaluateAtChapterEnd()
        }
        coordinator.isPlayable = { item in
            // Unplayable = the book's folder/file is gone (undownloaded ABS
            // book, ejected drive). Non-file identities are assumed playable.
            guard let url = URL(string: item.audiobookID), url.isFileURL else { return true }
            return (try? url.checkResourceIsReachable()) ?? false
        }
        checkpointCoordinator = coordinator

        playbackController.coordinator_handleChapterEndCheckpoint = { [weak self] chapterIndex in
            guard let self, let bookID = self.folderURL?.absoluteString else { return false }
            return self.checkpointCoordinator?.handleChapterEnd(
                audiobookID: bookID, chapterIndex: chapterIndex, naturalEnd: true) ?? false
        }
    }

    private func currentCheckpointSettings() -> StudyCheckpointSettings? {
        guard let settings = settingsManager else { return nil }
        return StudyCheckpointSettings(
            timeoutSeconds: settings.checkpointTimeoutSeconds,
            timeoutBehavior: CheckpointTimeoutBehavior(rawValue: settings.checkpointTimeoutBehavior)
                ?? .replay,
            autoAdvance: settings.checkpointAutoAdvance,
            remoteGrading: settings.checkpointRemoteGrading,
            globalNewChapterLimit: settings.studyGlobalNewChapterLimit)
    }

    /// Loads/seeks/plays one study queue item — the cross-book advance path.
    /// Same load-then-settle pattern as the old StatsView helper: `loadFolder`
    /// is async under the hood, so the seek waits 300 ms for the item to load.
    func playCheckpointItem(_ item: StudyPlayableItem) {
        let bookURL = URL(string: item.audiobookID) ?? URL(fileURLWithPath: item.audiobookID)
        if folderURL?.absoluteString != item.audiobookID {
            loadFolder(bookURL, autoplay: false)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.seek(toSeconds: max(0, item.startTime + 0.05))
            self.play()
        }
    }

    /// "Play Assignment" from the study session — one grading brain, two
    /// entrances (§4): playback goes through the same path the checkpoint
    /// advance uses, and the checkpoint itself fires at the chapter end.
    func playStudyAssignment(_ card: Flashcard) {
        selectedTab = .nowPlaying
        playCheckpointItem(
            StudyPlayableItem(
                flashcardID: card.id,
                audiobookID: card.audiobookID,
                chapterIndex: nil,
                planItemID: nil,
                title: card.frontText,
                startTime: card.mediaTimestamp,
                endTime: card.endTimestamp))
    }

    /// The remote-command grading window (§3.3): while a checkpoint is active
    /// and the setting is on, skip-forward means Good and skip-back means
    /// Again. Returns true when the command was consumed as a grade.
    func consumeRemoteSkipAsCheckpointGrade(
        _ action: StudyCheckpointCoordinator.CheckpointAction
    ) -> Bool {
        guard let coordinator = checkpointCoordinator,
            case .checkpointActive = coordinator.state,
            settingsManager?.checkpointRemoteGrading
                ?? SettingsManager.Defaults.checkpointRemoteGrading
        else { return false }
        coordinator.resolve(action)
        return true
    }
}
```

- [ ] Modify `EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift` (L29–39) — the countdown suspends with playback during a call and resumes with it:

```swift
    func playbackControllerInterruptionBegan(_ controller: PlaybackController) {
        wasPlayingBeforeInterruption = isPlaying
        // A phone call suspends the checkpoint countdown along with playback
        // (design §8); it resumes when the interruption ends.
        checkpointCoordinator?.suspendCountdown()
        pause()
    }

    func playbackControllerInterruptionEnded(_ controller: PlaybackController, shouldResume: Bool) {
        checkpointCoordinator?.resumeCountdown()
        if shouldResume && wasPlayingBeforeInterruption {
            play()
        }
        wasPlayingBeforeInterruption = false
    }
```

- [ ] pbxproj target membership: `PlayerModel.swift` is excluded from Echo macOS and echo-cli, so its new extension must be too. In `Echo.xcodeproj/project.pbxproj`, add the line

```
				"ViewModels/PlayerModel+StudyCheckpoint.swift",
```

immediately after the existing `"ViewModels/PlayerModel+Audiobookshelf.swift",` entry in BOTH exception sets:
  - `4FEA03AA769144F6DBB2EF55 /* Exceptions for "EchoCore" folder in "echo-cli" target */` (~L190)
  - `718DD03F18BB433E7AD362E2 /* Exceptions for "EchoCore" folder in "Echo macOS" target */` (~L312)

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/PlayerModelStudyCheckpointTests
```

- [ ] Verify SPDX still line 1 in all touched Swift files, then commit:

```bash
git add EchoCore/Services/StudyCheckpointAnnouncer.swift \
        "EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift" \
        EchoCore/Services/PlaybackController.swift \
        EchoCore/ViewModels/PlayerModel.swift \
        "EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift" \
        Echo.xcodeproj/project.pbxproj \
        EchoTests/PlayerModelStudyCheckpointTests.swift
git commit -m "feat(player): arm chapter checkpoints from natural chapter ends on iOS"
```

---

## Task 8: iOS interactive-notification channel

**Files:**
- Create: `EchoCore/Services/StudyCheckpointNotificationService.swift` (entire file inside `#if os(iOS)` — compiles to nothing on macOS/echo-cli, so NO pbxproj exceptions)
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (stored property, ~L505 next to `checkpointAnnouncer`)
- Modify: `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift` (wire post/remove/action into `configureStudyCheckpoint()`)

**Interfaces:**
- Consumes: `StudyCheckpointCoordinator.CheckpointAction` / `.Context` / closures (Task 6), UserNotifications.
- Produces (used by PlayerModel only):
  - `@MainActor final class StudyCheckpointNotificationService: NSObject, UNUserNotificationCenterDelegate`
  - `static let categoryIdentifier = "STUDY_CHECKPOINT"`, `goodActionIdentifier = "GOOD"`, `againActionIdentifier = "AGAIN"`, `notificationIdentifier = "com.echo.audiobooks.studyCheckpoint"`
  - `var onAction: ((StudyCheckpointCoordinator.CheckpointAction) -> Void)?`, `func activate()`, `func postCheckpoint(chapterTitle: String)`, `func removeCheckpoint()`

**This is a UI/system-channel task: notification delivery cannot be unit-tested (no failing-test cycle). Verification is `make build-tests` + the existing suites staying green + Task 15's manual checklist.**

**Steps:**

- [ ] Create `EchoCore/Services/StudyCheckpointNotificationService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import UserNotifications

    /// The interactive-notification channel for chapter checkpoints: a
    /// `STUDY_CHECKPOINT` category with Good/Again actions posts while the
    /// grade window is open (screen-off listening). It runs in PARALLEL with
    /// the in-player overlay and the remote-command window; first channel to
    /// answer wins. Strictly additive: when notification permission is denied
    /// the other channels still work (design §3.3, §8).
    @MainActor
    final class StudyCheckpointNotificationService: NSObject, UNUserNotificationCenterDelegate {
        static let categoryIdentifier = "STUDY_CHECKPOINT"
        static let goodActionIdentifier = "GOOD"
        static let againActionIdentifier = "AGAIN"
        static let notificationIdentifier = "com.echo.audiobooks.studyCheckpoint"

        /// Wired by PlayerModel to `checkpointCoordinator.resolve(_:)`.
        var onAction: ((StudyCheckpointCoordinator.CheckpointAction) -> Void)?

        private var didActivate = false

        /// Registers the category and installs self as the center delegate so
        /// action taps reach `onAction`. Idempotent.
        func activate() {
            guard !didActivate else { return }
            didActivate = true

            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let good = UNNotificationAction(
                identifier: Self.goodActionIdentifier,
                title: String(localized: "Good"),
                options: [])
            let again = UNNotificationAction(
                identifier: Self.againActionIdentifier,
                title: String(localized: "Again"),
                options: [])
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: Self.categoryIdentifier,
                    actions: [good, again],
                    intentIdentifiers: [],
                    options: [])
            ])
        }

        func postCheckpoint(chapterTitle: String) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Chapter finished")
            content.body = String(localized: "How did \"\(chapterTitle)\" go?")
            // No sound: the announcer already spoke the cue.
            content.categoryIdentifier = Self.categoryIdentifier
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: Self.notificationIdentifier,
                    content: content,
                    trigger: nil))
        }

        func removeCheckpoint() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(
                withIdentifiers: [Self.notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
        }

        // MARK: - UNUserNotificationCenterDelegate

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let actionID = response.actionIdentifier
            await MainActor.run {
                switch actionID {
                case Self.goodActionIdentifier: onAction?(.good)
                case Self.againActionIdentifier: onAction?(.again)
                default: break
                }
            }
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            // Foreground: the in-player overlay is already showing. Returning
            // no options matches the app's pre-delegate behavior (no foreground
            // banners) for every other notification too.
            []
        }
    }
#endif
```

- [ ] In `EchoCore/ViewModels/PlayerModel.swift`, next to `checkpointAnnouncer` (~L505), add:

```swift
    @ObservationIgnored let checkpointNotifications = StudyCheckpointNotificationService()
```

(PlayerModel is iOS-only — excluded from macOS and echo-cli — so no `#if` is needed here.)

- [ ] In `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift`, inside `configureStudyCheckpoint()` immediately before `checkpointCoordinator = coordinator`, add:

```swift
        coordinator.onCheckpointActivated = { [weak self] context in
            self?.checkpointNotifications.postCheckpoint(chapterTitle: context.chapterTitle)
        }
        coordinator.onCheckpointResolved = { [weak self] in
            self?.checkpointNotifications.removeCheckpoint()
        }
        checkpointNotifications.onAction = { [weak self] action in
            self?.checkpointCoordinator?.resolve(action)
        }
        checkpointNotifications.activate()
```

- [ ] Build + re-run the wiring suite (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/PlayerModelStudyCheckpointTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Services/StudyCheckpointNotificationService.swift \
        EchoCore/ViewModels/PlayerModel.swift \
        "EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift"
git commit -m "feat(study): add STUDY_CHECKPOINT interactive-notification channel on iOS"
```

---

## Task 9: Checkpoint panel view + iOS overlay presentation

**Files:**
- Create: `EchoCore/Views/StudyCheckpointPanelView.swift` (shared by iOS overlay + macOS panel; references ONLY the coordinator, never PlayerModel)
- Modify: `EchoCore/Views/RootTabView.swift` (outer `ZStack(alignment: .top)` in `RootTabView.body`, ~L163)
- Modify: `Echo.xcodeproj/project.pbxproj` (echo-cli exception only)

**Interfaces:**
- Consumes: `StudyCheckpointCoordinator` (`state`, `remainingSeconds`, `resolve(_:)`, `cancel()`), `ReviewGrade.again/.good` labels, `PlayerModel.checkpointCoordinator` (Task 7).
- Produces: `struct StudyCheckpointPanelView: View { let coordinator: StudyCheckpointCoordinator }` (used again by Task 14 on macOS).

**UI-only task: no unit-test cycle (UI tests are excluded from the Echo scheme by convention). Verification is `make build-tests` compiling both files and Task 15's builds + manual checklist.**

**Steps:**

- [ ] Create `EchoCore/Views/StudyCheckpointPanelView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The checkpoint grade card: Again / Good (+ Skip when the chapter has no
/// user cards) with a countdown readout. Shared by the iOS in-player overlay
/// and the macOS player-window panel — the platform hosts decide presentation;
/// this view only renders the active context and renders nothing when idle.
struct StudyCheckpointPanelView: View {
    let coordinator: StudyCheckpointCoordinator

    var body: some View {
        if case .checkpointActive(let context) = coordinator.state {
            VStack(spacing: 16) {
                header(context: context)
                gradeButtons(context: context)
                Button("Not Now") { coordinator.cancel() }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
        }
    }

    private func header(context: StudyCheckpointCoordinator.Context) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                Text("Chapter Checkpoint")
                    .font(.caption)
                Spacer()
                if coordinator.remainingSeconds > 0 {
                    Text("\(coordinator.remainingSeconds)")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.secondary.opacity(0.12), in: .circle)
                        .accessibilityLabel(
                            Text("\(coordinator.remainingSeconds) seconds left"))
                }
            }
            .foregroundStyle(.secondary)
            Text(context.chapterTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func gradeButtons(context: StudyCheckpointCoordinator.Context) -> some View {
        HStack(spacing: 8) {
            Button(ReviewGrade.again.label) { coordinator.resolve(.again) }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            if context.skipEligible {
                Button("Skip") { coordinator.resolve(.skip) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            Button(ReviewGrade.good.label) { coordinator.resolve(.good) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }
}
```

- [ ] Modify `EchoCore/Views/RootTabView.swift`. First Read the file around `var body: some View` (~L161) to see where the outer `ZStack(alignment: .top) { ... }` closes and its modifier chain begins. Attach the overlay to that ZStack as the FIRST modifier after its closing brace:

```swift
        .overlay(alignment: .bottom) {
            checkpointOverlay
        }
```

and add this computed property to `RootTabView` (next to the other private helpers at the bottom of the struct):

```swift
    /// The end-of-chapter grade window (design §3.3). Bottom-anchored so the
    /// player chrome stays visible behind it; renders nothing while idle.
    @ViewBuilder
    private var checkpointOverlay: some View {
        if let coordinator = model.checkpointCoordinator,
            case .checkpointActive = coordinator.state
        {
            StudyCheckpointPanelView(coordinator: coordinator)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
```

- [ ] pbxproj: add the line

```
				Views/StudyCheckpointPanelView.swift,
```

to the echo-cli exception set ONLY (`4FEA03AA769144F6DBB2EF55`, alphabetical — after `Views/StandaloneTranscriptView.swift,` and before `Views/Stats/BookStatsView.swift,`). Do NOT exclude it from Echo macOS: Task 14 reuses it there.

- [ ] Build-verify (expect clean build; the panel + overlay compile):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Views/StudyCheckpointPanelView.swift EchoCore/Views/RootTabView.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(study): shared checkpoint grade panel + iOS in-player overlay"
```

---

## Task 10: Study session — Skip, needs-attention, one grading brain

**Files:**
- Modify: `EchoCore/ViewModels/StudySessionViewModel.swift` (`loadQueue` L43–66; new methods after `gradeCurrent` L100)
- Modify: `EchoCore/Views/StudyAssignmentCardView.swift` (struct props L10–15; body L17–71)
- Modify: `EchoCore/Views/StudySessionView.swift` (`StudyAssignmentCardView(` call, L79–85)
- Modify: `EchoCore/Views/Stats/StatsView.swift` (`onRequestAssignmentPlayback` wiring L303–306; delete the private `playStudyAssignment` L324–337)
- Test: extend `EchoTests/StudySessionViewModelTests.swift`

**Interfaces:**
- Consumes: `StudyPlaybackQueueService.markSkipped / isSkipEligible / needsAttentionFlashcardIDs` (Task 5), `PlayerModel.playStudyAssignment(_:)` (Task 7).
- Produces:
  - `StudySessionViewModel.needsAttentionCardIDs: Set<String>`
  - `StudySessionViewModel.currentEntryIsSkipEligible() -> Bool`
  - `StudySessionViewModel.skipCurrent(now: Date = Date())`
  - `StudyAssignmentCardView` gains `var onSkip: (() -> Void)? = nil` and `var needsAttention: Bool = false`

**Steps:**

- [ ] Append these failing tests to the existing `EchoTests/StudySessionViewModelTests.swift` (Read the file first and match its construction idiom; the tests below use only the public initializer):

```swift
    @Test func skipCurrentWritesNoGradeDefersToTomorrowAndAdvances() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let vm = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        try vm.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(vm.currentEntry)
        #expect(entry.flashcard.frontText == "Book A Chapter 1")
        #expect(vm.currentEntryIsSkipEligible() == true)

        vm.skipCurrent(now: StudyQueueFixtures.mondayNoon)

        let skipped = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: entry.flashcard.id) })
        let tomorrow = StudyQueueFixtures.calendar.date(
            byAdding: .day, value: 1, to: StudyQueueFixtures.mondayNoon)!
        #expect(skipped.lastGrade == nil)
        #expect(skipped.nextReviewDate == tomorrow.ISO8601Format())
        #expect(vm.currentIndex == 1)
    }

    @Test func skipIsNotOfferedWhenTheChapterHasUserCards() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        // A user card inside Book A Chapter 1's audio range (0..<100).
        try StudyQueueFixtures.seedDueCard(
            id: "user-1", audiobookID: "book-a", frontText: "My card",
            nextReviewDate: StudyQueueFixtures.mondayNoon.addingTimeInterval(86_400),
            isEnabled: true, in: service)
        let vm = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        try vm.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(vm.currentEntry)
        #expect(entry.flashcard.frontText == "Book A Chapter 1")
        #expect(vm.currentEntryIsSkipEligible() == false)
    }

    @Test func needsAttentionFlagsLoadWithTheQueue() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        try queue.markNeedsAttention(
            item: StudyPlayableItem(
                flashcardID: "card-x", audiobookID: "book-a", chapterIndex: 0,
                planItemID: nil, title: "Book A Chapter 1", startTime: 0, endTime: 100),
            reason: "Book not downloaded", now: StudyQueueFixtures.mondayNoon)

        let vm = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        try vm.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(vm.needsAttentionCardIDs.contains("card-x"))
    }
```

- [ ] Run (expect compile failure: `has no member 'skipCurrent'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Implement in `EchoCore/ViewModels/StudySessionViewModel.swift`:

**(a)** Add a stored property under `var errorMessage: String?` (L13):

```swift
    /// Cards whose audio could not be played by hands-free advance today —
    /// surfaced in the session as "needs attention", never silently dropped.
    var needsAttentionCardIDs: Set<String> = []
```

**(b)** In `loadQueue`, after the `markIntroduced` call (L63) and before `updateReviewNotification(...)`, add:

```swift
        needsAttentionCardIDs =
            (try? StudyPlaybackQueueService(db: db)
                .needsAttentionFlashcardIDs(now: now, calendar: calendar)) ?? []
```

**(c)** After `gradeCurrent` (L100), add:

```swift
    /// Skip is offered only for listening assignments whose chapter has no
    /// user-created cards (§5.1).
    func currentEntryIsSkipEligible() -> Bool {
        guard let entry = currentEntry,
            entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
        else { return false }
        return (try? StudyPlaybackQueueService(db: db)
            .isSkipEligible(assignmentCardID: entry.flashcard.id)) ?? false
    }

    /// Retention-neutral skip: no FSRS grade, due tomorrow, logged (§5.1).
    func skipCurrent(now: Date = Date()) {
        guard let entry = currentEntry else { return }
        do {
            try StudyPlaybackQueueService(db: db)
                .markSkipped(flashcardID: entry.flashcard.id, now: now)
            advance()
            updateReviewNotification(remainingReviewNotificationCount())
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            logger.error(
                "Failed to skip card \(entry.flashcard.id): \(error.localizedDescription)")
        }
    }
```

- [ ] Implement in `EchoCore/Views/StudyAssignmentCardView.swift`:

**(a)** Extend the property list (L10–15) — defaults keep macOS/other call sites compiling:

```swift
struct StudyAssignmentCardView: View {
    let entry: StudyQueueEntry
    let isRevealed: Bool
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onGrade: (ReviewGrade) -> Void
    /// Non-nil only when the chapter is skip-eligible (§5.1).
    var onSkip: (() -> Void)? = nil
    /// True when hands-free advance couldn't play this card's audio today.
    var needsAttention: Bool = false
```

**(b)** Directly under the `Button("Play in context" / "Play Assignment", ...)` block (after L41), add:

```swift
            if needsAttention {
                Label(
                    "Couldn't auto-play this chapter today — play it manually.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
```

**(c)** In the revealed branch, replace the single `StudyAssignmentGradeButtons(...)` call (L62–64) with:

```swift
                StudyAssignmentGradeButtons(
                    grades: StudyAssignmentGradePolicy.choices(for: entry.flashcard.cardType),
                    onGrade: onGrade)
                if let onSkip {
                    Button("Skip — I know this chapter", action: onSkip)
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
```

- [ ] Implement in `EchoCore/Views/StudySessionView.swift` — replace the `StudyAssignmentCardView(` call (L79–85) with:

```swift
            StudyAssignmentCardView(
                entry: entry,
                isRevealed: viewModel.isRevealed,
                onPlay: { viewModel.requestPlayCurrentAssignment() },
                onReveal: { viewModel.reveal() },
                onGrade: { viewModel.gradeCurrent($0) },
                onSkip: viewModel.currentEntryIsSkipEligible()
                    ? { viewModel.skipCurrent() } : nil,
                needsAttention: viewModel.needsAttentionCardIDs.contains(entry.flashcard.id)
            )
```

- [ ] Implement in `EchoCore/Views/Stats/StatsView.swift` — one grading brain, two entrances (§4): replace the wiring at L303–306 with

```swift
        vm.onRequestAssignmentPlayback = { [weak model] card in
            model?.playStudyAssignment(card)
        }
```

and DELETE the now-dead private helper `playStudyAssignment(_:model:)` (L324–337).

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudySessionViewModelTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add EchoCore/ViewModels/StudySessionViewModel.swift \
        EchoCore/Views/StudyAssignmentCardView.swift \
        EchoCore/Views/StudySessionView.swift \
        EchoCore/Views/Stats/StatsView.swift \
        EchoTests/StudySessionViewModelTests.swift
git commit -m "feat(study): skippable re-listen + needs-attention surface in the study session"
```

---

## Task 11: Retire-chapter prompt

**Files:**
- Modify: `Shared/Study/StudyPlanTypes.swift` (`StudyCardMedia`, L47–49)
- Create: `Shared/Services/StudyChapterRetireService.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (one stored property, next to `checkpointCoordinator` ~L505)
- Modify: `EchoCore/Views/Components/FlashcardCreationSheet.swift` (`saveFlashcard()`, after the successful insert ~L200)
- Modify: `EchoCore/Views/RootTabView.swift` (alert on the root ZStack, next to the Task 9 overlay)
- Test: `EchoTests/StudyChapterRetireServiceTests.swift`

**Interfaces:**
- Consumes: `StudyPlan`/`StudyPlanItem`/`Flashcard`, `StudyPlanDAO.setItemEnabled`, `StudyFlashcardType.listeningAssignment`, `StudyCardMedia`.
- Produces:
  - `StudyCardMedia` gains `let retirePromptShownAt: String?` with `init(imagePath: String?, retirePromptShownAt: String? = nil)` (existing `StudyCardMedia(imagePath:)` call in `StudyPlanDAO.encodeMedia` keeps compiling)
  - `struct StudyChapterRetireService { let db: DatabaseWriter }`
  - `struct RetirePrompt: Identifiable, Equatable, Sendable { let assignmentCardID: String; let assignmentItemID: String; let chapterTitle: String; var id: String { assignmentCardID } }` (nested)
  - `func promptForNewUserCard(audiobookID: String, mediaTimestamp: TimeInterval, now: Date = Date()) throws -> RetirePrompt?`
  - `func retire(assignmentCardID: String, assignmentItemID: String, now: Date = Date()) throws`
  - `PlayerModel.pendingRetirePrompt: StudyChapterRetireService.RetirePrompt?`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyChapterRetireServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyChapterRetireServiceTests {
    private func assignmentCardID(in service: DatabaseService) throws -> String {
        try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
    }

    @Test func firstUserCardInAnActiveChapterPromptsExactlyOnce() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)

        // First user card inside chapter 1's audio range (0..<100): prompt.
        let prompt = try retire.promptForNewUserCard(
            audiobookID: "book-a", mediaTimestamp: 40, now: StudyQueueFixtures.mondayNoon)
        #expect(prompt?.chapterTitle == "Book A Chapter 1")

        // Second card in the same chapter: the prompt already fired.
        let second = try retire.promptForNewUserCard(
            audiobookID: "book-a", mediaTimestamp: 60, now: StudyQueueFixtures.mondayNoon)
        #expect(second == nil)
    }

    @Test func cardOutsideAnyAssignmentRangeDoesNotPrompt() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)

        // Chapter ranges are 0-100/100-200/200-300; 5000 is in none of them.
        let prompt = try retire.promptForNewUserCard(
            audiobookID: "book-a", mediaTimestamp: 5_000, now: StudyQueueFixtures.mondayNoon)
        #expect(prompt == nil)
    }

    @Test func pausedPlanDoesNotPrompt() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let prompt = try StudyChapterRetireService(db: service.writer).promptForNewUserCard(
            audiobookID: "book-a", mediaTimestamp: 40, now: StudyQueueFixtures.mondayNoon)
        #expect(prompt == nil)
    }

    @Test func retireDisablesTheAssignmentAndItIsReversible() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)
        let prompt = try #require(
            try retire.promptForNewUserCard(
                audiobookID: "book-a", mediaTimestamp: 40, now: StudyQueueFixtures.mondayNoon))

        try retire.retire(
            assignmentCardID: prompt.assignmentCardID,
            assignmentItemID: prompt.assignmentItemID,
            now: StudyQueueFixtures.mondayNoon)

        let retired = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: prompt.assignmentCardID) })
        #expect(retired.isEnabled == false)
        // The retired chapter leaves today's queue…
        let queueAfterRetire = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(
            !queueAfterRetire.entries.contains { $0.flashcard.id == prompt.assignmentCardID })

        // …and re-enabling from plan management brings it back (reversible §5.2).
        try StudyPlanDAO(db: service.writer).setItemEnabled(
            itemID: prompt.assignmentItemID, isEnabled: true, now: StudyQueueFixtures.mondayNoon)
        try service.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET is_enabled = 1 WHERE id = ?",
                arguments: [prompt.assignmentCardID])
        }
        let queueAfterRestore = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(
            queueAfterRestore.entries.contains { $0.flashcard.id == prompt.assignmentCardID })
    }

    @Test func legacyMediaJSONStillDecodesAfterTheFieldAddition() throws {
        let legacy = #"{"imagePath":"Images/one.png"}"#
        let decoded = try JSONDecoder().decode(
            StudyCardMedia.self, from: Data(legacy.utf8))
        #expect(decoded.imagePath == "Images/one.png")
        #expect(decoded.retirePromptShownAt == nil)
    }
}
```

- [ ] Run (expect compile failure: `cannot find 'StudyChapterRetireService' in scope`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Modify `Shared/Study/StudyPlanTypes.swift` — replace `StudyCardMedia` (L47–49) with:

```swift
struct StudyCardMedia: Codable, Equatable, Sendable {
    let imagePath: String?
    /// ISO-8601 stamp of when the once-per-chapter retire prompt fired for
    /// this assignment card (§5.2). Rides the existing mediaJSON — no new
    /// column; optional so legacy blobs decode unchanged.
    let retirePromptShownAt: String?

    init(imagePath: String?, retirePromptShownAt: String? = nil) {
        self.imagePath = imagePath
        self.retirePromptShownAt = retirePromptShownAt
    }
}
```

- [ ] Create `Shared/Services/StudyChapterRetireService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// The once-per-chapter "retire the re-listen card?" prompt (design §5.2):
/// the first time a user-created flashcard is saved into a chapter with an
/// active listening assignment, offer to retire the assignment and review
/// with the user's cards instead. Prompt state rides the assignment card's
/// mediaJSON (`StudyCardMedia.retirePromptShownAt`) — the AI-deck slice will
/// reuse this exact hook when accepted AI cards land in a chapter.
struct StudyChapterRetireService {
    let db: DatabaseWriter

    struct RetirePrompt: Identifiable, Equatable, Sendable {
        let assignmentCardID: String
        let assignmentItemID: String
        let chapterTitle: String

        var id: String { assignmentCardID }
    }

    /// Call after a user-created card is saved. Returns a prompt for the UI,
    /// or nil (no active assignment covers the timestamp, or the prompt has
    /// already fired for that chapter). The shown-stamp is written BEFORE
    /// returning, so the prompt fires exactly once even when declined.
    func promptForNewUserCard(
        audiobookID: String,
        mediaTimestamp: TimeInterval,
        now: Date = Date()
    ) throws -> RetirePrompt? {
        let match: (item: StudyPlanItem, card: Flashcard)? = try db.read { db in
            let plans = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_paused") == false)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)
            for plan in plans {
                let items = try StudyPlanItem
                    .filter(Column("plan_id") == plan.id)
                    .filter(Column("kind") == StudyPlanItemKind.chapter.rawValue)
                    .filter(Column("is_enabled") == true)
                    .order(Column("ordinal"))
                    .fetchAll(db)
                for item in items {
                    guard let cardID = item.flashcardID,
                        let card = try Flashcard.fetchOne(db, key: cardID),
                        card.isEnabled,
                        card.cardType == StudyFlashcardType.listeningAssignment,
                        card.mediaTimestamp <= mediaTimestamp,
                        mediaTimestamp < (card.endTimestamp ?? .greatestFiniteMagnitude)
                    else { continue }
                    return (item, card)
                }
            }
            return nil
        }

        guard let (item, card) = match else { return nil }
        let media = decodeMedia(card.mediaJSON)
        guard media?.retirePromptShownAt == nil else { return nil }

        try markPromptShown(card: card, existingImagePath: media?.imagePath, now: now)
        return RetirePrompt(
            assignmentCardID: card.id,
            assignmentItemID: item.id,
            chapterTitle: card.frontText)
    }

    /// Retires the chapter's re-listen card: disables the assignment card and
    /// its plan item. Reversible from plan management (`setItemEnabled`).
    func retire(assignmentCardID: String, assignmentItemID: String, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET is_enabled = 0, modified_at = ? WHERE id = ?",
                arguments: [now.ISO8601Format(), assignmentCardID]
            )
        }
        try StudyPlanDAO(db: db).setItemEnabled(
            itemID: assignmentItemID, isEnabled: false, now: now)
    }

    private func markPromptShown(
        card: Flashcard, existingImagePath: String?, now: Date
    ) throws {
        let media = StudyCardMedia(
            imagePath: existingImagePath,
            retirePromptShownAt: now.ISO8601Format())
        let json = String(decoding: try JSONEncoder().encode(media), as: UTF8.self)
        try db.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET media_json = ?, modified_at = ? WHERE id = ?",
                arguments: [json, now.ISO8601Format(), card.id]
            )
        }
    }

    private func decodeMedia(_ json: String?) -> StudyCardMedia? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudyCardMedia.self, from: data)
    }
}
```

- [ ] In `EchoCore/ViewModels/PlayerModel.swift`, next to `checkpointCoordinator` (~L505), add:

```swift
    /// A pending "retire this chapter's re-listen card?" prompt (§5.2), set by
    /// the card-creation flow and presented as an alert by RootTabView.
    var pendingRetirePrompt: StudyChapterRetireService.RetirePrompt?
```

- [ ] In `EchoCore/Views/Components/FlashcardCreationSheet.swift`, inside `saveFlashcard()` after the successful insert (between `ReviewPromptManager.shared.recordActivationEvent(.flashcardCreated)` and `return true`, ~L202), add:

```swift
            if let prompt = try? StudyChapterRetireService(db: db.writer).promptForNewUserCard(
                audiobookID: targetAudiobookID,
                mediaTimestamp: card.mediaTimestamp)
            {
                model.pendingRetirePrompt = prompt
            }
```

- [ ] In `EchoCore/Views/RootTabView.swift`, attach the alert directly after the Task 9 `.overlay(alignment: .bottom) { checkpointOverlay }` modifier:

```swift
        .alert(
            "Retire this chapter's re-listen card?",
            isPresented: Binding(
                get: { model.pendingRetirePrompt != nil },
                set: { if !$0 { model.pendingRetirePrompt = nil } }
            ),
            presenting: model.pendingRetirePrompt
        ) { prompt in
            Button("Retire", role: .destructive) {
                if let db = model.databaseService {
                    try? StudyChapterRetireService(db: db.writer).retire(
                        assignmentCardID: prompt.assignmentCardID,
                        assignmentItemID: prompt.assignmentItemID)
                    NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
                }
                model.pendingRetirePrompt = nil
            }
            Button("Keep Both", role: .cancel) {
                model.pendingRetirePrompt = nil
            }
        } message: { prompt in
            Text(
                "You now have your own flashcards in \"\(prompt.chapterTitle)\". Review with your cards instead? You can re-enable the re-listen card any time from the study plan."
            )
        }
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyChapterRetireServiceTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Study/StudyPlanTypes.swift \
        Shared/Services/StudyChapterRetireService.swift \
        EchoCore/ViewModels/PlayerModel.swift \
        EchoCore/Views/Components/FlashcardCreationSheet.swift \
        EchoCore/Views/RootTabView.swift \
        EchoTests/StudyChapterRetireServiceTests.swift
git commit -m "feat(study): once-per-chapter retire-the-relisten-card prompt"
```

---

## Task 12: iOS checkpoint settings UI

**Files:**
- Modify: `EchoCore/Views/SettingsView.swift` — `SettingsStudyRows` (row after the Stepper, ~L269–275) + new private view appended near `SettingsStudyRows` (~L326)

**Interfaces:**
- Consumes: `SettingsManager` checkpoint props (Task 3), `CheckpointTimeoutBehavior` (Task 1).
- Produces: `private struct CheckpointSettingsView: View` (file-private; nothing else consumes it).

**UI-only task: no unit-test cycle — settings persistence/clamping is already covered by Task 3. Verification is a clean build.**

**Steps:**

- [ ] In `SettingsStudyRows.body` (SettingsView.swift, after the `Stepper` block ending ~L274), add:

```swift
        NavigationLink("Chapter Checkpoints") {
            CheckpointSettingsView()
        }
```

- [ ] Append this private view after the closing brace of `SettingsStudyRows` (~L325):

```swift
private struct CheckpointSettingsView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("When the timer runs out", selection: $settings.checkpointTimeoutBehavior) {
                    Text("Replay the chapter")
                        .tag(CheckpointTimeoutBehavior.replay.rawValue)
                    Text("Grade Again and move on")
                        .tag(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue)
                    Text("Wait — no grade, re-queue today")
                        .tag(CheckpointTimeoutBehavior.wait.rawValue)
                }
                if settings.checkpointTimeoutBehavior != CheckpointTimeoutBehavior.wait.rawValue {
                    Picker("Checkpoint timeout", selection: $settings.checkpointTimeoutSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                }
                Toggle("Auto-advance after Good", isOn: $settings.checkpointAutoAdvance)
                Toggle("Lock-screen button grading", isOn: $settings.checkpointRemoteGrading)
            } header: {
                Text("Chapter Checkpoints")
            } footer: {
                Text(
                    "When a due study chapter finishes playing, Echo pauses and asks for a retention grade. While the window is open, lock-screen skip-forward means Good and skip-back means Again. Checkpoints only exist for books with an active study plan — pause the plan to silence them."
                )
            }
        }
        .navigationTitle("Chapter Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] Build-verify:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Views/SettingsView.swift
git commit -m "feat(settings): chapter-checkpoint group under Study & Notes (iOS)"
```

---

## Task 13: macOS study settings pane + plan creation

**Files:**
- Modify: `Echo macOS/Views/MacSettingsView.swift` (insert tab after the AI pane, ~L29–32; append pane struct after `MacAppearanceSettingsPane`)
- Modify: `Echo macOS/Echo_macOSApp.swift` (menu button after "Card Inbox…", ~L252–256; notification name next to `.requestCardInbox`, ~L557)
- Modify: `Echo macOS/Views/MacTriPaneView.swift` (state ~L23, sheet ~L79–86, onReceive ~L113–118, host struct at end of file)

**Interfaces:**
- Consumes: `SettingsManager` checkpoint + study props (Task 3), `CheckpointTimeoutBehavior` (Task 1), `StudyPlanSheet` / `StudyPlanViewModel` (existing, already compiled into the macOS target — NOT in its exception list), `MacPlayerModel.audiobookID` / `.currentTitle` / `.hasMedia`, `DatabaseService.writer`.
- Produces: `.requestStudyPlan` notification name; `MacStudySettingsPane`; `MacStudyPlanSheetHost` (both file-private to their hosts).

**macOS files sync only into the "Echo macOS" target — no pbxproj edits. UI-only task: verification is the macOS build (do NOT run it concurrently with iOS test runs).**

**Steps:**

- [ ] In `Echo macOS/Views/MacSettingsView.swift`, insert a Study tab between the AI and Support panes (~L29):

```swift
            MacStudySettingsPane()
                .tabItem {
                    Label("Study", systemImage: "rectangle.stack.badge.play")
                }
```

- [ ] In the same file, after the closing brace of `MacAppearanceSettingsPane` (~L98, Read the file to find it), add:

```swift
// MARK: - Study Pane

private struct MacStudySettingsPane: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Stepper(value: $settings.studyGlobalNewChapterLimit, in: 1...12) {
                    LabeledContent("Global New Chapters") {
                        Text("\(settings.studyGlobalNewChapterLimit) per day")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Daily Review Reminder", isOn: $settings.reviewNotificationsEnabled)
            } header: {
                Text("Study")
            }

            Section {
                Picker(
                    "When the timer runs out",
                    selection: $settings.checkpointTimeoutBehavior
                ) {
                    Text("Replay the chapter")
                        .tag(CheckpointTimeoutBehavior.replay.rawValue)
                    Text("Grade Again and move on")
                        .tag(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue)
                    Text("Wait — no grade, re-queue today")
                        .tag(CheckpointTimeoutBehavior.wait.rawValue)
                }
                if settings.checkpointTimeoutBehavior != CheckpointTimeoutBehavior.wait.rawValue {
                    Picker("Checkpoint timeout", selection: $settings.checkpointTimeoutSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                }
                Toggle("Auto-advance after Good", isOn: $settings.checkpointAutoAdvance)
            } header: {
                Text("Chapter Checkpoints")
            } footer: {
                Text(
                    "The macOS default is Wait: no countdown runs, and no grade fires at an empty desk chair. Pick a non-Wait behavior to run the same countdown as iOS. Checkpoints only exist for books with an active study plan."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] In `Echo macOS/Echo_macOSApp.swift`, after the "Card Inbox…" button (~L256), add:

```swift
                Button("Study Plan…") {
                    NotificationCenter.default.post(name: .requestStudyPlan, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!player.hasMedia)
```

and in the `Notification.Name` extension next to `.requestCardInbox` (~L557), add:

```swift
    static let requestStudyPlan = Notification.Name("com.echo.requestStudyPlan")
```

- [ ] In `Echo macOS/Views/MacTriPaneView.swift`:

**(a)** State (next to `showingCardInbox`, ~L23):

```swift
    @State private var showingStudyPlan = false
```

**(b)** Sheet (after the `showingCardInbox` sheet, ~L81):

```swift
            .sheet(isPresented: $showingStudyPlan) {
                if let audiobookID = player.audiobookID {
                    MacStudyPlanSheetHost(
                        audiobookID: audiobookID,
                        bookTitle: player.currentTitle,
                        db: dbService.writer)
                }
            }
```

**(c)** Handler (after the `.requestCardInbox` onReceive, ~L115):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .requestStudyPlan)) { _ in
            showingStudyPlan = true
        }
```

**(d)** Host struct at the end of the file (the shared `StudyPlanSheet`/`StudyPlanViewModel` already compile on macOS — window chrome is all this adds, per design §7). Add `import GRDB` at the top of the file if not already present:

```swift
private struct MacStudyPlanSheetHost: View {
    @State private var viewModel: StudyPlanViewModel

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        _viewModel = State(
            wrappedValue: StudyPlanViewModel(
                audiobookID: audiobookID, bookTitle: bookTitle, db: db))
    }

    var body: some View {
        StudyPlanSheet(viewModel: viewModel)
            .frame(minWidth: 460, minHeight: 520)
    }
}
```

- [ ] Build-verify the macOS target (wait for any iOS build/test to finish first):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add "Echo macOS/Views/MacSettingsView.swift" "Echo macOS/Echo_macOSApp.swift" "Echo macOS/Views/MacTriPaneView.swift"
git commit -m "feat(macos): study settings pane + study-plan creation sheet"
```

---

## Task 14: macOS checkpoint wiring + panel

**Files:**
- Modify: `Echo macOS/Views/MacPlayerModel.swift` (`dbService` ~L132; stored props near `sleepTimer` ~L137; `handleChapterBoundary` ~L1020; new methods near `loadFolder` ~L481)
- Modify: `Echo macOS/Views/MacTriPaneView.swift` (panel overlay on the content column, after `.navigationSplitViewColumnWidth(min: 300, ideal: 450)` ~L58)

**Interfaces:**
- Consumes: `StudyCheckpointCoordinator` (Task 6), `StudyCheckpointPanelView` (Task 9 — already in the macOS target), `StudyCheckpointAnnouncer` (Task 7), `SettingsManager` checkpoint props (Task 3), `MacPlayerModel.seekToChapter(_ index: Int)` / `seek(to seconds: Double)` / `play()` / `pause()` / `loadFolder(url:preserveLibraryRoot:)` / `sleepTimer` / `audiobookID` / `chapters` / `currentChapterIndex` / `loopMode` / `currentTime`.
- Produces: `MacPlayerModel.checkpointCoordinator: StudyCheckpointCoordinator?`, `MacPlayerModel.playCheckpointItem(_:)`.

**UI/side-effect wiring: state-machine behavior is covered by Task 6's suite; verification here is the macOS build (+ Task 15 manual checklist). Do not run concurrently with iOS tests.**

**Steps:**

- [ ] In `Echo macOS/Views/MacPlayerModel.swift`:

**(a)** Give `dbService` a didSet (L132):

```swift
    /// Database service for bookmark persistence. Set by the app entry point.
    var dbService: DatabaseService? {
        didSet { configureStudyCheckpoint() }
    }
```

**(b)** Next to `let sleepTimer = SleepTimerManager()` (~L137), add:

```swift
    /// Chapter-checkpoint state machine (design §3.1, §7). Created when the
    /// database arrives; the tri-pane panel observes its state.
    private(set) var checkpointCoordinator: StudyCheckpointCoordinator?
    private let checkpointAnnouncer = StudyCheckpointAnnouncer()
```

**(c)** Near `loadFolder(url:preserveLibraryRoot:)` (~L481), add:

```swift
    /// (Re)creates the checkpoint coordinator when the database arrives —
    /// same ownership pattern as the iOS PlayerModel. Remote-command
    /// reinterpretation does not apply on macOS (design §3.3), so
    /// `remoteGrading` is pinned false.
    private func configureStudyCheckpoint() {
        guard let db = dbService else {
            checkpointCoordinator = nil
            return
        }
        let coordinator = StudyCheckpointCoordinator(
            database: db,
            settingsProvider: { [weak self] in
                guard let settings = self?.settings else {
                    return StudyCheckpointSettings(
                        timeoutSeconds: SettingsManager.Defaults.checkpointTimeoutSeconds,
                        timeoutBehavior: .wait,
                        autoAdvance: SettingsManager.Defaults.checkpointAutoAdvance,
                        remoteGrading: false)
                }
                return StudyCheckpointSettings(
                    timeoutSeconds: settings.checkpointTimeoutSeconds,
                    timeoutBehavior: CheckpointTimeoutBehavior(
                        rawValue: settings.checkpointTimeoutBehavior) ?? .wait,
                    autoAdvance: settings.checkpointAutoAdvance,
                    remoteGrading: false,
                    globalNewChapterLimit: settings.studyGlobalNewChapterLimit)
            },
            replayChapter: { [weak self] in
                guard let self else { return }
                self.seekToChapter(self.currentChapterIndex)
                self.play()
            },
            advance: { [weak self] item in
                self?.playCheckpointItem(item)
            },
            announce: { [weak self] cue in
                self?.checkpointAnnouncer.announce(cue)
            }
        )
        coordinator.pausePlayback = { [weak self] in self?.pause() }
        coordinator.isSleepStopRequested = { [weak self] in
            self?.sleepTimer.mode == .endOfChapter
        }
        coordinator.fireSleepStop = { [weak self] in
            self?.sleepTimer.evaluateAtChapterEnd()
        }
        coordinator.isPlayable = { item in
            guard let url = URL(string: item.audiobookID), url.isFileURL else { return true }
            return (try? url.checkResourceIsReachable()) ?? false
        }
        checkpointCoordinator = coordinator
    }

    /// Cross-book advance: load the item's book if needed, then seek + play
    /// once the AVPlayer item settles (same 300 ms pattern as iOS).
    func playCheckpointItem(_ item: StudyPlayableItem) {
        if audiobookID != item.audiobookID, let url = URL(string: item.audiobookID) {
            loadFolder(url: url)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.seek(to: max(0, item.startTime + 0.05))
            self.play()
        }
    }
```

**(d)** In `handleChapterBoundary()` (~L1020), give the checkpoint first claim on a natural boundary; loop wins, and the coordinator honors the sleep stop after grading (so a claim skips `MacChapterLoopDecision` entirely this tick):

```swift
    private func handleChapterBoundary() {
        // Chapter checkpoint gets first claim on a naturally played boundary
        // (design §3.1/§4). Only loop-off boundaries qualify — checkpoints
        // never fire inside an intentional loop. `handleChapterEnd` declines
        // instantly (state guard + deferred-boundary guard) on repeat polls.
        if loopMode == .off,
            let coordinator = checkpointCoordinator,
            let bookID = audiobookID,
            chapters.indices.contains(currentChapterIndex),
            currentTime >= chapters[currentChapterIndex].endSeconds,
            coordinator.handleChapterEnd(
                audiobookID: bookID, chapterIndex: currentChapterIndex, naturalEnd: true)
        {
            return
        }

        let decision = MacChapterLoopDecision.evaluate(
            currentTime: currentTime,
            chapters: chapters,
            currentChapterIndex: currentChapterIndex,
            loopMode: loopMode,
            isEndOfChapterSleep: sleepTimer.mode == .endOfChapter
        )
        switch decision {
        case .none:
            break
        case .seek(let target):
            seek(to: target)
            currentTime = target
        case .fireSleep:
            sleepTimer.evaluateAtChapterEnd()
        }
    }
```

- [ ] In `Echo macOS/Views/MacTriPaneView.swift`, attach the panel to the content column — directly after `.navigationSplitViewColumnWidth(min: 300, ideal: 450)` (~L58) on the center `VStack`:

```swift
            .overlay(alignment: .bottom) {
                if let coordinator = player.checkpointCoordinator,
                    case .checkpointActive = coordinator.state
                {
                    StudyCheckpointPanelView(coordinator: coordinator)
                        .padding(.bottom, 64)
                }
            }
```

- [ ] Build-verify macOS (and confirm the iOS tests still pass, since `handleChapterBoundary` logic is macOS-only but the coordinator is shared):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] Verify SPDX still line 1, then commit:

```bash
git add "Echo macOS/Views/MacPlayerModel.swift" "Echo macOS/Views/MacTriPaneView.swift"
git commit -m "feat(macos): chapter-checkpoint panel with Wait default on the player window"
```

---

## Task 15: Final verification

**Files:** none created — this task runs the full gates and the manual checklist. Fix-forward any failures (each fix gets its own Conventional Commit).

**Steps:**

- [ ] SPDX sweep over every file this plan created:

```bash
for f in Shared/Study/StudyCheckpointTypes.swift \
         Shared/Services/StudyPlaybackQueueService.swift \
         Shared/Services/StudyChapterRetireService.swift \
         EchoCore/Services/StudyCheckpointCoordinator.swift \
         EchoCore/Services/StudyCheckpointAnnouncer.swift \
         EchoCore/Services/StudyCheckpointNotificationService.swift \
         "EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift" \
         EchoCore/Views/StudyCheckpointPanelView.swift; do
  head -1 "$f" | grep -q "SPDX-License-Identifier: GPL-3.0-or-later" || echo "MISSING SPDX: $f"
done
```

Expected: no output.

- [ ] Full iOS unit-test suite (serial, capped — never in parallel with anything):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
```

Expected: `TEST SUCCEEDED` with all new suites green (`StudyCheckpointTypesTests`, `FlashcardReviewMetadataTests`, `SettingsManagerCheckpointTests`, `StudyPlanDAOCheckpointTests`, `StudyPlaybackQueueServiceTests`, `StudyCheckpointCoordinatorTests`, `PlayerModelStudyCheckpointTests`, `StudyChapterRetireServiceTests`, extended `StudySessionViewModelTests`) and no regressions in the existing study suites. Known environmental exception: ABSTokenStore/auth-refresh Keychain tests are run-to-run flaky under unsigned sim builds — a failure ONLY there is environmental, re-run that suite once before treating it as a regression.

- [ ] macOS build (AFTER the iOS test run completes):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (this also proves the macOS Wait default compiles — the `#if os(macOS)` branch in `SettingsManager.Defaults`).

- [ ] echo-cli build (the CI step ordering test→macOS→echo-cli masks build breaks behind test failures, so prove it locally; AFTER the macOS build):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme echo-cli -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (proves the coordinator/queue service are UIKit-free and the pbxproj exclusions for `PlayerModel+StudyCheckpoint.swift` and `StudyCheckpointPanelView.swift` are correct).

- [ ] Manual verification checklist (owner, on device/desktop — record outcomes in the PR description later, outside this plan):
  - iOS: create a plan on a chaptered book, play a due chapter to its natural end → audio cue + overlay with Again/Good (+ Skip when no user cards) and a 30 s countdown.
  - iOS screen off: lock-screen skip-forward grades Good; the `STUDY_CHECKPOINT` notification shows Good/Again actions; first channel to answer wins.
  - iOS: seeking across a chapter boundary does NOT fire a checkpoint; chapter-loop mode never fires one.
  - iOS: sleep timer end-of-chapter + checkpoint → grade first, then playback stops without replaying.
  - iOS: Good on the last due chapter of book A advances into book B (cross-book).
  - iOS: timeout with "Replay" re-plays the chapter and Insights-visible metadata carries `"auto":true`.
  - iOS: saving a first user card inside an assignment chapter shows the retire prompt exactly once; Retire removes the chapter from the queue; re-enabling from plan management restores it.
  - macOS: Settings ▸ Study shows the cap/reminder/checkpoint group with Wait as the default behavior (no countdown at a checkpoint); Study ▸ Study Plan… (⌘⇧P) opens the plan sheet; the checkpoint panel waits indefinitely and grades on click.
  - Phone call during a countdown: the countdown suspends and resumes with playback.

- [ ] If any fixes were needed, commit them individually, then confirm the working tree is clean:

```bash
git status --short
```

Expected: clean. (Doc-sync — ARCHITECTURE.md/README/ROADMAP closeout — and the PR against `nightly` are handled OUTSIDE this plan.)

