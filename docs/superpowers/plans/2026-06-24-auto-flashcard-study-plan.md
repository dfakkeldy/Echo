# Auto Flashcard Study Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build book-scoped auto-generated study plans that release chapter and EPUB-image listening assignments on a daily or weekly cadence, then hand graded assignments to the existing FSRS flashcard scheduler.

**Architecture:** Add an additive GRDB study-plan layer (`study_plan`, `study_plan_item`) that controls initial assignment release while existing `flashcard` rows remain the review unit. Generation is preview-first and idempotent; queue building separates due reviews, introduced-but-ungraded assignments, and newly released assignments. SwiftUI owns presentation with `@MainActor @Observable` view models and delegates playback to `PlayerModel`.

**Tech Stack:** Swift 6, SwiftUI, Observation, GRDB, Swift Testing, existing Xcode file-system synchronized groups, no new third-party dependencies.

## Global Constraints

- Target iOS 19.0 or later, macOS 16.0 or later, watchOS 12.0 or later.
- Swift 6.0 or later, using modern Swift concurrency.
- SwiftUI backed up by `@Observable` classes for shared data.
- Do not introduce third-party frameworks without asking first.
- Avoid UIKit unless required by existing UIKit reader integration.
- Add a fresh migration. Do not edit shipped migrations.
- Keep existing manual and imported flashcards working as normal due-review cards.
- Generated listening/image assignments keep `next_review_date` nil until their first grade; FSRS owns future review dates after `FlashcardDAO.grade`.
- Mark a new `study_plan_item` introduced when it first enters the study queue/session, and keep it queued until its generated card receives a first grade.
- First UI entry point is `BookSettingsView`; add Reader-tab entry only if it is still small after the core sheet works.
- First image filtering skips front matter, hidden blocks, and missing image files. Do not add image dimension filtering in this implementation slice.
- PR must target `nightly`, not `main`.

---

## File Structure

Create:

- `Shared/Study/StudyPlanTypes.swift` - shared enums and preview/queue value types.
- `Shared/Database/Migrations/Schema_V25.swift` - additive `study_plan` and `study_plan_item` tables.
- `Shared/Database/StudyPlan.swift` - GRDB record for `study_plan`.
- `Shared/Database/StudyPlanItem.swift` - GRDB record for `study_plan_item`.
- `Shared/Database/DAOs/StudyPlanDAO.swift` - plan CRUD, transactional creation, introduction marking, queue queries.
- `Shared/Services/StudyPlanGenerator.swift` - preview candidates from EPUB blocks and optional image blocks.
- `Shared/Services/StudyQueueBuilder.swift` - due/in-progress/new queue assembly.
- `EchoCore/ViewModels/StudyPlanViewModel.swift` - plan sheet state and actions.
- `EchoCore/ViewModels/StudySessionViewModel.swift` - assignment-aware review session state and grading.
- `EchoCore/Views/StudyPlanSheet.swift` - generation/management sheet.
- `EchoCore/Views/StudySessionView.swift` - session shell for normal cards and assignments.
- `EchoCore/Views/StudyAssignmentCardView.swift` - chapter/image assignment card UI.
- `EchoTests/SchemaV25Tests.swift`
- `EchoTests/StudyPlanDAOTests.swift`
- `EchoTests/StudyPlanGeneratorTests.swift`
- `EchoTests/StudyQueueBuilderTests.swift`
- `EchoTests/StudySessionViewModelTests.swift`

Modify:

- `Shared/Database/DatabaseService.swift` - register migration v25.
- `Shared/Database/DAOs/FlashcardDAO.swift` - add enabled-filtered due query helpers.
- `Shared/Services/ChapterCardDrafter.swift` - keep the existing API as a compatibility wrapper around the new generator/DAO path.
- `EchoCore/Views/BookSettingsView.swift` - add Study Plan button and sheet entry.
- `EchoCore/Views/RootTabView.swift` - launch `StudySessionView`, delegate assignment playback, and wire review tap.
- `EchoCore/Views/DashboardShelf.swift` / `EchoCore/Views/UpcomingReviewsModuleView.swift` - show study queue counts and call review launcher from the live shelf location.
- `EchoCore/Views/FlashcardReviewSession.swift` and `EchoCore/Views/FlashcardReviewCard.swift` - keep compiling while `RootTabView` moves to `StudySessionView`.
- `README.md`, `ARCHITECTURE.md`, `docs/guides/testflight-beta-guide.md` - document the finished flow.

Project membership:

- The project uses `PBXFileSystemSynchronizedRootGroup` for `Shared`, `EchoCore`, and `EchoTests`. New files under those folders should be included automatically. Do not churn `Echo.xcodeproj/project.pbxproj` unless `make build-tests` proves a file is missing from a target.

---

### Task 0: Branch, Baseline, and Guardrails

**Files:**
- Read: `docs/superpowers/specs/2026-06-24-auto-flashcard-study-plan-design.md`
- Read: `docs/superpowers/plans/2026-06-24-auto-flashcard-study-plan.md`

**Interfaces:**
- Consumes: clean worktree on `codex/auto-flashcard-study-plan`, based on `origin/nightly`.
- Produces: confirmed baseline before code changes.

- [ ] **Step 1: Verify branch and worktree**

Run:

```bash
git status --short --branch
```

Expected:

```text
## codex/auto-flashcard-study-plan...origin/nightly [ahead 2]
```

There should be no uncommitted changes before implementation starts.

- [ ] **Step 2: Re-run baseline test build**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`. Existing warnings in unrelated files may remain; do not fix unrelated warnings in this feature branch.

- [ ] **Step 3: Commit only if baseline metadata changed**

No commit is expected for this task. If a generated file changes unexpectedly, stop and inspect before continuing.

---

### Task 1: Study Plan Schema, Records, and Migration

**Files:**
- Create: `Shared/Study/StudyPlanTypes.swift`
- Create: `Shared/Database/Migrations/Schema_V25.swift`
- Create: `Shared/Database/StudyPlan.swift`
- Create: `Shared/Database/StudyPlanItem.swift`
- Modify: `Shared/Database/Flashcard.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Test: `EchoTests/SchemaV25Tests.swift`

**Interfaces:**
- Produces:
  - `enum StudyPlanCadenceUnit: String, Codable, Sendable, CaseIterable`
  - `enum StudyPlanQueueMode: String, Codable, Sendable, CaseIterable`
  - `enum StudyPlanCatchUpPolicy: String, Codable, Sendable, CaseIterable`
  - `enum StudyPlanItemKind: String, Codable, Sendable, CaseIterable`
  - `enum StudyFlashcardType`
  - `struct StudyCardMedia: Codable, Equatable, Sendable`
  - `struct StudyPlan: Codable, FetchableRecord, MutablePersistableRecord`
  - `struct StudyPlanItem: Codable, FetchableRecord, MutablePersistableRecord`
  - `Schema_V25.migrate(_:)`
- Consumes: existing `audiobook`, `deck`, `flashcard`, and `epub_block` tables.

- [ ] **Step 1: Write failing schema tests**

Create `EchoTests/SchemaV25Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV25Tests {
    @Test func v25CreatesStudyPlanTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "study_plan", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("audiobook_id"))
        #expect(columns.contains("deck_id"))
        #expect(columns.contains("cadence_unit"))
        #expect(columns.contains("new_chapter_limit"))
        #expect(columns.contains("include_images"))
        #expect(columns.contains("queue_mode_default"))
        #expect(columns.contains("catch_up_policy"))
        #expect(columns.contains("start_date"))
        #expect(columns.contains("is_paused"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v25CreatesStudyPlanItemTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "study_plan_item", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("plan_id"))
        #expect(columns.contains("flashcard_id"))
        #expect(columns.contains("kind"))
        #expect(columns.contains("chapter_index"))
        #expect(columns.contains("source_block_id"))
        #expect(columns.contains("ordinal"))
        #expect(columns.contains("introduced_at"))
        #expect(columns.contains("is_enabled"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v25CreatesStudyPlanIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let planIndexes = try indexNames(table: "study_plan", db: db)
        let itemIndexes = try indexNames(table: "study_plan_item", db: db)

        #expect(planIndexes.contains("idx_study_plan_book"))
        #expect(planIndexes.contains("idx_study_plan_active"))
        #expect(itemIndexes.contains("idx_study_plan_item_plan_order"))
        #expect(itemIndexes.contains("idx_study_plan_item_pending"))
        #expect(itemIndexes.contains("idx_study_plan_item_flashcard"))
        #expect(itemIndexes.contains("idx_study_plan_item_source"))
    }

    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }
}
```

- [ ] **Step 2: Run schema test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV25Tests
```

Expected: FAIL because `study_plan` and `study_plan_item` do not exist.

- [ ] **Step 3: Add shared study enums and value types**

Create `Shared/Study/StudyPlanTypes.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum StudyPlanCadenceUnit: String, Codable, Sendable, CaseIterable {
    case day
    case week
}

