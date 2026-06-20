# FSRS as the Default Scheduler — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the already-implemented FSRS-4.5 scheduler the single active scheduler for all flashcard reviews — replacing the broken `repetitions >= 6` SM-2/FSRS hybrid — migrate existing SM-2 cards into FSRS memory state, and unify the review UI on the canonical 4-button grade scale.

**Architecture:** FSRS (`FSRSScheduler`) and SM-2 (`SM2Scheduler`) both already exist and conform to `SchedulingAlgorithm`. Today the review flow picks between them by `card.repetitions >= 6`, which is a bug: a card crosses to FSRS with `stability`/`difficulty` still `nil`, so FSRS treats review #7 as a *first* review and discards 6 reps of history; the 6-button UI also feeds FSRS mis-scaled grades. We make FSRS the default everywhere (one code path), add a one-time data migration that seeds FSRS state from each legacy card's SM-2 fields, and replace the 0–5 UI with a typed 4-value `ReviewGrade` (Again/Hard/Good/Easy = 1/2/3/4). `SM2Scheduler` stays as tested legacy but is no longer the active path.

**Tech Stack:** Swift, GRDB (SQLite, WAL), Swift Testing. iOS/watchOS/macOS sharing `Shared/`.

## Global Constraints

- **DI convention:** concrete-type + constructor injection; no `.shared`. Unit-test against `DatabaseService(inMemory: ())`, whose `.writer` is the `DatabaseWriter` (e.g. `FlashcardDAO(db: service.writer)`).
- **Tests:** Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`), `@testable import Echo`. Suites that touch a DB are `@MainActor`.
- **Migrations:** add a `Schema_Vxx` enum in `Shared/Database/Migrations/` and register it in `Shared/Database/DatabaseService.swift`. **Never edit an already-shipped migration.** The next free version is **V22** (highest registered today is `v21_batch_kind`, verified 2026-06-19).
- **FSRS grade scale (canonical):** `1 = Again, 2 = Hard, 3 = Good, 4 = Easy`. `FSRSScheduler.review` already clamps `grade` to `1...4`.
- **SPDX header:** every Swift file's line 1 is exactly `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows the whole file on each edit and can push the SPDX line below an `import` — **after every Swift edit, confirm SPDX is still line 1.**
- **Build/test commands (16 GB machine — never parallel-test, never run two xcodebuild at once):** `make build-tests` once after adding/renaming files, then `make test-only FILTER=EchoTests/<SuiteName>` for the edit→test loop.
- **No re-import / re-align required:** every change here is additive (a data-seeding migration + scheduler selection + UI). It does **not** force an EPUB re-import or an alignment re-run.

---

### Task 1: Make FSRS the sole active scheduler

Remove the `repetitions >= 6` hybrid and make `FSRSScheduler` the default everywhere. Because `InlineFlashcardTriggerController.gradeCard` and `DailyReviewViewModel.gradeCard` both ultimately call `FlashcardDAO.grade`, changing the DAO default fixes every grading path; we also drop the explicit hybrid in the review view model.

**Files:**
- Modify: `Shared/Database/DAOs/FlashcardDAO.swift:82-85` (the `grade(...)` default scheduler)
- Modify: `EchoCore/ViewModels/DailyReviewViewModel.swift:64-81` (remove the hybrid ternary)
- Test: `EchoTests/FlashcardDAOSchedulerTests.swift` (create)

