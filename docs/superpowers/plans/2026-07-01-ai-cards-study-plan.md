# AI Cards Ride the Study Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **DEPENDENCY — slice 1 first.** This plan REQUIRES the Chapter Checkpoint plan (`docs/superpowers/plans/2026-07-01-chapter-checkpoint-core-loop.md`) to be fully implemented before Task 1 here begins. It modifies files slice 1 creates (`StudyCheckpointCoordinator`, `StudyCheckpointPanelView`, `PlayerModel+StudyCheckpoint.swift`, `MacStudySettingsPane`, the MacTriPaneView checkpoint overlay) and consumes slice-1 services (`StudyChapterRetireService`, `StudyCheckpointSettings`, `StudyPlayableItem`).

> **⚠️ AMENDED 2026-07-02 — read before executing.** The design spec gained four amendments after this plan was verified: `../specs/2026-07-01-ai-cards-study-plan-design.md` **§11** (A1 per-plan default 2/day + daily card windows, A2 chapter pacing `card_drain`, A3 deferred retire prompt, A4 release-on-contact). **Everything below this banner — including the Goal/Architecture paragraphs and the File Structure table — shows pre-amendment values and code; the spec wins wherever they disagree.** Per-task deltas:
>
> - **Task 1:** `Schema_V33` adds **two** columns: `new_cards_per_day INTEGER NOT NULL DEFAULT 2` (task body says 20) and `chapter_pacing TEXT NOT NULL DEFAULT 'card_drain'`. Rename the registration to `v33_study_plan_card_pacing` (update `DatabaseService.swift` and every test or grep referencing the old name). `StudyPlan` gains `chapterPacing: String` + CodingKey `chapter_pacing`, and its `newCardsPerDay` **memberwise default also becomes 2** (task body line ~266 says 20); `Shared/Study/StudyPlanTypes.swift` gains `enum StudyPlanChapterPacing: String { case cardDrain = "card_drain"; case cadence }`. `StudyPlanCreationRequest` gains `chapterPacing: StudyPlanChapterPacing = .cardDrain` and its `newCardsPerDay` default becomes 2. Update `SchemaV33Tests` expectations (20 → 2; add `chapter_pacing` column + default assertions).
> - **Task 2:** unchanged — the **global** `studyNewCardsPerDayLimit` stays default 20, clamp 1…100. Note its semantics per A1: it caps how many new cards one queue build may *offer* (no cross-build memory); the doc comment should say so.
> - **Task 3:** per-plan default becomes 2 (`StudyPlanViewModel.newCardsPerDay` initial value + `cardLimitText` fixtures); stepper stays `1...100`; add a caption line under the stepper ("2 a day finishes a 5-card chapter in about 3 days"). ADD chapter-pacing editing: a picker (After each chapter's cards / On a schedule) in `StudyPlanSheet`, a `chapterPacing` property on the view model, and a non-defaulted `chapterPacing` parameter on `StudyPlanDAO.updateSettings` (same forgotten-argument-is-a-compile-error rationale as `newCardsPerDay`).
> - **Task 4:** two changes. (1) **A2 gate in the chapter phase:** in `card_drain` mode, `assignmentEntries` releases a new chapter only if the **frontier chapter** (highest-ordinal introduced chapter) has zero **releasable** pending card items — `kind = 'card' AND introduced_at IS NULL AND is_enabled AND flashcard_id IS NOT NULL` joined to an enabled flashcard (orphaned/disabled rows must never block; `flashcard_id` is ON DELETE SET NULL) — and, while the plan has any card items, caps new-chapter release to **one per build** (strict catch-up respects gate + cap); `cadence` bypasses both. (2) **`cardReleaseBudget` always uses `.day` windows** regardless of `plan.cadenceUnit` (A1) — the task body's window math is otherwise unchanged. Add tests: gate blocks while frontier cards pending, unblocks on drain, deleting/disabling a pending card unblocks, one-chapter-per-build under strict catch-up, vacuously open without card items, `cadence` bypasses, daily card windows on a weekly plan.
> - **Task 5 (inverted by A4):** `loadQueue` does **NOT** call `releaseCards` — it only offers `.newCard` entries; passive `build` callers (UpcomingReviewsModuleView, SettingsView reminder) still release nothing. The idempotent stamp moves to first **presentation**: `StudySessionViewModel` calls `releaseCards([itemID])` when a `.newCard` entry becomes the current card — with **no budget re-check** (bounded overshoot from a stale queue is accepted per A4). The `releaseCards` DAO method itself is unchanged. Rewrite `loadQueueReleasesQueuedCardsIdempotently`: after `loadQueue` alone, `introduced_at`/`next_review_date` are untouched; presenting the card stamps once.
> - **Task 6 (simplified by A3):** for plan books, acceptance **never** invokes `StudyChapterRetireService.promptForNewUserCard` (every accepted card creates a pending item, so all retire prompts defer to release time). Drop `StudyDeckRetirePrompt` and the `retirePrompts` field from `StudyDeckAcceptanceOutcome` (keep `acceptedCards` + `planID`). A card whose source block has **no chapter index seeds due-now** (like a plan-less book) instead of getting an unreachable NULL-chapter plan item. The deferred prompt needs new plumbing (spec §11 A3): `StudyChapterRetireService` gains a **chapter-keyed** `promptForDrainedChapter(audiobookID:chapterIndex:now:)` (the timestamp method mis-attributes `mediaTimestamp = 0` fallback cards); slice 1's `RetirePrompt` gains a `coveringCardCount: Int` (default 1) and `RootTabView`'s alert copy becomes conditional (bulk phrasing when > 1); the drain check runs after each `releaseCards` call — from `StudySessionViewModel` via a constructor-injected `onRetirePrompt` callback that PlayerModel binds to `pendingRetirePrompt`, and from the quiz path **after** quiz completion/dismissal, never during (no alert under the quiz overlay). Also guard slice 1's manual-card hook (`FlashcardCreationSheet`): skip the immediate prompt when the chapter has releasable pending card items, so the one-shot `retirePromptShownAt` stamp isn't burned mid-drip. Rework the retire tests accordingly (no prompt at acceptance; prompt on last release via chapter-keyed lookup; once per chapter; manual mid-drip defers).
> - **Tasks 7–8:** remove the retire-prompt follow-up steps from the post-accept flow and sheet UI (A3 moved them to release time); the plan-creation offer and drip summary stay. The drip-summary copy must bind the **per-plan `newCardsPerDay`** — NOT `settings.studyNewCardsPerDayLimit` as Task 8's verbatim code does (lines ~2763/2794); for the plan-less creation offer, use the creation-request default (2).
> - **Tasks 9–10:** the quiz draw **releases** the finished chapter's pending cards up to the remaining daily card budget before querying `dueQuizCards`, so a checkpoint right after listening quizzes freshly released cards. Budget plumbing: expose the day-window remaining-budget math as a **public `StudyQueueBuilder` helper**; the coordinator receives the **global limit via PlayerModel injection** alongside the checkpoint settings (it must not read `SettingsManager` directly). A draw that drains the chapter fires the deferred retire prompt **after the quiz ends** (A3). The screen-off cue counts **pending + released** due cards ("N cards ready when you are") and never releases. Extend the quiz tests: draw releases within budget; drained chapter prompts after quiz completion; screen-off counts pending and releases nothing.
> - **Task 13:** verify the amended behaviors end-to-end (pacing gate, presentation-time release, deferred retire, quiz-draw release). The registration-name grep expectation is now `v33_study_plan_card_pacing`. Two manual-checklist lines invert under the amendments: there is **no** retire follow-up in the post-accept sheet (the prompt fires later, on last release), and reopening the session the next day releases **nothing by itself** — only cards actually presented (or quiz-drawn) release.

**Goal:** Accepted AI-generated cards join a book's study plan — released chapter-by-chapter under a new-cards-per-day budget instead of all landing due today — reviewed in a chapter-grouped draft sheet, quizzed (screen-on, ≤5 cards, never auto-graded) right after the chapter checkpoint, and generatable from macOS.

**Architecture:** No new tables: `study_plan_item.kind` gains a `card` value linking each accepted card to its chapter (Schema V25 put no CHECK constraint on `kind` — a round-trip test pins that), and one small migration (V33) adds the per-plan `new_cards_per_day` override next to `new_chapter_limit`. `StudyQueueBuilder` grows a fourth phase (`StudyQueueCategory.newCard`) that releases queued cards only after their chapter's plan item was introduced, budgeted by `min(per-plan, global)` with the existing gentle/strict catch-up math; `StudySessionViewModel.loadQueue` performs the release write (stamp `introduced_at` + seed `next_review_date`), after which normal FSRS scheduling owns the card. `StudyDeckAcceptanceService` becomes plan-aware (deferred seeding + `card` plan items + slice-1 retire prompts phrased for bulk), and slice 1's `StudyCheckpointCoordinator` gains a `quizActive` state that flows the checkpoint into a capped `FlashcardReviewCard` quiz.

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
  Entries are kept alphabetical within each list; edit project.pbxproj as plain text. `EchoTests/` files need no pbxproj edit either (the test folder is synchronized too).
- The SwiftFormat PostToolUse hook reflows the whole file on every Edit; after each edit confirm `// SPDX-License-Identifier: GPL-3.0-or-later` is still line 1.
- **Slice 1 landed before this plan.** Line numbers in this plan for files slice 1 modified (SettingsManager, RootTabView, MacTriPaneView, MacSettingsView, PlayerModel+StudyCheckpoint.swift, StudyCheckpointCoordinator.swift, StudyCheckpointPanelView.swift) are approximate — Read each file and anchor on the quoted code, which comes verbatim from slice 1's plan.
- Existing test fixtures: `StudyQueueFixtures` (internal enum at the bottom of `EchoTests/StudyQueueBuilderTests.swift`) seeds in-memory DBs. `serviceWithPlan()` seeds book `book-a` with heading blocks titled "Book A Chapter 1..3" (chapterIndex 0..2), a plan (chapterLimit 1/day, gentle, started at `mondayNoon`), chapter-0's assignment already introduced yesterday, and one due normal card "Due Review". `serviceWithPlan(startDaysBeforeNow: 2)` backdates the plan start. `StudyQueueFixtures.mondayNoon` = `Date(timeIntervalSince1970: 1_782_129_600)`; `StudyQueueFixtures.calendar` is UTC-gregorian with Monday first. Assignment audio ranges are 0–100/100–200/200–300 per chapter.
- Migration numbering: V32 (`v32_narration_text`) is the current highest; slice 1 adds NO migration. **V33 is this plan's migration** — if anything else claimed V33 on nightly in the meantime, renumber to the next free version before starting.

## File Structure

### Created
| File | Responsibility |
|---|---|
| `Shared/Database/Migrations/Schema_V33.swift` | `study_plan.new_cards_per_day` column (default 20) |
| `EchoCore/Views/StudyDeckGenerationSheetHost.swift` | Cross-platform generator-factory host for the generation sheet (iOS BookSettings + macOS menu), excluded from echo-cli |
| `EchoTests/SchemaV33Tests.swift` | Migration + `kind='card'` round-trip tests |
| `EchoTests/SettingsManagerStudyCardLimitTests.swift` | Global new-cards-per-day setting tests |
| `EchoTests/StudyPlanNewCardsPerDayTests.swift` | Per-plan override DAO/view-model tests |
| `EchoTests/StudyCardFixtures.swift` | Shared seeding helper: accepted-AI-card rows (flashcard + `card` plan item) |
| `EchoTests/StudyQueueBuilderCardPhaseTests.swift` | Fourth-phase release/budget/catch-up/ordering tests |
| `EchoTests/StudySessionViewModelCardReleaseTests.swift` | `releaseCards` + loadQueue release-write tests |
| `EchoTests/StudyDeckAcceptancePlanTests.swift` | Plan-aware acceptance: deferred seeding, card items, retire prompts |
| `EchoTests/StudyDeckGenerationChapterFlowTests.swift` | Chapter grouping, accept-all, post-accept follow-up flow |
| `EchoTests/StudyPlanDAOQuizCardsTests.swift` | `dueQuizCards` eligibility/ordering/cap tests |
| `EchoTests/StudyCheckpointQuizTests.swift` | Coordinator quiz state-machine tests |

### Modified
| File | Change |
|---|---|
| `Shared/Database/DatabaseService.swift` | Register `v33_study_plan_new_cards_per_day` (~L148) |
| `Shared/Database/StudyPlan.swift` | `newCardsPerDay` field + CodingKey |
| `Shared/Study/StudyPlanTypes.swift` | `StudyPlanItemKind.card`; `StudyQueueCategory.newCard = 3` |
| `Shared/Database/DAOs/StudyPlanDAO.swift` | Request/create/updateSettings carry `newCardsPerDay`; new `releaseCards(itemIDs:now:)`; new `dueQuizCards(audiobookID:chapterIndex:now:limit:)` |
| `Shared/Services/StudyQueueBuilder.swift` | Fourth phase: `newCardEntries`, `cardReleaseBudget`, `introducedChapterIndexes`, `applyGlobalNewCardLimit`, `.card` case in the chapter-cap switch, card-kind exclusion from in-progress |
| `Shared/Services/StudyDeckAcceptanceService.swift` | Returns `StudyDeckAcceptanceOutcome`; plan books get deferred seeding + `card` plan items + bulk retire prompts |
| `EchoCore/Services/SettingsManager.swift` | `studyNewCardsPerDayLimit` (default 20, clamp 1…100) in Defaults/Keys/property/init/registerDefaults |
| `EchoCore/Views/SettingsView.swift` | "New Cards" stepper under the Global New Chapters stepper (~L269) |
| `Echo macOS/Views/MacSettingsView.swift` | Same stepper in slice 1's `MacStudySettingsPane` |
| `EchoCore/ViewModels/StudyPlanViewModel.swift` | `newCardsPerDay` property, load/apply/save plumbing |
| `EchoCore/Views/StudyPlanSheet.swift` | Per-plan new-cards stepper in `StudyPlanPacingSection` (~L69) |
| `EchoCore/ViewModels/StudySessionViewModel.swift` | `loadQueue` gains `globalNewCardLimit`; releases `.newCard` items |
| `EchoCore/Views/Stats/StatsView.swift` | Pass `globalNewCardLimit` to `loadQueue` (~L309) |
| `EchoCore/Views/UpcomingReviewsModuleView.swift` | Pass `globalNewCardLimit` to `build` (~L56) |
| `EchoCore/Views/SettingsView.swift` | Pass `globalNewCardLimit` in `updateDailyReviewReminder` (~L313) |
| `EchoTests/StudyDeckAcceptanceServiceTests.swift` | Mechanical `.acceptedCards` append on 8 accept-call results |
| `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` | Chapter grouping + accept-all + post-accept step machine (retire prompts, plan offer) |
| `EchoCore/Views/StudyDeckGenerationSheet.swift` | Chapter-grouped sections with accept-all; inline follow-up sections; plan-sheet routing; drip summary |
| `EchoCore/Services/StudyCheckpointCoordinator.swift` | `quizActive` state, `quizCards`/`gradeQuizCard`/`dismissQuiz`, `isScreenOn` seam, deferred finish |
| `EchoCore/Views/StudyCheckpointPanelView.swift` | Quiz panel (FlashcardReviewCard, card X of N, Done for Now) |
| `EchoCore/Views/RootTabView.swift` | Overlay renders for quiz state too (`state != .idle`) |
| `Echo macOS/Views/MacTriPaneView.swift` | Overlay condition for quiz; generation sheet host + onReceive; toolbar button |
| `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift` | Wire `coordinator.isScreenOn` (iOS applicationState) |
| `EchoCore/Views/BookSettingsView.swift` | Use the shared `StudyDeckGenerationSheetHost`; delete the private host |
| `Echo macOS/Echo_macOSApp.swift` | "Generate Study Deck…" menu command + `.requestStudyDeckGeneration` name |
| `Echo.xcodeproj/project.pbxproj` | Un-exclude `Views/FlashcardReviewCard.swift` from Echo macOS; exclude `Views/StudyDeckGenerationSheetHost.swift` from echo-cli |

---

## Task 1: Schema V33 (`new_cards_per_day`) + `card` plan-item kind

**Files:**
- Create: `Shared/Database/Migrations/Schema_V33.swift`
- Modify: `Shared/Database/DatabaseService.swift` (migration registration after `v32_narration_text`, ~L146–148)
- Modify: `Shared/Database/StudyPlan.swift` (whole struct, 35 lines)
- Modify: `Shared/Study/StudyPlanTypes.swift` (`StudyPlanItemKind`, ~L26)
- Modify: `Shared/Database/DAOs/StudyPlanDAO.swift` (`StudyPlanCreationRequest` ~L5; `createPlan` StudyPlan construction ~L75)
- Modify: `Shared/Services/StudyQueueBuilder.swift` (`applyGlobalNewChapterLimit` switch, ~L304)
- Test: `EchoTests/SchemaV33Tests.swift`

**Interfaces:**
- Consumes: existing `StudyPlan`, `StudyPlanItem`, `StudyPlanDAO.createPlan(_:)`, `DatabaseService(inMemory: ())`, migration pattern (`Schema_V32` idiom). No slice-1 symbols.
- Produces (used by Tasks 3, 4, 6):
  - `Schema_V33.migrate(_ db: Database) throws` registered as `"v33_study_plan_new_cards_per_day"`
  - `StudyPlan.newCardsPerDay: Int` (memberwise default 20, column `new_cards_per_day`)
  - `StudyPlanItemKind.card` (raw value `"card"`)
  - `StudyPlanCreationRequest` explicit init with `newCardsPerDay: Int = 20` inserted after `newChapterLimit`

**Steps:**

- [ ] Write the failing test at `EchoTests/SchemaV33Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV33Tests {
    @Test func v33AddsNewCardsPerDayToStudyPlan() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(study_plan)")
            return Set(rows.compactMap { $0["name"] as? String })
        }
        #expect(columns.contains("new_cards_per_day"))
    }

    @Test func rowsInsertedWithoutTheColumnDefaultTo20() throws {
        let db = try DatabaseService(inMemory: ())
        try seedPlanRow(in: db)
        let plan = try db.read { database in try StudyPlan.fetchOne(database, key: "p") }
        #expect(plan?.newCardsPerDay == 20)
    }

    @Test func planItemKindCardRoundTrips() throws {
        // Design §3: study_plan_item.kind is plain TEXT (Schema V25 put no
        // CHECK constraint on it) — 'card' must round-trip through the record
        // and the enum without a relaxing migration.
        let db = try DatabaseService(inMemory: ())
        try seedPlanRow(in: db)
        var item = StudyPlanItem(
            id: "item-1", planID: "p", flashcardID: nil,
            kind: StudyPlanItemKind.card.rawValue, chapterIndex: 3, sourceBlockID: nil,
            ordinal: 7, introducedAt: nil, isEnabled: true,
            createdAt: "2026-07-01T00:00:00Z", modifiedAt: "2026-07-01T00:00:00Z")
        try db.write { database in try item.insert(database) }

        let fetched = try db.read { database in
            try StudyPlanItem.fetchOne(database, key: "item-1")
        }
        #expect(fetched?.kind == "card")
        #expect(fetched.flatMap { StudyPlanItemKind(rawValue: $0.kind) } == .card)
    }

    @Test func createPlanPersistsNewCardsPerDayOverride() throws {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b', 'B', 10)")
        }
        let result = try StudyPlanDAO(db: service.writer).createPlan(
            StudyPlanCreationRequest(
                audiobookID: "b",
                bookTitle: "B",
                cadenceUnit: .day,
                newChapterLimit: 1,
                newCardsPerDay: 7,
                includeImages: false,
                queueMode: .bookByBook,
                catchUpPolicy: .gentle,
                startDate: Date(timeIntervalSince1970: 1_750_000_000),
                candidates: [],
                now: Date(timeIntervalSince1970: 1_750_000_000)
            )
        )
        #expect(result.plan.newCardsPerDay == 7)
        let stored = try service.read { db in
            try Int.fetchOne(
                db, sql: "SELECT new_cards_per_day FROM study_plan WHERE id = ?",
                arguments: [result.plan.id])
        }
        #expect(stored == 7)
    }

    private func seedPlanRow(in db: DatabaseService) throws {
        try db.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b', 'B', 10)")
            // Deliberately omits new_cards_per_day: proves the column default.
            try database.execute(
                sql: """
                    INSERT INTO study_plan
                    (id, audiobook_id, cadence_unit, new_chapter_limit, include_images,
                     queue_mode_default, catch_up_policy, start_date, is_paused,
                     created_at, modified_at)
                    VALUES ('p', 'b', 'day', 1, 0, 'book_by_book', 'gentle',
                            '2026-07-01T00:00:00Z', 0,
                            '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z')
                    """)
        }
    }
}
```

- [ ] Run it (expect compile failure: `extra argument 'newCardsPerDay' in call` / `type 'StudyPlanItemKind' has no member 'card'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Create `Shared/Database/Migrations/Schema_V33.swift` (Shared/ is folder-synchronized — no pbxproj edit):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Adds the per-plan AI-card drip override (AI-cards design §4): how many new
/// AI cards a plan may release per cadence window, alongside the existing
/// `new_chapter_limit`. Existing plans backfill to the global default (20).
enum Schema_V33 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "study_plan") { t in
            t.add(column: "new_cards_per_day", .integer).notNull().defaults(to: 20)
        }
    }
}
```

- [ ] In `Shared/Database/DatabaseService.swift`, after the `v32_narration_text` registration (~L146) and before `try migrator.migrate(writer)`, add:

```swift
        migrator.registerMigration("v33_study_plan_new_cards_per_day") { db in
            try Schema_V33.migrate(db)
        }
```

- [ ] Replace the whole struct in `Shared/Database/StudyPlan.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlan: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    var id: String
    var audiobookID: String
    var deckID: String?
    var cadenceUnit: String
    var newChapterLimit: Int
    /// AI-cards design §4: per-plan new-card drip override (default = the
    /// global setting's default). The queue builder takes
    /// min(this, global cap) per cadence window.
    var newCardsPerDay: Int = 20
    var includeImages: Bool
    var queueModeDefault: String
    var catchUpPolicy: String
    var startDate: String
    var isPaused: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "study_plan"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case deckID = "deck_id"
        case cadenceUnit = "cadence_unit"
        case newChapterLimit = "new_chapter_limit"
        case newCardsPerDay = "new_cards_per_day"
        case includeImages = "include_images"
        case queueModeDefault = "queue_mode_default"
        case catchUpPolicy = "catch_up_policy"
        case startDate = "start_date"
        case isPaused = "is_paused"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
```

(The `= 20` memberwise default keeps the existing labeled `StudyPlan(id:audiobookID:…)` construction in `StudyPlanDAO.createPlan` compiling until the next step passes the real value.)

- [ ] In `Shared/Study/StudyPlanTypes.swift`, extend the kind enum (~L26):

```swift
enum StudyPlanItemKind: String, Codable, Sendable, CaseIterable {
    case chapter
    case image
    /// An accepted AI flashcard riding the plan's chapter cadence (design §3).
    case card
}
```

- [ ] In `Shared/Services/StudyQueueBuilder.swift`, the `switch kind` inside `applyGlobalNewChapterLimit` (~L304) is now non-exhaustive. Add a third case after the `case .image:` branch:

```swift
            case .card:
                // AI cards ride their own daily budget (Task 4's
                // applyGlobalNewCardLimit), never the chapter cap.
                return true
```

- [ ] In `Shared/Database/DAOs/StudyPlanDAO.swift`, replace `StudyPlanCreationRequest` (~L5–16) with (explicit init so the existing call sites that omit `newCardsPerDay` keep compiling):

```swift
struct StudyPlanCreationRequest: Sendable {
    let audiobookID: String
    let bookTitle: String
    let cadenceUnit: StudyPlanCadenceUnit
    let newChapterLimit: Int
    let newCardsPerDay: Int
    let includeImages: Bool
    let queueMode: StudyPlanQueueMode
    let catchUpPolicy: StudyPlanCatchUpPolicy
    let startDate: Date
    let candidates: [StudyPlanCandidate]
    let now: Date

    init(
        audiobookID: String,
        bookTitle: String,
        cadenceUnit: StudyPlanCadenceUnit,
        newChapterLimit: Int,
        newCardsPerDay: Int = 20,
        includeImages: Bool,
        queueMode: StudyPlanQueueMode,
        catchUpPolicy: StudyPlanCatchUpPolicy,
        startDate: Date,
        candidates: [StudyPlanCandidate],
        now: Date
    ) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.cadenceUnit = cadenceUnit
        self.newChapterLimit = newChapterLimit
        self.newCardsPerDay = newCardsPerDay
        self.includeImages = includeImages
        self.queueMode = queueMode
        self.catchUpPolicy = catchUpPolicy
        self.startDate = startDate
        self.candidates = candidates
        self.now = now
    }
}
```

- [ ] Still in `StudyPlanDAO.createPlan`, in the `var plan = StudyPlan(` construction (~L75), insert one line after `newChapterLimit: boundedLimit,`:

```swift
                newCardsPerDay: max(1, request.newCardsPerDay),
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/SchemaV33Tests
```

Also re-run the neighbors that touch these types:

```bash
make test-only FILTER=EchoTests/StudyPlanDAOTests
make test-only FILTER=EchoTests/StudyQueueBuilderTests
```

- [ ] **REQUIRED REVIEW:** run the schema-migration-reviewer agent on the V33 diff (`Shared/Database/Migrations/Schema_V33.swift` + the `DatabaseService.swift` registration) BEFORE committing this task. Address any findings first.

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Database/Migrations/Schema_V33.swift Shared/Database/DatabaseService.swift \
    Shared/Database/StudyPlan.swift Shared/Study/StudyPlanTypes.swift \
    Shared/Database/DAOs/StudyPlanDAO.swift Shared/Services/StudyQueueBuilder.swift \
    EchoTests/SchemaV33Tests.swift
git commit -m "feat(study): add V33 new_cards_per_day migration and 'card' plan-item kind"
```

---

## Task 2: Global `studyNewCardsPerDayLimit` setting (default 20, clamp 1…100)

**Files:**
- Modify: `EchoCore/Services/SettingsManager.swift` — `Defaults` enum (after `studyGlobalNewChapterLimit`, L62), `Keys` enum (after `studyGlobalNewChapterLimit`, L128), stored property (after `studyGlobalNewChapterLimit` property, ~L334), init load (after the `studyGlobalNewChapterLimit` load, ~L691), `registerDefaults` (after `Keys.studyGlobalNewChapterLimit` entry, ~L762), clamp helper (next to `boundedStudyGlobalNewChapterLimit`, ~L830)
- Modify: `EchoCore/Views/SettingsView.swift` — stepper after the Global New Chapters stepper (~L269–274) and a `cardLimitText` helper after `limitText` (~L277–281)
- Modify: `Echo macOS/Views/MacSettingsView.swift` — same stepper in slice 1's `MacStudySettingsPane` (Read the file; anchor on its Global New Chapters stepper)
- Test: `EchoTests/SettingsManagerStudyCardLimitTests.swift`

**Interfaces:**
- Consumes: `SettingsManager` UserDefaults pattern (existing `studyGlobalNewChapterLimit` end-to-end idiom); slice-1 symbol: `MacStudySettingsPane` (private struct slice 1 added to `Echo macOS/Views/MacSettingsView.swift`).
- Produces (used by Tasks 5, 8):
  - `SettingsManager.Defaults.studyNewCardsPerDayLimit: Int` (20)
  - `var studyNewCardsPerDayLimit: Int` (clamped 1…100 in didSet and on load)

**Steps:**

- [ ] Write the failing test at `EchoTests/SettingsManagerStudyCardLimitTests.swift` (same harness idiom as slice 1's `SettingsManagerCheckpointTests`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct SettingsManagerStudyCardLimitTests {
    private func makeSettings(
        seed: (UserDefaults) -> Void = { _ in }
    ) throws -> (SettingsManager, UserDefaults, String) {
        let suiteName = "card-limit-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        seed(defaults)
        let appGroupDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-group"))
        let settings = SettingsManager(
            defaults: defaults,
            appGroupDefaults: appGroupDefaults,
            defaultsDomainName: nil,
            appGroupDefaultsDomainName: nil
        )
        return (settings, defaults, suiteName)
    }

    @Test func defaultsTo20() throws {
        let (settings, _, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(settings.studyNewCardsPerDayLimit == 20)
    }

    @Test func clampsWritesTo1Through100() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.studyNewCardsPerDayLimit = 0
        #expect(settings.studyNewCardsPerDayLimit == 1)

        settings.studyNewCardsPerDayLimit = 250
        #expect(settings.studyNewCardsPerDayLimit == 100)
        #expect(defaults.integer(forKey: "studyNewCardsPerDayLimit") == 100)

        settings.studyNewCardsPerDayLimit = 35
        #expect(settings.studyNewCardsPerDayLimit == 35)
        #expect(defaults.integer(forKey: "studyNewCardsPerDayLimit") == 35)
    }

    @Test func tamperedStoredValueLoadsClamped() throws {
        let (settings, _, suite) = try makeSettings { defaults in
            defaults.set(9_999, forKey: "studyNewCardsPerDayLimit")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(settings.studyNewCardsPerDayLimit == 100)
    }
}
```

- [ ] Run it (expect compile failure: `value of type 'SettingsManager' has no member 'studyNewCardsPerDayLimit'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Implement in `EchoCore/Services/SettingsManager.swift` — six edits, each mirroring the `studyGlobalNewChapterLimit` idiom exactly:

**(a)** In `enum Defaults`, after `static let studyGlobalNewChapterLimit = 12` (L62), add:

```swift
        static let studyNewCardsPerDayLimit = 20
```

**(b)** In `private enum Keys`, after `static let studyGlobalNewChapterLimit = "studyGlobalNewChapterLimit"` (L128), add:

```swift
        static let studyNewCardsPerDayLimit = "studyNewCardsPerDayLimit"
```

**(c)** In the `// MARK: - Study` section, after the closing brace of the `studyGlobalNewChapterLimit` property (~L334), add:

```swift
    /// Cross-plan daily cap on newly released AI cards (design §4). The queue
    /// builder takes min(per-plan `newCardsPerDay`, this) per cadence window.
    var studyNewCardsPerDayLimit: Int {
        didSet {
            let boundedValue = Self.boundedStudyNewCardsPerDayLimit(studyNewCardsPerDayLimit)
            guard studyNewCardsPerDayLimit == boundedValue else {
                studyNewCardsPerDayLimit = boundedValue
                return
            }
            defaults.set(boundedValue, forKey: Keys.studyNewCardsPerDayLimit)
        }
    }
```

**(d)** In `init`, immediately after the `studyGlobalNewChapterLimit = Self.boundedStudyGlobalNewChapterLimit(...)` load (~L688–691), add:

```swift
        studyNewCardsPerDayLimit = Self.boundedStudyNewCardsPerDayLimit(
            defaults.object(forKey: Keys.studyNewCardsPerDayLimit) as? Int
                ?? Defaults.studyNewCardsPerDayLimit
        )
```

**(e)** In `registerDefaults`, after `Keys.studyGlobalNewChapterLimit: Defaults.studyGlobalNewChapterLimit,` (~L762), add:

```swift
            Keys.studyNewCardsPerDayLimit: Defaults.studyNewCardsPerDayLimit,
```

**(f)** After `private static func boundedStudyGlobalNewChapterLimit(_ value: Int) -> Int { ... }` (~L828–830), add:

```swift
    private static func boundedStudyNewCardsPerDayLimit(_ value: Int) -> Int {
        min(max(1, value), 100)
    }
```

- [ ] In `EchoCore/Views/SettingsView.swift`, after the Global New Chapters `Stepper` block (ends ~L274), add:

```swift
        Stepper(value: $settings.studyNewCardsPerDayLimit, in: 1...100) {
            LabeledContent("New Cards") {
                Text(cardLimitText)
                    .foregroundStyle(.secondary)
            }
        }
```

and after the `limitText` computed property (~L281), add:

```swift
    private var cardLimitText: String {
        let limit = settings.studyNewCardsPerDayLimit
        let unit = limit == 1 ? "card" : "cards"
        return "\(limit) \(unit) per day"
    }
```

- [ ] In `Echo macOS/Views/MacSettingsView.swift`, Read the file, find slice 1's `MacStudySettingsPane`, and directly after its `Stepper(value: $settings.studyGlobalNewChapterLimit, in: 1...12) { ... }` block add:

```swift
                Stepper(value: $settings.studyNewCardsPerDayLimit, in: 1...100) {
                    LabeledContent("New AI Cards") {
                        Text("\(settings.studyNewCardsPerDayLimit) per day")
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] Run again (expect pass; the macOS pane compiles in Task 13's macOS build):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/SettingsManagerStudyCardLimitTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add EchoCore/Services/SettingsManager.swift EchoCore/Views/SettingsView.swift \
    "Echo macOS/Views/MacSettingsView.swift" EchoTests/SettingsManagerStudyCardLimitTests.swift
git commit -m "feat(settings): add global new-cards-per-day limit (default 20, clamp 1-100)"
```

---

## Task 3: Per-plan `newCardsPerDay` override editing

**Files:**
- Modify: `Shared/Database/DAOs/StudyPlanDAO.swift` (`updateSettings`, ~L145–166)
- Modify: `EchoCore/ViewModels/StudyPlanViewModel.swift` (property ~L14; `save()` both branches ~L100–148; `apply(_:)` ~L175)
- Modify: `EchoCore/Views/StudyPlanSheet.swift` (`StudyPlanPacingSection`, after the chapter `Stepper` ~L69–71)
- Modify: `EchoTests/StudyPlanDAOTests.swift` (one `updateSettings` call, ~L92)
- Test: `EchoTests/StudyPlanNewCardsPerDayTests.swift`

**Interfaces:**
- Consumes: `StudyPlan.newCardsPerDay` / `StudyPlanCreationRequest(newCardsPerDay:)` (Task 1), `StudyQueueFixtures.serviceWithPlan()` (existing).
- Produces (used by the plan sheet UI and Task 4's budget math):
  - `StudyPlanDAO.updateSettings(planID:cadenceUnit:newChapterLimit:newCardsPerDay:includeImages:queueMode:catchUpPolicy:now:)` (parameter inserted after `newChapterLimit`, NOT defaulted — a forgotten argument must be a compile error, not a silent reset to 20)
  - `StudyPlanViewModel.newCardsPerDay: Int` (+ `cardLimitText: String`)

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyPlanNewCardsPerDayTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlanNewCardsPerDayTests {
    @Test func updateSettingsPersistsTheOverride() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))

        try dao.updateSettings(
            planID: plan.id,
            cadenceUnit: .day,
            newChapterLimit: plan.newChapterLimit,
            newCardsPerDay: 33,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(try dao.plan(for: "book-a")?.newCardsPerDay == 33)
    }

    @Test func updateSettingsFloorsTheOverrideAtOne() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))

        try dao.updateSettings(
            planID: plan.id,
            cadenceUnit: .day,
            newChapterLimit: plan.newChapterLimit,
            newCardsPerDay: 0,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(try dao.plan(for: "book-a")?.newCardsPerDay == 1)
    }

    @Test func viewModelLoadsAndSavesTheOverride() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.updateSettings(
            planID: plan.id,
            cadenceUnit: .day,
            newChapterLimit: plan.newChapterLimit,
            newCardsPerDay: 15,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            now: StudyQueueFixtures.mondayNoon
        )

        let vm = StudyPlanViewModel(
            audiobookID: "book-a", bookTitle: "Book A", db: service.writer)
        vm.load()
        #expect(vm.newCardsPerDay == 15)

        vm.newCardsPerDay = 40
        #expect(vm.save(now: StudyQueueFixtures.mondayNoon))
        #expect(try dao.plan(for: "book-a")?.newCardsPerDay == 40)
    }
}
```

- [ ] Run it (expect compile failure: `extra argument 'newCardsPerDay' in call`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] In `Shared/Database/DAOs/StudyPlanDAO.swift`, replace `updateSettings` (~L145–166) with:

```swift
    func updateSettings(
        planID: String,
        cadenceUnit: StudyPlanCadenceUnit,
        newChapterLimit: Int,
        newCardsPerDay: Int,
        includeImages: Bool,
        queueMode: StudyPlanQueueMode,
        catchUpPolicy: StudyPlanCatchUpPolicy,
        now: Date = Date()
    ) throws {
        try db.write { db in
            _ = try StudyPlan
                .filter(Column("id") == planID)
                .updateAll(db, [
                    Column("cadence_unit").set(to: cadenceUnit.rawValue),
                    Column("new_chapter_limit").set(to: max(1, newChapterLimit)),
                    Column("new_cards_per_day").set(to: max(1, newCardsPerDay)),
                    Column("include_images").set(to: includeImages),
                    Column("queue_mode_default").set(to: queueMode.rawValue),
                    Column("catch_up_policy").set(to: catchUpPolicy.rawValue),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }
```

- [ ] In `EchoTests/StudyPlanDAOTests.swift`, the existing `updatesSettingsPauseStateAndItemEnabledState` test (~L92) now fails to compile. In its `try dao.updateSettings(` call, insert one line after `newChapterLimit: 2,`:

```swift
            newCardsPerDay: 20,
```

- [ ] In `EchoCore/ViewModels/StudyPlanViewModel.swift`:

**(a)** After `var newChapterLimit: Int = 1` (L14), add:

```swift
    var newCardsPerDay: Int = 20
```

**(b)** After the `chapterLimitText` computed property (~L46–49), add:

```swift
    var cardLimitText: String {
        let unit = newCardsPerDay == 1 ? "new AI card" : "new AI cards"
        return "\(newCardsPerDay) \(unit) per \(cadenceLabel)"
    }
```

**(c)** In `save()`, existing-plan branch, insert one line into the `try dao.updateSettings(` call after `newChapterLimit: newChapterLimit,` (~L104):

```swift
                    newCardsPerDay: newCardsPerDay,
```

**(d)** In `save()`, create branch, insert one line into the `StudyPlanCreationRequest(` construction after `newChapterLimit: newChapterLimit,` (~L140):

```swift
                        newCardsPerDay: newCardsPerDay,
```

**(e)** In `apply(_ plan: StudyPlan)` (~L175), after `newChapterLimit = max(1, plan.newChapterLimit)`, add:

```swift
        newCardsPerDay = max(1, plan.newCardsPerDay)
```

- [ ] In `EchoCore/Views/StudyPlanSheet.swift`, inside `StudyPlanPacingSection`, after the chapter `Stepper` block (`Stepper(value: $viewModel.newChapterLimit, in: 1...12) { ... }`, ~L69–71), add:

```swift
            Stepper(value: $viewModel.newCardsPerDay, in: 1...100) {
                Text(viewModel.cardLimitText)
            }
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyPlanNewCardsPerDayTests
make test-only FILTER=EchoTests/StudyPlanDAOTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Database/DAOs/StudyPlanDAO.swift EchoCore/ViewModels/StudyPlanViewModel.swift \
    EchoCore/Views/StudyPlanSheet.swift EchoTests/StudyPlanDAOTests.swift \
    EchoTests/StudyPlanNewCardsPerDayTests.swift
git commit -m "feat(study): per-plan new-cards-per-day override with plan-sheet stepper"
```

---

## Task 4: StudyQueueBuilder fourth phase — new-card release

**Files:**
- Modify: `Shared/Study/StudyPlanTypes.swift` (`StudyQueueCategory`, ~L75)
- Modify: `Shared/Services/StudyQueueBuilder.swift` (`build` ~L8–44; `assignmentEntries` in-progress filter ~L52–57; `introducedChapterCount` rename ~L185; new private members after `releaseBudget`)
- Create: `EchoTests/StudyCardFixtures.swift`
- Test: `EchoTests/StudyQueueBuilderCardPhaseTests.swift`

**Interfaces:**
- Consumes: `StudyPlan.newCardsPerDay` / `StudyPlanItemKind.card` (Task 1), existing `StudyQueueBuilder` internals (`releaseBudget`, `cadenceWindowStart`, `elapsedCadenceWindowCount`, `ItemCardRow`, `ordered`), `StudyQueueFixtures` (existing).
- Produces (used by Tasks 5, 13):
  - `StudyQueueCategory.newCard = 3`
  - `StudyQueueBuilder.build(now:calendar:modeOverride:globalNewChapterLimit:globalNewCardLimit:)` — new `globalNewCardLimit: Int? = nil` trailing parameter
  - `.newCard` entries with id `"card-<planItemID>"`
  - Test helper `StudyCardFixtures.seedAcceptedCard(id:audiobookID:chapterIndex:ordinal:released:releasedAt:in:)` (flashcard id = `id`, plan-item id = `"item-<id>"`, front text `"Card <id>"`)

**Steps:**

- [ ] Create the shared test fixture at `EchoTests/StudyCardFixtures.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

@testable import Echo

/// Seeds accepted-AI-card row pairs (a flashcard plus its kind-'card'
/// study_plan_item) for the slice-2 suites, mirroring exactly what
/// StudyDeckAcceptanceService writes and what StudyPlanDAO.releaseCards stamps.
@MainActor
enum StudyCardFixtures {
    struct MissingPlanError: Error {}

    /// - Parameters:
    ///   - released: when true, stamps `introduced_at` AND a due
    ///     `next_review_date` (the pair `releaseCards` writes); when false the
    ///     card is still queued (both NULL).
    ///   - releasedAt: the release stamp used when `released` is true —
    ///     defaults to an hour before `mondayNoon` (already due "today").
    static func seedAcceptedCard(
        id: String,
        audiobookID: String = "book-a",
        chapterIndex: Int,
        ordinal: Int,
        released: Bool = false,
        releasedAt: Date = StudyQueueFixtures.mondayNoon.addingTimeInterval(-3_600),
        in service: DatabaseService
    ) throws {
        let planID = try service.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM study_plan WHERE audiobook_id = ?",
                arguments: [audiobookID])
        }
        guard let planID else { throw MissingPlanError() }

        let stamp = StudyQueueFixtures.mondayNoon.ISO8601Format()
        let releasedStamp = releasedAt.ISO8601Format()
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flashcard
                    (id, audiobook_id, front_text, back_text, media_timestamp, trigger_timing,
                     next_review_date, interval_days, ease_factor, repetitions, is_enabled,
                     card_type, created_at, modified_at)
                    VALUES (?, ?, ?, 'Back', 0, 'manualOnly', ?, 0, 2.5, 0, 1, 'normal', ?, ?)
                    """,
                arguments: [
                    id, audiobookID, "Card \(id)",
                    released ? releasedStamp : nil,
                    stamp, stamp,
                ])
            try db.execute(
                sql: """
                    INSERT INTO study_plan_item
                    (id, plan_id, flashcard_id, kind, chapter_index, ordinal,
                     introduced_at, is_enabled, created_at, modified_at)
                    VALUES (?, ?, ?, 'card', ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    "item-\(id)", planID, id, chapterIndex, ordinal,
                    released ? releasedStamp : nil,
                    stamp, stamp,
                ])
        }
    }
}
```

- [ ] Write the failing test at `EchoTests/StudyQueueBuilderCardPhaseTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyQueueBuilderCardPhaseTests {
    private func newCardTitles(in queue: StudyQueue) -> [String] {
        queue.entries.filter { $0.category == .newCard }.map(\.flashcard.frontText)
    }

    @Test func cardsReleaseOnlyAfterTheirChapterIsIntroduced() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        // Chapter 0 was introduced by the fixture; chapter 1 was not.
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-ch0", chapterIndex: 0, ordinal: 100, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-ch1", chapterIndex: 1, ordinal: 101, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card card-ch0"])
    }

    @Test func perPlanBudgetIsMinOfPlanAndGlobal() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for i in 0..<3 {
            try StudyCardFixtures.seedAcceptedCard(
                id: "card-\(i)", chapterIndex: 0, ordinal: 100 + i, in: service)
        }
        let builder = StudyQueueBuilder(db: service.writer)

        // Global 2 beats the plan default (20).
        let globallyCapped = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 2
        )
        #expect(newCardTitles(in: globallyCapped).count == 2)

        // Plan override 1 beats global 20.
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET new_cards_per_day = 1")
        }
        let planCapped = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )
        #expect(newCardTitles(in: planCapped) == ["Card card-0"])
    }

    @Test func gentleCatchUpCountsCardsAlreadyReleasedThisWindow() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET new_cards_per_day = 3")
        }
        // Two cards already released earlier today eat into today's budget.
        try StudyCardFixtures.seedAcceptedCard(
            id: "released-1", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "released-2", chapterIndex: 0, ordinal: 101, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending-1", chapterIndex: 0, ordinal: 102, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending-2", chapterIndex: 0, ordinal: 103, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card pending-1"])
    }

    @Test func strictCatchUpAllowsTheMissedWindows() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(startDaysBeforeNow: 2)
        try service.write { db in
            try db.execute(
                sql: "UPDATE study_plan SET new_cards_per_day = 1, catch_up_policy = 'strict'")
        }
        for i in 0..<4 {
            try StudyCardFixtures.seedAcceptedCard(
                id: "card-\(i)", chapterIndex: 0, ordinal: 100 + i, in: service)
        }

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        // 3 elapsed daily windows x 1/day, none released yet → 3 owed.
        #expect(newCardTitles(in: queue).count == 3)
    }

    @Test func releasedCardsSurfaceAsDueReviewsNotInProgressAssignments() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "released", chapterIndex: 0, ordinal: 100, released: true, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let entries = queue.entries.filter { $0.flashcard.id == "released" }
        #expect(entries.map(\.category) == [.dueReview])
    }

    @Test func fourthPhaseOrdersAfterTheOtherThree() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let categories = queue.entries.map(\.category.rawValue)
        #expect(categories == categories.sorted())
        #expect(queue.entries.last?.category == .newCard)
    }

    @Test func chapterCapDoesNotSwallowCardEntries() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewChapterLimit: 0,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card pending"])
        #expect(queue.newAssignmentCount == 0)
    }

    @Test func pausedPlanReleasesNoNewCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue).isEmpty)
    }

    @Test func retiredChapterStillReleasesItsCards() throws {
        // Design §4: introduction is what gates cards, not the chapter item's
        // current enabled state — retiring the re-listen card must not dam the
        // drip behind it.
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)
        try service.write { db in
            try db.execute(
                sql: """
                    UPDATE study_plan_item SET is_enabled = 0
                    WHERE kind = 'chapter' AND chapter_index = 0
                    """)
        }

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card pending"])
    }
}
```

- [ ] Run it (expect compile failure: `type 'StudyQueueCategory' has no member 'newCard'` / `extra argument 'globalNewCardLimit' in call`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] In `Shared/Study/StudyPlanTypes.swift`, extend the category enum (~L75):

```swift
enum StudyQueueCategory: Int, Codable, Sendable, CaseIterable {
    case dueReview = 0
    case inProgressAssignment = 1
    case newAssignment = 2
    /// Fourth phase (AI-cards design §4): queued AI cards whose chapter has
    /// been introduced and whose daily budget allows release.
    case newCard = 3
}
```

- [ ] In `Shared/Services/StudyQueueBuilder.swift`, five edits:

**(a)** Replace `build(...)` (~L8–44) with:

```swift
    func build(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil,
        globalNewChapterLimit: Int? = nil,
        globalNewCardLimit: Int? = nil
    ) throws -> StudyQueue {
        let dueCards = try FlashcardDAO(db: db).allDueCards(now: now)
        let plans = try StudyPlanDAO(db: db).plansForQueue()
        let planOrder = Dictionary(uniqueKeysWithValues: plans.enumerated().map { ($0.element.id, $0.offset) })
        let itemRowsByPlanID = try Dictionary(
            uniqueKeysWithValues: plans.map { plan in
                (plan.id, try itemCardRows(planID: plan.id))
            }
        )

        let dueEntries = dueEntries(
            for: dueCards,
            plans: plans,
            itemRowsByPlanID: itemRowsByPlanID
        )
        let assignmentQueueEntries = plans.flatMap { plan in
            assignmentEntries(
                for: plan,
                rows: itemRowsByPlanID[plan.id] ?? [],
                now: now,
                calendar: calendar
            )
        }
        let newCardQueueEntries = try plans.flatMap { plan in
            try newCardEntries(
                for: plan,
                rows: itemRowsByPlanID[plan.id] ?? [],
                now: now,
                calendar: calendar,
                globalNewCardLimit: globalNewCardLimit
            )
        }
        let modeSourcePlan = plans.first { !$0.isPaused } ?? plans.first
        let mode = modeOverride
            ?? modeSourcePlan.flatMap { StudyPlanQueueMode(rawValue: $0.queueModeDefault) }
            ?? .bookByBook
        let orderedEntries = ordered(
            entries: dueEntries + assignmentQueueEntries + newCardQueueEntries,
            mode: mode,
            planOrder: planOrder
        )
        let chapterCappedEntries = applyGlobalNewChapterLimit(globalNewChapterLimit, to: orderedEntries)
        let cappedEntries = applyGlobalNewCardLimit(globalNewCardLimit, to: chapterCappedEntries)

        return StudyQueue(entries: cappedEntries)
    }