enum StudyPlanQueueMode: String, Codable, Sendable, CaseIterable {
    case bookByBook = "book_by_book"
    case mixed

    var title: String {
        switch self {
        case .bookByBook: "Book by Book"
        case .mixed: "Mixed"
        }
    }
}

enum StudyPlanCatchUpPolicy: String, Codable, Sendable, CaseIterable {
    case gentle
    case strict
}

enum StudyPlanItemKind: String, Codable, Sendable, CaseIterable {
    case chapter
    case image
}

enum StudyFlashcardType {
    static let normal = "normal"
    static let listeningAssignment = "listening_assignment"
    static let imageAssignment = "image_assignment"
}

struct StudyCardMedia: Codable, Equatable, Sendable {
    let imagePath: String?
}

struct StudyPlanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let kind: StudyPlanItemKind
    let sourceBlockID: String
    let chapterIndex: Int?
    let ordinal: Int
    let title: String
    let defaultIncluded: Bool
    let imagePath: String?
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval?
    let playlistPosition: TimeInterval?
}

struct StudyPlanPreview: Equatable, Sendable {
    let audiobookID: String
    let bookTitle: String
    let candidates: [StudyPlanCandidate]

    var includedByDefault: [StudyPlanCandidate] {
        candidates.filter(\.defaultIncluded)
    }
}

enum StudyQueueCategory: Int, Codable, Sendable, CaseIterable {
    case dueReview = 0
    case inProgressAssignment = 1
    case newAssignment = 2
}

struct StudyQueueEntry: Identifiable, Equatable, Sendable {
    let id: String
    let category: StudyQueueCategory
    let plan: StudyPlan?
    let item: StudyPlanItem?
    let flashcard: Flashcard
}

struct StudyQueue: Equatable, Sendable {
    var entries: [StudyQueueEntry]

    static let empty = StudyQueue(entries: [])

    var dueReviewCount: Int {
        entries.filter { $0.category == .dueReview }.count
    }

    var inProgressAssignmentCount: Int {
        entries.filter { $0.category == .inProgressAssignment }.count
    }

    var newAssignmentCount: Int {
        entries.filter { $0.category == .newAssignment }.count
    }