**Interfaces:**
- Consumes: `FlashcardDAO(db: DatabaseWriter)`, `FlashcardDAO.grade(cardID:grade:now:scheduler:)`, `DatabaseService(inMemory:)`, `DatabaseService.writer`, `Flashcard` memberwise init.
- Produces: `FlashcardDAO.grade` now defaults to `FSRSScheduler()`; `DailyReviewViewModel.gradeCard(_:)` always schedules via FSRS.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FlashcardDAOSchedulerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct FlashcardDAOSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A "mature" card (8 reps) with no FSRS state. Under the old `repetitions >= 6`
    /// hybrid this ran SM-2 and left `stability` nil; the default scheduler must now
    /// be FSRS, which seeds memory state. `stability != nil` is the discriminator
    /// (SM-2 never writes stability).
    @Test func gradeWithDefaultScheduler_usesFSRS_seedsMemoryState() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = FlashcardDAO(db: service.writer)
        try dao.insert(makeCard(id: "c1", repetitions: 8, intervalDays: 30))

        try dao.grade(cardID: "c1", grade: 3, now: now)  // default scheduler

        let updated = try service.read { try Flashcard.fetchOne($0, key: "c1") }
        #expect(updated?.stability != nil)
        #expect(updated?.repetitions == 9)
    }

    private func makeCard(id: String, repetitions: Int, intervalDays: Int) -> Flashcard {
        Flashcard(
            id: id, audiobookID: "book", frontText: "F", backText: "B",
            mediaTimestamp: 0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: intervalDays, easeFactor: 2.5,
            repetitions: repetitions, lastReviewedAt: nil, lastGrade: nil,
            isEnabled: true, deckID: nil, tags: nil, mediaJSON: nil,
            sourceBlockID: nil, playlistPosition: nil, createdAt: nil, modifiedAt: nil,
            stability: nil, difficulty: nil, cardType: "normal", clozeIndex: nil)
    }
}
```

- [ ] **Step 2: Build the test target, run the test, verify it FAILS**

Run: `make build-tests && make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests`
Expected: FAIL — `updated?.stability` is `nil` (default scheduler is still `SM2Scheduler`, which never sets stability).

- [ ] **Step 3: Change the DAO default scheduler to FSRS**

In `Shared/Database/DAOs/FlashcardDAO.swift`, change the `grade` signature default (line 84):

```swift
    func grade(
        cardID: String, grade: Int, now: Date = Date(),
        scheduler: some SchedulingAlgorithm = FSRSScheduler()
    ) throws {
        try db.write { db in
            guard let card = try Flashcard.fetchOne(db, key: cardID) else { return }
            let updated = scheduler.review(card: card, grade: grade, now: now)
            try updated.update(db)
            try syncToTimeline(db, card: updated)
        }
    }
```

- [ ] **Step 4: Remove the hybrid in the review view model**

In `EchoCore/ViewModels/DailyReviewViewModel.swift`, replace the body of `gradeCard(_:)` (lines 64–81) so it no longer constructs a scheduler — it relies on the new FSRS default:

```swift
    func gradeCard(_ grade: Int) {
        guard let card = currentCard else { return }
        snippetPlayer?.stop()
        isPlayingSnippet = false
        do {
            let dao = FlashcardDAO(db: db)
            try dao.grade(cardID: card.id, grade: grade, now: Date())  // FSRS (DAO default)
            logFlashcardReviewed(card: card, grade: grade)
            let remaining = dueCards.count - (currentIndex + 1)
            ReviewNotificationService.updateNotification(dueCount: remaining)
        } catch {
            logger.error("Failed to grade card \(card.id): \(error.localizedDescription)")
        }
        advance()
    }
```

- [ ] **Step 5: Confirm SPDX is still line 1 in both edited Swift files** (the SwiftFormat hook may have reflowed them).

Run: `head -1 Shared/Database/DAOs/FlashcardDAO.swift EchoCore/ViewModels/DailyReviewViewModel.swift`
Expected: each prints `// SPDX-License-Identifier: GPL-3.0-or-later`. If not, move the SPDX comment back to line 1.

- [ ] **Step 6: Run the new test + the existing scheduler suite, verify PASS**