```

**(b)** In `assignmentEntries`, the `inProgress` filter (~L52–57) must exclude card-kind rows (a released-but-unreviewed AI card is already a due review — surfacing it as in-progress too would duplicate it). Replace the filter closure:

```swift
        let inProgress = rows
            .filter { row in
                row.item.introducedAt != nil
                    && row.item.kind != StudyPlanItemKind.card.rawValue
                    && row.card.repetitions == 0
                    && row.card.lastReviewedAt == nil
            }
```

**(c)** Generalize `introducedChapterCount` (~L185–198) to count by kind — replace the whole function with:

```swift
    private func introducedItemCount(
        rows: [ItemCardRow],
        kind: StudyPlanItemKind,
        after startDate: Date,
        through endDate: Date
    ) -> Int {
        rows.filter { row in
            guard row.item.kind == kind.rawValue,
                  let introducedAt = row.item.introducedAt,
                  let introducedDate = try? Date(introducedAt, strategy: .iso8601) else {
                return false
            }
            return introducedDate >= startDate && introducedDate <= endDate
        }.count
    }
```

and update the two call sites inside `releaseBudget` (~L166 and ~L180):

```swift
            let introducedThisWindow = introducedItemCount(
                rows: rows,
                kind: .chapter,
                after: windowStart,
                through: now
            )