    var totalCount: Int {
        entries.count
    }
}
```

- [ ] **Step 4: Add GRDB records**

Create `Shared/Database/StudyPlan.swift`:

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

Create `Shared/Database/StudyPlanItem.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanItem: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    var id: String
    var planID: String
    var flashcardID: String?
    var kind: String
    var chapterIndex: Int?
    var sourceBlockID: String?
    var ordinal: Int
    var introducedAt: String?
    var isEnabled: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "study_plan_item"

    enum CodingKeys: String, CodingKey {
        case id
        case planID = "plan_id"
        case flashcardID = "flashcard_id"
        case kind
        case chapterIndex = "chapter_index"
        case sourceBlockID = "source_block_id"
        case ordinal
        case introducedAt = "introduced_at"
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
```

Modify `Shared/Database/Flashcard.swift` so queue value types can safely carry cards:

```swift
struct Flashcard: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
```

- [ ] **Step 5: Add migration**

Create `Shared/Database/Migrations/Schema_V25.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V25 - auto-generated flashcard study plans.
///
/// The plan controls first release of generated chapter/image assignments.
/// Existing `flashcard` rows remain the FSRS review unit after first grade.
enum Schema_V25 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "study_plan", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("deck_id", .text)
                .references("deck", onDelete: .setNull)
            t.column("cadence_unit", .text).notNull().defaults(to: "day")
            t.column("new_chapter_limit", .integer).notNull().defaults(to: 1)
            t.column("include_images", .boolean).notNull().defaults(to: false)
            t.column("queue_mode_default", .text).notNull().defaults(to: "book_by_book")
            t.column("catch_up_policy", .text).notNull().defaults(to: "gentle")
            t.column("start_date", .text).notNull()
            t.column("is_paused", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(table: "study_plan_item", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("plan_id", .text).notNull()
                .references("study_plan", onDelete: .cascade)
            t.column("flashcard_id", .text)
                .references("flashcard", onDelete: .setNull)
            t.column("kind", .text).notNull()
            t.column("chapter_index", .integer)
            t.column("source_block_id", .text)
                .references("epub_block", onDelete: .setNull)
            t.column("ordinal", .integer).notNull()
            t.column("introduced_at", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(
            index: "idx_study_plan_book",
            on: "study_plan",
            columns: ["audiobook_id"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_active",
            on: "study_plan",
            columns: ["is_paused", "start_date"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_plan_order",
            on: "study_plan_item",
            columns: ["plan_id", "ordinal"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_pending",
            on: "study_plan_item",
            columns: ["plan_id", "is_enabled", "introduced_at"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_flashcard",
            on: "study_plan_item",
            columns: ["flashcard_id"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_source",
            on: "study_plan_item",
            columns: ["source_block_id"],
            ifNotExists: true
        )
    }
}
```

- [ ] **Step 6: Register migration**

Modify `Shared/Database/DatabaseService.swift` after v24:

```swift
migrator.registerMigration("v25_study_plans") { db in
    try Schema_V25.migrate(db)
}
```

- [ ] **Step 7: Run schema test**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV25Tests
```

Expected: PASS.

- [ ] **Step 8: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

Run:

```bash
git add Shared/Study/StudyPlanTypes.swift Shared/Database/Migrations/Schema_V25.swift Shared/Database/StudyPlan.swift Shared/Database/StudyPlanItem.swift Shared/Database/Flashcard.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV25Tests.swift
git commit -m "feat(study): add study plan schema"
```

---

### Task 2: Study Plan DAO and Transactional Creation

**Files:**
- Create: `Shared/Database/DAOs/StudyPlanDAO.swift`
- Test: `EchoTests/StudyPlanDAOTests.swift`

**Interfaces:**
- Consumes:
  - `StudyPlanCandidate`
  - `StudyPlanCadenceUnit`
  - `StudyPlanQueueMode`
  - `StudyPlanCatchUpPolicy`
- Produces:
  - `StudyPlanCreationRequest`
  - `StudyPlanCreationResult`
  - `StudyPlanDAO.plan(for:)`
  - `StudyPlanDAO.createPlan(_:)`
  - `StudyPlanDAO.items(for:)`
  - `StudyPlanDAO.markIntroduced(itemIDs:now:)`
  - `StudyPlanDAO.updateSettings(planID:cadenceUnit:newChapterLimit:includeImages:queueMode:catchUpPolicy:)`
  - `StudyPlanDAO.setPaused(planID:isPaused:)`
  - `StudyPlanDAO.setItemEnabled(itemID:isEnabled:)`

- [ ] **Step 1: Write failing DAO tests**

Create `EchoTests/StudyPlanDAOTests.swift` with these tests:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanDAOTests {
    @Test func createsPlanDeckCardsAndItemsTransactionally() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let request = makeRequest(now: now)

        let result = try dao.createPlan(request)

        #expect(result.plan.audiobookID == "book")
        #expect(result.createdCards.count == 2)
        #expect(result.createdItems.count == 2)
        #expect(result.createdCards.allSatisfy { $0.nextReviewDate == nil })
        #expect(result.createdCards.allSatisfy { $0.cardType == StudyFlashcardType.listeningAssignment })
        #expect(result.createdItems.map(\.ordinal) == [0, 1])
    }

    @Test func fetchesPlanByBook() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        _ = try dao.createPlan(makeRequest())

        let plan = try dao.plan(for: "book")

        #expect(plan?.audiobookID == "book")
        #expect(plan?.newChapterLimit == 1)
    }

    @Test func marksItemsIntroduced() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let result = try dao.createPlan(makeRequest())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        try dao.markIntroduced(itemIDs: [result.createdItems[0].id], now: now)

        let items = try dao.items(for: result.plan.id)
        #expect(items[0].introducedAt == now.ISO8601Format())
        #expect(items[1].introducedAt == nil)
    }

    @Test func updatesSettingsAndPauseState() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let result = try dao.createPlan(makeRequest())

        try dao.updateSettings(
            planID: result.plan.id,
            cadenceUnit: .week,
            newChapterLimit: 2,
            includeImages: true,
            queueMode: .mixed,
            catchUpPolicy: .strict
        )
        try dao.setPaused(planID: result.plan.id, isPaused: true)

        let plan = try #require(dao.plan(for: "book"))
        #expect(plan.cadenceUnit == StudyPlanCadenceUnit.week.rawValue)
        #expect(plan.newChapterLimit == 2)
        #expect(plan.includeImages)
        #expect(plan.queueModeDefault == StudyPlanQueueMode.mixed.rawValue)
        #expect(plan.catchUpPolicy == StudyPlanCatchUpPolicy.strict.rawValue)
        #expect(plan.isPaused)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Study Book', 3600, '2026-06-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO epub_block (
                    id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                    block_kind, text, chapter_index, is_hidden, is_front_matter, created_at
                ) VALUES
                ('h1', 'book', 'ch1.xhtml', 0, 0, 0, 'heading', 'Chapter 1', 0, 0, 0, '2026-06-01T00:00:00Z'),
                ('h2', 'book', 'ch2.xhtml', 1, 0, 1, 'heading', 'Chapter 2', 1, 0, 0, '2026-06-01T00:00:00Z')
                """)
        }
        return service
    }

    private func makeRequest(now: Date = Date(timeIntervalSince1970: 1_750_000_000)) -> StudyPlanCreationRequest {
        StudyPlanCreationRequest(
            audiobookID: "book",
            bookTitle: "Study Book",
            cadenceUnit: .day,
            newChapterLimit: 1,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            startDate: now,
            candidates: [
                StudyPlanCandidate(
                    id: "chapter-h1",
                    kind: .chapter,
                    sourceBlockID: "h1",
                    chapterIndex: 0,
                    ordinal: 0,
                    title: "Chapter 1",
                    defaultIncluded: true,
                    imagePath: nil,
                    mediaTimestamp: 10,
                    endTimestamp: 100,
                    playlistPosition: nil
                ),
                StudyPlanCandidate(
                    id: "chapter-h2",
                    kind: .chapter,
                    sourceBlockID: "h2",
                    chapterIndex: 1,
                    ordinal: 1,
                    title: "Chapter 2",
                    defaultIncluded: true,
                    imagePath: nil,
                    mediaTimestamp: 100,
                    endTimestamp: 200,
                    playlistPosition: nil
                ),
            ],
            now: now
        )
    }
}
```

- [ ] **Step 2: Run DAO test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/StudyPlanDAOTests
```

Expected: FAIL because `StudyPlanDAO` and request/result types do not exist.

- [ ] **Step 3: Implement DAO request/result and methods**

Create `Shared/Database/DAOs/StudyPlanDAO.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanCreationRequest: Sendable {
    let audiobookID: String
    let bookTitle: String
    let cadenceUnit: StudyPlanCadenceUnit
    let newChapterLimit: Int
    let includeImages: Bool
    let queueMode: StudyPlanQueueMode
    let catchUpPolicy: StudyPlanCatchUpPolicy
    let startDate: Date
    let candidates: [StudyPlanCandidate]
    let now: Date
}

struct StudyPlanCreationResult: Sendable {
    let plan: StudyPlan
    let createdCards: [Flashcard]
    let createdItems: [StudyPlanItem]
}

struct StudyPlanDAO {
    let db: DatabaseWriter

    func plan(for audiobookID: String) throws -> StudyPlan? {
        try db.read { db in
            try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func activePlans() throws -> [StudyPlan] {
        try db.read { db in
            try StudyPlan
                .filter(Column("is_paused") == false)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func items(for planID: String) throws -> [StudyPlanItem] {
        try db.read { db in
            try StudyPlanItem
                .filter(Column("plan_id") == planID)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    func createPlan(_ request: StudyPlanCreationRequest) throws -> StudyPlanCreationResult {
        let included = request.candidates.filter(\.defaultIncluded)
        let boundedLimit = max(1, request.newChapterLimit)
        let nowString = request.now.ISO8601Format()
        let startString = request.startDate.ISO8601Format()

        return try db.write { db in
            let deckID = try findOrCreateDeck(named: request.bookTitle, nowString: nowString, db: db)
            var plan = StudyPlan(
                id: UUID().uuidString,
                audiobookID: request.audiobookID,
                deckID: deckID,
                cadenceUnit: request.cadenceUnit.rawValue,
                newChapterLimit: boundedLimit,
                includeImages: request.includeImages,
                queueModeDefault: request.queueMode.rawValue,
                catchUpPolicy: request.catchUpPolicy.rawValue,
                startDate: startString,
                isPaused: false,
                createdAt: nowString,
                modifiedAt: nowString
            )
            try plan.insert(db)

            var createdCards: [Flashcard] = []
            var createdItems: [StudyPlanItem] = []

            for candidate in included {
                if try existingItemCount(sourceBlockID: candidate.sourceBlockID, kind: candidate.kind, db: db) > 0 {
                    continue
                }

                var card = makeFlashcard(
                    request: request,
                    candidate: candidate,
                    deckID: deckID,
                    nowString: nowString
                )
                try card.insert(db)

                var item = StudyPlanItem(
                    id: UUID().uuidString,
                    planID: plan.id,
                    flashcardID: card.id,
                    kind: candidate.kind.rawValue,
                    chapterIndex: candidate.chapterIndex,
                    sourceBlockID: candidate.sourceBlockID,
                    ordinal: candidate.ordinal,
                    introducedAt: nil,
                    isEnabled: true,
                    createdAt: nowString,
                    modifiedAt: nowString
                )
                try item.insert(db)

                createdCards.append(card)
                createdItems.append(item)
            }

            return StudyPlanCreationResult(plan: plan, createdCards: createdCards, createdItems: createdItems)
        }
    }

    func markIntroduced(itemIDs: [String], now: Date = Date()) throws {
        guard !itemIDs.isEmpty else { return }
        let nowString = now.ISO8601Format()
        try db.write { db in
            try StudyPlanItem
                .filter(itemIDs.contains(Column("id")))
                .filter(Column("introduced_at") == nil)
                .updateAll(db, [
                    Column("introduced_at").set(to: nowString),
                    Column("modified_at").set(to: nowString),
                ])
        }
    }

    func updateSettings(
        planID: String,
        cadenceUnit: StudyPlanCadenceUnit,
        newChapterLimit: Int,
        includeImages: Bool,
        queueMode: StudyPlanQueueMode,
        catchUpPolicy: StudyPlanCatchUpPolicy,
        now: Date = Date()
    ) throws {
        try db.write { db in
            try StudyPlan
                .filter(Column("id") == planID)
                .updateAll(db, [
                    Column("cadence_unit").set(to: cadenceUnit.rawValue),
                    Column("new_chapter_limit").set(to: max(1, newChapterLimit)),
                    Column("include_images").set(to: includeImages),
                    Column("queue_mode_default").set(to: queueMode.rawValue),
                    Column("catch_up_policy").set(to: catchUpPolicy.rawValue),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    func setPaused(planID: String, isPaused: Bool, now: Date = Date()) throws {
        try db.write { db in
            try StudyPlan
                .filter(Column("id") == planID)
                .updateAll(db, [
                    Column("is_paused").set(to: isPaused),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    func setItemEnabled(itemID: String, isEnabled: Bool, now: Date = Date()) throws {
        try db.write { db in
            try StudyPlanItem
                .filter(Column("id") == itemID)
                .updateAll(db, [
                    Column("is_enabled").set(to: isEnabled),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    private func findOrCreateDeck(named name: String, nowString: String, db: Database) throws -> String {
        if let existing: String = try String.fetchOne(
            db,
            sql: "SELECT id FROM deck WHERE name = ? ORDER BY created_at LIMIT 1",
            arguments: [name]
        ) {
            return existing
        }

        let id = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'auto', ?, ?)
                """,
            arguments: [id, name, nowString, nowString]
        )
        return id
    }

    private func existingItemCount(sourceBlockID: String, kind: StudyPlanItemKind, db: Database) throws -> Int {
        try StudyPlanItem
            .filter(Column("source_block_id") == sourceBlockID)
            .filter(Column("kind") == kind.rawValue)
            .fetchCount(db)
    }

    private func makeFlashcard(
        request: StudyPlanCreationRequest,
        candidate: StudyPlanCandidate,
        deckID: String,
        nowString: String
    ) -> Flashcard {
        let cardType = candidate.kind == .image
            ? StudyFlashcardType.imageAssignment
            : StudyFlashcardType.listeningAssignment
        let backText = candidate.kind == .image
            ? "Review what this image adds to the chapter."
            : "Review what you retained from this chapter."
        let tag = candidate.kind == .image
            ? "auto study image"
            : "auto study chapter"

        return Flashcard(
            id: UUID().uuidString,
            audiobookID: request.audiobookID,
            frontText: candidate.title,
            backText: backText,
            mediaTimestamp: candidate.mediaTimestamp,
            endTimestamp: candidate.endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: nil,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: deckID,
            tags: tag,
            mediaJSON: encodeMedia(imagePath: candidate.imagePath),
            sourceBlockID: candidate.sourceBlockID,
            playlistPosition: candidate.playlistPosition,
            createdAt: nowString,
            modifiedAt: nowString,
            stability: nil,
            difficulty: nil,
            cardType: cardType,
            clozeIndex: nil
        )
    }

    private func encodeMedia(imagePath: String?) -> String? {
        guard let imagePath else { return nil }
        guard let data = try? JSONEncoder().encode(StudyCardMedia(imagePath: imagePath)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run DAO tests**

Run:

```bash
make test-only FILTER=EchoTests/StudyPlanDAOTests
```

Expected: PASS.

- [ ] **Step 5: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

Run:

```bash
git add Shared/Database/DAOs/StudyPlanDAO.swift EchoTests/StudyPlanDAOTests.swift
git commit -m "feat(study): create study plans transactionally"
```

---

### Task 3: Study Plan Generator Preview

**Files:**
- Create: `Shared/Services/StudyPlanGenerator.swift`
- Modify: `Shared/Services/ChapterCardDrafter.swift`
- Test: `EchoTests/StudyPlanGeneratorTests.swift`
- Test: `EchoTests/ChapterCardDrafterTests.swift`

**Interfaces:**
- Consumes:
  - `StudyPlanCandidate`
  - `StudyPlanPreview`
  - `EPubBlockRecord`
  - `timeline_item.audio_start_time`, `audio_end_time`, `playlist_position`
- Produces:
  - `StudyPlanGenerator.preview(audiobookID:bookTitle:includeImages:) throws -> StudyPlanPreview`
  - `ChapterCardDrafter.draftCards(...)` remains available for compatibility but creates listening-assignment plan rows instead of loose normal cards.

- [ ] **Step 1: Write failing generator tests**

Create `EchoTests/StudyPlanGeneratorTests.swift` with test cases matching this shape:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanGeneratorTests {
    @Test func previewExcludesFrontMatterAndHiddenHeadings() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(audiobookID: "book", bookTitle: "Study Book", includeImages: false)

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
        #expect(preview.candidates.allSatisfy { $0.kind == .chapter })
    }

    @Test func previewIncludesImagesWhenEnabledAndFileExists() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { path in path == "/tmp/diagram.png" })

        let preview = try generator.preview(audiobookID: "book", bookTitle: "Study Book", includeImages: true)

        #expect(preview.candidates.map(\.kind) == [.chapter, .image, .chapter])
        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "img1", "h2"])
    }

    @Test func previewSkipsMissingImages() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in false })

        let preview = try generator.preview(audiobookID: "book", bookTitle: "Study Book", includeImages: true)

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
    }

    @Test func previewCarriesTimelineAudioRange() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(audiobookID: "book", bookTitle: "Study Book", includeImages: false)
        let first = try #require(preview.candidates.first)

        #expect(first.mediaTimestamp == 10)
        #expect(first.endTimestamp == 100)
        #expect(first.playlistPosition == 10)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Study Book', 3600, '2026-06-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO epub_block (
                    id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                    block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                ) VALUES
                ('front', 'book', 'front.xhtml', 0, 0, 0, 'heading', 'Praise', NULL, -1, 0, 1, '2026-06-01T00:00:00Z'),
                ('h1', 'book', 'ch1.xhtml', 1, 0, 1, 'heading', 'Chapter 1', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                ('img1', 'book', 'ch1.xhtml', 1, 1, 2, 'image', NULL, '/tmp/diagram.png', 0, 0, 0, '2026-06-01T00:00:00Z'),
                ('hidden', 'book', 'ch1.xhtml', 1, 2, 3, 'heading', 'Hidden', NULL, 0, 1, 0, '2026-06-01T00:00:00Z'),
                ('h2', 'book', 'ch2.xhtml', 2, 0, 4, 'heading', 'Chapter 2', NULL, 1, 0, 0, '2026-06-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO timeline_item (
                    id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                    granularity_level, playlist_position, is_enabled, epub_block_id
                ) VALUES
                ('t-h1', 'book', 'textSegment', 'Chapter 1', 10, 100, 1, 10, 1, 'h1'),
                ('t-img1', 'book', 'imageAsset', 'Image', 15, NULL, 1, 15, 1, 'img1'),
                ('t-h2', 'book', 'textSegment', 'Chapter 2', 100, 200, 1, 100, 1, 'h2')
                """)
        }
        return service
    }
}
```

- [ ] **Step 2: Run generator test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/StudyPlanGeneratorTests
```

Expected: FAIL because `StudyPlanGenerator` does not exist.

- [ ] **Step 3: Implement generator**

Create `Shared/Services/StudyPlanGenerator.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanGenerator {
    let db: DatabaseWriter
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    func preview(audiobookID: String, bookTitle: String, includeImages: Bool) throws -> StudyPlanPreview {
        let candidates = try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        eb.id,
                        eb.block_kind,
                        eb.text,
                        eb.image_path,
                        eb.chapter_index,
                        eb.sequence_index,
                        COALESCE(ti.audio_start_time, 0) AS media_timestamp,
                        ti.audio_end_time,
                        ti.playlist_position
                    FROM epub_block eb
                    LEFT JOIN timeline_item ti ON ti.epub_block_id = eb.id
                    WHERE eb.audiobook_id = ?
                      AND eb.is_front_matter = 0
                      AND eb.is_hidden = 0
                      AND (
                        eb.block_kind = 'heading'
                        OR (? = 1 AND eb.block_kind = 'image')
                      )
                    ORDER BY eb.sequence_index
                    """,
                arguments: [audiobookID, includeImages]
            )

            return rows.enumerated().compactMap { offset, row -> StudyPlanCandidate? in
                let blockKind: String = row["block_kind"]
                let sourceBlockID: String = row["id"]
                let chapterIndex: Int? = row["chapter_index"]
                let mediaTimestamp: TimeInterval = row["media_timestamp"] ?? 0
                let endTimestamp: TimeInterval? = row["audio_end_time"]
                let playlistPosition: TimeInterval? = row["playlist_position"]

                if blockKind == EPubBlockRecord.Kind.heading.rawValue {
                    let title = (row["text"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return StudyPlanCandidate(
                        id: "chapter-\(sourceBlockID)",
                        kind: .chapter,
                        sourceBlockID: sourceBlockID,
                        chapterIndex: chapterIndex,
                        ordinal: offset,
                        title: title?.isEmpty == false ? title ?? "Chapter" : "Chapter",
                        defaultIncluded: true,
                        imagePath: nil,
                        mediaTimestamp: max(0, mediaTimestamp),
                        endTimestamp: endTimestamp,
                        playlistPosition: playlistPosition
                    )
                }

                guard blockKind == EPubBlockRecord.Kind.image.rawValue,
                      let imagePath = row["image_path"] as String?,
                      fileExists(imagePath) else {
                    return nil
                }

                let chapterLabel = chapterIndex.map { "Chapter \($0 + 1)" } ?? "this chapter"
                return StudyPlanCandidate(
                    id: "image-\(sourceBlockID)",
                    kind: .image,
                    sourceBlockID: sourceBlockID,
                    chapterIndex: chapterIndex,
                    ordinal: offset,
                    title: "Review this image from \(chapterLabel)",
                    defaultIncluded: true,
                    imagePath: imagePath,
                    mediaTimestamp: max(0, mediaTimestamp),
                    endTimestamp: nil,
                    playlistPosition: playlistPosition
                )
            }
        }

        return StudyPlanPreview(audiobookID: audiobookID, bookTitle: bookTitle, candidates: candidates)
    }
}
```

- [ ] **Step 4: Update `ChapterCardDrafter` compatibility path**

Modify `Shared/Services/ChapterCardDrafter.swift` so `draftCards(for:bookTitle:db:)` uses `StudyPlanGenerator.preview(... includeImages: false)` and `StudyPlanDAO.createPlan`.

Keep the public signature unchanged:

```swift
func draftCards(
    for audiobookID: String,
    bookTitle: String,
    db: DatabaseWriter
) async throws -> Int
```

Implementation shape:

```swift
let generator = StudyPlanGenerator(db: db)
let preview = try generator.preview(audiobookID: audiobookID, bookTitle: bookTitle, includeImages: false)
guard !preview.candidates.isEmpty else { return 0 }