Run: `make build-tests && make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests && make test-only FILTER=EchoTests/SchedulingAlgorithmTests`
Expected: both suites PASS (FSRS now runs by default; `SM2Scheduler`'s own unit tests are unaffected).

- [ ] **Step 7: Commit**

```bash
git add Shared/Database/DAOs/FlashcardDAO.swift EchoCore/ViewModels/DailyReviewViewModel.swift EchoTests/FlashcardDAOSchedulerTests.swift
git commit -m "fix(srs): make FSRS the default scheduler, drop the rep>=6 hybrid

The repetitions>=6 SM-2/FSRS hybrid crossed cards to FSRS with nil
stability, so FSRS treated review #7 as a first review and discarded
history. FSRS is now the DAO default, so both the review flow and the
inline-trigger flow schedule via FSRS.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Seed legacy SM-2 cards into FSRS memory state (Schema V22)

A one-time data migration: every previously-reviewed card (`repetitions > 0`) with no FSRS `stability` is seeded from its SM-2 fields, so its next FSRS review evolves real memory instead of restarting. Never-reviewed cards stay `nil` and seed naturally on first review.

**Files:**
- Create: `Shared/Database/FSRSMigration.swift` (pure seeding helper)
- Create: `Shared/Database/Migrations/Schema_V22.swift`
- Modify: `Shared/Database/DatabaseService.swift:113` (register `v22_fsrs_seed` after `v21_batch_kind`)
- Test: `EchoTests/FSRSMigrationTests.swift` (create), `EchoTests/SchemaV22Tests.swift` (create)

**Interfaces:**
- Consumes: GRDB `Database`, `Row`, `FlashcardDAO.insert`, `DatabaseService.writer`/`.write`/`.read`.
- Produces: `FSRSMigration.seed(intervalDays: Int, easeFactor: Double) -> (stability: Double, difficulty: Double)`; `enum Schema_V22 { static func migrate(_ db: Database) throws }`.

- [ ] **Step 1: Write the failing test for the pure seeding helper**

Create `EchoTests/FSRSMigrationTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct FSRSMigrationTests {
    @Test func seed_intervalBecomesStability_defaultEaseIsNeutralDifficulty() {
        let s = FSRSMigration.seed(intervalDays: 14, easeFactor: 2.5)
        #expect(s.stability == 14)
        #expect(s.difficulty == 5)
    }

    @Test func seed_lowEase_pushesDifficultyHigh_clampedToTen() {
        let s = FSRSMigration.seed(intervalDays: 1, easeFactor: 1.3)
        // 5 - (1.3 - 2.5) * 5 = 5 + 6 = 11 -> clamped to 10
        #expect(s.difficulty == 10)
        #expect(s.stability == 1)
    }

    @Test func seed_zeroInterval_isFlooredStability() {
        let s = FSRSMigration.seed(intervalDays: 0, easeFactor: 2.5)
        #expect(s.stability == 0.1)
    }
}
```

- [ ] **Step 2: Run it, verify it FAILS**

Run: `make build-tests && make test-only FILTER=EchoTests/FSRSMigrationTests`
Expected: FAIL to build — `FSRSMigration` is undefined.

- [ ] **Step 3: Implement the pure helper**

Create `Shared/Database/FSRSMigration.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Seeds FSRS memory state from a legacy SM-2 card's fields. This is a heuristic
/// proxy, not a perfect reconstruction: the SM-2 interval approximates FSRS
/// stability (the day-interval at ~90% retention), and the SM-2 ease factor maps
/// inversely to FSRS difficulty (lower ease = harder card = higher difficulty;
/// the SM-2 default ease 2.5 maps to a neutral difficulty of 5).
enum FSRSMigration {
    static func seed(intervalDays: Int, easeFactor: Double)
        -> (stability: Double, difficulty: Double)
    {
        let stability = max(0.1, Double(intervalDays))
        let rawDifficulty = 5.0 - (easeFactor - 2.5) * 5.0
        let difficulty = min(max(rawDifficulty, 1.0), 10.0)
        return (stability, difficulty)
    }
}
```

- [ ] **Step 4: Run the helper test, verify PASS**

Run: `make build-tests && make test-only FILTER=EchoTests/FSRSMigrationTests`
Expected: PASS.

- [ ] **Step 5: Write the failing migration test**

Create `EchoTests/SchemaV22Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV22Tests {
    /// `DatabaseService(inMemory:)` already runs all migrations including V22, so we
    /// insert legacy-shaped cards *after* migration and invoke `Schema_V22.migrate`
    /// directly (it is idempotent — it only touches `stability IS NULL`).
    @Test func v22_seedsReviewedCard_andLeavesNeverReviewedCardNil() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = FlashcardDAO(db: service.writer)
        try dao.insert(makeCard(id: "old", repetitions: 4, intervalDays: 20, ease: 2.0))
        try dao.insert(makeCard(id: "new", repetitions: 0, intervalDays: 0, ease: 2.5))

        try service.write { try Schema_V22.migrate($0) }

        let old = try service.read { try Flashcard.fetchOne($0, key: "old") }
        let new = try service.read { try Flashcard.fetchOne($0, key: "new") }
        #expect(old?.stability == 20)
        #expect((old?.difficulty ?? 0) >= 1 && (old?.difficulty ?? 0) <= 10)
        #expect(new?.stability == nil)
    }

    private func makeCard(id: String, repetitions: Int, intervalDays: Int, ease: Double)
        -> Flashcard
    {
        Flashcard(
            id: id, audiobookID: "book", frontText: "F", backText: "B",
            mediaTimestamp: 0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: intervalDays, easeFactor: ease,
            repetitions: repetitions, lastReviewedAt: nil, lastGrade: nil,
            isEnabled: true, deckID: nil, tags: nil, mediaJSON: nil,
            sourceBlockID: nil, playlistPosition: nil, createdAt: nil, modifiedAt: nil,
            stability: nil, difficulty: nil, cardType: "normal", clozeIndex: nil)
    }
}
```

- [ ] **Step 6: Run it, verify it FAILS**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV22Tests`
Expected: FAIL to build — `Schema_V22` is undefined.

- [ ] **Step 7: Implement the migration**