```

```swift
            let introducedTotal = introducedItemCount(
                rows: rows, kind: .chapter, after: startDate, through: now)
```

**(d)** After the closing brace of `releaseBudget` (~L183), add the fourth-phase members:

```swift
    /// Fourth phase (AI-cards design §4): queued AI cards, released only when
    /// (a) their chapter's plan item was introduced (regardless of whether the
    /// re-listen card was since retired) and (b) the per-plan/global daily
    /// budget allows. Mirrors `assignmentEntries` + `releaseBudget` for cards.
    private func newCardEntries(
        for plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar,
        globalNewCardLimit: Int?
    ) throws -> [StudyQueueEntry] {
        guard !plan.isPaused else { return [] }

        let budget = min(
            cardReleaseBudget(plan: plan, rows: rows, now: now, calendar: calendar),
            globalNewCardLimit ?? Int.max
        )
        guard budget > 0 else { return [] }

        let introducedChapters = try introducedChapterIndexes(planID: plan.id)
        let pendingCards = rows
            .filter { row in
                row.item.kind == StudyPlanItemKind.card.rawValue
                    && row.item.introducedAt == nil
                    && row.item.chapterIndex.map { introducedChapters.contains($0) } == true
            }
            .sorted { $0.item.ordinal < $1.item.ordinal }
            .prefix(budget)

        return pendingCards.map { row in
            StudyQueueEntry(
                id: "card-\(row.item.id)",
                category: .newCard,
                plan: plan,
                item: row.item,
                flashcard: row.card
            )
        }
    }

    /// `releaseBudget` for cards: same gentle/strict catch-up math, counting
    /// card introductions against `new_cards_per_day`.
    private func cardReleaseBudget(
        plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let limit = max(1, plan.newCardsPerDay)
        guard let startDate = try? Date(plan.startDate, strategy: .iso8601),
              startDate <= now else {
            return 0
        }

        let unit = StudyPlanCadenceUnit(rawValue: plan.cadenceUnit) ?? .day
        let catchUpPolicy = StudyPlanCatchUpPolicy(rawValue: plan.catchUpPolicy) ?? .gentle

        switch catchUpPolicy {
        case .gentle:
            let windowStart = max(
                startDate,
                cadenceWindowStart(for: unit, containing: now, calendar: calendar)
            )
            let introducedThisWindow = introducedItemCount(
                rows: rows,
                kind: .card,
                after: windowStart,
                through: now
            )
            return max(0, limit - introducedThisWindow)

        case .strict:
            let allowedCardCount = limit * elapsedCadenceWindowCount(
                from: startDate,
                through: now,
                unit: unit,
                calendar: calendar
            )
            let introducedTotal = introducedItemCount(
                rows: rows, kind: .card, after: startDate, through: now)
            return max(0, allowedCardCount - introducedTotal)
        }
    }

    /// Chapters that have EVER been introduced for this plan. Deliberately
    /// does NOT filter `is_enabled`: retiring a chapter's re-listen card must
    /// not stop its accepted AI cards from dripping (design §4). This is why
    /// the lookup can't reuse `itemCardRows` (which filters enabled rows).
    private func introducedChapterIndexes(planID: String) throws -> Set<Int> {
        try db.read { db in
            let indexes = try Int.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT chapter_index FROM study_plan_item
                    WHERE plan_id = ?
                      AND kind = 'chapter'
                      AND introduced_at IS NOT NULL
                      AND chapter_index IS NOT NULL
                    """,
                arguments: [planID]
            )
            return Set(indexes)
        }
    }
```

**(e)** After the closing brace of `applyGlobalNewChapterLimit` (~L318), add the cross-plan card cap:

```swift
    /// Cross-plan daily cap on `.newCard` releases, mirroring the global
    /// chapter cap. Runs after ordering so the first plans in queue order win.
    private func applyGlobalNewCardLimit(
        _ limit: Int?,
        to entries: [StudyQueueEntry]
    ) -> [StudyQueueEntry] {
        guard let limit else { return entries }

        let effectiveLimit = max(0, limit)
        var releasedCardCount = 0

        return entries.filter { entry in
            guard entry.category == .newCard else { return true }
            guard releasedCardCount < effectiveLimit else { return false }
            releasedCardCount += 1
            return true
        }
    }
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyQueueBuilderCardPhaseTests
make test-only FILTER=EchoTests/StudyQueueBuilderTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Study/StudyPlanTypes.swift Shared/Services/StudyQueueBuilder.swift \
    EchoTests/StudyCardFixtures.swift EchoTests/StudyQueueBuilderCardPhaseTests.swift
git commit -m "feat(study): fourth queue phase releases AI cards per chapter introduction + daily budget"
```

---

## Task 5: Release writes — `releaseCards` + loadQueue plumbing

**Files:**
- Modify: `Shared/Database/DAOs/StudyPlanDAO.swift` (new method after `markIntroduced`, ~L143)
- Modify: `EchoCore/ViewModels/StudySessionViewModel.swift` (`loadQueue`, ~L43–66)
- Modify: `EchoCore/Views/Stats/StatsView.swift` (`try vm.loadQueue(` call, ~L309–312)
- Modify: `EchoCore/Views/UpcomingReviewsModuleView.swift` (`StudyQueueBuilder(...).build(` call in `loadStats()`, ~L56–59)
- Modify: `EchoCore/Views/SettingsView.swift` (`StudyQueueBuilder(...).build(` call in `updateDailyReviewReminder()`, ~L313–315)
- Test: `EchoTests/StudySessionViewModelCardReleaseTests.swift`

**Interfaces:**
- Consumes: `StudyQueueCategory.newCard` / `build(globalNewCardLimit:)` (Task 4), `SettingsManager.studyNewCardsPerDayLimit` + `Defaults.studyNewCardsPerDayLimit` (Task 2), `StudyCardFixtures.seedAcceptedCard` (Task 4), `StudySessionViewModel(db:updateReviewNotification:)` (existing).
- Produces (used by Task 10's quiz — released cards are what the quiz queries):
  - `StudyPlanDAO.releaseCards(itemIDs: [String], now: Date = Date()) throws`
  - `StudySessionViewModel.loadQueue(now:calendar:modeOverride:globalNewChapterLimit:globalNewCardLimit:)`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudySessionViewModelCardReleaseTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudySessionViewModelCardReleaseTests {
    @Test func loadQueueReleasesQueuedCardsIdempotently() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-1", chapterIndex: 0, ordinal: 100, in: service)
        let vm = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })

        try vm.loadQueue(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let nowString = StudyQueueFixtures.mondayNoon.ISO8601Format()
        let card = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: "card-1") })
        #expect(card.nextReviewDate == nowString)
        let introducedAt = try service.read { db in
            try String.fetchOne(
                db, sql: "SELECT introduced_at FROM study_plan_item WHERE id = 'item-card-1'")
        }
        #expect(introducedAt == nowString)

        // A later rebuild must not re-stamp the release: the card is now a
        // plain due review owned by FSRS.
        try vm.loadQueue(
            now: StudyQueueFixtures.mondayNoon.addingTimeInterval(60),
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )
        let after = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: "card-1") })
        #expect(after.nextReviewDate == nowString)
    }

    @Test func releaseCardsIsScopedToTheGivenItems() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-a", chapterIndex: 0, ordinal: 100, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-b", chapterIndex: 0, ordinal: 101, in: service)

        try StudyPlanDAO(db: service.writer).releaseCards(
            itemIDs: ["item-card-a"], now: StudyQueueFixtures.mondayNoon)

        let a = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: "card-a") })
        let b = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: "card-b") })
        #expect(a.nextReviewDate == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(b.nextReviewDate == nil)
    }

    @Test func releaseCardsNeverRewritesAnAlreadyScheduledCard() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        // Released an hour ago: introduced + due stamps already set.
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-a", chapterIndex: 0, ordinal: 100, released: true, in: service)
        let releasedStamp = StudyQueueFixtures.mondayNoon
            .addingTimeInterval(-3_600).ISO8601Format()

        try StudyPlanDAO(db: service.writer).releaseCards(
            itemIDs: ["item-card-a"], now: StudyQueueFixtures.mondayNoon)

        let a = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: "card-a") })
        #expect(a.nextReviewDate == releasedStamp)
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'releaseCards'` / `extra argument 'globalNewCardLimit' in call`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] In `Shared/Database/DAOs/StudyPlanDAO.swift`, after `markIntroduced(itemIDs:now:)` (~L143), add:

```swift
    /// Releases queued AI cards (AI-cards design §4): stamps the plan items
    /// introduced and seeds each card's first due date, after which normal
    /// FSRS scheduling owns it. Idempotent — already-introduced items and
    /// already-scheduled cards are left untouched. Chapter assignments go
    /// through `markIntroduced` instead; their cards are never date-seeded.
    func releaseCards(itemIDs: [String], now: Date = Date()) throws {
        guard !itemIDs.isEmpty else { return }

        let nowString = now.ISO8601Format()
        let placeholders = databaseQuestionMarks(count: itemIDs.count)
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE flashcard
                    SET next_review_date = ?, modified_at = ?
                    WHERE next_review_date IS NULL
                      AND id IN (
                        SELECT flashcard_id FROM study_plan_item
                        WHERE id IN (\(placeholders))
                          AND flashcard_id IS NOT NULL
                          AND introduced_at IS NULL
                      )
                    """,
                arguments: StatementArguments([nowString, nowString] + itemIDs)
            )
            _ = try StudyPlanItem
                .filter(itemIDs.contains(Column("id")))
                .filter(Column("introduced_at") == nil)
                .updateAll(db, [
                    Column("introduced_at").set(to: nowString),
                    Column("modified_at").set(to: nowString),
                ])
        }
    }
