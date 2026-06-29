# M3 — Generated Narration QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** After narrating an EPUB/PDF, let the user run a deterministic "listen back" QA pass that re-transcribes the generated audio, aligns heard-vs-source with TokenDTW, persists reviewable `narration_quality_issue` rows, optionally enriches labels with a triple-gated Foundation Models classifier, and surfaces them in an iOS review screen.

**Architecture:** A pure, device-independent `NarrationQADetector` turns (source blocks + re-transcribed heard words) into `DivergenceWindow`s via `TokenDTW.wordMatchesWithBisection`; a `DivergenceClassifier` protocol (the one justified DI seam: a rule-based `DeterministicDivergenceClassifier` always present + a gated `FoundationModelsDivergenceClassifier` that wraps the deterministic one as a per-issue fallback) labels each window; `NarrationQAService` (`@MainActor`) orchestrates re-transcription via the shared `WhisperSession`, runs the detector, classifies, and persists via `NarrationQualityIssueDAO`. A `narrationQAClassifier` setting and a `DivergenceClassifierFactory` decide which classifier to build. QA is user-initiated (NOT auto-run after render). The iOS `NarrationQAReviewModel`/`NarrationQAReviewView` list issues with expected/heard text and status actions.

**Tech Stack:** Swift 6 (MainActor default isolation on iOS target), SwiftUI, GRDB (SQLite), Swift Testing (`@Suite`/`@Test`/`#expect`), WhisperKit (on-device CoreML ASR), Foundation Models (iOS 26/macOS 26 only, triple-gated), `os.Logger`.

## Global Constraints

- **Deployment floor:** iOS 18.0 / macOS 15.0 / watchOS 11.0. Any Foundation Models code is dark for most users and MUST be triple-gated: `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)` + runtime `SystemLanguageModel.default.availability`. watchOS never compiles FM. The deterministic path is the workhorse.
- **Canonical audiobook id** = `folderURL.absoluteString`. It is the `id` of `AudiobookRecord` (table `audiobook`) and the FK target of `epub_block`, `timeline_item`, `word_timing`, `standalone_transcript`, `alignment_anchor`. NEVER key by `audioFileURL.absoluteString`.
- **WordTokenizer is the single word-boundary authority** (`Shared/WordTokenizer.swift`): `static func wordRanges(in:) -> [Range<String.Index>]`, `static func words(in:) -> [Substring]`. The `word_timing.word_index` producer and the reader highlight MUST both go through it. Whitespace-delimited; punctuation stays attached.
- **DI:** concrete-type + closure/constructor injection (the `DatabaseService(inMemory:)` pattern). Do NOT add a protocol/mock unless two real implementations exist. The ONE justified new protocol is `DivergenceClassifier` (FM impl + deterministic impl).
- **Migrations:** additive-only; new enum `Schema_Vxx` in `Shared/Database/Migrations/`; register in `DatabaseService.runMigrations` before `try migrator.migrate(writer)`; `ifNotExists`; for ADD COLUMN guard with a `db.columns(in:)` existence check; snake_case; FK `.references("audiobook", onDelete: .cascade)`; index `idx_<table>_<cols>`. Re-verify the next free version against `origin/nightly` when the branch opens (V28 is the latest registered; tentatively M1=V29, M3=V30 — re-check) and run the `schema-migration-reviewer` agent before committing the migration. Every migration ships an `EchoTests/SchemaVxxTests.swift`.
- **SPDX:** every new Swift/Swift-test file starts with line 1 `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows the WHOLE file on edit and can push the SPDX header below an import — after any edit, verify SPDX is still line 1.
- **Build/test:** iOS tests via `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. `make` targets run under `CODE_SIGNING_ALLOWED=NO`. 16 GB machine: never run two `xcodebuild`s concurrently and never enable parallel testing; prefix builds with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`. UI-test action stays excluded. Under `CODE_SIGNING_ALLOWED=NO` the iOS-sim Keychain round-trip is flaky — don't add Keychain-dependent tests.
- **Cross-platform parity:** materialization/alignment/QA/overrides are shared logic. Any new UIKit-only or `PlayerModel`-only file must be excluded from BOTH the `Echo macOS` AND the `echo-cli` targets in `Echo.xcodeproj/project.pbxproj` (CI step order masks macOS/cli build breaks behind iOS test passes). Pure `EchoCore/Services` logic with no UIKit import auto-bundles into all targets and needs no exclusion. Run `cross-platform-parity-reviewer` after touching `Shared/`/`EchoCore`.
- **Branching:** branch off `nightly`; commit at checkpoints (Conventional Commits); PR `--base nightly`; never push protected branches.

---

> **Pre-flight (do once, before Task 1):** `git fetch origin && git merge-base --is-ancestor origin/nightly HEAD || git reset --hard origin/nightly`. Re-verify the next free migration version: `grep registerMigration Shared/Database/DatabaseService.swift`. This plan assumes M1's `Schema_V29` (`v29_audiobook_text_origin`) has already landed on `nightly`, so M3 takes **V30**. If `Schema_V29` is NOT yet registered when this branch opens, renumber this milestone's migration to the actual next free integer and rename every `V30`/`v30_` token below accordingly (and tell the user). Then `git switch -c feature/m3-narration-qa`.

---

## Task 1 — Schema_V30 migration: `narration_quality_issue` table + SchemaV30Tests

**Files**
- Create `Shared/Database/Migrations/Schema_V30.swift`
- Modify `Shared/Database/DatabaseService.swift` (insert one `registerMigration` line after the `v28_pdf_block_page` block at :114-116, before `try migrator.migrate(writer)` at :117)
- Create `EchoTests/SchemaV30Tests.swift`

**Interfaces**
- Produces: `enum Schema_V30 { nonisolated static func migrate(_ db: Database) throws }` creating table `narration_quality_issue`.

Steps:

- [ ] **Step 1: Write the failing migration test.** Create `EchoTests/SchemaV30Tests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV30Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v30CreatesNarrationQualityIssueTable() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "narration_quality_issue", db: db)
        for expected in [
            "id", "audiobook_id", "source_block_id", "source_word_start", "source_word_end",
            "audio_start_time", "audio_end_time", "expected_text", "heard_text", "issue_type",
            "confidence", "suggested_fix_json", "status", "created_at", "resolved_at",
        ] {
            #expect(cols.contains(expected))
        }
    }

    @Test func v30CreatesStatusIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try indexNames(table: "narration_quality_issue", db: db)
        #expect(idx.contains("idx_narration_quality_issue_book_status"))
    }
}
```

- [ ] **Step 2: Run it — expect FAIL (table missing).** `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` then `make test-only FILTER=EchoTests/SchemaV30Tests`. Expect failures (`no such table: narration_quality_issue`).

- [ ] **Step 3: Write the migration.** Create `Shared/Database/Migrations/Schema_V30.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V30 — per-book generated-narration QA issues (heard-vs-source divergences).
/// Additive; FK to `audiobook` cascades so issues vanish when a book is deleted.
enum Schema_V30 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "narration_quality_issue", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("source_block_id", .text)
            t.column("source_word_start", .integer)
            t.column("source_word_end", .integer)
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("expected_text", .text).notNull()
            t.column("heard_text", .text).notNull()
            t.column("issue_type", .text).notNull()
            t.column("confidence", .double).notNull()
            t.column("suggested_fix_json", .text)
            t.column("status", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("resolved_at", .text)
        }
        try db.create(
            index: "idx_narration_quality_issue_book_status",
            on: "narration_quality_issue",
            columns: ["audiobook_id", "status"], ifNotExists: true)
    }
}
```
Then register it in `Shared/Database/DatabaseService.swift` immediately after the `v28_pdf_block_page` block (after :116, before :117):
```swift
        migrator.registerMigration("v30_narration_quality_issue") { db in
            try Schema_V30.migrate(db)
        }