Create `Shared/Database/Migrations/Schema_V22.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V22 — seed FSRS memory state (`stability`, `difficulty`) for legacy SM-2 cards.
///
/// One-time data migration. Every previously-reviewed card (`repetitions > 0`)
/// with no FSRS `stability` yet is seeded from its SM-2 state, so its next FSRS
/// review evolves the existing memory instead of restarting from a first review
/// (which would discard its history). Never-reviewed cards stay `nil` and seed
/// naturally on their first FSRS review. Idempotent: only touches rows where
/// `stability IS NULL`.
enum Schema_V22 {
    nonisolated static func migrate(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, interval_days, ease_factor FROM flashcard
                WHERE repetitions > 0 AND stability IS NULL
                """)
        for row in rows {
            let id: String = row["id"]
            let intervalDays: Int = row["interval_days"]
            let easeFactor: Double = row["ease_factor"]
            let seed = FSRSMigration.seed(intervalDays: intervalDays, easeFactor: easeFactor)
            try db.execute(
                sql: "UPDATE flashcard SET stability = ?, difficulty = ? WHERE id = ?",
                arguments: [seed.stability, seed.difficulty, id])
        }
    }
}
```

- [ ] **Step 8: Register the migration**

In `Shared/Database/DatabaseService.swift`, immediately after the `v21_batch_kind` line (113), add:

```swift
        migrator.registerMigration("v22_fsrs_seed") { db in try Schema_V22.migrate(db) }
```

- [ ] **Step 9: Confirm SPDX is line 1 in all three new/edited Swift files.**

Run: `head -1 Shared/Database/FSRSMigration.swift Shared/Database/Migrations/Schema_V22.swift Shared/Database/DatabaseService.swift`
Expected: each prints the SPDX line.

- [ ] **Step 10: Run both new suites, verify PASS**

Run: `make build-tests && make test-only FILTER=EchoTests/FSRSMigrationTests && make test-only FILTER=EchoTests/SchemaV22Tests`
Expected: both PASS.

- [ ] **Step 11: Commit**

```bash
git add Shared/Database/FSRSMigration.swift Shared/Database/Migrations/Schema_V22.swift Shared/Database/DatabaseService.swift EchoTests/FSRSMigrationTests.swift EchoTests/SchemaV22Tests.swift
git commit -m "feat(srs): seed legacy SM-2 cards into FSRS state (Schema V22)

One-time data migration: previously-reviewed cards (repetitions>0) with
no FSRS stability are seeded from their SM-2 interval/ease so FSRS evolves
real memory instead of restarting. Never-reviewed cards seed on first review.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Unify the review UI on a typed 4-button `ReviewGrade`

Replace the 0–5 (six-button) review UI with the canonical four-button FSRS scale. A `ReviewGrade` enum (rawValue 1–4) prevents the prior mis-scaling. The view emits `grade.rawValue`, so downstream signatures (`onGrade: (Int) -> Void`, `gradeCard(_ grade: Int)`, the DAO, the protocol) are unchanged and no other call sites move.

**Files:**
- Create: `Shared/Database/ReviewGrade.swift`
- Modify: `EchoCore/Views/FlashcardReviewCard.swift:48-94` (the grade-button block + `gradeLabel`/`gradeColor`)
- Test: `EchoTests/ReviewGradeTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum ReviewGrade: Int, CaseIterable, Sendable` with cases `.again=1, .hard=2, .good=3, .easy=4` and `var label: String`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReviewGradeTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReviewGradeTests {
    @Test func rawValuesMatchFSRSScale() {
        #expect(ReviewGrade.again.rawValue == 1)
        #expect(ReviewGrade.hard.rawValue == 2)
        #expect(ReviewGrade.good.rawValue == 3)
        #expect(ReviewGrade.easy.rawValue == 4)
    }

    @Test func allCasesOrderedAgainToEasy() {
        #expect(ReviewGrade.allCases == [.again, .hard, .good, .easy])
        #expect(ReviewGrade.allCases.map(\.label) == ["Again", "Hard", "Good", "Easy"])
    }
}
```

- [ ] **Step 2: Run it, verify it FAILS**

Run: `make build-tests && make test-only FILTER=EchoTests/ReviewGradeTests`
Expected: FAIL to build — `ReviewGrade` is undefined.

- [ ] **Step 3: Implement the enum**

Create `Shared/Database/ReviewGrade.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The canonical review grade — the four-button FSRS scale. Raw values are the
/// exact grades `FSRSScheduler` expects: 1 = Again, 2 = Hard, 3 = Good, 4 = Easy.
/// Introduced to prevent the prior 0–5-vs-1–4 mismatch that mis-fed FSRS.
enum ReviewGrade: Int, CaseIterable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}
```