if try StudyPlanDAO(db: db).plan(for: audiobookID) != nil {
    return 0
}

let result = try StudyPlanDAO(db: db).createPlan(
    StudyPlanCreationRequest(
        audiobookID: audiobookID,
        bookTitle: bookTitle,
        cadenceUnit: .day,
        newChapterLimit: 1,
        includeImages: false,
        queueMode: .bookByBook,
        catchUpPolicy: .gentle,
        startDate: Date(),
        candidates: preview.candidates,
        now: Date()
    )
)
return result.createdCards.count
```

Update `ChapterCardDrafterTests` expected card type from `"normal"` assumptions to `StudyFlashcardType.listeningAssignment` where the test inspects card type. Existing count/idempotency tests should still pass.

- [ ] **Step 5: Run generator and drafter tests**

Run:

```bash
make test-only FILTER=EchoTests/StudyPlanGeneratorTests
make test-only FILTER=EchoTests/ChapterCardDrafterTests
```

Expected: PASS.

- [ ] **Step 6: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

Run:

```bash
git add Shared/Services/StudyPlanGenerator.swift Shared/Services/ChapterCardDrafter.swift EchoTests/StudyPlanGeneratorTests.swift EchoTests/ChapterCardDrafterTests.swift
git commit -m "feat(study): preview generated chapter assignments"
```

---

### Task 4: Study Queue Builder

**Files:**
- Create: `Shared/Services/StudyQueueBuilder.swift`
- Modify: `Shared/Database/DAOs/FlashcardDAO.swift`
- Test: `EchoTests/StudyQueueBuilderTests.swift`

**Interfaces:**
- Consumes:
  - `StudyPlanDAO.activePlans()`
  - `StudyPlanItem`
  - existing `FlashcardDAO.grade`
- Produces:
  - `FlashcardDAO.allDueCards(now:) throws -> [Flashcard]`
  - `StudyQueueBuilder.build(now:calendar:modeOverride:) throws -> StudyQueue`

- [ ] **Step 1: Add failing queue tests**

Create `EchoTests/StudyQueueBuilderTests.swift` with these cases:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct StudyQueueBuilderTests {
    @Test func dueReviewsPrecedeInProgressAndNewAssignments() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.entries.map(\.category) == [.dueReview, .inProgressAssignment, .newAssignment])
    }

    @Test func dayCadenceIntroducesConfiguredChapterCount() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 1)
    }

    @Test func weekCadenceIntroducesConfiguredChapterCountForWeekWindow() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(cadenceUnit: .week, chapterLimit: 2)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 2)
    }

    @Test func gentleCatchUpDoesNotPileUpMissedChapters() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1, startDaysBeforeNow: 7)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 1)
    }

    @Test func mixedModePreservesNewAssignmentOrderPerBook() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlans()
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            modeOverride: .mixed
        )
        let newCards = queue.entries.filter { $0.category == .newAssignment }.map(\.flashcard.frontText)

        #expect(newCards == ["Book A Chapter 1", "Book B Chapter 1"])
    }
}
```