```

- [ ] **Step 4: Run it — expect PASS.** `make test-only FILTER=EchoTests/SchemaV30Tests`. Both tests pass. Verify SPDX is line 1 in `Schema_V30.swift` (SwiftFormat hook).

- [ ] **Step 5: Commit.** `git add Shared/Database/Migrations/Schema_V30.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV30Tests.swift && git commit -m "feat(db): add narration_quality_issue table (Schema_V30)"`. Run the `schema-migration-reviewer` agent on the diff before pushing later.

---

## Task 2 — `NarrationQualityIssueRecord` + `NarrationQualityIssueDAO`

**Files**
- Create `Shared/Database/NarrationQualityIssueRecord.swift`
- Create `Shared/Database/DAOs/NarrationQualityIssueDAO.swift`
- Create `EchoTests/NarrationQualityIssueDAOTests.swift`

**Interfaces**
- Produces: `struct NarrationQualityIssueRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord` (fields per contract M3); `struct NarrationQualityIssueDAO { let db: DatabaseWriter; func insert(_:[NarrationQualityIssueRecord]) throws; func issues(for:) throws -> [NarrationQualityIssueRecord]; func issues(for:status:) throws -> [NarrationQualityIssueRecord]; func updateStatus(id:status:resolvedAt:) throws; func deleteAll(for:) throws; func deleteAll(for:blockIDs:) throws }`.
- Consumes: table `narration_quality_issue` (Task 1).

Steps:

- [ ] **Step 1: Write the failing DAO round-trip test.** Create `EchoTests/NarrationQualityIssueDAOTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQualityIssueDAOTests {
    private func seedBook(_ id: String, db: DatabaseService) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, folder_path, title) VALUES (?, ?, ?)",
                arguments: [id, id, "Test"])
        }
    }

    private func make(_ id: String, book: String, status: String) -> NarrationQualityIssueRecord {
        NarrationQualityIssueRecord(
            id: id, audiobookID: book, sourceBlockID: "blk1",
            sourceWordStart: 2, sourceWordEnd: 3, audioStartTime: 1.0, audioEndTime: 2.0,
            expectedText: "colonel", heardText: "kernel",
            issueType: NarrationQAIssueType.substitution.rawValue, confidence: 0.8,
            suggestedFixJSON: nil, status: status,
            createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
    }

    @Test func insertsAndFetchesByBook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open"), make("i2", book: "b1", status: "open")])
        #expect(try dao.issues(for: "b1").count == 2)
    }

    @Test func filtersByStatusAndUpdatesStatus() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.updateStatus(id: "i1", status: "resolved", resolvedAt: "2026-06-29T01:00:00Z")
        #expect(try dao.issues(for: "b1", status: "open").isEmpty)
        #expect(try dao.issues(for: "b1", status: "resolved").count == 1)
    }

    @Test func deletesByBookAndByBlockIDs() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1", blockIDs: ["blk1"])
        #expect(try dao.issues(for: "b1").isEmpty)
        try dao.insert([make("i2", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1")
        #expect(try dao.issues(for: "b1").isEmpty)
    }
}
```
> Note: the `INSERT INTO audiobook` columns (`folder_path`, `title`) mirror the seed used in existing FK-cascade tests; if `audiobook`'s NOT-NULL columns differ on your branch, run `PRAGMA table_info(audiobook)` once and adjust the seed. The cascade FK requires a real parent row.

- [ ] **Step 2: Run it — expect FAIL (types undefined).** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQualityIssueDAOTests`. Expect compile failure (`NarrationQualityIssueRecord` / `NarrationQAIssueType` unresolved).

- [ ] **Step 3a: Write the record.** Create `Shared/Database/NarrationQualityIssueRecord.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// One detected heard-vs-source divergence in generated narration audio.
/// Persisted per book; status survives relaunch. `id` is a UUID string.
struct NarrationQualityIssueRecord: Identifiable, Equatable, Codable, FetchableRecord,
    MutablePersistableRecord
{
    var id: String
    var audiobookID: String
    var sourceBlockID: String?
    var sourceWordStart: Int?
    var sourceWordEnd: Int?
    var audioStartTime: TimeInterval
    var audioEndTime: TimeInterval
    var expectedText: String
    var heardText: String
    var issueType: String
    var confidence: Double
    var suggestedFixJSON: String?
    var status: String
    var createdAt: String
    var resolvedAt: String?

    static let databaseTableName = "narration_quality_issue"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case sourceBlockID = "source_block_id"
        case sourceWordStart = "source_word_start"
        case sourceWordEnd = "source_word_end"
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case expectedText = "expected_text"
        case heardText = "heard_text"
        case issueType = "issue_type"
        case confidence
        case suggestedFixJSON = "suggested_fix_json"
        case status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}

/// Closed vocabulary for `narration_quality_issue.issue_type`.
enum NarrationQAIssueType: String, Sendable {
    case pronunciation
    case omission
    case insertion
    case substitution
    case normalization
    case timingDrift
    case lowConfidence
}

/// Closed vocabulary for `narration_quality_issue.status`.
enum NarrationQAIssueStatus: String, Sendable {
    case open
    case resolved
    case ignored
}
```

- [ ] **Step 3b: Write the DAO.** Create `Shared/Database/DAOs/NarrationQualityIssueDAO.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct NarrationQualityIssueDAO {
    let db: DatabaseWriter

    func insert(_ records: [NarrationQualityIssueRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for var r in records { try r.insert(db) }
        }
    }

    func issues(for audiobookID: String) throws -> [NarrationQualityIssueRecord] {
        try db.read { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    func issues(for audiobookID: String, status: String) throws -> [NarrationQualityIssueRecord] {
        try db.read { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("status") == status)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    func updateStatus(id: String, status: String, resolvedAt: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE narration_quality_issue SET status = ?, resolved_at = ? WHERE id = ?",
                arguments: [status, resolvedAt, id])
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func deleteAll(for audiobookID: String, blockIDs: [String]) throws {
        guard !blockIDs.isEmpty else { return }
        _ = try db.write { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("source_block_id")))
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQualityIssueDAOTests`. All three tests pass. Verify SPDX line 1 on both new files.

- [ ] **Step 5: Commit.** `git add Shared/Database/NarrationQualityIssueRecord.swift Shared/Database/DAOs/NarrationQualityIssueDAO.swift EchoTests/NarrationQualityIssueDAOTests.swift && git commit -m "feat(db): add NarrationQualityIssueRecord + DAO"`.

---

## Task 3 — `DivergenceWindow` + `DivergenceClassification` value types

**Files**
- Create `EchoCore/Services/Narration/QA/DivergenceTypes.swift`
- Create `EchoTests/DivergenceTypesTests.swift`

**Interfaces**
- Produces: `struct DivergenceWindow: Equatable, Sendable { let blockID: String; let expectedText: String; let heardText: String; let expectedWordStart: Int; let expectedWordEnd: Int; let audioStart: TimeInterval; let audioEnd: TimeInterval; let confidence: Double }`; `struct DivergenceClassification: Equatable, Sendable { let issueType: NarrationQAIssueType; let suggestedSpokenForm: String?; let suggestedIPA: String?; let confidence: Double }`.
- Consumes: `NarrationQAIssueType` (Task 2).

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/DivergenceTypesTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct DivergenceTypesTests {
    @Test func windowAndClassificationAreValueEqual() {
        let w1 = DivergenceWindow(
            blockID: "b", expectedText: "colonel", heardText: "kernel",
            expectedWordStart: 2, expectedWordEnd: 3, audioStart: 1.0, audioEnd: 2.0,
            confidence: 0.7)
        let w2 = DivergenceWindow(
            blockID: "b", expectedText: "colonel", heardText: "kernel",
            expectedWordStart: 2, expectedWordEnd: 3, audioStart: 1.0, audioEnd: 2.0,
            confidence: 0.7)
        #expect(w1 == w2)
        let c = DivergenceClassification(
            issueType: .substitution, suggestedSpokenForm: nil, suggestedIPA: nil, confidence: 0.8)
        #expect(c.issueType == .substitution)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL (types undefined).** `make build-tests` then `make test-only FILTER=EchoTests/DivergenceTypesTests`. Expect compile failure.

- [ ] **Step 3: Write the types.** Create `EchoCore/Services/Narration/QA/DivergenceTypes.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A contiguous span where re-transcribed ("heard") narration diverges from the
/// source text. Pure value type produced by `NarrationQADetector`; consumed by a
/// `DivergenceClassifier`. Word indices are over `WordTokenizer.words(in: blockText)`.
struct DivergenceWindow: Equatable, Sendable {
    let blockID: String
    let expectedText: String
    let heardText: String
    let expectedWordStart: Int
    let expectedWordEnd: Int
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    /// Lowest ASR confidence observed in the window (1.0 when none reported).
    let confidence: Double
}

/// A classifier's verdict for one `DivergenceWindow`. The deterministic impl
/// always fills `issueType`/`confidence`; FM may also fill the suggested forms.
struct DivergenceClassification: Equatable, Sendable {
    let issueType: NarrationQAIssueType
    let suggestedSpokenForm: String?
    let suggestedIPA: String?
    let confidence: Double
}

/// Canonical Codable shape persisted in `narration_quality_issue.suggested_fix_json`.
/// Produced by `NarrationQAService.encodeFix` (this milestone) and decoded by
/// `ContributionPayloadFilter` (M5) — this is the single source of truth for that JSON.
/// Keep it minimal: `confidence`/`issueType` already live on the issue row's columns.
struct SuggestedFix: Codable, Equatable, Sendable {
    let spokenForm: String?
    let ipa: String?
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/DivergenceTypesTests`.

- [ ] **Step 5: Commit.** `git add EchoCore/Services/Narration/QA/DivergenceTypes.swift EchoTests/DivergenceTypesTests.swift && git commit -m "feat(narration-qa): add DivergenceWindow + DivergenceClassification value types"`.

---

## Task 4 — `NarrationQADetector` (deterministic, TokenDTW heard-vs-source)

**Files**
- Create `EchoCore/Services/Narration/QA/NarrationQADetector.swift`
- Create `EchoTests/NarrationQADetectorTests.swift`

**Interfaces**
- Produces: `enum NarrationQADetector { static func detect(expectedBlocks: [(blockID: String, text: String)], heardWords: [TranscribedWord], audiobookID: String) -> [DivergenceWindow] }`.
- Consumes: `TokenDTW.EPubToken`, `TokenDTW.AudioToken`, `TokenDTW.normalize`, `TokenDTW.wordMatchesWithBisection` (`EchoCore/Services/TokenDTW.swift`); `TranscribedWord` (`EchoCore/Services/AlignmentTranscript.swift:13`); `WordTokenizer.words(in:)` (`Shared/WordTokenizer.swift`); `DivergenceWindow` (Task 3).

> Design: build `EPubToken`s by `WordTokenizer.words(in: block.text)` → per word emit `TokenDTW.normalize(word)` tokens carrying `blockID` (skip words that normalize to empty, e.g. "a"/"I"/punctuation-only — they carry no alignment signal and are not reportable). Build `AudioToken`s from `heardWords` via `TokenDTW.normalize(word.text)` carrying `word.start`. Run `TokenDTW.wordMatchesWithBisection`. For each block, the matched source-word indices (mapped back through the word→firstNormalizedTokenIndex table) form the "covered" set; maximal runs of *uncovered* consecutive source words become `DivergenceWindow`s (substitution/omission — classified later). `audioStart`/`audioEnd` come from the nearest bracketing matches' `audioTime` (or the block's match-time span); `confidence` is left 1.0 here (ASR per-word confidence is not on `TranscribedWord`; lowConfidence handling is deterministic-classifier territory in Task 5 using gap size). Deterministic + device-independent: same inputs → same windows.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/NarrationQADetectorTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationQADetectorTests {
    // Source sentence; the narrator "heard" version drops "brown" and swaps "lazy"->"crazy".
    private let blocks: [(blockID: String, text: String)] = [
        ("blk1", "the quick brown fox jumps over the lazy dog")
    ]

    private func heard(_ words: [(String, TimeInterval)]) -> [TranscribedWord] {
        words.map { TranscribedWord(text: $0.0, start: $0.1) }
    }

    @Test func cleanReadingProducesNoWindows() {
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("brown", 0.8), ("fox", 1.2), ("jumps", 1.6),
            ("over", 2.0), ("the", 2.4), ("lazy", 2.8), ("dog", 3.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words, audiobookID: "b1")
        #expect(windows.isEmpty)
    }

    @Test func omittedAndSubstitutedWordsBecomeWindows() {
        // "brown" omitted; "lazy" -> "crazy".
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("fox", 0.8), ("jumps", 1.2), ("over", 1.6),
            ("the", 2.0), ("crazy", 2.4), ("dog", 2.8),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words, audiobookID: "b1")
        #expect(!windows.isEmpty)
        // Every window names blk1 and references real source-word indices.
        #expect(windows.allSatisfy { $0.blockID == "blk1" })
        #expect(windows.allSatisfy { $0.expectedWordStart <= $0.expectedWordEnd })
        // The substituted/omitted source words ("brown" idx 2, "lazy" idx 7) are covered.
        let covered = windows.contains { $0.expectedWordStart <= 2 && 2 <= $0.expectedWordEnd }
            || windows.contains { $0.expectedWordStart <= 7 && 7 <= $0.expectedWordEnd }
        #expect(covered)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQADetectorTests`. Expect compile failure (`NarrationQADetector` undefined).

- [ ] **Step 3: Write the detector.** Create `EchoCore/Services/Narration/QA/NarrationQADetector.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, deterministic heard-vs-source divergence detector for generated
/// narration. Reuses the alignment engine (`TokenDTW`) so the issue *set* is
/// device-independent: same source blocks + same heard words -> same windows.
/// Classification (which kind of issue, suggested fixes) is a separate step.
enum NarrationQADetector {
    static func detect(
        expectedBlocks: [(blockID: String, text: String)],
        heardWords: [TranscribedWord],
        audiobookID: String
    ) -> [DivergenceWindow] {
        guard !expectedBlocks.isEmpty, !heardWords.isEmpty else { return [] }

        // Build EPUB tokens + a per-token map back to (blockID, sourceWordIndex).
        var epubTokens: [TokenDTW.EPubToken] = []
        // token position -> (blockID, sourceWordIndex)
        var tokenOrigin: [(blockID: String, wordIndex: Int)] = []
        // blockID -> [sourceWordIndex -> source word string], for window text.
        var blockWords: [String: [String]] = [:]
        for block in expectedBlocks {
            let words = WordTokenizer.words(in: block.text).map(String.init)
            blockWords[block.blockID] = words
            for (wordIndex, word) in words.enumerated() {
                for norm in TokenDTW.normalize(word) {
                    epubTokens.append(TokenDTW.EPubToken(text: norm, blockID: block.blockID))
                    tokenOrigin.append((block.blockID, wordIndex))
                }
            }
        }
        guard !epubTokens.isEmpty else { return [] }

        let audioTokens: [TokenDTW.AudioToken] = heardWords.flatMap { hw in
            TokenDTW.normalize(hw.text).map { TokenDTW.AudioToken(text: $0, time: hw.start) }
        }
        guard !audioTokens.isEmpty else { return [] }

        let matches = TokenDTW.wordMatchesWithBisection(epub: epubTokens, audio: audioTokens)

        // Covered source words per block, and the audio time for each.
        var coveredWords: [String: Set<Int>] = [:]
        var matchAudioTimes: [String: [Int: TimeInterval]] = [:]
        for m in matches {
            coveredWords[m.blockID, default: []].insert(m.wordIndexInBlock)
            matchAudioTimes[m.blockID, default: [:]][m.wordIndexInBlock] = m.audioTime
        }

        var windows: [DivergenceWindow] = []
        for block in expectedBlocks {
            guard let words = blockWords[block.blockID], !words.isEmpty else { continue }
            // A source word is "reportable" only if it contributed at least one
            // normalized token (i.e. it could ever match). Words that normalize to
            // empty ("a", "I", punctuation) are never flagged.
            let reportable = Set(
                tokenOrigin.filter { $0.blockID == block.blockID }.map { $0.wordIndex })
            let covered = coveredWords[block.blockID] ?? []
            let times = matchAudioTimes[block.blockID] ?? [:]

            var run: [Int] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                let start = nearestTime(before: first, in: times) ?? times.values.min() ?? 0
                let end = nearestTime(after: last, in: times) ?? times.values.max() ?? start
                let expected = words[first...last].joined(separator: " ")
                windows.append(
                    DivergenceWindow(
                        blockID: block.blockID,
                        expectedText: expected,
                        heardText: "",
                        expectedWordStart: first,
                        expectedWordEnd: last,
                        audioStart: start,
                        audioEnd: max(end, start),
                        confidence: 1.0))
                run = []
            }
            for idx in words.indices {
                let isGap = reportable.contains(idx) && !covered.contains(idx)
                if isGap {
                    run.append(idx)
                } else {
                    flush()
                }
            }
            flush()
        }
        return windows
    }

    private static func nearestTime(before index: Int, in times: [Int: TimeInterval]) -> TimeInterval? {
        times.keys.filter { $0 < index }.max().flatMap { times[$0] }
    }

    private static func nearestTime(after index: Int, in times: [Int: TimeInterval]) -> TimeInterval? {
        times.keys.filter { $0 > index }.min().flatMap { times[$0] }
    }
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQADetectorTests`. Both tests pass. (If the clean-reading test reports a spurious window, the run is likely from a normalized-token boundary; confirm `reportable` excludes short-word tokens — adjust the fixture, not the engine.) Verify SPDX line 1.

- [ ] **Step 5: Commit.** `git add EchoCore/Services/Narration/QA/NarrationQADetector.swift EchoTests/NarrationQADetectorTests.swift && git commit -m "feat(narration-qa): add deterministic NarrationQADetector"`.

---

## Task 5 — `DivergenceClassifier` protocol + `DeterministicDivergenceClassifier`

**Files**
- Create `EchoCore/Services/Narration/QA/DivergenceClassifier.swift`
- Create `EchoTests/DeterministicDivergenceClassifierTests.swift`

**Interfaces**
- Produces: `protocol DivergenceClassifier: Sendable { func classify(_ window: DivergenceWindow) async -> DivergenceClassification }`; `struct DeterministicDivergenceClassifier: DivergenceClassifier`.
- Consumes: `DivergenceWindow`, `DivergenceClassification`, `NarrationQAIssueType`.

> Rules (pure, device-independent): empty `heardText` and non-empty `expectedText` → `.omission`; non-empty `heardText` & non-empty `expectedText` of equal word count → `.substitution`; single expected word that looks like a hard proper-noun/acronym (all-caps or mixed-case interior capitals) → `.pronunciation`; `confidence < 0.5` → `.lowConfidence`; default → `.substitution`. No suggested IPA/spoken-form in the deterministic path (that is FM's enrichment). The deterministic classifier never crashes and is `Sendable` (no stored mutable state).

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/DeterministicDivergenceClassifierTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct DeterministicDivergenceClassifierTests {
    private func window(expected: String, heard: String, confidence: Double = 1.0) -> DivergenceWindow {
        DivergenceWindow(
            blockID: "b", expectedText: expected, heardText: heard,
            expectedWordStart: 0, expectedWordEnd: 0, audioStart: 0, audioEnd: 1,
            confidence: confidence)
    }

    @Test func emptyHeardIsOmission() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "brown", heard: ""))
        #expect(r.issueType == .omission)
        #expect(r.suggestedIPA == nil)
    }

    @Test func lowConfidenceWins() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "fox", heard: "fix", confidence: 0.3))
        #expect(r.issueType == .lowConfidence)
    }

    @Test func properNounIsPronunciation() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "Colonel", heard: "kernel"))
        #expect(r.issueType == .pronunciation)
    }

    @Test func defaultIsSubstitution() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "lazy", heard: "crazy"))
        #expect(r.issueType == .substitution)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/DeterministicDivergenceClassifierTests`. Expect compile failure (`DeterministicDivergenceClassifier` undefined).