```

- [ ] In `EchoCore/ViewModels/StudySessionViewModel.swift`, replace `loadQueue` (~L43–66) with:

```swift
    func loadQueue(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil,
        globalNewChapterLimit: Int? = nil,
        globalNewCardLimit: Int? = nil
    ) throws {
        let builder = StudyQueueBuilder(db: db)
        queue = try builder.build(
            now: now,
            calendar: calendar,
            modeOverride: modeOverride,
            globalNewChapterLimit: globalNewChapterLimit,
            globalNewCardLimit: globalNewCardLimit
        )
        currentIndex = 0
        isRevealed = false
        errorMessage = nil

        let newItemIDs = queue.entries
            .filter { $0.category == .newAssignment }
            .compactMap { $0.item?.id }
        try StudyPlanDAO(db: db).markIntroduced(itemIDs: newItemIDs, now: now)

        // Fourth phase (AI-cards design §4): surfacing a .newCard entry IS its
        // release — stamp introduction and seed the first due date now.
        let newCardItemIDs = queue.entries
            .filter { $0.category == .newCard }
            .compactMap { $0.item?.id }
        try StudyPlanDAO(db: db).releaseCards(itemIDs: newCardItemIDs, now: now)

        updateReviewNotification(remainingReviewNotificationCount())
        NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
    }