In the same file, add `StudyQueueFixtures` with helper methods that seed:

- one due normal card with `next_review_date` before `now`
- one introduced assignment item whose card has `repetitions = 0`
- at least two unintroduced chapter assignment items
- two-plan data for mixed ordering

Use `DatabaseService(inMemory: ())` and insert through `StudyPlanDAO.createPlan` where possible, then update `introduced_at` and `next_review_date` with SQL for setup.

- [ ] **Step 2: Run queue tests to verify they fail**

Run:

```bash
make test-only FILTER=EchoTests/StudyQueueBuilderTests
```

Expected: FAIL because `StudyQueueBuilder` and `FlashcardDAO.allDueCards(now:)` do not exist.

- [ ] **Step 3: Add enabled-filtered due helper**

Modify `Shared/Database/DAOs/FlashcardDAO.swift`:

```swift
func allDueCards(now: Date = Date()) throws -> [Flashcard] {
    try db.read { db in
        try Flashcard
            .filter(Column("is_enabled") == true)
            .filter(Column("next_review_date") != nil)
            .filter(Column("next_review_date") <= now.ISO8601Format())
            .order(Column("next_review_date"))
            .fetchAll(db)
    }
}
```

Update existing `allDueCards()` call sites to compile with the default parameter. Also update `dueCards(for:)` and `reviewStats()` to filter `is_enabled == true` and `next_review_date != nil` so generated unintroduced cards are not counted as due.

- [ ] **Step 4: Implement queue builder**

Create `Shared/Services/StudyQueueBuilder.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyQueueBuilder {
    let db: DatabaseWriter

    func build(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil
    ) throws -> StudyQueue {
        let dueCards = try FlashcardDAO(db: db).allDueCards(now: now)
        let plans = try StudyPlanDAO(db: db).activePlans()

        let dueEntries = dueCards.map {
            StudyQueueEntry(id: "due-\($0.id)", category: .dueReview, plan: nil, item: nil, flashcard: $0)
        }

        let assignmentEntries = try plans.flatMap { plan in
            try assignmentEntries(for: plan, now: now, calendar: calendar)
        }

        let mode = modeOverride ?? plans.first.flatMap { StudyPlanQueueMode(rawValue: $0.queueModeDefault) } ?? .bookByBook
        let orderedAssignments = ordered(entries: assignmentEntries, mode: mode)

        return StudyQueue(entries: dueEntries + orderedAssignments)
    }

    private func assignmentEntries(for plan: StudyPlan, now: Date, calendar: Calendar) throws -> [StudyQueueEntry] {
        let rows = try itemCardRows(planID: plan.id)
        let inProgress = rows
            .filter { row in
                row.item.isEnabled
                    && row.item.introducedAt != nil
                    && row.card.repetitions == 0
                    && row.card.lastReviewedAt == nil
            }
            .map { row in
                StudyQueueEntry(
                    id: "progress-\(row.item.id)",
                    category: .inProgressAssignment,
                    plan: plan,
                    item: row.item,
                    flashcard: row.card
                )
            }

        let budget = releaseBudget(plan: plan, rows: rows, now: now, calendar: calendar)
        guard budget > 0 else { return inProgress }

        let pendingChapters = rows
            .filter { row in
                row.item.isEnabled
                    && row.item.introducedAt == nil
                    && row.item.kind == StudyPlanItemKind.chapter.rawValue
            }
            .prefix(budget)

        let pendingChapterIndexes = Set(pendingChapters.compactMap { $0.item.chapterIndex })
        let pendingImages = rows.filter { row in
            row.item.isEnabled
                && row.item.introducedAt == nil
                && row.item.kind == StudyPlanItemKind.image.rawValue
                && row.item.chapterIndex.map { pendingChapterIndexes.contains($0) } == true
        }

        let newRows = (Array(pendingChapters) + pendingImages).sorted { $0.item.ordinal < $1.item.ordinal }
        let newEntries = newRows.map { row in
            StudyQueueEntry(
                id: "new-\(row.item.id)",
                category: .newAssignment,
                plan: plan,
                item: row.item,
                flashcard: row.card
            )
        }

        return inProgress + newEntries
    }

    private func releaseBudget(plan: StudyPlan, rows: [ItemCardRow], now: Date, calendar: Calendar) -> Int {
        let limit = max(1, plan.newChapterLimit)
        let unit = StudyPlanCadenceUnit(rawValue: plan.cadenceUnit) ?? .day
        let windowStart: Date
        switch unit {
        case .day:
            windowStart = calendar.startOfDay(for: now)
        case .week:
            windowStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        }
        let introducedChapterCount = rows.filter { row in
            guard row.item.kind == StudyPlanItemKind.chapter.rawValue,
                  let introducedAt = row.item.introducedAt,
                  let introducedDate = try? Date(introducedAt, strategy: .iso8601) else {
                return false
            }
            return introducedDate >= windowStart && introducedDate <= now
        }.count
        return max(0, limit - introducedChapterCount)
    }

    private func ordered(entries: [StudyQueueEntry], mode: StudyPlanQueueMode) -> [StudyQueueEntry] {
        switch mode {
        case .bookByBook:
            entries.sorted {
                let leftPlan = $0.plan?.createdAt ?? ""
                let rightPlan = $1.plan?.createdAt ?? ""
                if leftPlan != rightPlan { return leftPlan < rightPlan }
                if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                return ($0.item?.ordinal ?? 0) < ($1.item?.ordinal ?? 0)
            }
        case .mixed:
            entries.sorted {
                if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                let leftOrdinal = $0.item?.ordinal ?? 0
                let rightOrdinal = $1.item?.ordinal ?? 0
                if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
                return ($0.plan?.createdAt ?? "") < ($1.plan?.createdAt ?? "")
            }
        }
    }

    private struct ItemCardRow {
        let item: StudyPlanItem
        let card: Flashcard
    }

    private func itemCardRows(planID: String) throws -> [ItemCardRow] {
        try db.read { db in
            let items = try StudyPlanItem
                .filter(Column("plan_id") == planID)
                .filter(Column("is_enabled") == true)
                .order(Column("ordinal"))
                .fetchAll(db)
            let cardIDs = items.compactMap(\.flashcardID)
            let cards = try Flashcard
                .filter(cardIDs.contains(Column("id")))
                .filter(Column("is_enabled") == true)
                .fetchAll(db)
            let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            return items.compactMap { item in
                guard let flashcardID = item.flashcardID,
                      let card = cardsByID[flashcardID] else {
                    return nil
                }
                return ItemCardRow(item: item, card: card)
            }
        }
    }
}
```

- [ ] **Step 5: Run queue tests**

Run:

```bash
make test-only FILTER=EchoTests/StudyQueueBuilderTests
```

Expected: PASS.

- [ ] **Step 6: Run flashcard scheduler tests**

Run:

```bash
make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests
```

Expected: PASS.