- [ ] **Step 3: Write the protocol + deterministic impl.** Create `EchoCore/Services/Narration/QA/DivergenceClassifier.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The single justified DI seam in M3 (two real impls: deterministic always-on,
/// Foundation Models gated). Given an already-detected `DivergenceWindow`, return
/// a label + optional suggested fix. Classification never *detects* — detection
/// is `NarrationQADetector`'s deterministic job.
protocol DivergenceClassifier: Sendable {
    func classify(_ window: DivergenceWindow) async -> DivergenceClassification
}

/// Rule-based, always-available classifier. Pure + `Sendable` (no stored state),
/// so the QA issue *set and labels* are reproducible across devices and CI.
struct DeterministicDivergenceClassifier: DivergenceClassifier {
    func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
        let issueType = Self.label(for: window)
        return DivergenceClassification(
            issueType: issueType, suggestedSpokenForm: nil, suggestedIPA: nil,
            confidence: window.confidence)
    }

    static func label(for window: DivergenceWindow) -> NarrationQAIssueType {
        if window.confidence < 0.5 { return .lowConfidence }
        let expected = window.expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = window.heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty, !expected.isEmpty { return .omission }
        if expected.isEmpty, !heard.isEmpty { return .insertion }
        if looksLikeProperNounOrAcronym(expected) { return .pronunciation }
        return .substitution
    }

    private static func looksLikeProperNounOrAcronym(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count == 1, let word = words.first else { return false }
        // All-caps acronym (>=2 letters) or interior capital (CamelCase proper noun).
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        let interior = letters.dropFirst()
        return interior.contains(where: \.isUppercase)
    }
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/DeterministicDivergenceClassifierTests`. All four pass. Verify SPDX line 1.