```

- [ ] In `EchoCore/Views/Stats/StatsView.swift`, replace the `try vm.loadQueue(` call (~L309–312) with:

```swift
            try vm.loadQueue(
                globalNewChapterLimit: model.settingsManager?.studyGlobalNewChapterLimit
                    ?? SettingsManager.Defaults.studyGlobalNewChapterLimit,
                globalNewCardLimit: model.settingsManager?.studyNewCardsPerDayLimit
                    ?? SettingsManager.Defaults.studyNewCardsPerDayLimit
            )
```

- [ ] In `EchoCore/Views/UpcomingReviewsModuleView.swift`, in `loadStats()`, replace the `build(` call (~L56–59) with:

```swift
            let queue = try StudyQueueBuilder(db: db.writer).build(
                globalNewChapterLimit: model.settingsManager?.studyGlobalNewChapterLimit
                    ?? SettingsManager.Defaults.studyGlobalNewChapterLimit,
                globalNewCardLimit: model.settingsManager?.studyNewCardsPerDayLimit
                    ?? SettingsManager.Defaults.studyNewCardsPerDayLimit
            )
```

- [ ] In `EchoCore/Views/SettingsView.swift`, in `updateDailyReviewReminder()`, replace the `build(` call (~L313–315) with:

```swift
            let queue = try StudyQueueBuilder(db: db.writer).build(
                globalNewChapterLimit: settings.studyGlobalNewChapterLimit,
                globalNewCardLimit: settings.studyNewCardsPerDayLimit
            )
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudySessionViewModelCardReleaseTests
make test-only FILTER=EchoTests/StudySessionViewModelTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Database/DAOs/StudyPlanDAO.swift EchoCore/ViewModels/StudySessionViewModel.swift \
    EchoCore/Views/Stats/StatsView.swift EchoCore/Views/UpcomingReviewsModuleView.swift \
    EchoCore/Views/SettingsView.swift EchoTests/StudySessionViewModelCardReleaseTests.swift
git commit -m "feat(study): release queued AI cards on queue load (introduce + seed due date)"
```

---

## Task 6: Plan-aware acceptance — deferred seeding, card items, bulk retire prompts

**Files:**
- Modify: `Shared/Services/StudyDeckAcceptanceService.swift` (whole `accept` + new types + `makeFlashcards`/`flashcard` signature)
- Modify: `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` (one line in `accept()`, ~L130)
- Modify: `EchoTests/StudyDeckAcceptanceServiceTests.swift` (mechanical `.acceptedCards` on 8 call results)
- Test: `EchoTests/StudyDeckAcceptancePlanTests.swift`

**Interfaces:**
- Consumes: `StudyPlanItemKind.card` / `StudyPlan.newCardsPerDay` (Task 1); slice-1 symbols: `StudyChapterRetireService` (`promptForNewUserCard(audiobookID:mediaTimestamp:now:) throws -> RetirePrompt?`, `RetirePrompt { assignmentCardID, assignmentItemID, chapterTitle; id }`), whose once-per-chapter stamp (`StudyCardMedia.retirePromptShownAt`) makes repeated accepts quiet.
- Produces (used by Tasks 7, 8):
  - `struct StudyDeckRetirePrompt: Identifiable, Equatable, Sendable { let prompt: StudyChapterRetireService.RetirePrompt; let acceptedCardCount: Int; var id: String }`
  - `struct StudyDeckAcceptanceOutcome: Sendable { let acceptedCards: [Flashcard]; let planID: String?; let retirePrompts: [StudyDeckRetirePrompt] }`
  - `StudyDeckAcceptanceService.accept(_:audiobookID:bookTitle:selectedCardIDs:now:) throws -> StudyDeckAcceptanceOutcome` (return type CHANGED from `[Flashcard]`)

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeckAcceptancePlanTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckAcceptancePlanTests {
    @Test func planBookDefersSchedulingAndLinksCardsToChapters() throws {
        let service = try seededService()
        let plan = try createPlan(in: service)

        let outcome = try StudyDeckAcceptanceService(db: service.writer).accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-1", "draft-3"],
            now: fixedNow
        )

        #expect(outcome.planID == plan.id)
        #expect(outcome.acceptedCards.count == 2)
        #expect(outcome.acceptedCards.allSatisfy { $0.nextReviewDate == nil })

        let items = try service.read { db in
            try StudyPlanItem
                .filter(Column("kind") == StudyPlanItemKind.card.rawValue)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
        #expect(items.count == 2)
        // The plan's two chapter items took ordinals 0 and 1; cards continue.
        #expect(items.map(\.ordinal) == [2, 3])
        #expect(items.map(\.chapterIndex) == [0, 1])
        #expect(items.allSatisfy { $0.introducedAt == nil })
        #expect(items.allSatisfy { $0.planID == plan.id })
        let linkedCardIDs = Set(items.compactMap(\.flashcardID))
        #expect(linkedCardIDs == Set(outcome.acceptedCards.map(\.id)))
    }

    @Test func planlessBookKeepsDueNowSeeding() throws {
        let service = try seededService()

        let outcome = try StudyDeckAcceptanceService(db: service.writer).accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-1"],
            now: fixedNow
        )

        #expect(outcome.planID == nil)
        #expect(outcome.retirePrompts.isEmpty)
        #expect(outcome.acceptedCards.first?.nextReviewDate == fixedNow.ISO8601Format())
        let itemCount = try service.read { db in
            try StudyPlanItem.fetchCount(db)
        }
        #expect(itemCount == 0)
    }

    @Test func retirePromptsFireOncePerChapterWithBulkCounts() throws {
        let service = try seededService()
        _ = try createPlan(in: service)
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        // draft-1 + draft-2 land in chapter 0; draft-3 in chapter 1.
        let outcome = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-1", "draft-2", "draft-3"],
            now: fixedNow
        )

        #expect(outcome.retirePrompts.count == 2)
        let byTitle = Dictionary(
            uniqueKeysWithValues: outcome.retirePrompts.map { ($0.prompt.chapterTitle, $0) })
        #expect(byTitle["Chapter One"]?.acceptedCardCount == 2)
        #expect(byTitle["Chapter Two"]?.acceptedCardCount == 1)

        // A later accept into an already-prompted chapter stays quiet:
        // slice 1's shown-stamp makes the prompt once-per-chapter.
        let extraDraft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "extra-1", sourceBlockID: "block-2",
                    frontText: "Extra front", backText: "Extra back",
                    tags: ["generated"])
            ],
            validSourceBlockIDs: ["block-2"]
        )
        let second = try acceptance.accept(
            extraDraft,
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["extra-1"],
            now: fixedNow.addingTimeInterval(60)
        )
        #expect(second.retirePrompts.isEmpty)
    }

    @Test func clozeExpansionCountsEveryInsertedCard() throws {
        let service = try seededService()
        _ = try createPlan(in: service)

        let clozeDraft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-1",
                    sourceBlockID: "block-1",
                    frontText: "The heart pumps blood.",
                    backText: "The heart pumps blood.",
                    tags: ["generated", "cloze"],
                    kind: .cloze,
                    clozeText: "The {{c1::heart}} pumps {{c2::blood}}."
                )
            ],
            validSourceBlockIDs: ["block-1"]
        )

        let outcome = try StudyDeckAcceptanceService(db: service.writer).accept(
            clozeDraft,
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["cloze-1"],
            now: fixedNow
        )

        // Two deletions → two flashcards, two card plan items, one prompt
        // counting both.
        #expect(outcome.acceptedCards.count == 2)
        let itemCount = try service.read { db in
            try StudyPlanItem
                .filter(Column("kind") == StudyPlanItemKind.card.rawValue)
                .fetchCount(db)
        }
        #expect(itemCount == 2)
        #expect(outcome.retirePrompts.count == 1)
        #expect(outcome.retirePrompts.first?.acceptedCardCount == 2)
    }

    // MARK: - Fixtures

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_750_100_000)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Synthetic Study Book', 3600, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter,
                        created_at
                    ) VALUES
                    ('block-1', 'book', 'ch1.xhtml', 0, 0, 0, 'paragraph', 'Synthetic idea 1.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-2', 'book', 'ch1.xhtml', 0, 1, 1, 'paragraph', 'Synthetic idea 2.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-3', 'book', 'ch2.xhtml', 1, 0, 2, 'paragraph', 'Synthetic idea 3.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-4', 'book', 'ch2.xhtml', 1, 1, 3, 'paragraph', 'Synthetic idea 4.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time,
                        audio_end_time, granularity_level, playlist_position, is_enabled,
                        source_table, source_rowid, epub_block_id
                    ) VALUES
                    ('epub-block-1', 'book', 'textSegment', 'Block 1', 12.5, 18.75, 1, 4.25, 1, 'epub_block', 'block-1', 'block-1'),
                    ('epub-block-2', 'book', 'textSegment', 'Block 2', 28.0, NULL, 1, NULL, 1, 'epub_block', 'block-2', 'block-2'),
                    ('epub-block-3', 'book', 'textSegment', 'Block 3', 42.0, 47.0, 1, 10.0, 1, 'epub_block', 'block-3', 'block-3')
                    """
            )
        }
        return service
    }

    /// Chapter assignments whose audio ranges cover the timeline rows above:
    /// chapter 0 = 0..<40 (blocks at 12.5 and 28.0), chapter 1 = 40..<90
    /// (block at 42.0) — so slice 1's retire lookup finds them by timestamp.
    private func createPlan(in service: DatabaseService) throws -> StudyPlan {
        try StudyPlanDAO(db: service.writer).createPlan(
            StudyPlanCreationRequest(
                audiobookID: "book",
                bookTitle: "Synthetic Study Book",
                cadenceUnit: .day,
                newChapterLimit: 1,
                includeImages: false,
                queueMode: .bookByBook,
                catchUpPolicy: .gentle,
                startDate: fixedNow,
                candidates: [
                    StudyPlanCandidate(
                        id: "cand-0", kind: .chapter, sourceBlockID: "block-1",
                        chapterIndex: 0, ordinal: 0, title: "Chapter One",
                        defaultIncluded: true, imagePath: nil,
                        mediaTimestamp: 0, endTimestamp: 40, playlistPosition: nil),
                    StudyPlanCandidate(
                        id: "cand-1", kind: .chapter, sourceBlockID: "block-3",
                        chapterIndex: 1, ordinal: 1, title: "Chapter Two",
                        defaultIncluded: true, imagePath: nil,
                        mediaTimestamp: 40, endTimestamp: 90, playlistPosition: nil),
                ],
                now: fixedNow
            )
        ).plan
    }

    private func draft() -> GeneratedStudyDeckDraft {
        GeneratedStudyDeckDraft(
            cards: [
                cardDraft(id: "draft-1", sourceBlockID: "block-1"),
                cardDraft(id: "draft-2", sourceBlockID: "block-2"),
                cardDraft(id: "draft-3", sourceBlockID: "block-3"),
                cardDraft(id: "draft-4", sourceBlockID: "block-4"),
            ],
            validSourceBlockIDs: ["block-1", "block-2", "block-3", "block-4"]
        )
    }

    private func cardDraft(id: String, sourceBlockID: String) -> GeneratedStudyDeckCardDraft {
        GeneratedStudyDeckCardDraft(
            id: id,
            sourceBlockID: sourceBlockID,
            frontText: "Front \(sourceBlockID.suffix(1))",
            backText: "Back \(sourceBlockID.suffix(1))",
            tags: ["generated", "plan"]
        )
    }
}
```

- [ ] Run it (expect compile failure: `value of type '[Flashcard]' has no member 'planID'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] In `Shared/Services/StudyDeckAcceptanceService.swift`:

**(a)** After the imports (before `struct StudyDeckAcceptanceService`), add the outcome types:

```swift
/// One "N cards now cover this chapter — retire its re-listen card?"
/// follow-up (AI-cards design §5): slice 1's once-per-chapter prompt plus how
/// many cards this acceptance just landed in that chapter, so the UI can
/// phrase it for bulk.
struct StudyDeckRetirePrompt: Identifiable, Equatable, Sendable {
    let prompt: StudyChapterRetireService.RetirePrompt
    let acceptedCardCount: Int

    var id: String { prompt.id }
}

/// What `accept` did: the inserted cards, the plan they joined (nil = the
/// book has no plan, so cards seeded due-now), and retire follow-ups to show.
struct StudyDeckAcceptanceOutcome: Sendable {
    let acceptedCards: [Flashcard]
    let planID: String?
    let retirePrompts: [StudyDeckRetirePrompt]
}
```

**(b)** Replace the whole `accept` function (~L10–53) with:

```swift
    func accept(
        _ draft: GeneratedStudyDeckDraft,
        audiobookID: String,
        bookTitle: String,
        selectedCardIDs: Set<String>,
        now: Date = Date()
    ) throws -> StudyDeckAcceptanceOutcome {
        let selectedCards = draft.cards.filter { selectedCardIDs.contains($0.id) }
        guard !selectedCards.isEmpty else {
            return StudyDeckAcceptanceOutcome(acceptedCards: [], planID: nil, retirePrompts: [])
        }

        let deckName = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deckName.isEmpty else { throw DeckDAOError.emptyName }

        let nowString = now.ISO8601Format()
        let inserted: InsertionResult = try db.write { db in
            let deckID = try Self.findOrCreateDeck(
                named: deckName,
                nowString: nowString,
                db: db
            )
            // Plan books get deferred seeding + card plan items (design §3).
            // Latest plan wins, matching StudyPlanDAO.latestPlan.
            let plan = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("created_at").desc)
                .fetchOne(db)
            var nextOrdinal = try Self.nextPlanOrdinal(planID: plan?.id, db: db)

            var acceptedCards: [Flashcard] = []
            var chapterAcceptances: [Int: ChapterAcceptance] = [:]

            for draftCard in selectedCards {
                let timelineMapping = try Self.timelineMapping(
                    audiobookID: audiobookID,
                    sourceBlockID: draftCard.sourceBlockID,
                    db: db
                )
                let chapterIndex = try Self.chapterIndex(
                    sourceBlockID: draftCard.sourceBlockID, db: db)
                let cards = Self.makeFlashcards(
                    draftCard: draftCard,
                    audiobookID: audiobookID,
                    deckID: deckID,
                    timelineMapping: timelineMapping,
                    nowString: nowString,
                    deferScheduling: plan != nil
                )
                for card in cards {
                    try FlashcardDAO.insert(card, in: db)
                    acceptedCards.append(card)

                    guard let plan else { continue }
                    var item = StudyPlanItem(
                        id: UUID().uuidString,
                        planID: plan.id,
                        flashcardID: card.id,
                        kind: StudyPlanItemKind.card.rawValue,
                        chapterIndex: chapterIndex,
                        sourceBlockID: draftCard.sourceBlockID,
                        ordinal: nextOrdinal,
                        introducedAt: nil,
                        isEnabled: true,
                        createdAt: nowString,
                        modifiedAt: nowString
                    )
                    try item.insert(db)
                    nextOrdinal += 1

                    if let chapterIndex {
                        chapterAcceptances[
                            chapterIndex,
                            default: ChapterAcceptance(
                                chapterIndex: chapterIndex,
                                mediaTimestamp: card.mediaTimestamp,
                                cardCount: 0
                            )
                        ].cardCount += 1
                    }
                }
            }

            return InsertionResult(
                acceptedCards: acceptedCards,
                planID: plan?.id,
                chapters: chapterAcceptances.values.sorted { $0.chapterIndex < $1.chapterIndex }
            )
        }

        // Retire follow-ups run OUTSIDE the insert transaction: the retire
        // service owns its own reads/writes, and slice 1's shown-stamp keeps
        // this once-per-chapter across repeated accepts.
        var retirePrompts: [StudyDeckRetirePrompt] = []
        if inserted.planID != nil {
            let retire = StudyChapterRetireService(db: db)
            for chapter in inserted.chapters {
                if let prompt = try retire.promptForNewUserCard(
                    audiobookID: audiobookID,
                    mediaTimestamp: chapter.mediaTimestamp,
                    now: now
                ) {
                    retirePrompts.append(
                        StudyDeckRetirePrompt(
                            prompt: prompt, acceptedCardCount: chapter.cardCount))
                }
            }
        }

        return StudyDeckAcceptanceOutcome(
            acceptedCards: inserted.acceptedCards,
            planID: inserted.planID,
            retirePrompts: retirePrompts
        )
    }

    /// Everything the write transaction produced, handed to the post-commit
    /// retire pass.
    private struct InsertionResult {
        let acceptedCards: [Flashcard]
        let planID: String?
        let chapters: [ChapterAcceptance]
    }

    private struct ChapterAcceptance {
        let chapterIndex: Int
        let mediaTimestamp: TimeInterval
        var cardCount: Int
    }

    /// The containing chapter for a source block — the same derivation the
    /// plan generator uses (`epub_block.chapter_index`).
    private static func chapterIndex(sourceBlockID: String, db: Database) throws -> Int? {
        try Int.fetchOne(
            db,
            sql: "SELECT chapter_index FROM epub_block WHERE id = ?",
            arguments: [sourceBlockID]
        )
    }

    /// Card plan items continue the plan's existing ordinal sequence.
    private static func nextPlanOrdinal(planID: String?, db: Database) throws -> Int {
        guard let planID else { return 0 }
        let maxOrdinal = try Int.fetchOne(
            db,
            sql: "SELECT MAX(ordinal) FROM study_plan_item WHERE plan_id = ?",
            arguments: [planID]
        )
        return (maxOrdinal ?? -1) + 1
    }
```

**(c)** Thread `deferScheduling` through the card makers. In `makeFlashcards` (~L127), add the parameter and pass it down — the signature becomes:

```swift
    private static func makeFlashcards(
        draftCard: GeneratedStudyDeckCardDraft,
        audiobookID: String,
        deckID: String,
        timelineMapping: TimelineMapping,
        nowString: String,
        deferScheduling: Bool
    ) -> [Flashcard] {
```

and both `Self.flashcard(` calls inside it gain `deferScheduling: deferScheduling,` immediately after `nowString: nowString,`. Then in the private `flashcard(` builder (~L174), add `deferScheduling: Bool` after `nowString: String` and change the seeding line:

```swift
            nextReviewDate: deferScheduling ? nil : nowString,
```

(Plan books release later via `StudyPlanDAO.releaseCards`; plan-less books keep today's due-now behavior — design §3.)

- [ ] In `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift`, the `accept()` call (~L130) no longer returns `[Flashcard]`. Append `.acceptedCards` to the call so the rest of the method compiles unchanged (Task 7 replaces this properly):

```swift
            let acceptedCards = try StudyDeckAcceptanceService(db: db).accept(
                draft,
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                selectedCardIDs: selectedCardIDs,
                now: now
            ).acceptedCards
```

- [ ] Mechanically update the 8 existing call sites in `EchoTests/StudyDeckAcceptanceServiceTests.swift` (every `accept(...)` there ends with a `now: fixedNow` or `now: fixedNow.addingTimeInterval(60)` argument):

```bash
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/pensive-fermi-dae756
perl -0pi -e 's/(now: fixedNow(?:\.addingTimeInterval\(60\))?\n        \))/$1.acceptedCards/g' EchoTests/StudyDeckAcceptanceServiceTests.swift
grep -c "\.acceptedCards" EchoTests/StudyDeckAcceptanceServiceTests.swift
```

Expected grep output: `8`. (These tests seed no plans, so their due-now expectations still hold.)

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyDeckAcceptancePlanTests
make test-only FILTER=EchoTests/StudyDeckAcceptanceServiceTests
make test-only FILTER=EchoTests/StudyDeckGenerationViewModelTests
```

- [ ] Verify SPDX still line 1 in all touched files, then commit:

```bash
git add Shared/Services/StudyDeckAcceptanceService.swift \
    EchoCore/ViewModels/StudyDeckGenerationViewModel.swift \
    EchoTests/StudyDeckAcceptanceServiceTests.swift EchoTests/StudyDeckAcceptancePlanTests.swift
git commit -m "feat(study): plan-aware AI-card acceptance (deferred seeding, card items, bulk retire prompts)"
```

---

## Task 7: Generation view model — chapter grouping, accept-all, post-accept flow

**Files:**
- Modify: `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` (FULL replacement below)
- Test: `EchoTests/StudyDeckGenerationChapterFlowTests.swift`

**Interfaces:**
- Consumes: `StudyDeckAcceptanceOutcome` / `StudyDeckRetirePrompt` (Task 6), `EPubBlockDAO.visibleBlocks(for:)` + `EPubBlockRecord.Kind` (existing), slice-1 `StudyChapterRetireService.retire(assignmentCardID:assignmentItemID:now:)`, `StudyPlanViewModel(audiobookID:bookTitle:db:)` (existing).
- Produces (used by Task 8):
  - `struct StudyDeckChapterGroup: Identifiable, Equatable { let chapterIndex: Int?; let title: String; let cards: [GeneratedStudyDeckCardDraft]; var id: String }`
  - `StudyDeckGenerationViewModel.chapterGroups: [StudyDeckChapterGroup]`, `isGroupFullySelected(_:) -> Bool`, `setGroup(_:selected:)`, `refreshChapterMaps() throws`
  - `enum PostAcceptStep: Equatable { case retirePrompt(StudyDeckRetirePrompt); case offerPlan }` (nested), `postAcceptStep: PostAcceptStep?`, `hasPostAcceptFollowUps: Bool`, `currentRetirePrompt: StudyDeckRetirePrompt?`, `isOfferingPlanCreation: Bool`, `planLinked: Bool`
  - `resolveRetirePrompt(retire:now:)`, `declinePlanOffer()`, `makeStudyPlanViewModel() -> StudyPlanViewModel`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyDeckGenerationChapterFlowTests.swift`. The private `StubGenerator` mirrors the one already living in `StudyDeckGenerationViewModelTests` (an existing, justified DI seam — not a new protocol):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckGenerationChapterFlowTests {
    private struct StubGenerator: StudyDeckGenerating {
        let cards: [GeneratedStudyDeckCardDraft]
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(
                cards: cards, validSourceBlockIDs: Set(cards.map(\.sourceBlockID)))
        }
    }

    @Test func chapterGroupsGroupCardsByChapterWithHeadingTitles() async throws {
        let service = try seededService()
        let vm = makeViewModel(
            service: service,
            cards: [
                cardDraft(id: "d1", sourceBlockID: "block-1"),
                cardDraft(id: "d2", sourceBlockID: "block-2"),
                cardDraft(id: "d3", sourceBlockID: "block-3"),
            ]
        )

        await vm.load()

        let groups = vm.chapterGroups
        #expect(groups.count == 2)
        #expect(groups.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(groups[0].cards.map(\.id) == ["d1", "d2"])
        #expect(groups[1].cards.map(\.id) == ["d3"])
    }

    @Test func acceptAllPerChapterTogglesOnlyThatChapter() async throws {
        let service = try seededService()
        let vm = makeViewModel(
            service: service,
            cards: [
                cardDraft(id: "d1", sourceBlockID: "block-1"),
                cardDraft(id: "d2", sourceBlockID: "block-2"),
                cardDraft(id: "d3", sourceBlockID: "block-3"),
            ]
        )
        await vm.load()
        let chapterOne = try #require(vm.chapterGroups.first)

        vm.setGroup(chapterOne, selected: false)
        #expect(vm.selectedCardIDs == ["d3"])
        #expect(vm.isGroupFullySelected(chapterOne) == false)

        vm.setGroup(chapterOne, selected: true)
        #expect(vm.selectedCardIDs == ["d1", "d2", "d3"])
        #expect(vm.isGroupFullySelected(chapterOne))
    }

    @Test func acceptOnPlanlessBookOffersPlanCreation() async throws {
        let service = try seededService()
        let vm = makeViewModel(
            service: service,
            cards: [cardDraft(id: "d1", sourceBlockID: "block-1")]
        )
        await vm.load()

        #expect(vm.accept(now: fixedNow))
        #expect(vm.planLinked == false)
        #expect(vm.isOfferingPlanCreation)
        #expect(vm.hasPostAcceptFollowUps)

        vm.declinePlanOffer()
        #expect(vm.postAcceptStep == nil)
        #expect(vm.hasPostAcceptFollowUps == false)
    }

    @Test func acceptOnPlanBookWalksRetirePromptsThenFinishes() async throws {
        let service = try seededService()
        try createPlan(in: service)
        let vm = makeViewModel(
            service: service,
            cards: [
                cardDraft(id: "d1", sourceBlockID: "block-1"),
                cardDraft(id: "d2", sourceBlockID: "block-2"),
                cardDraft(id: "d3", sourceBlockID: "block-3"),
            ]
        )
        await vm.load()

        #expect(vm.accept(now: fixedNow))
        #expect(vm.planLinked)

        let first = try #require(vm.currentRetirePrompt)
        #expect(first.prompt.chapterTitle == "Chapter One")
        #expect(first.acceptedCardCount == 2)

        vm.resolveRetirePrompt(retire: false, now: fixedNow)
        let second = try #require(vm.currentRetirePrompt)
        #expect(second.prompt.chapterTitle == "Chapter Two")

        vm.resolveRetirePrompt(retire: false, now: fixedNow)
        // Plan exists → no plan offer after the prompts.
        #expect(vm.postAcceptStep == nil)
    }

    @Test func resolvingWithRetireDisablesTheAssignment() async throws {
        let service = try seededService()
        try createPlan(in: service)
        let vm = makeViewModel(
            service: service,
            cards: [cardDraft(id: "d1", sourceBlockID: "block-1")]
        )
        await vm.load()
        #expect(vm.accept(now: fixedNow))
        #expect(vm.currentRetirePrompt != nil)

        vm.resolveRetirePrompt(retire: true, now: fixedNow)

        let enabled = try service.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT is_enabled FROM flashcard WHERE front_text = 'Chapter One'")
        }
        #expect(enabled == false)
    }

    // MARK: - Fixtures

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_750_100_000)
    }

    private func makeViewModel(
        service: DatabaseService,
        cards: [GeneratedStudyDeckCardDraft]
    ) -> StudyDeckGenerationViewModel {
        StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            generator: StubGenerator(cards: cards)
        )
    }

    private func cardDraft(id: String, sourceBlockID: String) -> GeneratedStudyDeckCardDraft {
        GeneratedStudyDeckCardDraft(
            id: id,
            sourceBlockID: sourceBlockID,
            frontText: "Front \(id)",
            backText: "Back \(id)",
            tags: ["generated"]
        )
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Synthetic Study Book', 3600, '2026-06-01T00:00:00Z')
                    """
            )
            // Heading blocks give the groups their titles.
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter,
                        created_at
                    ) VALUES
                    ('h-0', 'book', 'ch1.xhtml', 0, 0, 0, 'heading', 'Chapter One', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-1', 'book', 'ch1.xhtml', 0, 1, 1, 'paragraph', 'Synthetic idea 1.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-2', 'book', 'ch1.xhtml', 0, 2, 2, 'paragraph', 'Synthetic idea 2.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('h-1', 'book', 'ch2.xhtml', 1, 0, 3, 'heading', 'Chapter Two', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-3', 'book', 'ch2.xhtml', 1, 1, 4, 'paragraph', 'Synthetic idea 3.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time,
                        audio_end_time, granularity_level, playlist_position, is_enabled,
                        source_table, source_rowid, epub_block_id
                    ) VALUES
                    ('epub-block-1', 'book', 'textSegment', 'Block 1', 12.5, 18.75, 1, 4.25, 1, 'epub_block', 'block-1', 'block-1'),
                    ('epub-block-2', 'book', 'textSegment', 'Block 2', 28.0, NULL, 1, NULL, 1, 'epub_block', 'block-2', 'block-2'),
                    ('epub-block-3', 'book', 'textSegment', 'Block 3', 42.0, 47.0, 1, 10.0, 1, 'epub_block', 'block-3', 'block-3')
                    """
            )
        }
        return service
    }

    /// Chapter 0 assignment covers 0..<40, chapter 1 covers 40..<90 — matching
    /// the timeline rows so retire prompts resolve by timestamp.
    private func createPlan(in service: DatabaseService) throws {
        _ = try StudyPlanDAO(db: service.writer).createPlan(
            StudyPlanCreationRequest(
                audiobookID: "book",
                bookTitle: "Synthetic Study Book",
                cadenceUnit: .day,
                newChapterLimit: 1,
                includeImages: false,
                queueMode: .bookByBook,
                catchUpPolicy: .gentle,
                startDate: fixedNow,
                candidates: [
                    StudyPlanCandidate(
                        id: "cand-0", kind: .chapter, sourceBlockID: "block-1",
                        chapterIndex: 0, ordinal: 0, title: "Chapter One",
                        defaultIncluded: true, imagePath: nil,
                        mediaTimestamp: 0, endTimestamp: 40, playlistPosition: nil),
                    StudyPlanCandidate(
                        id: "cand-1", kind: .chapter, sourceBlockID: "block-3",
                        chapterIndex: 1, ordinal: 1, title: "Chapter Two",
                        defaultIncluded: true, imagePath: nil,
                        mediaTimestamp: 40, endTimestamp: 90, playlistPosition: nil),
                ],
                now: fixedNow
            )
        )
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'chapterGroups'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Replace `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift` in FULL with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// One chapter's slice of the generated draft, for the grouped review sheet
/// (AI-cards design §5): a section title plus the draft cards whose source
/// blocks live in that chapter.
struct StudyDeckChapterGroup: Identifiable, Equatable {
    let chapterIndex: Int?
    let title: String
    let cards: [GeneratedStudyDeckCardDraft]

    var id: String { chapterIndex.map(String.init) ?? "unassigned" }
}

@MainActor
@Observable
final class StudyDeckGenerationViewModel {
    /// The post-accept follow-up being presented: retire prompts first (one
    /// per affected chapter, design §5), then the create-a-plan offer for
    /// plan-less books.
    enum PostAcceptStep: Equatable {
        case retirePrompt(StudyDeckRetirePrompt)
        case offerPlan
    }

    var cards: [GeneratedStudyDeckCardDraft] = []
    var selectedCardIDs: Set<String> = []
    var isLoading = false
    var isAccepting = false
    var errorMessage: String?
    var acceptedCount = 0
    /// True when the accepted cards joined a study plan (deferred drip).
    private(set) var planLinked = false
    private(set) var postAcceptStep: PostAcceptStep?
    /// `(done, total)` batch progress while a generation run is in flight; `nil` otherwise.
    var progress: (done: Int, total: Int)?

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let generator: any StudyDeckGenerating
    @ObservationIgnored private let logger = Logger(category: "StudyDeckGenerationViewModel")
    @ObservationIgnored private var draft: GeneratedStudyDeckDraft?
    /// The in-flight load, owned here so `cancelLoad()` (e.g. the sheet's Cancel button) can cancel it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var chapterIndexByBlockID: [String: Int] = [:]
    @ObservationIgnored private var chapterTitleByIndex: [Int: String] = [:]
    @ObservationIgnored private var queuedRetirePrompts: [StudyDeckRetirePrompt] = []
    @ObservationIgnored private var planOfferPending = false

    var selectedCardCount: Int {
        selectedCardIDs.count
    }

    var canAccept: Bool {
        !isLoading && !isAccepting && !cards.isEmpty && !selectedCardIDs.isEmpty
    }

    var hasPostAcceptFollowUps: Bool {
        postAcceptStep != nil
    }

    var currentRetirePrompt: StudyDeckRetirePrompt? {
        if case .retirePrompt(let prompt) = postAcceptStep { return prompt }
        return nil
    }

    var isOfferingPlanCreation: Bool {
        postAcceptStep == .offerPlan
    }

    /// Draft cards grouped by containing chapter, in book order; cards whose
    /// block has no chapter mapping sort last under "Unassigned".
    var chapterGroups: [StudyDeckChapterGroup] {
        let grouped = Dictionary(grouping: cards) { chapterIndexByBlockID[$0.sourceBlockID] }
        return grouped
            .map { chapterIndex, groupCards in
                StudyDeckChapterGroup(
                    chapterIndex: chapterIndex,
                    title: chapterIndex.map { chapterTitleByIndex[$0] ?? "Chapter \($0 + 1)" }
                        ?? "Unassigned",
                    cards: groupCards
                )
            }
            .sorted { ($0.chapterIndex ?? Int.max) < ($1.chapterIndex ?? Int.max) }
    }

    var isShowingError: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    init(
        audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter,
        generator: any StudyDeckGenerating = FixtureStudyDeckGenerator()
    ) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
        self.generator = generator
    }

    /// Runs a cancellable generation. Owns the work in `loadTask` so `cancelLoad()` can stop it,
    /// while keeping the existing `.task { await viewModel.load() }` call site working (we await
    /// the stored task's value).
    func load() async {
        loadTask = Task { await self.runLoad() }
        await loadTask?.value
        loadTask = nil
    }

    /// Cancels an in-flight `load()` (e.g. the sheet's Cancel button).
    func cancelLoad() {
        loadTask?.cancel()
    }

    private func runLoad() async {
        isLoading = true
        defer {
            isLoading = false
            progress = nil
        }

        do {
            errorMessage = nil
            acceptedCount = 0
            progress = nil

            try refreshChapterMaps()
            let sources = try StudyDeckSourceBuilder(db: db).sources(
                audiobookID: audiobookID,
                selection: .wholeBook
            )
            let generatedDraft = await generator.generate(
                sources: sources,
                settings: StudyDeckGenerationSettings()
            )

            draft = generatedDraft
            cards = generatedDraft.cards
            selectedCardIDs = Set(generatedDraft.cards.map(\.id))
        } catch {
            draft = nil
            cards = []
            selectedCardIDs = []
            errorMessage = error.localizedDescription
            logger.error("Failed to generate study deck draft: \(error.localizedDescription)")
        }
    }

    /// Builds the sourceBlockID → chapter maps behind `chapterGroups` from the
    /// book's visible blocks (the first heading per chapter becomes the
    /// section title). Internal so tests can drive grouping without a
    /// generator run.
    func refreshChapterMaps() throws {
        let blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
        var indexByBlockID: [String: Int] = [:]
        var titleByIndex: [Int: String] = [:]
        for block in blocks {
            guard let chapterIndex = block.chapterIndex else { continue }
            indexByBlockID[block.id] = chapterIndex
            if titleByIndex[chapterIndex] == nil,
                EPubBlockRecord.Kind(rawValue: block.blockKind) == .heading,
                let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                titleByIndex[chapterIndex] = text
            }
        }
        chapterIndexByBlockID = indexByBlockID
        chapterTitleByIndex = titleByIndex
    }

    func toggleCard(_ card: GeneratedStudyDeckCardDraft) {
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    func isGroupFullySelected(_ group: StudyDeckChapterGroup) -> Bool {
        !group.cards.isEmpty && group.cards.allSatisfy { selectedCardIDs.contains($0.id) }
    }

    /// Accept-all / clear-all for one chapter section (design §5).
    func setGroup(_ group: StudyDeckChapterGroup, selected: Bool) {
        if selected {
            selectedCardIDs.formUnion(group.cards.map(\.id))
        } else {
            selectedCardIDs.subtract(group.cards.map(\.id))
        }
    }

    @discardableResult
    func accept(now: Date = Date()) -> Bool {
        acceptedCount = 0
        planLinked = false
        postAcceptStep = nil
        queuedRetirePrompts = []
        planOfferPending = false

        guard let draft else {
            errorMessage = "Generate a study deck draft before accepting cards."
            return false
        }
        guard !selectedCardIDs.isEmpty else {
            errorMessage = "Select at least one card to accept."
            return false
        }

        isAccepting = true
        defer { isAccepting = false }

        do {
            errorMessage = nil
            let outcome = try StudyDeckAcceptanceService(db: db).accept(
                draft,
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                selectedCardIDs: selectedCardIDs,
                now: now
            )
            guard !outcome.acceptedCards.isEmpty else {
                errorMessage = "No cards were accepted."
                return false
            }

            acceptedCount = outcome.acceptedCards.count
            planLinked = outcome.planID != nil
            queuedRetirePrompts = outcome.retirePrompts
            planOfferPending = outcome.planID == nil
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID]
            )
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
            advancePostAcceptStep()
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to accept generated study deck: \(error.localizedDescription)")
            return false
        }
    }

    /// Resolves the retire follow-up currently showing. `retire` disables the
    /// chapter's re-listen assignment (reversible from plan management).
    func resolveRetirePrompt(retire: Bool, now: Date = Date()) {
        guard case .retirePrompt(let item) = postAcceptStep else { return }
        if retire {
            do {
                try StudyChapterRetireService(db: db).retire(
                    assignmentCardID: item.prompt.assignmentCardID,
                    assignmentItemID: item.prompt.assignmentItemID,
                    now: now
                )
                NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to retire assignment: \(error.localizedDescription)")
            }
        }
        advancePostAcceptStep()
    }

    func declinePlanOffer() {
        guard case .offerPlan = postAcceptStep else { return }
        postAcceptStep = nil
    }

    /// The plan sheet shown when the user takes the create-a-plan offer (§5).
    func makeStudyPlanViewModel() -> StudyPlanViewModel {
        StudyPlanViewModel(audiobookID: audiobookID, bookTitle: bookTitle, db: db)
    }

    private func advancePostAcceptStep() {
        if !queuedRetirePrompts.isEmpty {
            postAcceptStep = .retirePrompt(queuedRetirePrompts.removeFirst())
        } else if planOfferPending {
            planOfferPending = false
            postAcceptStep = .offerPlan
        } else {
            postAcceptStep = nil
        }
    }
}
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyDeckGenerationChapterFlowTests
make test-only FILTER=EchoTests/StudyDeckGenerationViewModelTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/ViewModels/StudyDeckGenerationViewModel.swift \
    EchoTests/StudyDeckGenerationChapterFlowTests.swift
git commit -m "feat(study): chapter-grouped draft state + post-accept retire/plan-offer flow"
```

---

## Task 8: Generation sheet UI — grouped sections, accept-all, inline follow-ups

**Files:**
- Modify: `EchoCore/Views/StudyDeckGenerationSheet.swift` (FULL replacement below)

**Interfaces:**
- Consumes: `StudyDeckChapterGroup` / view-model API (Task 7), `SettingsManager.studyNewCardsPerDayLimit` (Task 2), `StudyPlanSheet` / `StudyPlanViewModel` (existing, compiled in all three targets).
- Produces: nothing new for later tasks (Task 12 presents this same sheet on macOS).

**UI-only task: no unit-test cycle (UI tests are excluded from the Echo scheme). Verification is `make build-tests` compiling the file plus Task 13's builds + manual checklist. Note the follow-ups render as inline Form sections, NOT `.alert` chains — sequential alerts driven off one boolean re-present unreliably in SwiftUI, and the design's "sheet flows into follow-ups" reads better inline anyway.**

**Steps:**

- [ ] Replace `EchoCore/Views/StudyDeckGenerationSheet.swift` in FULL with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudyDeckGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settings
    @Bindable var viewModel: StudyDeckGenerationViewModel
    @State private var showingPlanSheet = false

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading {
                    Section {
                        if let progress = viewModel.progress {
                            ProgressView(
                                "Generating cards… (\(progress.done) of \(progress.total))",
                                value: Double(progress.done),
                                total: Double(progress.total)
                            )
                        } else {
                            ProgressView("Generating Study Deck")
                        }
                    }
                } else if viewModel.cards.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Eligible Blocks",
                            systemImage: "rectangle.stack.badge.questionmark",
                            description: Text(
                                "This book does not have visible EPUB text blocks for a study deck."
                            )
                        )
                    }
                } else {
                    StudyDeckChapterGroupsSection(viewModel: viewModel)
                }

                if viewModel.acceptedCount > 0 {
                    acceptedSummarySection
                }
                followUpSection
            }
            .navigationTitle("Generate Study Deck")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelLoad()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isAccepting ? "Accepting" : "Accept") {
                        // Stay open while follow-ups (retire prompts, plan
                        // offer) still need answers; they dismiss when done.
                        if viewModel.accept(), !viewModel.hasPostAcceptFollowUps {
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canAccept)
                }
            }
            .alert("Study Deck Error", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $showingPlanSheet, onDismiss: { dismiss() }) {
                StudyPlanSheet(viewModel: viewModel.makeStudyPlanViewModel())
            }
            .onDisappear {
                viewModel.cancelLoad()
            }
            .task {
                await viewModel.load()
            }
        }
    }

    private var acceptedSummarySection: some View {
        Section {
            Label(
                "\(viewModel.acceptedCount) cards accepted",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            if viewModel.planLinked {
                Text(
                    "These cards join the study plan: released with each chapter, up to \(settings.studyNewCardsPerDayLimit) new cards a day."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Post-accept follow-ups (design §5): one retire prompt per affected
    /// chapter, phrased for bulk, then the create-a-plan offer on plan-less
    /// books. Inline sections rather than alert chains — see task note.
    @ViewBuilder
    private var followUpSection: some View {
        if let item = viewModel.currentRetirePrompt {
            Section("Retire this chapter's re-listen card?") {
                Text(
                    "\(item.acceptedCardCount) new cards now cover “\(item.prompt.chapterTitle)”. Review with those cards instead of re-listening? You can re-enable the re-listen card any time from the study plan."
                )
                .font(.footnote)
                Button("Retire Re-listen Card", role: .destructive) {
                    viewModel.resolveRetirePrompt(retire: true)
                    dismissIfFollowUpsDone()
                }
                Button("Keep Both") {
                    viewModel.resolveRetirePrompt(retire: false)
                    dismissIfFollowUpsDone()
                }
            }
        } else if viewModel.isOfferingPlanCreation {
            Section("Add a study plan?") {
                Text(
                    "Without a plan, all \(viewModel.acceptedCount) cards are due today. A study plan releases them chapter by chapter, up to \(settings.studyNewCardsPerDayLimit) new cards a day."
                )
                .font(.footnote)
                Button("Create Study Plan") {
                    viewModel.declinePlanOffer()
                    showingPlanSheet = true
                }
                Button("Not Now") {
                    viewModel.declinePlanOffer()
                    dismiss()
                }
            }
        }
    }

    private func dismissIfFollowUpsDone() {
        if !viewModel.hasPostAcceptFollowUps {
            dismiss()
        }
    }
}

private struct StudyDeckChapterGroupsSection: View {
    @Bindable var viewModel: StudyDeckGenerationViewModel

    var body: some View {
        ForEach(viewModel.chapterGroups) { group in
            Section {
                ForEach(group.cards) { card in
                    StudyDeckDraftCardRow(card: card, viewModel: viewModel)
                }
            } header: {
                HStack {
                    Text(group.title)
                    Spacer()
                    Button(
                        viewModel.isGroupFullySelected(group) ? "Clear All" : "Accept All"
                    ) {
                        viewModel.setGroup(
                            group, selected: !viewModel.isGroupFullySelected(group))
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }

        Section {
        } footer: {
            Text("\(viewModel.selectedCardCount) of \(viewModel.cards.count) selected")
        }
    }
}

private struct StudyDeckDraftCardRow: View {
    let card: GeneratedStudyDeckCardDraft
    @Bindable var viewModel: StudyDeckGenerationViewModel

    var body: some View {
        let isSelected = viewModel.selectedCardIDs.contains(card.id)

        Button {
            viewModel.toggleCard(card)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading) {
                    Text(card.frontText)
                        .foregroundStyle(.primary)
                    Text(card.backText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(card.sourceBlockID, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isSelected ? "Included" : "Excluded"))
    }
}
```

- [ ] Build-verify (expect clean build):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Views/StudyDeckGenerationSheet.swift
git commit -m "feat(study): chapter-grouped draft sheet with accept-all and post-accept follow-ups"
```

---

## Task 9: `StudyPlanDAO.dueQuizCards` — checkpoint-quiz card lookup

**Files:**
- Modify: `Shared/Database/DAOs/StudyPlanDAO.swift` (after `releaseCards`, added in Task 5)
- Test: `EchoTests/StudyPlanDAOQuizCardsTests.swift`

**Interfaces:**
- Consumes: `StudyCardFixtures.seedAcceptedCard` (Task 4), `StudyQueueFixtures.serviceWithPlan()` (existing), `Flashcard` snake_case CodingKeys (existing — raw-SQL fetch maps `front_text` → `frontText`).
- Produces (used by Task 10):
  - `StudyPlanDAO.dueQuizCards(audiobookID: String, chapterIndex: Int, now: Date = Date(), limit: Int = 5) throws -> [Flashcard]`

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyPlanDAOQuizCardsTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlanDAOQuizCardsTests {
    @Test func returnsDueReleasedChapterCardsInOrdinalOrderCapped() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for i in 0..<6 {
            try StudyCardFixtures.seedAcceptedCard(
                id: "quiz-\(i)", chapterIndex: 0, ordinal: 100 + i, released: true, in: service)
        }
        let dao = StudyPlanDAO(db: service.writer)

        let cards = try dao.dueQuizCards(
            audiobookID: "book-a", chapterIndex: 0,
            now: StudyQueueFixtures.mondayNoon, limit: 5)

        #expect(cards.count == 5)
        #expect(cards.map(\.id) == ["quiz-0", "quiz-1", "quiz-2", "quiz-3", "quiz-4"])
    }

    @Test func excludesUnreleasedOtherChapterAndFutureDueCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "eligible", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "unreleased", chapterIndex: 0, ordinal: 101, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "other-chapter", chapterIndex: 1, ordinal: 102, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "future-due", chapterIndex: 0, ordinal: 103, released: true,
            releasedAt: StudyQueueFixtures.mondayNoon.addingTimeInterval(86_400), in: service)

        let cards = try StudyPlanDAO(db: service.writer).dueQuizCards(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(cards.map(\.id) == ["eligible"])
    }

    @Test func pausedPlanYieldsNoQuizCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "quiz-0", chapterIndex: 0, ordinal: 100, released: true, in: service)
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let cards = try dao.dueQuizCards(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(cards.isEmpty)
    }

    @Test func disabledItemIsExcluded() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "quiz-0", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyPlanDAO(db: service.writer).setItemEnabled(
            itemID: "item-quiz-0", isEnabled: false, now: StudyQueueFixtures.mondayNoon)

        let cards = try StudyPlanDAO(db: service.writer).dueQuizCards(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(cards.isEmpty)
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'dueQuizCards'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] In `Shared/Database/DAOs/StudyPlanDAO.swift`, after `releaseCards(itemIDs:now:)`, add:

```swift
    /// The checkpoint quiz's card source (AI-cards design §6): released
    /// (`introduced_at` set), currently due, enabled AI cards of the finished
    /// chapter, in plan order, capped by the caller (quiz cap = 5). Paused
    /// plans quiz nothing.
    func dueQuizCards(
        audiobookID: String,
        chapterIndex: Int,
        now: Date = Date(),
        limit: Int = 5
    ) throws -> [Flashcard] {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            try Flashcard.fetchAll(
                db,
                sql: """
                    SELECT f.* FROM flashcard f
                    JOIN study_plan_item i ON i.flashcard_id = f.id
                    JOIN study_plan p ON p.id = i.plan_id
                    WHERE p.audiobook_id = ?
                      AND p.is_paused = 0
                      AND i.kind = 'card'
                      AND i.chapter_index = ?
                      AND i.is_enabled = 1
                      AND i.introduced_at IS NOT NULL
                      AND f.is_enabled = 1
                      AND f.next_review_date IS NOT NULL
                      AND f.next_review_date <= ?
                    ORDER BY i.ordinal
                    LIMIT ?
                    """,
                arguments: [audiobookID, chapterIndex, nowString, limit]
            )
        }
    }
```

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyPlanDAOQuizCardsTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add Shared/Database/DAOs/StudyPlanDAO.swift EchoTests/StudyPlanDAOQuizCardsTests.swift
git commit -m "feat(study): due-quiz-card lookup for the chapter checkpoint quiz"
```

---

## Task 10: Checkpoint quiz state machine (coordinator extension)

**Files:**
- Modify: `EchoCore/Services/StudyCheckpointCoordinator.swift` (slice-1 file; anchors below quote slice 1's code verbatim — Read the file first)
- Test: `EchoTests/StudyCheckpointQuizTests.swift`

**Interfaces:**
- Consumes: slice-1 `StudyCheckpointCoordinator` internals (`State`, `Context`, `resolve(_:now:)`, `finish(context:replay:)`, `grade(_:context:auto:now:)`, `settingsProvider`, `announce`, `logger`, `database`), `StudyPlanDAO.dueQuizCards` (Task 9), `FlashcardDAO.grade(cardID:grade:now:scheduler:)`, `RealTimeEventDAO.log(...)`, `FlashcardReviewMetadata(card:grade:auto:)` (slice 1), `ReviewGrade` (full four-button scale — quiz cards are normal/cloze cards, so `StudyAssignmentGradePolicy.choices` already returns all four).
- Produces (used by Task 11):
  - `StudyCheckpointCoordinator.QuizContext: Equatable, Sendable { let audiobookID: String; let chapterIndex: Int; let chapterTitle: String }` (nested)
  - `State.quizActive(QuizContext)` (new case)
  - `static let quizCardCap = 5`
  - `private(set) var quizCards: [Flashcard]`, `private(set) var quizPosition: Int`, `var currentQuizCard: Flashcard?`
  - `func gradeQuizCard(_ grade: ReviewGrade, now: Date = Date())`, `func dismissQuiz()`
  - `@ObservationIgnored var isScreenOn: (() -> Bool)?` (nil = treat as on; macOS leaves it nil)

**Behavior contract (design §6):** the quiz runs only after a DELIBERATE tap resolution (`.good`/`.again`) — never after `.skip`, never after a timeout auto-grade (no tap means nobody is looking). Screen off → an audio nudge ("N cards waiting for review.") and the normal finish. Q&A cards are NEVER auto-graded: dismissal or abandonment writes nothing and leaves them due. The chapter's replay/advance/sleep-stop finish is DEFERRED until the quiz completes or is dismissed.

**Steps:**

- [ ] Write the failing test at `EchoTests/StudyCheckpointQuizTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Minimal recording harness in the slice-1 CheckpointHarness style (that one
/// is file-private to its own suite).
@MainActor
private final class QuizHarness {
    let service: DatabaseService
    var advanced: [StudyPlayableItem] = []
    var announcements: [String] = []
    var replayCount = 0
    private(set) var coordinator: StudyCheckpointCoordinator!

    init(service: DatabaseService) {
        self.service = service
        coordinator = StudyCheckpointCoordinator(
            database: service,
            settingsProvider: {
                StudyCheckpointSettings(
                    timeoutSeconds: 30, timeoutBehavior: .replay,
                    autoAdvance: true, remoteGrading: true)
            },
            replayChapter: { [weak self] in self?.replayCount += 1 },
            advance: { [weak self] item in self?.advanced.append(item) },
            announce: { [weak self] line in self?.announcements.append(line) }
        )
        coordinator.pausePlayback = {}
    }
}

@MainActor
struct StudyCheckpointQuizTests {
    private func harness(quizCardCount: Int, chapterIndex: Int = 0) throws -> QuizHarness {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for i in 0..<quizCardCount {
            try StudyCardFixtures.seedAcceptedCard(
                id: "quiz-\(i)", chapterIndex: chapterIndex, ordinal: 100 + i,
                released: true, in: service)
        }
        return QuizHarness(service: service)
    }

    @Test func goodTapStartsQuizCappedAtFive() throws {
        let h = try harness(quizCardCount: 6)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        guard case .quizActive(let quiz) = h.coordinator.state else {
            Issue.record("Expected an active quiz")
            return
        }
        #expect(quiz.chapterIndex == 0)
        #expect(h.coordinator.quizCards.count == 5)
        #expect(h.coordinator.currentQuizCard?.id == "quiz-0")
        // The chapter finish (advance) is deferred until the quiz ends.
        #expect(h.advanced.isEmpty)
    }

    @Test func gradingThroughTheQuizWritesFSRSGradesThenAdvances() throws {
        let h = try harness(quizCardCount: 2)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        h.coordinator.gradeQuizCard(.good, now: StudyQueueFixtures.mondayNoon)
        #expect(h.coordinator.currentQuizCard?.id == "quiz-1")
        h.coordinator.gradeQuizCard(.easy, now: StudyQueueFixtures.mondayNoon)

        let first = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: "quiz-0") })
        let second = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: "quiz-1") })
        #expect(first.lastGrade == 3)
        #expect(first.repetitions == 1)
        #expect(second.lastGrade == 4)
        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func dismissLeavesRemainingCardsUntouchedAndRunsTheFinish() throws {
        let h = try harness(quizCardCount: 2)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)
        h.coordinator.gradeQuizCard(.again, now: StudyQueueFixtures.mondayNoon)

        h.coordinator.dismissQuiz()

        let abandoned = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: "quiz-1") })
        #expect(abandoned.lastGrade == nil)
        #expect(abandoned.repetitions == 0)
        // Still due at its release stamp — stays in the regular due queue.
        let releasedStamp = StudyQueueFixtures.mondayNoon
            .addingTimeInterval(-3_600).ISO8601Format()
        #expect(abandoned.nextReviewDate == releasedStamp)
        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.count == 1)
    }

    @Test func screenOffSkipsTheQuizAndNudges() throws {
        let h = try harness(quizCardCount: 3)
        h.coordinator.isScreenOn = { false }
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.state == .idle)
        #expect(h.announcements.contains("3 cards waiting for review."))
        #expect(h.advanced.count == 1)
        // Nothing was graded.
        let untouched = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: "quiz-0") })
        #expect(untouched.lastGrade == nil)
    }

    @Test func timeoutAutoGradeNeverStartsAQuiz() throws {
        let h = try harness(quizCardCount: 3)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.state == .idle)
        #expect(h.replayCount == 1)
        #expect(h.coordinator.quizCards.isEmpty)
    }

    @Test func skipNeverStartsAQuiz() throws {
        let h = try harness(quizCardCount: 3)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.skip, now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.quizCards.isEmpty)
    }

    @Test func quizPullsOnlyReleasedCardsOfTheFinishedChapter() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "eligible", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "unreleased", chapterIndex: 0, ordinal: 101, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "other-chapter", chapterIndex: 1, ordinal: 102, released: true, in: service)
        let h = QuizHarness(service: service)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.quizCards.map(\.id) == ["eligible"])
    }

    @Test func noDueCardsMeansNoQuizAndNormalFinish() throws {
        let h = try harness(quizCardCount: 0)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.count == 1)
    }
}
```

- [ ] Run it (expect compile failure: `has no member 'quizCards'` / `has no member 'isScreenOn'`):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Modify `EchoCore/Services/StudyCheckpointCoordinator.swift` — five edits (Read the file first; the anchors are slice-1 code):

**(a)** Extend the nested state types. After the `Context` struct's closing brace and BEFORE `enum State`, add:

```swift
    /// What the quiz panel renders while the checkpoint quiz is active (§6).
    struct QuizContext: Equatable, Sendable {
        let audiobookID: String
        let chapterIndex: Int
        let chapterTitle: String
    }