- [ ] **Step 7: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

Run:

```bash
git add Shared/Services/StudyQueueBuilder.swift Shared/Database/DAOs/FlashcardDAO.swift EchoTests/StudyQueueBuilderTests.swift
git commit -m "feat(study): build daily study queues"
```

---

### Task 5: Study Session View Model

**Files:**
- Create: `EchoCore/ViewModels/StudySessionViewModel.swift`
- Test: `EchoTests/StudySessionViewModelTests.swift`

**Interfaces:**
- Consumes:
  - `StudyQueueBuilder.build(...)`
  - `StudyPlanDAO.markIntroduced(itemIDs:now:)`
  - `FlashcardDAO.grade(cardID:grade:now:)`
- Produces:
  - `@MainActor @Observable final class StudySessionViewModel`
  - `StudySessionViewModel.loadQueue(now:)`
  - `StudySessionViewModel.gradeCurrent(_:)`
  - `StudySessionViewModel.requestPlayCurrentAssignment()`

- [ ] **Step 1: Write failing view-model tests**

Create `EchoTests/StudySessionViewModelTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct StudySessionViewModelTests {
    @Test func loadQueueMarksNewItemsIntroduced() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let vm = StudySessionViewModel(db: service.writer)

        try vm.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let introduced = try service.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM study_plan_item WHERE introduced_at IS NOT NULL"
            ) ?? 0
        }
        #expect(vm.queue.newAssignmentCount == 1)
        #expect(introduced == 1)
    }

    @Test func gradeCurrentUsesFSRSAndAdvances() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        let vm = StudySessionViewModel(db: service.writer)
        try vm.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        vm.gradeCurrent(.good, now: StudyQueueFixtures.mondayNoon)

        let reviewed = try service.read { db in
            try Flashcard.fetchOne(db, key: "due-card")
        }
        #expect(reviewed?.lastGrade == ReviewGrade.good.rawValue)
        #expect(reviewed?.repetitions == 1)
        #expect(vm.currentIndex == 1)
    }

    @Test func playAssignmentCallsPlaybackClosure() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let vm = StudySessionViewModel(db: service.writer)
        var requestedCardID: String?
        vm.onRequestAssignmentPlayback = { card in requestedCardID = card.id }

        try vm.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        vm.requestPlayCurrentAssignment()

        #expect(requestedCardID == vm.currentEntry?.flashcard.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/StudySessionViewModelTests
```

Expected: FAIL because `StudySessionViewModel` does not exist.

- [ ] **Step 3: Implement view model**

Create `EchoCore/ViewModels/StudySessionViewModel.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudySessionViewModel {
    var queue: StudyQueue = .empty
    var currentIndex: Int = 0
    var isRevealed: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudySessionViewModel")
    @ObservationIgnored var onRequestAssignmentPlayback: ((Flashcard) -> Void)?

    var currentEntry: StudyQueueEntry? {
        guard queue.entries.indices.contains(currentIndex) else { return nil }
        return queue.entries[currentIndex]
    }

    var progress: (current: Int, total: Int) {
        (min(currentIndex + 1, queue.entries.count), queue.entries.count)
    }

    var isComplete: Bool {
        currentIndex >= queue.entries.count
    }

    init(db: DatabaseWriter) {
        self.db = db
    }

    func loadQueue(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil
    ) throws {
        let builder = StudyQueueBuilder(db: db)
        queue = try builder.build(now: now, calendar: calendar, modeOverride: modeOverride)
        currentIndex = 0
        isRevealed = false

        let newItemIDs = queue.entries
            .filter { $0.category == .newAssignment }
            .compactMap { $0.item?.id }
        try StudyPlanDAO(db: db).markIntroduced(itemIDs: newItemIDs, now: now)
        ReviewNotificationService.updateNotification(dueCount: queue.dueReviewCount + queue.inProgressAssignmentCount)
    }

    func reveal() {
        isRevealed = true
    }

    func requestPlayCurrentAssignment() {
        guard let entry = currentEntry,
              entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
                || entry.flashcard.cardType == StudyFlashcardType.imageAssignment else {
            return
        }
        onRequestAssignmentPlayback?(entry.flashcard)
    }

    func gradeCurrent(_ grade: ReviewGrade, now: Date = Date()) {
        guard let entry = currentEntry else { return }
        do {
            try FlashcardDAO(db: db).grade(cardID: entry.flashcard.id, grade: grade.rawValue, now: now)
            logFlashcardReviewed(card: entry.flashcard, grade: grade.rawValue, now: now)
            advance()
            let remaining = max(0, queue.entries.count - currentIndex)
            ReviewNotificationService.updateNotification(dueCount: remaining)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to grade card \(entry.flashcard.id): \(error.localizedDescription)")
        }
    }

    func advance() {
        currentIndex += 1
        isRevealed = false
    }

    private func logFlashcardReviewed(card: Flashcard, grade: Int, now: Date) {
        let dao = RealTimeEventDAO(db: db)
        do {
            let data = try JSONSerialization.data(withJSONObject: ["cardId": card.id, "grade": grade])
            let metaJSON = String(data: data, encoding: .utf8)
            try dao.log(
                id: UUID().uuidString,
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: "Grade: \(grade)",
                metadataJSON: metaJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
        } catch {
            logger.error("Failed to log flashcard review: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run view-model tests**

Run:

```bash
make test-only FILTER=EchoTests/StudySessionViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

Run:

```bash
git add EchoCore/ViewModels/StudySessionViewModel.swift EchoTests/StudySessionViewModelTests.swift
git commit -m "feat(study): add assignment-aware study session model"
```

---

### Task 6: Study Session UI and Playback Delegation

**Files:**
- Create: `EchoCore/Views/StudySessionView.swift`
- Create: `EchoCore/Views/StudyAssignmentCardView.swift`
- Modify: `EchoCore/Views/RootTabView.swift`
- Read: `EchoCore/Views/FlashcardReviewCard.swift`

**Interfaces:**
- Consumes:
  - `StudySessionViewModel`
  - `PlayerModel.loadFolder(_:autoplay:)`
  - `PlayerModel.seek(toSeconds:)`
  - `PlayerModel.play()`
- Produces:
  - a session sheet that handles normal Q/A cards, chapter listening assignments, and image assignments.

- [ ] **Step 1: Add `StudyAssignmentCardView`**

Create `EchoCore/Views/StudyAssignmentCardView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct StudyAssignmentCardView: View {
    let entry: StudyQueueEntry
    let isRevealed: Bool
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onGrade: (ReviewGrade) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(labelTitle, systemImage: labelIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.flashcard.frontText)
                    .font(.title3)
                    .bold()
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let imagePath {
                StudyLocalImageView(path: imagePath, accessibilityLabel: entry.flashcard.frontText)
                    .frame(maxHeight: 260)
            }

            Button("Play Assignment", systemImage: "play.circle.fill", action: onPlay)
                .buttonStyle(.borderedProminent)

            if isRevealed {
                Text(entry.flashcard.backText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                gradeButtons
            } else {
                Button("Review Retention", systemImage: "checkmark.circle", action: onReveal)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private var gradeButtons: some View {
        HStack(spacing: 8) {
            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                Button(grade.label) {
                    onGrade(grade)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var labelTitle: String {
        entry.flashcard.cardType == StudyFlashcardType.imageAssignment ? "Image Assignment" : "Listening Assignment"
    }

    private var labelIcon: String {
        entry.flashcard.cardType == StudyFlashcardType.imageAssignment ? "photo" : "headphones"
    }

    private var imagePath: String? {
        guard entry.flashcard.cardType == StudyFlashcardType.imageAssignment else { return nil }
        guard let mediaJSON = entry.flashcard.mediaJSON,
              let data = mediaJSON.data(using: .utf8),
              let media = try? JSONDecoder().decode(StudyCardMedia.self, from: data) else {
            return nil
        }
        return media.imagePath
    }
}

private struct StudyLocalImageView: View {
    let path: String
    let accessibilityLabel: String

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(contentsOfFile: path) {
            decorated(Image(uiImage: image))
        } else {
            placeholder
        }
        #elseif canImport(AppKit)
        if let image = NSImage(contentsOfFile: path) {
            decorated(Image(nsImage: image))
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private func decorated(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text("Image unavailable"))
    }
}
```

- [ ] **Step 2: Add `StudySessionView`**