- [ ] **Step 5: Commit.** `git add EchoCore/Services/Narration/QA/DivergenceClassifier.swift EchoTests/DeterministicDivergenceClassifierTests.swift && git commit -m "feat(narration-qa): add DivergenceClassifier protocol + deterministic impl"`.

---

## Task 6 — Gated `FoundationModelsDivergenceClassifier` + `DivergenceClassifierFactory`

**Files**
- Create `EchoCore/Services/Narration/QA/FoundationModelsDivergenceClassifier.swift`
- Create `EchoCore/Services/Narration/QA/DivergenceClassifierFactory.swift`
- Create `EchoTests/DivergenceClassifierFactoryTests.swift`

**Interfaces**
- Produces: (gated) `FoundationModelsDivergenceClassifier: DivergenceClassifier` wrapping `fallback: DivergenceClassifier`; `enum DivergenceClassifierFactory { @MainActor static func make(preference: String, availabilityIsAvailable: Bool) -> DivergenceClassifier }`.
- Consumes: `DivergenceClassifier`, `DeterministicDivergenceClassifier`; the contract FM gating snippet; `NarrationQAIssueType`.

> Gating: the FM type's entire body is inside `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)`. The factory returns the FM-wrapped-deterministic classifier ONLY when `preference == "auto"` AND `availabilityIsAvailable == true` AND the FM type is compiled in AND the running OS satisfies `if #available(iOS 26, macOS 26, *)`; otherwise it returns `DeterministicDivergenceClassifier()`. `availabilityIsAvailable` is computed by the caller (Task 7 / settings UI) from `SystemLanguageModel.default.availability`, so the factory itself stays unit-testable on the iOS-18 sim (CI) without ever touching FM. The FM `classify` falls back to `fallback.classify(window)` on EVERY `GenerationError` and any throw.