```

then replace the `State` enum:

```swift
    enum State: Equatable {
        case idle
        case checkpointActive(Context)
        /// Post-grade screen-on quiz over the finished chapter's due AI cards
        /// (§6). The chapter's replay/advance/sleep finish is parked in
        /// `pendingFinish` until the quiz ends.
        case quizActive(QuizContext)
    }
```

**(b)** Add the quiz storage. Directly after `private(set) var remainingSeconds: Int = 0`, add:

```swift
    /// Hard cap on cards per checkpoint quiz (§6); the rest stay in the due
    /// queue.
    static let quizCardCap = 5

    /// The quiz deck for the active `quizActive` state, in plan order.
    private(set) var quizCards: [Flashcard] = []
    /// Index of the card currently showing.
    private(set) var quizPosition: Int = 0

    var currentQuizCard: Flashcard? {
        quizCards.indices.contains(quizPosition) ? quizCards[quizPosition] : nil
    }
```

and next to the other `@ObservationIgnored var` wiring closures (after `isPlayable`), add:

```swift
    /// Whether a human is plausibly looking at the screen right now. The quiz
    /// is screen-on only (§6); nil (macOS, tests) means "on".
    @ObservationIgnored var isScreenOn: (() -> Bool)?
```

and next to `deferredBoundary`'s declaration, add:

```swift
    /// The chapter finish (replay/advance/sleep) parked while a quiz runs.
    @ObservationIgnored private var pendingFinish: PendingFinish?

    private struct PendingFinish {
        let context: Context
        let replay: Bool
    }