Create `EchoCore/Views/StudySessionView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: StudySessionViewModel

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isComplete {
                    ContentUnavailableView(
                        "All Done",
                        systemImage: "checkmark.circle.fill",
                        description: Text("You've finished today's study queue.")
                    )
                } else if let entry = viewModel.currentEntry {
                    progressHeader
                    Spacer(minLength: 16)
                    card(for: entry)
                    Spacer(minLength: 16)
                }
            }
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Study Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Card \(viewModel.progress.current) of \(viewModel.progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(
                value: Double(viewModel.progress.current),
                total: Double(max(1, viewModel.progress.total))
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func card(for entry: StudyQueueEntry) -> some View {
        if entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
            || entry.flashcard.cardType == StudyFlashcardType.imageAssignment {
            StudyAssignmentCardView(
                entry: entry,
                isRevealed: viewModel.isRevealed,
                onPlay: { viewModel.requestPlayCurrentAssignment() },
                onReveal: { viewModel.reveal() },
                onGrade: { viewModel.gradeCurrent($0) }
            )
        } else {
            FlashcardReviewCard(
                frontText: entry.flashcard.frontText,
                backText: entry.flashcard.backText,
                onGrade: { grade in
                    if let reviewGrade = ReviewGrade(rawValue: grade) {
                        viewModel.gradeCurrent(reviewGrade)
                    }
                }
            )
        }
    }
}
```

- [ ] **Step 3: Wire `RootTabView` to launch session**

In `EchoCore/Views/RootTabView.swift`:

1. Replace `@State private var reviewViewModel: DailyReviewViewModel?` with:

```swift
@State private var studySessionViewModel: StudySessionViewModel?
```

2. Replace the review sheet body with:

```swift
.sheet(isPresented: $showingReview) {
    if let vm = studySessionViewModel {
        StudySessionView(viewModel: vm)
    }
}
```

3. Replace `launchReview()` with:

```swift
private func launchStudySession() {
    guard let db = model.databaseService else { return }
    let vm = StudySessionViewModel(db: db.writer)
    vm.onRequestAssignmentPlayback = { [weak model] card in
        guard let model else { return }
        playStudyAssignment(card, model: model)
    }
    do {
        try vm.loadQueue()
        studySessionViewModel = vm
        showingReview = true
    } catch {
        // The session view owns user-visible errors after launch; before launch,
        // fail closed instead of presenting an empty sheet.
        studySessionViewModel = nil
        showingReview = false
    }
}
```

4. Add helper:

```swift
@MainActor
private func playStudyAssignment(_ card: Flashcard, model: PlayerModel) {
    let bookURL = URL(string: card.audiobookID) ?? URL(fileURLWithPath: card.audiobookID)
    if model.folderURL?.absoluteString != card.audiobookID {
        model.loadFolder(bookURL, autoplay: false)
    }
    model.selectedTab = .nowPlaying
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        model.seek(toSeconds: max(0, card.mediaTimestamp + 0.05))
        model.play()
    }
}
```

Use `Task.sleep(for:)`, not `Task.sleep(nanoseconds:)`.

- [ ] **Step 4: Preserve legacy review views unchanged**

Leave `FlashcardReviewSession.swift` unchanged. `RootTabView` no longer launches it after this task, and `StudySessionView` reuses `FlashcardReviewCard` for normal Q/A cards.

- [ ] **Step 5: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

Run:

```bash
git add EchoCore/Views/StudySessionView.swift EchoCore/Views/StudyAssignmentCardView.swift EchoCore/Views/RootTabView.swift
git commit -m "feat(study): present assignment-aware study sessions"
```

---

### Task 7: Study Plan Sheet and Book Settings Entry Point

**Files:**
- Create: `EchoCore/ViewModels/StudyPlanViewModel.swift`
- Create: `EchoCore/Views/StudyPlanSheet.swift`
- Modify: `EchoCore/Views/BookSettingsView.swift`
- Test: build verification

**Interfaces:**
- Consumes:
  - `StudyPlanGenerator.preview(...)`
  - `StudyPlanDAO.plan(for:)`
  - `StudyPlanDAO.createPlan(_:)`
  - `StudyPlanDAO.updateSettings(...)`
  - `StudyPlanDAO.setPaused(...)`
- Produces:
  - Book-scoped Study Plan sheet from Book Settings.

- [ ] **Step 1: Add view model**