Steps:

- [ ] **Step 1: Write the failing factory test (CI-runnable; no FM at runtime).** Create `EchoTests/DivergenceClassifierFactoryTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor @Suite struct DivergenceClassifierFactoryTests {
    private func window() -> DivergenceWindow {
        DivergenceWindow(
            blockID: "b", expectedText: "lazy", heardText: "crazy",
            expectedWordStart: 0, expectedWordEnd: 0, audioStart: 0, audioEnd: 1, confidence: 1.0)
    }

    @Test func deterministicPreferenceAlwaysReturnsDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "deterministic", availabilityIsAvailable: true)
        #expect(c is DeterministicDivergenceClassifier)
        // Still classifies.
        let r = await c.classify(window())
        #expect(r.issueType == .substitution)
    }

    @Test func autoButUnavailableFallsBackToDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "auto", availabilityIsAvailable: false)
        #expect(c is DeterministicDivergenceClassifier)
    }

    @Test func unknownPreferenceFallsBackToDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "garbage", availabilityIsAvailable: true)
        #expect(c is DeterministicDivergenceClassifier)
    }
}
```
> On the iOS-18 CI sim, the `auto + available` branch also resolves to deterministic because `if #available(iOS 26, ...)` is false at runtime; that case isn't asserted here (it's covered by the device/TestFlight FM tests noted in Task 11). These three assertions are all deterministic and device-independent.

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/DivergenceClassifierFactoryTests`. Expect compile failure (`DivergenceClassifierFactory` undefined).

- [ ] **Step 3a: Write the gated FM classifier.** Create `EchoCore/Services/Narration/QA/FoundationModelsDivergenceClassifier.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels

/// Structured output for the FM classifier. Constrained decoding fills these —
/// no manual JSON parsing. `kind` is validated back into `NarrationQAIssueType`;
/// an unknown string falls through to the deterministic label.
@available(iOS 26, macOS 26, *)
@Generable
struct IssueClassification {
    @Guide(
        description:
            "One of: pronunciation, omission, insertion, substitution, normalization, timingDrift, lowConfidence"
    )
    let kind: String
    let suggestedSpokenForm: String?
    let suggestedIPA: String?
    @Guide(.range(0...1))
    let confidence: Double
}

/// Gated enrichment classifier. Re-labels and suggests fixes for an
/// already-detected window; wraps the deterministic classifier as a per-issue
/// fallback so any FM error degrades to the deterministic label (never a crash).
@available(iOS 26, macOS 26, *)
struct FoundationModelsDivergenceClassifier: DivergenceClassifier {
    let fallback: DivergenceClassifier
    private static let logger = Logger(category: "NarrationQA.FM")

    private static let instructions =
        "You classify a single text-to-speech narration mistake. You are given the expected "
        + "source words and what an automatic transcriber heard. Choose the single best kind and, "
        + "for a pronunciation error, optionally suggest a corrected spoken spelling and IPA. "
        + "Never invent words that are not implied by the inputs."

    func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
        let det = await fallback.classify(window)
        // Only book/transcript-derived text goes in the PROMPT, never instructions.
        let prompt =
            "Expected: \"\(window.expectedText)\"\nHeard: \"\(window.heardText)\"\n"
            + "Deterministic guess: \(det.issueType.rawValue)."
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: prompt, generating: IssueClassification.self,
                options: GenerationOptions(sampling: .greedy))
            let content = response.content
            let kind = NarrationQAIssueType(rawValue: content.kind) ?? det.issueType
            return DivergenceClassification(
                issueType: kind,
                suggestedSpokenForm: content.suggestedSpokenForm,
                suggestedIPA: content.suggestedIPA,
                confidence: content.confidence)
        } catch let error as LanguageModelSession.GenerationError {
            Self.logger.error("FM classify fell back: \(String(describing: error))")
            return det
        } catch {
            Self.logger.error("FM classify fell back (other): \(error.localizedDescription)")
            return det
        }
    }
}
#endif
```
> If `LanguageModelSession.GenerationError` is not the exact error type name on the SDK build, the second `catch` still guarantees fallback — do not let the file fail to compile chasing the exact enum; the bare `catch` is the safety net the spec requires.

- [ ] **Step 3b: Write the factory.** Create `EchoCore/Services/Narration/QA/DivergenceClassifierFactory.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides which `DivergenceClassifier` to build. FM-wrapped-deterministic is
/// returned ONLY when preference is "auto", FM reports available, the FM path is
/// compiled in, and the running OS is iOS 26 / macOS 26+. Otherwise deterministic.
/// `availabilityIsAvailable` is supplied by the caller (computed from
/// `SystemLanguageModel.default.availability`) so this stays testable off-device.
enum DivergenceClassifierFactory {
    @MainActor
    static func make(preference: String, availabilityIsAvailable: Bool) -> DivergenceClassifier {
        let deterministic = DeterministicDivergenceClassifier()
        guard preference == "auto", availabilityIsAvailable else { return deterministic }
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return FoundationModelsDivergenceClassifier(fallback: deterministic)
        }
        #endif
        return deterministic
    }
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/DivergenceClassifierFactoryTests`. All three pass. Verify SPDX line 1 on both new files (the FM file's `import Foundation` must not displace the SPDX header — the hook can reorder; re-check).

- [ ] **Step 5: Cross-platform note + commit.** These two files are pure `EchoCore/Services` (no UIKit/PlayerModel import) so they auto-bundle into macOS/echo-cli/watch — no `project.pbxproj` exclusion needed, but watchOS must still not compile FM: the `#if canImport(FoundationModels)` guard already excludes it there (watchOS has no FoundationModels). Commit: `git add EchoCore/Services/Narration/QA/FoundationModelsDivergenceClassifier.swift EchoCore/Services/Narration/QA/DivergenceClassifierFactory.swift EchoTests/DivergenceClassifierFactoryTests.swift && git commit -m "feat(narration-qa): add gated FM classifier + factory"`.

---

## Task 7 — `narrationQAClassifier` setting (SettingsManager 4-edit)

**Files**
- Modify `EchoCore/Services/SettingsManager.swift` (4 coordinated edits: `Defaults` enum :66 region, `Keys` enum :130 region, stored property :343 region, init + `registerDefaults` :752 / :758 region)
- Create `EchoTests/SettingsNarrationQAClassifierTests.swift`

**Interfaces**
- Produces: `SettingsManager.narrationQAClassifier: String` (values `"auto"` | `"deterministic"`, default `"auto"`).