```

**(c)** Route tap resolutions through the quiz gate. In `resolve(_:now:)`, replace the `.good` and `.again` cases (leave `.skip` untouched):

```swift
        case .good:
            grade(.good, context: context, auto: false, now: now)
            finishOrStartQuiz(context: context, replay: false, now: now)
        case .again:
            grade(.again, context: context, auto: false, now: now)
            // Tapped Again replays unless the user chose "grade and move on".
            finishOrStartQuiz(
                context: context,
                replay: settingsProvider().timeoutBehavior != .gradeAndAdvance,
                now: now)
```

(`timeoutFired` stays exactly as slice 1 wrote it: auto-grades call `finish` directly and never quiz — no tap means nobody is looking.)

**(d)** Add the quiz section after the `// MARK: - Grading` section's `grade` function (before `finish`):

```swift
    // MARK: - Checkpoint quiz (AI-cards design §6)

    /// After a deliberate tap grade: quiz the finished chapter's due AI cards
    /// when the screen is on, else nudge and finish. The parked finish runs
    /// when the quiz completes or is dismissed.
    private func finishOrStartQuiz(context: Context, replay: Bool, now: Date) {
        let dueCards: [Flashcard]
        do {
            dueCards = try StudyPlanDAO(db: database.writer).dueQuizCards(
                audiobookID: context.audiobookID,
                chapterIndex: context.chapterIndex,
                now: now,
                limit: Self.quizCardCap
            )
        } catch {
            logger.error("Quiz card lookup failed: \(error.localizedDescription)")
            finish(context: context, replay: replay)
            return
        }
        guard !dueCards.isEmpty else {
            finish(context: context, replay: replay)
            return
        }
        guard isScreenOn?() ?? true else {
            // Screen off: nudge only — the cards stay in the due queue (§6).
            announce(String(localized: "\(dueCards.count) cards waiting for review."))
            finish(context: context, replay: replay)
            return
        }

        pendingFinish = PendingFinish(context: context, replay: replay)
        quizCards = dueCards
        quizPosition = 0
        state = .quizActive(
            QuizContext(
                audiobookID: context.audiobookID,
                chapterIndex: context.chapterIndex,
                chapterTitle: context.chapterTitle))
    }

    /// Grades the showing quiz card through the exact FlashcardDAO/FSRS path
    /// the study session uses. Quiz grades are always deliberate taps — never
    /// auto (§6) — so no `auto` flag is written.
    func gradeQuizCard(_ grade: ReviewGrade, now: Date = Date()) {
        guard case .quizActive = state, let card = currentQuizCard else { return }
        do {
            try FlashcardDAO(db: database.writer).grade(
                cardID: card.id, grade: grade.rawValue, now: now)
            let metadataJSON = try FlashcardReviewMetadata(card: card, grade: grade.rawValue)
                .encodedJSONString()
            try RealTimeEventDAO(db: database.writer).log(
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: "Grade: \(grade.rawValue)",
                metadataJSON: metadataJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            logger.error("Checkpoint quiz grade failed: \(error.localizedDescription)")
        }

        quizPosition += 1
        if quizPosition >= quizCards.count {
            endQuiz()
        }
    }

    /// "Done for now": ungraded cards stay due, untouched (§6), and the
    /// parked chapter finish runs.
    func dismissQuiz() {
        guard case .quizActive = state else { return }
        endQuiz()
    }

    private func endQuiz() {
        quizCards = []
        quizPosition = 0
        guard let pending = pendingFinish else {
            state = .idle
            onCheckpointResolved?()
            return
        }
        pendingFinish = nil
        finish(context: pending.context, replay: pending.replay)
    }
```