Create `EchoCore/ViewModels/StudyPlanViewModel.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudyPlanViewModel {
    var existingPlan: StudyPlan?
    var candidates: [StudyPlanCandidate] = []
    var selectedCandidateIDs: Set<String> = []
    var cadenceUnit: StudyPlanCadenceUnit = .day
    var newChapterLimit: Int = 1
    var includeImages: Bool = false
    var queueMode: StudyPlanQueueMode = .bookByBook
    var isPaused: Bool = false
    var isLoading: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudyPlanViewModel")

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            let dao = StudyPlanDAO(db: db)
            existingPlan = try dao.plan(for: audiobookID)
            if let plan = existingPlan {
                cadenceUnit = StudyPlanCadenceUnit(rawValue: plan.cadenceUnit) ?? .day
                newChapterLimit = plan.newChapterLimit
                includeImages = plan.includeImages
                queueMode = StudyPlanQueueMode(rawValue: plan.queueModeDefault) ?? .bookByBook
                isPaused = plan.isPaused
            }
            let preview = try StudyPlanGenerator(db: db).preview(
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                includeImages: includeImages
            )
            candidates = preview.candidates
            selectedCandidateIDs = Set(preview.includedByDefault.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load study plan: \(error.localizedDescription)")
        }
    }

    func toggleCandidate(_ candidate: StudyPlanCandidate) {
        if selectedCandidateIDs.contains(candidate.id) {
            selectedCandidateIDs.remove(candidate.id)
        } else {
            selectedCandidateIDs.insert(candidate.id)
        }
    }

    func save() {
        do {
            let dao = StudyPlanDAO(db: db)
            if let existingPlan {
                try dao.updateSettings(
                    planID: existingPlan.id,
                    cadenceUnit: cadenceUnit,
                    newChapterLimit: newChapterLimit,
                    includeImages: includeImages,
                    queueMode: queueMode,
                    catchUpPolicy: .gentle
                )
                try dao.setPaused(planID: existingPlan.id, isPaused: isPaused)
            } else {
                let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
                _ = try dao.createPlan(
                    StudyPlanCreationRequest(
                        audiobookID: audiobookID,
                        bookTitle: bookTitle,
                        cadenceUnit: cadenceUnit,
                        newChapterLimit: newChapterLimit,
                        includeImages: includeImages,
                        queueMode: queueMode,
                        catchUpPolicy: .gentle,
                        startDate: Date(),
                        candidates: selected,
                        now: Date()
                    )
                )
                existingPlan = try dao.plan(for: audiobookID)
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to save study plan: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Add Study Plan sheet**

Create `EchoCore/Views/StudyPlanSheet.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudyPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading {
                    ProgressView("Loading Study Plan")
                } else {
                    settingsSection
                    if viewModel.existingPlan == nil {
                        candidatesSection
                    } else {
                        managementSection
                    }
                }
            }
            .navigationTitle("Study Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.existingPlan == nil ? "Create" : "Save") {
                        viewModel.save()
                        if viewModel.errorMessage == nil {
                            dismiss()
                        }
                    }
                    .disabled(viewModel.existingPlan == nil && viewModel.selectedCandidateIDs.isEmpty)
                }
            }
            .alert("Study Plan Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                viewModel.load()
            }
        }
    }

    private var settingsSection: some View {
        Section("Pacing") {
            Picker("Cadence", selection: $viewModel.cadenceUnit) {
                Text("Daily").tag(StudyPlanCadenceUnit.day)
                Text("Weekly").tag(StudyPlanCadenceUnit.week)
            }
            .pickerStyle(.segmented)

            Stepper(value: $viewModel.newChapterLimit, in: 1...12) {
                Text("^[\(viewModel.newChapterLimit) chapter](inflect: true) per \(viewModel.cadenceUnit.rawValue)")
            }

            Toggle("Create picture cards from EPUB images", isOn: $viewModel.includeImages)
                .onChange(of: viewModel.includeImages) { _, _ in
                    viewModel.load()
                }

            Picker("Queue Mode", selection: $viewModel.queueMode) {
                ForEach(StudyPlanQueueMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    private var candidatesSection: some View {
        Section("Chapters") {
            ForEach(viewModel.candidates) { candidate in
                Button {
                    viewModel.toggleCandidate(candidate)
                } label: {
                    HStack {
                        Image(systemName: viewModel.selectedCandidateIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(viewModel.selectedCandidateIDs.contains(candidate.id) ? .tint : .secondary)
                        VStack(alignment: .leading) {
                            Text(candidate.title)
                            Text(candidate.kind == .image ? "Image" : "Chapter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text("Front matter and hidden chapters are excluded before this list is built.")
        }
    }

    private var managementSection: some View {
        Section("Status") {
            Toggle("Paused", isOn: $viewModel.isPaused)
            Text("Existing generated items stay in the review queue until graded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Add Book Settings entry**

Modify `EchoCore/Views/BookSettingsView.swift`:

1. Add state to `BookSettingsView`:

```swift
@State private var showingStudyPlan = false
```

2. Add a new `Section` before `BookOverridesSections(model: model)`:

```swift
Section("Study") {
    Button("Study Plan", systemImage: "rectangle.stack.badge.play") {
        showingStudyPlan = true
    }
    .disabled(model.databaseService == nil || model.folderURL == nil)
}
```

3. Add sheet to the `NavigationStack`:

```swift
.sheet(isPresented: $showingStudyPlan) {
    if let db = model.databaseService?.writer,
       let audiobookID = model.folderURL?.absoluteString {
        StudyPlanSheet(
            viewModel: StudyPlanViewModel(
                audiobookID: audiobookID,
                bookTitle: model.currentTitle,
                db: db
            )
        )
    }
}
```

- [ ] **Step 4: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

Run:

```bash
git add EchoCore/ViewModels/StudyPlanViewModel.swift EchoCore/Views/StudyPlanSheet.swift EchoCore/Views/BookSettingsView.swift
git commit -m "feat(study): add book study plan sheet"
```

---

### Task 8: Dashboard Counts and Review Launch Wiring

**Files:**
- Modify: `EchoCore/Views/RootTabView.swift`
- Modify: `EchoCore/Views/DashboardShelf.swift`
- Modify: `EchoCore/Views/UpcomingReviewsModuleView.swift`
- Test: build verification

**Interfaces:**
- Consumes:
  - `StudyQueueBuilder.build(...)`
  - `RootTabView.launchStudySession()`
- Produces:
  - dashboard review card opens the assignment-aware study session.
  - dashboard count includes due reviews plus in-progress assignments plus newly available assignments.

- [ ] **Step 1: Restore live dashboard shelf**

Add `DashboardShelf` to `RootTabView` above `UnifiedBottomDock` in the root-owned bottom overlay:

```swift
VStack(spacing: 0) {
    Spacer()
    if model.folderURL != nil {
        DashboardShelf(onReviewTap: launchStudySession)
    }
    UnifiedBottomDock(
        onCreateBookmark: { draft in newBookmarkDraft = draft },
        onShowPlaybackOptions: { showingPlaybackOptions = true },
        onShowChapters: { showingChapterPicker = true },
        onShowBookmarks: { model.selectedTab = .read },
        onShowSettings: { showingSettings = true }
    )
    .environment(\.showPlaybackOptions, { showingPlaybackOptions = true })
}
```

- [ ] **Step 2: Update review module count**

Modify `EchoCore/Views/UpcomingReviewsModuleView.swift` to use the study queue:

```swift
@State private var queueCount: Int = 0
@State private var reviewedToday: Int = 0
```

In `loadStats()`:

```swift
guard let db = model.databaseService else { return }
do {
    let stats = try FlashcardDAO(db: db.writer).reviewStats()
    let queue = try StudyQueueBuilder(db: db.writer).build()
    queueCount = queue.totalCount
    reviewedToday = stats.reviewedToday
    ReviewNotificationService.updateNotification(dueCount: queue.dueReviewCount + queue.inProgressAssignmentCount)
} catch {
    queueCount = 0
    reviewedToday = 0
}
```

Update label text:

```swift
Text("\(queueCount)")
    .font(.title2)
    .bold()
    .foregroundStyle(queueCount > 0 ? .purple : .secondary)

Text(queueCount == 0 ? "all caught up" : "tap to study")
    .font(.caption2)
    .foregroundStyle(.secondary)
```

- [ ] **Step 3: Build tests**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

Run:

```bash
git add EchoCore/Views/RootTabView.swift EchoCore/Views/DashboardShelf.swift EchoCore/Views/UpcomingReviewsModuleView.swift
git commit -m "feat(study): wire dashboard study queue"
```

---

### Task 9: Documentation and Release Verification

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`
- Modify: `docs/guides/testflight-beta-guide.md`

**Interfaces:**
- Consumes: finished feature behavior.
- Produces: documented beta test flow and architectural notes.

- [ ] **Step 1: Update README**

Add a short study-plan note to the EPUB/study section:

```markdown
### Auto Study Plans

For EPUB-backed books, Echo can create a Study Plan from Book Settings. A plan generates one listening-assignment card per included chapter, can include image cards for EPUB pictures, and releases new chapter work on a daily or weekly cadence. After the first grade, the existing FSRS review scheduler controls future due dates.
```

- [ ] **Step 2: Update ARCHITECTURE**

Add or update the database/study section with:

```markdown
### Study Plans

`study_plan` stores a book-level generated study configuration: cadence, chapter limit, image inclusion, queue mode, catch-up policy, pause state, and the generated deck. `study_plan_item` stores ordered generated assignments and introduction state. Existing `flashcard` rows remain the review unit; generated assignments keep `next_review_date` nil until first grade, then `FlashcardDAO.grade` schedules them through FSRS.
```

- [ ] **Step 3: Update TestFlight guide**

Add this manual test path to `docs/guides/testflight-beta-guide.md`:

```markdown
### Auto Study Plan Beta Pass

1. Import or open an EPUB-backed book.
2. Open Book Settings and tap Study Plan.
3. Confirm front matter is not selected.
4. Create a plan with 1 chapter per day and image cards enabled.
5. Open the Reviews/Study dashboard card.
6. Confirm due cards appear before new chapter assignments.
7. Play a chapter assignment, reveal the retention prompt, and grade it.
8. Reopen the queue and confirm the graded assignment is no longer shown as new.
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV25Tests
make test-only FILTER=EchoTests/StudyPlanDAOTests
make test-only FILTER=EchoTests/StudyPlanGeneratorTests
make test-only FILTER=EchoTests/StudyQueueBuilderTests
make test-only FILTER=EchoTests/StudySessionViewModelTests
make test-only FILTER=EchoTests/ChapterCardDrafterTests
make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests
```

Expected: PASS.

- [ ] **Step 5: Run full test build**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Run SwiftLint if installed**

Run:

```bash
if command -v swiftlint >/dev/null 2>&1; then swiftlint; else echo "SwiftLint not installed"; fi
```

Expected: either no SwiftLint warnings/errors, or `SwiftLint not installed`.

- [ ] **Step 7: Commit docs**

Run:

```bash
git add README.md ARCHITECTURE.md docs/guides/testflight-beta-guide.md
git commit -m "docs(study): document auto study plans"
```

---

### Task 10: Final Review and PR Against Nightly

**Files:**
- Read: all changed files.
- Modify: only small fixes found during final review.

**Interfaces:**
- Produces: pushed branch and PR targeting `nightly`.

- [ ] **Step 1: Inspect final diff**

Run:

```bash
git status --short --branch
git diff --stat origin/nightly...HEAD
git diff --check origin/nightly...HEAD
```

Expected: clean worktree, no whitespace errors.

- [ ] **Step 2: Review migration safety**

Run:

```bash
sed -n '1,220p' Shared/Database/Migrations/Schema_V25.swift
sed -n '86,130p' Shared/Database/DatabaseService.swift
```

Verify:

- v25 only creates new tables and indexes.
- v25 is registered after v24.
- No shipped migration was edited except registration in `DatabaseService`.

- [ ] **Step 3: Review generated-card invariants**

Run:

```bash
rg -n "listening_assignment|image_assignment|nextReviewDate|introducedAt|StudyQueueCategory" Shared EchoCore EchoTests
```

Verify:

- Generated assignment cards have `nextReviewDate: nil` at creation.
- `StudySessionViewModel.loadQueue` marks new items introduced.
- In-progress assignment query keeps ungraded introduced cards visible.
- Grading uses `FlashcardDAO.grade`.

- [ ] **Step 4: Final build**

Run:

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Push branch**

Run:

```bash
git push -u origin codex/auto-flashcard-study-plan
```

- [ ] **Step 6: Open PR against nightly**

Run:

```bash
gh pr create \
  --base nightly \
  --head codex/auto-flashcard-study-plan \
  --title "Add auto flashcard study plans" \
  --body "$(cat <<'PR_BODY'
## Summary
- Adds GRDB-backed study plans and ordered study plan items for generated chapter/image assignments
- Generates book study plans from EPUB chapters and optional images
- Builds a daily study queue that separates due reviews, in-progress assignments, and new assignments
- Adds SwiftUI plan creation and assignment-aware study session UI

## Tests
- make test-only FILTER=EchoTests/SchemaV25Tests
- make test-only FILTER=EchoTests/StudyPlanDAOTests
- make test-only FILTER=EchoTests/StudyPlanGeneratorTests
- make test-only FILTER=EchoTests/StudyQueueBuilderTests
- make test-only FILTER=EchoTests/StudySessionViewModelTests
- make test-only FILTER=EchoTests/ChapterCardDrafterTests
- make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests
- make build-tests

## Notes
- Generated assignments keep next_review_date nil until first grade; FSRS schedules later reviews.
- PR targets nightly per Echo promotion workflow.
PR_BODY
)"
```

Expected: PR is created with base `nightly`.