> Mirror the existing `autoAlignmentModelSize` String setting exactly. Uses `defaults` (UserDefaults.standard), NOT the app-group store.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/SettingsNarrationQAClassifierTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor @Suite struct SettingsNarrationQAClassifierTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.narrationQAClassifier.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsToAuto() {
        let settings = SettingsManager(defaults: freshDefaults())
        #expect(settings.narrationQAClassifier == "auto")
    }

    @Test func persistsWrite() {
        let d = freshDefaults()
        let a = SettingsManager(defaults: d)
        a.narrationQAClassifier = "deterministic"
        let b = SettingsManager(defaults: d)
        #expect(b.narrationQAClassifier == "deterministic")
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/SettingsNarrationQAClassifierTests`. Expect compile failure (`narrationQAClassifier` undefined).

- [ ] **Step 3: Apply the 4 edits to `SettingsManager.swift`.**
  - (1) In `enum Defaults`, after `static let autoAlignmentModelSize = "base.en"` (:66), add: `static let narrationQAClassifier = "auto"`.
  - (2) In `private enum Keys`, after `static let autoAlignmentModelSize = "autoAlignmentModelSize"` (:130), add: `static let narrationQAClassifier = "narrationQAClassifier"`.
  - (3) After the `autoAlignmentModelSize` stored property (:343-345), add:
```swift
    var narrationQAClassifier: String {
        didSet { defaults.set(narrationQAClassifier, forKey: Keys.narrationQAClassifier) }
    }
```
  - (4a) In `init`, after the `autoAlignmentModelSize = ...` assignment (:660-661), add:
```swift
        narrationQAClassifier =
            defaults.string(forKey: Keys.narrationQAClassifier) ?? Defaults.narrationQAClassifier
```
  - (4b) In `registerDefaults`'s `defaults.register(defaults: [...])`, after `Keys.autoAlignmentModelSize: Defaults.autoAlignmentModelSize,` (:752), add: `Keys.narrationQAClassifier: Defaults.narrationQAClassifier,`.

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/SettingsNarrationQAClassifierTests`. Both pass. Verify SPDX line 1 still intact on `SettingsManager.swift` after the edits.

- [ ] **Step 5: Commit.** `git add EchoCore/Services/SettingsManager.swift EchoTests/SettingsNarrationQAClassifierTests.swift && git commit -m "feat(settings): add narrationQAClassifier preference (auto|deterministic)"`.

---

## Task 8 — `NarrationQAService.runQA` (re-transcribe, detect, classify, persist)

**Files**
- Create `EchoCore/Services/Narration/QA/NarrationQAService.swift`
- Create `EchoTests/NarrationQAServiceTests.swift`

**Interfaces**
- Produces: `@MainActor final class NarrationQAService { init(db: DatabaseWriter, classifier: DivergenceClassifier, transcribe: @escaping @Sendable (_ fileURL: URL) async -> [TranscribedWord] = NarrationQAService.whisperTranscribe); func runQA(audiobookID: String, chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]) async throws }`.
- Consumes: `NarrationQADetector.detect`, `DivergenceClassifier`, `NarrationQualityIssueDAO`, `EPubBlockDAO.blocks(for:)` (to fetch source text for the chapter's `spokenBlockIDs`), `WhisperSession.shared.acquire/release`, `AlignmentTranscript.transcribeWords` + `AudioSegmentReader.samples` for the default transcribe closure, `NarrationQAIssueStatus`.

> The injected `transcribe` closure is the WhisperKit seam — the default calls the real model; tests inject a stub of canned `TranscribedWord`s so they run on CI with NO model load. This is concrete-type + closure injection (the approved DI pattern), not protocol theater. `runQA` clears this book's prior issues for the touched `spokenBlockIDs` (via `deleteAll(for:blockIDs:)`) before rewriting so re-runs converge. NOT auto-run by any render path — only an explicit caller invokes it.

Steps:

- [ ] **Step 1: Write the failing test (stubbed transcribe, no WhisperKit).** Create `EchoTests/NarrationQAServiceTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAServiceTests {
    private func seed(_ db: DatabaseService, book: String) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, folder_path, title) VALUES (?, ?, ?)",
                arguments: [book, book, "Test"])
        }
        // One source block whose words the narrator will partly drop/swap.
        let dao = EPubBlockDAO(db: db.writer)
        try dao.insert(
            EPubBlockRecord(
                id: "blk1", audiobookID: book, spineHref: "s.html", spineIndex: 0, blockIndex: 0,
                sequenceIndex: 0, blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                text: "the quick brown fox jumps over the lazy dog", htmlContent: nil,
                cardColor: nil, chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
                isHidden: false, hiddenReason: nil, wordCount: 9, markers: nil, textFormats: nil,
                createdAt: nil, modifiedAt: nil))
    }

    @Test func plantedErrorProducesIssueDeterministically() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        // "brown" omitted, "lazy" -> "crazy".
        let heard: [TranscribedWord] = [
            ("the", 0.0), ("quick", 0.4), ("fox", 0.8), ("jumps", 1.2), ("over", 1.6),
            ("the", 2.0), ("crazy", 2.4), ("dog", 2.8),
        ].map { TranscribedWord(text: $0.0, start: $0.1) }

        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })

        let fileURL = URL(fileURLWithPath: "/tmp/does-not-matter.m4a")
        try await service.runQA(
            audiobookID: "b1",
            chapters: [(chapterIndex: 0, fileURL: fileURL, spokenBlockIDs: ["blk1"])])

        let issues = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1")
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.status == NarrationQAIssueStatus.open.rawValue })
        #expect(issues.allSatisfy { $0.sourceBlockID == "blk1" })
    }

    @Test func reRunReplacesPriorIssuesForBlock() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let heard: [TranscribedWord] = [("the", 0.0), ("quick", 0.4), ("dog", 0.8)]
            .map { TranscribedWord(text: $0.0, start: $0.1) }
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })
        let fileURL = URL(fileURLWithPath: "/tmp/x.m4a")
        try await service.runQA(
            audiobookID: "b1", chapters: [(0, fileURL, ["blk1"])])
        let firstCount = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1").count
        try await service.runQA(
            audiobookID: "b1", chapters: [(0, fileURL, ["blk1"])])
        let secondCount = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1").count
        #expect(firstCount == secondCount)  // cleared + rewritten, not doubled
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQAServiceTests`. Expect compile failure (`NarrationQAService` undefined).

- [ ] **Step 3: Write the service.** Create `EchoCore/Services/Narration/QA/NarrationQAService.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// User-initiated "listen back" QA for generated narration. For each rendered
/// chapter: re-transcribe the audio, detect heard-vs-source divergences with the
/// deterministic `NarrationQADetector`, label each window with the injected
/// `DivergenceClassifier`, and persist `narration_quality_issue` rows. NOT
/// auto-run after render; the QA pass never mutates the rendered audio.
@MainActor
final class NarrationQAService {
    private let db: DatabaseWriter
    private let classifier: DivergenceClassifier
    private let transcribe: @Sendable (_ fileURL: URL) async -> [TranscribedWord]
    private let logger = Logger(category: "NarrationQA")
    private static let iso = ISO8601DateFormatter()

    init(
        db: DatabaseWriter,
        classifier: DivergenceClassifier,
        transcribe: @escaping @Sendable (_ fileURL: URL) async -> [TranscribedWord] =
            NarrationQAService.whisperTranscribe
    ) {
        self.db = db
        self.classifier = classifier
        self.transcribe = transcribe
    }

    func runQA(
        audiobookID: String,
        chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]
    ) async throws {
        let blockDAO = EPubBlockDAO(db: db)
        let issueDAO = NarrationQualityIssueDAO(db: db)
        let allBlocks = try blockDAO.blocks(for: audiobookID)
        let blocksByID = Dictionary(uniqueKeysWithValues: allBlocks.map { ($0.id, $0) })
        let now = Self.iso.string(from: Date())

        for chapter in chapters {
            // Clear this chapter's prior issues so a re-run converges.
            try issueDAO.deleteAll(for: audiobookID, blockIDs: chapter.spokenBlockIDs)

            let expectedBlocks: [(blockID: String, text: String)] = chapter.spokenBlockIDs.compactMap {
                id in
                guard let text = blocksByID[id]?.text, !text.isEmpty else { return nil }
                return (id, text)
            }
            guard !expectedBlocks.isEmpty else { continue }

            let heard = await transcribe(chapter.fileURL)
            guard !heard.isEmpty else {
                logger.notice("QA chapter \(chapter.chapterIndex): no heard words; skipping")
                continue
            }

            let windows = NarrationQADetector.detect(
                expectedBlocks: expectedBlocks, heardWords: heard, audiobookID: audiobookID)

            var records: [NarrationQualityIssueRecord] = []
            for window in windows {
                let c = await classifier.classify(window)
                let fixJSON = Self.encodeFix(c)
                records.append(
                    NarrationQualityIssueRecord(
                        id: UUID().uuidString,
                        audiobookID: audiobookID,
                        sourceBlockID: window.blockID,
                        sourceWordStart: window.expectedWordStart,
                        sourceWordEnd: window.expectedWordEnd,
                        audioStartTime: window.audioStart,
                        audioEndTime: window.audioEnd,
                        expectedText: window.expectedText,
                        heardText: window.heardText,
                        issueType: c.issueType.rawValue,
                        confidence: c.confidence,
                        suggestedFixJSON: fixJSON,
                        status: NarrationQAIssueStatus.open.rawValue,
                        createdAt: now,
                        resolvedAt: nil))
            }
            try issueDAO.insert(records)
            logger.notice("QA chapter \(chapter.chapterIndex): \(records.count) issues")
        }
    }

    private static func encodeFix(_ c: DivergenceClassification) -> String? {
        guard c.suggestedSpokenForm != nil || c.suggestedIPA != nil else { return nil }
        // Encode the shared, typed SuggestedFix (NOT a manual dict) so M5's
        // ContributionPayloadFilter decodes the exact same shape.
        let fix = SuggestedFix(spokenForm: c.suggestedSpokenForm, ipa: c.suggestedIPA)
        return (try? JSONEncoder().encode(fix)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Default transcribe seam: reads the whole file and runs the shared
    /// WhisperKit model (same options the alignment pipeline uses). Returns []
    /// on any failure so QA degrades to "no issues found" rather than crashing.
    static func whisperTranscribe(fileURL: URL) async -> [TranscribedWord] {
        do {
            let duration = try await Self.fileDuration(fileURL)
            let samples = try await AudioSegmentReader.samples(
                from: fileURL, at: 0, duration: duration)
            guard !samples.isEmpty else { return [] }
            let wk = try await WhisperSession.shared.acquire()
            defer { WhisperSession.shared.release() }
            return await AlignmentTranscript.transcribeWords(
                with: wk, samples: samples, captureStart: 0)
        } catch {
            Logger(category: "NarrationQA").error(
                "whisperTranscribe failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func fileDuration(_ fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let d = try await asset.load(.duration)
        return CMTimeGetSeconds(d)
    }
}

import AVFoundation
```
> Move `import AVFoundation` to the top with the other imports if the SwiftFormat hook doesn't (keep SPDX line 1). `EPubBlockDAO.blocks(for:)`, `AlignmentTranscript.transcribeWords`, and `AudioSegmentReader.samples` are all existing verified signatures. The whole file is pure `EchoCore/Services` (no UIKit/PlayerModel import) → auto-bundles into all targets, no pbxproj change.

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQAServiceTests`. Both pass (no WhisperKit loaded — the stub closure is used). Verify SPDX line 1.

- [ ] **Step 5: Commit.** `git add EchoCore/Services/Narration/QA/NarrationQAService.swift EchoTests/NarrationQAServiceTests.swift && git commit -m "feat(narration-qa): add NarrationQAService runQA orchestration"`.

---

## Task 9 — `NarrationQAReviewModel` (iOS @Observable)

**Files**
- Create `EchoCore/ViewModels/NarrationQAReviewModel.swift`
- Modify `Echo.xcodeproj/project.pbxproj` (add `ViewModels/NarrationQAReviewModel.swift` to the `Echo macOS` AND `echo-cli` EchoCore `membershipExceptions` lists if the model imports UIKit/PlayerModel; see note)
- Create `EchoTests/NarrationQAReviewModelTests.swift`

**Interfaces**
- Produces: `@MainActor @Observable final class NarrationQAReviewModel { var issues: [NarrationQualityIssueRecord]; init(db: DatabaseWriter, audiobookID: String); func load(); func ignore(_ issue: NarrationQualityIssueRecord); func markResolved(_ issue: NarrationQualityIssueRecord) }`.
- Consumes: `NarrationQualityIssueDAO`, `NarrationQAIssueStatus`.

> Keep the model pure-Foundation (no UIKit import) so it auto-bundles everywhere and needs NO pbxproj exclusion — mirror `DailyReviewViewModel` (injects `DatabaseWriter`, `@MainActor @Observable`). Save-override / regenerate actions are M4; this model only does ignore/resolve + refresh. If the model genuinely must import UIKit later it would need the exclusion — it does not here, so skip the pbxproj edit (note it in the commit).

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/NarrationQAReviewModelTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAReviewModelTests {
    private func seed(_ db: DatabaseService, book: String) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, folder_path, title) VALUES (?, ?, ?)",
                arguments: [book, book, "Test"])
        }
        try NarrationQualityIssueDAO(db: db.writer).insert([
            NarrationQualityIssueRecord(
                id: "i1", audiobookID: book, sourceBlockID: "blk1", sourceWordStart: 0,
                sourceWordEnd: 1, audioStartTime: 0, audioEndTime: 1, expectedText: "colonel",
                heardText: "kernel", issueType: NarrationQAIssueType.substitution.rawValue,
                confidence: 0.8, suggestedFixJSON: nil,
                status: NarrationQAIssueStatus.open.rawValue, createdAt: "t", resolvedAt: nil)
        ])
    }

    @Test func loadShowsOpenIssues() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        #expect(model.issues.count == 1)
    }

    @Test func ignoreRemovesFromOpenList() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.ignore(model.issues[0])
        #expect(model.issues.isEmpty)
        // Persisted as ignored.
        let ignored = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.ignored.rawValue)
        #expect(ignored.count == 1)
    }

    @Test func markResolvedPersistsResolvedAt() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.markResolved(model.issues[0])
        let resolved = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.resolved.rawValue)
        #expect(resolved.count == 1)
        #expect(resolved[0].resolvedAt != nil)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQAReviewModelTests`. Expect compile failure (`NarrationQAReviewModel` undefined).

- [ ] **Step 3: Write the model.** Create `EchoCore/ViewModels/NarrationQAReviewModel.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// Drives the per-book narration-QA review screen: loads open issues and applies
/// ignore/resolve status changes (override + regenerate land in M4). Pure
/// Foundation (no UIKit), so it bundles into every target without exclusion.
@MainActor
@Observable
final class NarrationQAReviewModel {
    var issues: [NarrationQualityIssueRecord] = []

    private let db: DatabaseWriter
    private let audiobookID: String
    private let logger = Logger(category: "NarrationQAReview")
    private static let iso = ISO8601DateFormatter()

    init(db: DatabaseWriter, audiobookID: String) {
        self.db = db
        self.audiobookID = audiobookID
    }

    func load() {
        do {
            issues = try NarrationQualityIssueDAO(db: db)
                .issues(for: audiobookID, status: NarrationQAIssueStatus.open.rawValue)
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
            issues = []
        }
    }

    func ignore(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .ignored, resolvedAt: nil)
    }

    func markResolved(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .resolved, resolvedAt: Self.iso.string(from: Date()))
    }

    private func update(
        _ issue: NarrationQualityIssueRecord, status: NarrationQAIssueStatus, resolvedAt: String?
    ) {
        do {
            try NarrationQualityIssueDAO(db: db)
                .updateStatus(id: issue.id, status: status.rawValue, resolvedAt: resolvedAt)
            issues.removeAll { $0.id == issue.id }
        } catch {
            logger.error("update status failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run it — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/NarrationQAReviewModelTests`. All three pass. Verify SPDX line 1.

- [ ] **Step 5: Commit.** `git add EchoCore/ViewModels/NarrationQAReviewModel.swift EchoTests/NarrationQAReviewModelTests.swift && git commit -m "feat(narration-qa): add NarrationQAReviewModel"`. (No pbxproj change: model is UIKit-free and bundles into all targets.)

---

## Task 10 — `NarrationQAReviewView` (iOS SwiftUI) + macOS/echo-cli exclusion

**Files**
- Create `EchoCore/Views/Narration/NarrationQAReviewView.swift`
- Modify `Echo.xcodeproj/project.pbxproj` (add `Views/Narration/NarrationQAReviewView.swift` to BOTH the `Echo macOS` EchoCore `membershipExceptions` list (block near :284) AND the `echo-cli` EchoCore exception set; match the existing `Views/...` entries' formatting)

**Interfaces**
- Consumes: `NarrationQAReviewModel` (Task 9); `NarrationQualityIssueRecord`; `NarrationQAIssueType`.

> SwiftUI iOS view, so it MUST be excluded from the macOS AND echo-cli targets (it's a `Views/` file like `AutoAlignmentProgressView.swift`, which already appears in the macOS exception list). Build verification is the iOS build; macOS/echo-cli builds must still compile with the file excluded — confirm in Step 4.

Steps:

- [ ] **Step 1: Write the view.** Create `EchoCore/Views/Narration/NarrationQAReviewView.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Per-book narration-QA review list: each row shows the source text, what the
/// transcriber heard, the issue label, and ignore/resolve actions. Override +
/// regenerate actions arrive in M4. iOS-only (excluded from macOS/echo-cli).
struct NarrationQAReviewView: View {
    @State private var model: NarrationQAReviewModel

    init(model: NarrationQAReviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            if model.issues.isEmpty {
                ContentUnavailableView(
                    "No issues", systemImage: "checkmark.seal",
                    description: Text("Run narration QA to check this book."))
            } else {
                ForEach(model.issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.issueType.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Expected", value: issue.expectedText)
                        LabeledContent("Heard", value: issue.heardText.isEmpty ? "—" : issue.heardText)
                    }
                    .swipeActions {
                        Button("Resolve") { model.markResolved(issue) }.tint(.green)
                        Button("Ignore", role: .destructive) { model.ignore(issue) }
                    }
                }
            }
        }
        .navigationTitle("Narration QA")
        .onAppear { model.load() }
    }
}
```

- [ ] **Step 2: Add the macOS + echo-cli exclusions in `project.pbxproj`.** In the `Echo macOS` EchoCore `membershipExceptions` array (the block around :284, where `Views/AutoAlignmentProgressView.swift` already appears), add a line in alphabetical position: `Views/Narration/NarrationQAReviewView.swift,`. Then locate the `echo-cli` EchoCore `PBXFileSystemSynchronizedBuildFileExceptionSet` (the exception set whose `target` is the echo-cli target) and add the same entry. (Search: `grep -n "echo-cli" Echo.xcodeproj/project.pbxproj` to find the target id, then the matching exception set.)

- [ ] **Step 3: Verify iOS builds with the view + verify macOS/echo-cli build with it excluded.** `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` (iOS — compiles the view into the iOS test/app module). Then confirm the macOS + echo-cli targets still build (the view must NOT be compiled there): `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO -quiet` and `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme echo-cli build CODE_SIGNING_ALLOWED=NO -quiet` (use the actual echo-cli scheme name from `xcodebuild -list`). Both must succeed. If macOS/cli fail with "cannot find NarrationQAReviewView", the exclusion is wrong — the view should NOT be referenced from any shared code; it is only constructed by iOS UI (wired in a later UI-integration task outside this milestone's core).

- [ ] **Step 4: Commit.** `git add EchoCore/Views/Narration/NarrationQAReviewView.swift Echo.xcodeproj/project.pbxproj && git commit -m "feat(narration-qa): add iOS NarrationQAReviewView (excluded from macOS/echo-cli)"`.

---

## Task 11 — Parity, FM-availability branches, and doc-sync

**Files**
- Modify `ARCHITECTURE.md` (add a "Narration QA" subsystem subsection)
- Modify `CHANGELOG.md` (add the M3 entry under the unreleased/nightly heading)
- No new Swift production files; this task is review + docs. Optionally create `EchoTests/NarrationQAFMAvailabilityNotes.md`-style guidance is NOT a Swift file — instead document the device-gated FM test procedure in `ARCHITECTURE.md`.

**Interfaces**
- Consumes: everything from Tasks 1-10.

Steps:

- [ ] **Step 1: Full suite green.** `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` then run each new suite: `make test-only FILTER=EchoTests/SchemaV30Tests`, `make test-only FILTER=EchoTests/NarrationQualityIssueDAOTests`, `make test-only FILTER=EchoTests/DivergenceTypesTests`, `make test-only FILTER=EchoTests/NarrationQADetectorTests`, `make test-only FILTER=EchoTests/DeterministicDivergenceClassifierTests`, `make test-only FILTER=EchoTests/DivergenceClassifierFactoryTests`, `make test-only FILTER=EchoTests/SettingsNarrationQAClassifierTests`, `make test-only FILTER=EchoTests/NarrationQAServiceTests`, `make test-only FILTER=EchoTests/NarrationQAReviewModelTests`. All pass.

- [ ] **Step 2: Run `cross-platform-parity-reviewer`** on the diff (touched `Shared/` + `EchoCore/`). Confirm: the QA service/detector/classifiers/factory/record/DAO are pure logic that auto-bundles into macOS/echo-cli/watch; the FM file is excluded from watchOS via `#if canImport(FoundationModels)`; only the SwiftUI view is target-excluded. Fix any flagged gap.

- [ ] **Step 3: Run `schema-migration-reviewer`** on `Schema_V30.swift` + the `DatabaseService.runMigrations` registration. Confirm additive-only, `ifNotExists`, FK cascade, index naming, and that V30 is still the free version against the current `origin/nightly` (re-run `grep registerMigration Shared/Database/DatabaseService.swift`). If a higher version landed meanwhile, renumber.

- [ ] **Step 4: Doc-sync.** Run the `doc-sync` skill. In `ARCHITECTURE.md`, add a "Generated Narration QA" subsection describing: the user-initiated `NarrationQAService.runQA` pass; deterministic `NarrationQADetector` (TokenDTW heard-vs-source, device-independent issue set); the `DivergenceClassifier` seam (`DeterministicDivergenceClassifier` always + triple-gated `FoundationModelsDivergenceClassifier` enriching labels/fixes, falling back per-issue); the `narrationQAClassifier` setting (`auto`/`deterministic`, default `auto`); the `narration_quality_issue` table (Schema_V30); and the FM device-test procedure (the `auto + available + iOS 26` runtime branch is exercised only via the Xcode scheme's "Simulated Foundation Models Availability" override on a real AI-capable device / TestFlight, since VM CI cannot run FM). In `CHANGELOG.md`, add: "Added: on-device generated-narration QA — re-transcribe narrated audio, surface mispronunciation/omission/substitution issues for review (deterministic; Foundation Models enrichment on supported devices)."

- [ ] **Step 5: Commit + push + PR.** `git add ARCHITECTURE.md CHANGELOG.md && git commit -m "docs: document Generated Narration QA subsystem (M3)"`. Then `git fetch origin && git rebase origin/nightly` (resolve cleanly or stop and report), `git push -u origin feature/m3-narration-qa --force-with-lease`, and `gh pr create --base nightly --title "feat: Generated Narration QA (M3)" --body "..."`. After opening, watch CI with `gh pr checks` and fix any concrete failures until green/pending.