**(e)** No change to `handleChapterEnd` is needed — its `guard naturalEnd, case .idle = state` already refuses to re-arm while a quiz is active.

- [ ] Run again (expect pass):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/StudyCheckpointQuizTests
make test-only FILTER=EchoTests/StudyCheckpointCoordinatorTests
```

- [ ] Verify SPDX still line 1, then commit:

```bash
git add EchoCore/Services/StudyCheckpointCoordinator.swift EchoTests/StudyCheckpointQuizTests.swift
git commit -m "feat(study): checkpoint quiz state — screen-on, capped at 5, never auto-graded"
```

---

## Task 11: Quiz UI — panel section, overlay conditions, screen-on wiring

**Files:**
- Modify: `EchoCore/Views/StudyCheckpointPanelView.swift` (slice-1 file)
- Modify: `EchoCore/Views/RootTabView.swift` (slice-1 `checkpointOverlay` computed property)
- Modify: `Echo macOS/Views/MacTriPaneView.swift` (slice-1 checkpoint overlay on the content column)
- Modify: `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift` (slice-1 file, iOS-only)
- Modify: `Echo.xcodeproj/project.pbxproj` (remove ONE line from the macOS exception set)

**Interfaces:**
- Consumes: `StudyCheckpointCoordinator.quizActive`/`quizCards`/`quizPosition`/`currentQuizCard`/`gradeQuizCard`/`dismissQuiz`/`isScreenOn` (Task 10), `FlashcardReviewCard(frontText:backText:onGrade:)` (existing — full four-button grading built in), `ReviewGrade(rawValue:)`.
- Produces: nothing for later tasks.

**UI-only task: no unit-test cycle. Verification is `make build-tests` + the macOS build (sequentially — never concurrent with iOS work) + Task 13's manual checklist.**

**Steps:**

- [ ] pbxproj FIRST (the panel is about to reference `FlashcardReviewCard`, which is currently excluded from macOS): in `Echo.xcodeproj/project.pbxproj`, inside the **Echo macOS** exception set `718DD03F18BB433E7AD362E2 /* Exceptions for "EchoCore" folder in "Echo macOS" target */`, DELETE the line:

```
				Views/FlashcardReviewCard.swift,
```

Do NOT touch the echo-cli exception set — `FlashcardReviewCard.swift` stays excluded there (as does `StudyCheckpointPanelView.swift`, which slice 1 excluded from echo-cli). `FlashcardReviewCard` is pure SwiftUI, so it compiles on macOS as-is.

- [ ] In `EchoCore/Views/StudyCheckpointPanelView.swift`, replace the `body` (slice 1's body is a single `if case .checkpointActive` block) with:

```swift
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
        } else if case .quizActive(let quiz) = coordinator.state {
            quizPanel(quiz: quiz)
        }
    }
```

and add the quiz panel below `gradeButtons(context:)`:

```swift
    /// The post-checkpoint quiz (AI-cards design §6): one FlashcardReviewCard
    /// at a time with the full four-button grade row, a position readout, and
    /// an explicit escape that grades nothing.
    private func quizPanel(quiz: StudyCheckpointCoordinator.QuizContext) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.play")
                Text("Checkpoint Quiz — \(quiz.chapterTitle)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(coordinator.quizPosition + 1) of \(coordinator.quizCards.count)")
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel(
                        Text(
                            "Card \(coordinator.quizPosition + 1) of \(coordinator.quizCards.count)"
                        ))
            }
            .foregroundStyle(.secondary)

            if let card = coordinator.currentQuizCard {
                FlashcardReviewCard(
                    frontText: card.frontText,
                    backText: card.backText,
                    onGrade: { grade in
                        if let reviewGrade = ReviewGrade(rawValue: grade) {
                            coordinator.gradeQuizCard(reviewGrade)
                        }
                    }
                )
                // New identity per card so the flip state resets.
                .id(card.id)
            }

            Button("Done for Now") { coordinator.dismissQuiz() }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
```

- [ ] In `EchoCore/Views/RootTabView.swift`, slice 1's `checkpointOverlay` computed property renders only while `.checkpointActive`. Change its condition so the quiz keeps the overlay up — replace:

```swift
        if let coordinator = model.checkpointCoordinator,
            case .checkpointActive = coordinator.state
        {
```

with:

```swift
        if let coordinator = model.checkpointCoordinator,
            coordinator.state != .idle
        {
```

- [ ] In `Echo macOS/Views/MacTriPaneView.swift`, find the checkpoint overlay slice 1 attached to the content column (the block containing `StudyCheckpointPanelView(coordinator: coordinator)`) and apply the same condition change: replace its `case .checkpointActive = coordinator.state` pattern-match with `coordinator.state != .idle` (Read the file for the exact surrounding lines).

- [ ] In `EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift` (slice-1 file, iOS-only — excluded from macOS and echo-cli, so UIKit is safe here), inside `configureStudyCheckpoint()`, directly after the `coordinator.isPlayable = ...` wiring, add:

```swift
        // Checkpoint quiz is screen-on only (§6): backgrounded playback gets
        // the audio nudge instead of a quiz nobody can see.
        coordinator.isScreenOn = { UIApplication.shared.applicationState == .active }
```

and confirm the file has `import UIKit` at the top (add it after the existing imports if missing; the file is iOS-only). macOS's `MacPlayerModel` leaves `isScreenOn` nil — a Mac window is screen-on by definition.

- [ ] Build-verify iOS, then macOS — ONE AT A TIME, waiting for the first to finish before starting the second:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

then, after it completes:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: both end in `** BUILD SUCCEEDED **` (the macOS one proves the FlashcardReviewCard un-exclusion is correct).

- [ ] Re-run the coordinator suites to confirm no behavior drift:

```bash
make test-only FILTER=EchoTests/StudyCheckpointQuizTests
```

- [ ] Verify SPDX still line 1 in all touched Swift files, then commit:

```bash
git add EchoCore/Views/StudyCheckpointPanelView.swift EchoCore/Views/RootTabView.swift \
    "Echo macOS/Views/MacTriPaneView.swift" EchoCore/ViewModels/PlayerModel+StudyCheckpoint.swift \
    Echo.xcodeproj/project.pbxproj
git commit -m "feat(study): checkpoint-quiz panel UI on iOS overlay and macOS panel"
```

---

## Task 12: macOS generation entry point

**Files:**
- Create: `EchoCore/Views/StudyDeckGenerationSheetHost.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` (echo-cli exception for the new host)
- Modify: `EchoCore/Views/BookSettingsView.swift` (sheet call ~L236–238; delete the private host struct ~L360–392)
- Modify: `Echo macOS/Echo_macOSApp.swift` (menu button after slice 1's "Study Plan…", notification name next to `.requestStudyPlan`)
- Modify: `Echo macOS/Views/MacTriPaneView.swift` (state, sheet, onReceive, toolbar button)

**Interfaces:**
- Consumes: `StudyDeckGenerationSheet` (Task 8), `StudyDeckGenerationViewModel` (Task 7), `APIKeyStore`, `AICardGenerationSettings`, `StudyDeckGeneratorFactory.make(preference:hasKey:fmAvailable:anthropic:)`, `AnthropicStudyDeckGenerator`, `AnthropicMessagesClient(apiKey:model:)`, `StudyDeckFMAvailability.isAvailable` (all existing); slice-1 symbols: the "Study Plan…" menu button and `.requestStudyPlan` notification (placement anchors), `MacPlayerModel.audiobookID`/`.currentTitle`/`.hasMedia` (slice 1 already consumed these — they exist).
- Produces:
  - `struct StudyDeckGenerationSheetHost: View { init(audiobookID: String, bookTitle: String, db: DatabaseWriter) }` (shared iOS + macOS)
  - `Notification.Name.requestStudyDeckGeneration = "com.echo.requestStudyDeckGeneration"`

**UI-only task: no unit-test cycle. Verification is `make build-tests` + the macOS and echo-cli builds.**

**Steps:**

- [ ] Create `EchoCore/Views/StudyDeckGenerationSheetHost.swift` (this is BookSettingsView's private `StudyDeckGenerationSheetHost` logic, promoted to a shared internal view):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI

/// Cross-platform host for the AI-card generation sheet: builds the generator
/// from the user's saved provider settings (BYO key → on-device FM → fixture)
/// and owns the sheet's view model. iOS presents it from BookSettingsView;
/// macOS from the "Generate Study Deck…" menu command (AI-cards design §7).
struct StudyDeckGenerationSheetHost: View {
    @State private var viewModel: StudyDeckGenerationViewModel

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        // Read key + model on the MainActor (View.init is @MainActor). Capture
        // plain Strings so the @Sendable closure never crosses actor boundaries
        // with a @MainActor-isolated object.
        let store = APIKeyStore()
        let hasKey = store.hasKey
        let key = store.anthropicKey ?? ""
        let model = AICardGenerationSettings.selectedModel
        let generator = StudyDeckGeneratorFactory.make(
            preference: AICardGenerationSettings.providerPreference,
            hasKey: hasKey,
            fmAvailable: StudyDeckFMAvailability.isAvailable
        ) {
            AnthropicStudyDeckGenerator(
                client: AnthropicMessagesClient(apiKey: key, model: model))
        }
        _viewModel = State(
            wrappedValue: StudyDeckGenerationViewModel(
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                db: db,
                generator: generator
            )
        )
    }

    var body: some View {
        StudyDeckGenerationSheet(viewModel: viewModel)
            #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
            #endif
    }
}
```

- [ ] pbxproj: the host references `AICardGenerationSettings` (defined in `Views/AICardGenerationSettingsView.swift`, which is excluded from echo-cli), so the new file must be excluded from echo-cli too. In the echo-cli exception set `4FEA03AA769144F6DBB2EF55`, add the line:

```
				Views/StudyDeckGenerationSheetHost.swift,
```

placed alphabetically near `Views/StudyCheckpointPanelView.swift,` (which slice 1 added around `Views/StandaloneTranscriptView.swift,`); if the surrounding order differs, keep it between `Views/StreakModuleView.swift,` and `Views/ThemeSelectionView.swift,`. Do NOT add it to the Echo macOS exception set — macOS is the whole point.

- [ ] In `EchoCore/Views/BookSettingsView.swift`:

**(a)** Replace the sheet call (~L236–238):

```swift
        .sheet(item: $studyDeckGenerationPresentation) { presentation in
            StudyDeckGenerationSheetHost(
                audiobookID: presentation.audiobookID,
                bookTitle: presentation.bookTitle,
                db: presentation.db
            )
        }
```

**(b)** DELETE the entire `private struct StudyDeckGenerationSheetHost: View { ... }` (~L360–392 — the one with `init(presentation: StudyDeckGenerationSheetPresentation)`). Keep the `StudyDeckGenerationSheetPresentation` struct — the iOS sheet still uses it as its `Identifiable` item.

- [ ] In `Echo macOS/Echo_macOSApp.swift`, directly after slice 1's "Study Plan…" button block, add:

```swift
                Button("Generate Study Deck…") {
                    NotificationCenter.default.post(
                        name: .requestStudyDeckGeneration, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!player.hasMedia)
```

and in the `Notification.Name` extension, next to slice 1's `.requestStudyPlan`, add:

```swift
    /// Posted when the user asks to generate an AI study deck (menu/toolbar).
    static let requestStudyDeckGeneration = Notification.Name(
        "com.echo.requestStudyDeckGeneration")
```

- [ ] In `Echo macOS/Views/MacTriPaneView.swift`, four edits:

**(a)** State, next to slice 1's `showingStudyPlan` (~L24):

```swift
    @State private var showingStudyDeckGeneration = false
```

**(b)** Sheet, after slice 1's `showingStudyPlan` sheet:

```swift
            .sheet(isPresented: $showingStudyDeckGeneration) {
                if let audiobookID = player.audiobookID {
                    StudyDeckGenerationSheetHost(
                        audiobookID: audiobookID,
                        bookTitle: player.currentTitle,
                        db: dbService.writer)
                }
            }
```

**(c)** Handler, after slice 1's `.requestStudyPlan` onReceive:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .requestStudyDeckGeneration)) { _ in
            showingStudyDeckGeneration = true
        }
```

**(d)** The design asks for a button near the book context as well as the menu command (§7). In the `transcriptQAToolbar` computed property (~L287), directly before the `Spacer()`, add:

```swift
            // Generate Study Deck: same flow as the menu command (§7).
            Button {
                NotificationCenter.default.post(
                    name: .requestStudyDeckGeneration, object: nil)
            } label: {
                Label("Generate Study Deck", systemImage: "rectangle.stack.badge.plus")
            }
            .help("Generate AI study cards for this book")
```

- [ ] Build-verify all three targets — ONE AT A TIME, each command only after the previous finishes:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

then:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

then:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme echo-cli -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: three `** BUILD SUCCEEDED **` results (the echo-cli one proves the host's exclusion is correct — a miss here is exactly the failure mode CI masks behind test steps).

- [ ] Verify SPDX still line 1 in all touched Swift files, then commit:

```bash
git add EchoCore/Views/StudyDeckGenerationSheetHost.swift EchoCore/Views/BookSettingsView.swift \
    "Echo macOS/Echo_macOSApp.swift" "Echo macOS/Views/MacTriPaneView.swift" \
    Echo.xcodeproj/project.pbxproj
git commit -m "feat(macos): Generate Study Deck menu command, toolbar button, and shared sheet host"
```

---

## Task 13: Final verification

**Files:** none (verification only).

**Interfaces:** everything above.

**Steps:**

- [ ] Run the FULL unit-test suite (gated; never concurrent with anything else):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
```

Expected: `TEST SUCCEEDED` with all new suites green (`SchemaV33Tests`, `SettingsManagerStudyCardLimitTests`, `StudyPlanNewCardsPerDayTests`, `StudyQueueBuilderCardPhaseTests`, `StudySessionViewModelCardReleaseTests`, `StudyDeckAcceptancePlanTests`, `StudyDeckGenerationChapterFlowTests`, `StudyPlanDAOQuizCardsTests`, `StudyCheckpointQuizTests`) and no regressions in `StudyQueueBuilderTests`, `StudyPlanDAOTests`, `StudyDeckAcceptanceServiceTests`, `StudyDeckGenerationViewModelTests`, `StudySessionViewModelTests`, or slice 1's checkpoint suites. Known environmental exception: ABSTokenStore/auth-refresh Keychain tests are run-to-run flaky under unsigned sim builds — a failure ONLY there is environmental; re-run that suite once before treating it as a regression.

- [ ] Build the two non-iOS targets — ONE AT A TIME, after the test run finishes:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

then:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme echo-cli -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` twice.

- [ ] Confirm no stray V33 collision landed on nightly while this plan executed:

```bash
git fetch origin nightly && git log origin/nightly --oneline -5
grep -rn "v33_" Shared/Database/DatabaseService.swift
```

Expected: exactly one `v33_study_plan_new_cards_per_day` registration. If nightly grew its own V33, renumber this plan's migration (file, enum, registration, test name) to the next free version before the PR.

- [ ] Manual verification checklist (owner, on device/desktop — record results in the PR description):
  - [ ] iOS: Book Settings ▸ Generate Study Deck on a plan-less EPUB book → draft sheet shows chapter sections with working per-chapter Accept All / Clear All; Accept → "Add a study plan?" section appears; "Create Study Plan" routes into the plan sheet; "Not Now" dismisses.
  - [ ] iOS: same flow on a book WITH a plan → accepted cards are NOT due today (Study tab count unchanged); summary line mentions the drip; retire follow-up appears once per accepted chapter and "Retire Re-listen Card" removes that chapter's assignment from the queue.
  - [ ] iOS: Settings ▸ Study shows the "New Cards" stepper (1–100, default 20); the plan sheet shows the per-plan stepper.
  - [ ] iOS: open the study session on the plan book → at most min(per-plan, global) new AI cards appear at the end of the queue; reopening the next day releases the next batch.
  - [ ] iOS: finish a due chapter naturally with the screen on → grade the checkpoint → quiz panel flows in (≤5 cards, four grade buttons, "Done for Now" leaves the rest due); with the screen off/locked → audio nudge only, no quiz, and the queue advances.
  - [ ] macOS: Study menu shows "Generate Study Deck…" (⌘⇧G) and the reader toolbar shows the stack-plus button; both present the same sheet; the full loop (generate → accept → plan drip → checkpoint quiz in the panel) works.
  - [ ] Timeout auto-grade (pocketed phone) never shows a quiz and never grades a Q&A card.

- [ ] Doc-sync and PR creation are handled OUTSIDE this plan (the doc-sync skill + maintainer workflow). Do not push from here.