- [ ] **Step 4: Run the enum test, verify PASS**

Run: `make build-tests && make test-only FILTER=EchoTests/ReviewGradeTests`
Expected: PASS.

- [ ] **Step 5: Rewire the review card to four buttons**

In `EchoCore/Views/FlashcardReviewCard.swift`, replace the grade-button block (lines 48–71, the `if isRevealed { HStack { ForEach(0..<6) ... } }`) with:

```swift
            // Grade buttons (shown after reveal)
            if isRevealed {
                HStack(spacing: 8) {
                    ForEach(ReviewGrade.allCases, id: \.self) { grade in
                        Button {
                            onGrade(grade.rawValue)
                        } label: {
                            Text(grade.label)
                                .font(.caption)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(color(for: grade).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel(Text(grade.label))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
```

Then replace the two helpers (lines 76–94, `gradeLabel(_:)` and `gradeColor(_:)`) with a single color helper:

```swift
    private func color(for grade: ReviewGrade) -> Color {
        switch grade {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }
```

(`onGrade` stays `(Int) -> Void`; the two callers — `FlashcardReviewSession.swift:32` and `FlashcardOverlayView.swift:17` — are unchanged.)

- [ ] **Step 6: Confirm SPDX is line 1 in both Swift files.**

Run: `head -1 Shared/Database/ReviewGrade.swift EchoCore/Views/FlashcardReviewCard.swift`
Expected: each prints the SPDX line.

- [ ] **Step 7: Build the app target + run the review-related suites, verify PASS**

Run: `make build-tests && make test-only FILTER=EchoTests/ReviewGradeTests && make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests`
Expected: PASS. (The view change is compile-verified by `make build-tests`; UI tests are intentionally excluded from the scheme.)

- [ ] **Step 8: Commit**

```bash
git add Shared/Database/ReviewGrade.swift EchoCore/Views/FlashcardReviewCard.swift EchoTests/ReviewGradeTests.swift
git commit -m "feat(srs): four-button ReviewGrade UI on the FSRS scale

Replace the 0-5 six-button review UI with the canonical four-button
Again/Hard/Good/Easy (1-4) the FSRS algorithm expects, via a typed
ReviewGrade enum, fixing the grade-scale mismatch.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Full-suite verification + schema-migration review

A reviewer gate: the whole change set is data-correct and the new migration is safe, before this branch is considered done.

**Files:** none (verification only).

- [ ] **Step 1: Run the schema-migration-reviewer on V22**

Invoke the `schema-migration-reviewer` agent over the diff touching `Shared/Database/` (the new `Schema_V22`, `FSRSMigration`, and the `DatabaseService` registration). Confirm: no version collision (V22 is free), the migration is registered in order, no shipped migration was edited, `SchemaV22Tests` exists, and the change does **not** force an EPUB re-import or alignment re-run.

- [ ] **Step 2: Run the full unit/integration suite**

Run: `make test`
Expected: green, with **no new failures** versus the pre-change baseline. (Note: `EchoTests/RealTimeEventIntegrityTests` calls `viewModel.gradeCard(5)`; `5` still compiles and FSRS clamps it to `4` (Easy), so the suite stays green. Optionally update that literal to `3` for realism — not required.)

- [ ] **Step 3: Confirm SPDX line 1 across all new/edited Swift files**

Run: `for f in Shared/Database/DAOs/FlashcardDAO.swift EchoCore/ViewModels/DailyReviewViewModel.swift Shared/Database/FSRSMigration.swift Shared/Database/Migrations/Schema_V22.swift Shared/Database/DatabaseService.swift Shared/Database/ReviewGrade.swift EchoCore/Views/FlashcardReviewCard.swift; do head -1 "$f"; done`
Expected: every line is `// SPDX-License-Identifier: GPL-3.0-or-later`.

- [ ] **Step 4: (If the gate is clean) the branch is ready** — open a PR or hand back per the project's workflow.

---

## Out of scope (next plans)

These are explicitly **not** in this plan — they belong to the Chapter Study Mode / review-queue plan that builds on this scheduler:

- **New-cards-per-day limits** (per-deck + global) — no daily-limit logic exists today; net-new.
- **The interleaved review queue UI** beyond the existing `allDueCards()` ordering.
- **Chapter Study Mode** (chapter-as-card, the `.again`/`.good` 2-button subset, retire-on-card-create) — its own design pass + plan.
- **Retiring `SM2Scheduler`** entirely — kept as tested legacy for now (its unit tests stay green); deletion is a later cleanup, not part of making FSRS the default.
