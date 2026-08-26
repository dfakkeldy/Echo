# M2 — Source-Backed Transcript Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** For a book that has both EPUB/PDF source text and audio, align its on-device ASR words to the canonical source blocks — persisting `.transcriptAlignment` anchors and refining `word_timing` — without ever rewriting the source `epub_block` text, and clearing only its own anchors on re-run.

**Architecture:** A new pure `enum SourceBackedAlignmentCoordinator` reuses the proven DB-free engine (`TokenDTW.alignWithBisection` → `AnchorSelector.select`, plus `TokenDTW.wordMatchesWithBisection` grouped by block) exactly the way `MacAlignmentService` already does, but reads its audio tokens from the already-persisted `standalone_transcript` rows instead of running WhisperKit. It clears prior same-source anchors by the **source column** (new `AlignmentAnchorDAO.deleteAnchors(for:source:)`), writes `AlignmentAnchorRecord`s via the canonical `AlignmentService.insertAnchors`, then materializes interpolated word timings (`WordTimingMaterializer.materialize`) and overrides matched words with DTW-derived times (`WordTimingMaterializer.refine`). `epub_block.text` is read-only throughout.

**Tech Stack:** Swift 6, GRDB (SQLite), Swift Testing (`@Suite`/`@Test`/`#expect`), `DatabaseService(inMemory: ())`. No UIKit, no `PlayerModel`, no Foundation Models in this milestone — `SourceBackedAlignmentCoordinator` is pure `EchoCore/Services` logic that auto-bundles into all targets.

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

> **Milestone note — no migration in M2.** Per design decision **D4**, source-backed anchor identity is a *code-only* change: the `alignment_anchor.source` column already stores the `AlignmentAnchorRecord.Source` raw value, so adding the `.transcriptAlignment` case needs no schema migration. M2 therefore has no `Schema_Vxx`/`SchemaVxxTests` task. The first tasks are the code-only enum case and the new delete-by-source DAO method.

---

## Task 1 — Add `AlignmentAnchorRecord.Source.transcriptAlignment`

**Files**
- Modify: `Shared/Database/AlignmentAnchorRecord.swift` (the `enum Source: String, Sendable` at lines 47-55 — add a case after `.synthesized`).
- Create: `EchoTests/AlignmentAnchorTranscriptSourceTests.swift`.

**Interfaces**
- Produces: `AlignmentAnchorRecord.Source.transcriptAlignment` with `rawValue == "transcriptAlignment"`.
- Consumes: nothing.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/AlignmentAnchorTranscriptSourceTests.swift` mirroring `EchoTests/AlignmentAnchorSourceTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct AlignmentAnchorTranscriptSourceTests {
    @Test func transcriptAlignmentHasStableRawValue() {
        #expect(AlignmentAnchorRecord.Source.transcriptAlignment.rawValue == "transcriptAlignment")
    }

    @Test func transcriptAlignmentRoundTripsFromRawValue() {
        #expect(AlignmentAnchorRecord.Source(rawValue: "transcriptAlignment") == .transcriptAlignment)
    }
}
```
- [ ] **Step 2: Build the test target, then run the suite (expect FAIL — case does not exist yet).**
  `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
  then `make test-only FILTER=EchoTests/AlignmentAnchorTranscriptSourceTests`
  Expected: compile error / FAIL (`transcriptAlignment` is not a member of `Source`).
- [ ] **Step 3: Add the enum case.** In `Shared/Database/AlignmentAnchorRecord.swift`, add the new case to `enum Source` immediately after the `synthesized` case (line 54):
```swift
        case synthesized = "synthesized"  // TTS-generated narration anchors
        case transcriptAlignment = "transcriptAlignment"  // ASR↔source-block alignment (M2)
```
- [ ] **Step 4: Re-run the suite (expect PASS).** `make test-only FILTER=EchoTests/AlignmentAnchorTranscriptSourceTests` → PASS. After the edit, verify the SwiftFormat hook left `// SPDX-License-Identifier: GPL-3.0-or-later` on line 1 of `AlignmentAnchorRecord.swift` and the test file.
- [ ] **Step 5: Commit.** `git add Shared/Database/AlignmentAnchorRecord.swift EchoTests/AlignmentAnchorTranscriptSourceTests.swift && git commit -m "feat(alignment): add AlignmentAnchorRecord.Source.transcriptAlignment case"`

---

## Task 2 — Add `AlignmentAnchorDAO.deleteAnchors(for:source:)`

**Files**
- Modify: `Shared/Database/DAOs/AlignmentAnchorDAO.swift` (add a new method in the `// MARK: - Delete` section after `delete(id:)`, lines 29-35).
- Create: `EchoTests/AlignmentAnchorDeleteBySourceTests.swift`.

**Interfaces**
- Produces: `func deleteAnchors(for audiobookID: String, source: String) throws -> Int` (returns count removed).
- Consumes: `AlignmentAnchorRecord.Source.transcriptAlignment` (Task 1); `AlignmentAnchorDAO.insert(_:)`, `anchors(for:)` (existing).

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/AlignmentAnchorDeleteBySourceTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct AlignmentAnchorDeleteBySourceTests {
    private func seedBook(_ db: DatabaseService, id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Book', 100)",
                arguments: [id])
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(
                id: "b0", audiobookID: id, spineHref: "c.xhtml", spineIndex: 0,
                blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
                text: "x", chapterIndex: 0, isHidden: false),
        ])
    }

    private func anchor(
        _ id: String, book: String, source: AlignmentAnchorRecord.Source, time: Double
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id, audiobookID: book, epubBlockID: "b0", audioTime: time,
            audioEndTime: nil, anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: source.rawValue, note: nil,
            createdAt: AlignmentService.isoFormatter.string(from: Date()), modifiedAt: nil)
    }

    /// Deleting by source removes ONLY rows whose source column matches, leaving
    /// hand-placed (moveToNow) and other-source anchors intact.
    @Test func deletesOnlyMatchingSource() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook(db, id: "bk")
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(anchor("a1", book: "bk", source: .transcriptAlignment, time: 1))
        try dao.insert(anchor("a2", book: "bk", source: .transcriptAlignment, time: 2))
        try dao.insert(anchor("h1", book: "bk", source: .moveToNow, time: 3))

        let removed = try dao.deleteAnchors(
            for: "bk", source: AlignmentAnchorRecord.Source.transcriptAlignment.rawValue)

        #expect(removed == 2)
        #expect(try dao.anchors(for: "bk").map(\.id) == ["h1"])
    }

    /// Scoped to the audiobook: another book's same-source anchors survive.
    @Test func scopedToAudiobook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook(db, id: "bk1")
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk2','B',100)")
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(
                id: "b0", audiobookID: "bk2", spineHref: "c.xhtml", spineIndex: 0,
                blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
                text: "y", chapterIndex: 0, isHidden: false),
        ])
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(anchor("a1", book: "bk1", source: .transcriptAlignment, time: 1))
        try dao.insert(anchor("a2", book: "bk2", source: .transcriptAlignment, time: 1))

        let removed = try dao.deleteAnchors(
            for: "bk1", source: AlignmentAnchorRecord.Source.transcriptAlignment.rawValue)

        #expect(removed == 1)
        #expect(try dao.anchors(for: "bk2").count == 1)
    }
}
```
- [ ] **Step 2: Run the suite (expect FAIL — method does not exist).**
  `make build-tests` (re-run if not already built this session)
  then `make test-only FILTER=EchoTests/AlignmentAnchorDeleteBySourceTests` → FAIL (no member `deleteAnchors(for:source:)`).
- [ ] **Step 3: Implement the DAO method.** In `Shared/Database/DAOs/AlignmentAnchorDAO.swift`, add after `delete(id:)` (line 35), inside the `// MARK: - Delete` section:
```swift
    /// Deletes every anchor for `audiobookID` whose `source` column equals
    /// `source`. Used by source-backed transcript alignment to clear only its
    /// own `.transcriptAlignment` anchors on re-run, leaving hand-placed and
    /// other-pipeline anchors intact (the queryable counterpart to the legacy
    /// id-prefix `deleteAutoPipelineAnchors`).
    /// - Returns: The number of anchors removed.
    @discardableResult
    func deleteAnchors(for audiobookID: String, source: String) throws -> Int {
        try db.write { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source") == source)
                .deleteAll(db)
        }
    }
```
- [ ] **Step 4: Re-run the suite (expect PASS).** `make test-only FILTER=EchoTests/AlignmentAnchorDeleteBySourceTests` → PASS. Verify SPDX is still line 1 of both edited/created files.
- [ ] **Step 5: Commit.** `git add Shared/Database/DAOs/AlignmentAnchorDAO.swift EchoTests/AlignmentAnchorDeleteBySourceTests.swift && git commit -m "feat(alignment): add AlignmentAnchorDAO.deleteAnchors(for:source:)"`

---

## Task 3 — `SourceBackedAlignmentCoordinator`: build inputs from DB (tokens + audio words)

This task creates the coordinator file with a single pure, testable helper that turns persisted DB rows into the two token streams the engine needs — proving the read side before wiring the write side in Task 4.

**Files**
- Create: `EchoCore/Services/SourceBackedAlignmentCoordinator.swift`.
- Create: `EchoTests/SourceBackedAlignmentInputsTests.swift`.

**Interfaces**
- Produces:
  - `enum SourceBackedAlignmentCoordinator` (no stored state; pure static funcs).
  - `static func epubTokens(audiobookID: String, dbService: DatabaseService) throws -> [TokenDTW.EPubToken]` — visible, non-empty-text blocks in sequence order; one `EPubToken` per block (text = block text).
  - `static func audioTokens(audiobookID: String, dbService: DatabaseService) throws -> [TokenDTW.AudioToken]` — decode each `standalone_transcript.words_json` into `[StandaloneTranscribedWord]`, ordered by `(chapter_index, segment_index)`, build `TranscribedWord(text: word.word, start: word.start)`, then expand via `TokenDTW.normalize(tw.text).map { AudioToken(text: $0, time: tw.start) }` (matching `AutoAlignmentWorker`'s token-build pattern; `start` is ABSOLUTE audio time per OI-1).
- Consumes: `EPubBlockDAO.visibleBlocks(for:)`, `TokenDTW.EPubToken`, `TokenDTW.AudioToken`, `TokenDTW.normalize(_:)`, `StandaloneTranscriptRecord`, `StandaloneTranscribedWord`, `TranscribedWord(text:start:)`.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/SourceBackedAlignmentInputsTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentInputsTests {
    private func encodeWords(_ words: [StandaloneTranscribedWord]) -> String {
        String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
    }

    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100)")
            // Two visible blocks + one hidden + one empty-text → only the two
            // visible non-empty blocks become tokens.
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','hello world', 0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','goodbye now', 0),
                           ('bh','bk','c.xhtml',0,2,2,'paragraph','hidden text', 1),
                           ('be','bk','c.xhtml',0,3,3,'paragraph','', 0)
                    """)
        }
        // Two transcript segments with word-level JSON; absolute start times.
        let seg0 = encodeWords([
            StandaloneTranscribedWord(word: "hello", start: 1.0, end: 1.4, confidence: 0.9),
            StandaloneTranscribedWord(word: "world", start: 1.5, end: 1.9, confidence: 0.9),
        ])
        let seg1 = encodeWords([
            StandaloneTranscribedWord(word: "goodbye", start: 2.0, end: 2.4, confidence: 0.9),
            StandaloneTranscribedWord(word: "now", start: 2.5, end: 2.9, confidence: 0.9),
        ])
        try db.write { db in
            // Inserted out of order to prove ordering by (chapter, segment).
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s1','bk',0,1,'goodbye now',2.0,2.9,?,'now'),
                           ('s0','bk',0,0,'hello world',1.0,1.9,?,'now')
                    """,
                arguments: [seg1, seg0])
        }
    }

    @Test func epubTokensSkipHiddenAndEmpty() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let tokens = try SourceBackedAlignmentCoordinator.epubTokens(
            audiobookID: "bk", dbService: db)
        #expect(tokens.map(\.blockID) == ["b0", "b1"])
        #expect(tokens.map(\.text) == ["hello world", "goodbye now"])
    }

    @Test func audioTokensOrderedByChapterThenSegmentWithAbsoluteTimes() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let audio = try SourceBackedAlignmentCoordinator.audioTokens(
            audiobookID: "bk", dbService: db)
        // normalize keeps each whole word here (all ≥2 chars, no digits).
        #expect(audio.map(\.text) == ["hello", "world", "goodbye", "now"])
        #expect(abs(audio[0].time - 1.0) < 0.001)
        #expect(abs(audio[3].time - 2.5) < 0.001)
    }
}
```
- [ ] **Step 2: Run the suite (expect FAIL — type does not exist).**
  `make build-tests`
  then `make test-only FILTER=EchoTests/SourceBackedAlignmentInputsTests` → FAIL (no `SourceBackedAlignmentCoordinator`).
- [ ] **Step 3: Implement the coordinator's read side.** Create `EchoCore/Services/SourceBackedAlignmentCoordinator.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Aligns a source-backed book's on-device ASR words (already persisted in
/// `standalone_transcript`) to its canonical EPUB/PDF source blocks.
///
/// Reuses the pure, DB-free engine the auto-alignment pipeline and
/// `MacAlignmentService` already use — `TokenDTW` + `AnchorSelector` +
/// `WordTimingMaterializer` — but takes its audio tokens from stored ASR rows
/// instead of running WhisperKit. The source `epub_block.text` is read-only:
/// alignment writes only `alignment_anchor` rows and refines `word_timing`.
enum SourceBackedAlignmentCoordinator {

    /// Visible, text-bearing source blocks in reading order, one `EPubToken`
    /// per block (text = the whole block; `TokenDTW.normalize` tokenizes it).
    static func epubTokens(
        audiobookID: String, dbService: DatabaseService
    ) throws -> [TokenDTW.EPubToken] {
        let blocks = try EPubBlockDAO(db: dbService.writer).visibleBlocks(for: audiobookID)
        return blocks.compactMap { block in
            guard let text = block.text, !text.isEmpty else { return nil }
            return TokenDTW.EPubToken(text: text, blockID: block.id)
        }
    }

    /// ASR audio tokens for the book, ordered by `(chapter_index, segment_index)`
    /// with ABSOLUTE audio-file start times, expanded through `TokenDTW.normalize`
    /// exactly as `AutoAlignmentWorker` does for live transcription.
    static func audioTokens(
        audiobookID: String, dbService: DatabaseService
    ) throws -> [TokenDTW.AudioToken] {
        let segments = try dbService.writer.read { db in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("chapter_index"), Column("segment_index"))
                .fetchAll(db)
        }
        let decoder = JSONDecoder()
        var tokens: [TokenDTW.AudioToken] = []
        for segment in segments {
            guard
                let json = segment.wordsJSON,
                let data = json.data(using: .utf8),
                let words = try? decoder.decode([StandaloneTranscribedWord].self, from: data)
            else { continue }
            for word in words {
                let tw = TranscribedWord(text: word.word, start: word.start)
                tokens.append(contentsOf: TokenDTW.normalize(tw.text).map {
                    TokenDTW.AudioToken(text: $0, time: tw.start)
                })
            }
        }
        return tokens
    }
}
```
- [ ] **Step 4: Re-run the suite (expect PASS).** `make test-only FILTER=EchoTests/SourceBackedAlignmentInputsTests` → PASS. Verify SPDX line 1 in both files.
- [ ] **Step 5: Commit.** `git add EchoCore/Services/SourceBackedAlignmentCoordinator.swift EchoTests/SourceBackedAlignmentInputsTests.swift && git commit -m "feat(alignment): add SourceBackedAlignmentCoordinator input builders"`

---

## Task 4 — `SourceBackedAlignmentCoordinator.align`: run engine, clear own anchors, persist, refine

**Files**
- Modify: `EchoCore/Services/SourceBackedAlignmentCoordinator.swift` (add `align(audiobookID:dbService:)` after `audioTokens`).
- Create: `EchoTests/SourceBackedAlignmentCoordinatorTests.swift`.

**Interfaces**
- Produces: `static func align(audiobookID: String, dbService: DatabaseService) async throws`.
- Consumes: `epubTokens(audiobookID:dbService:)`, `audioTokens(audiobookID:dbService:)` (Task 3); `TokenDTW.alignWithBisection(epub:audio:)`, `AnchorSelector.select(candidates:)`, `TokenDTW.wordMatchesWithBisection(epub:audio:)`, `TokenDTW.WordMatch`, `TokenDTW.AnchorCandidate`; `AlignmentAnchorDAO.deleteAnchors(for:source:)` (Task 2); `AlignmentAnchorRecord(...)`, `.Source.transcriptAlignment` (Task 1), `.AnchorKind.point`; `AlignmentService(db:audiobookID:)`, `AlignmentService.insertAnchors(_:)`, `AlignmentService.isoFormatter`; `WordTimingMaterializer.materialize(audiobookID:writer:)`, `WordTimingMaterializer.refine(audiobookID:dtwMatchesByBlock:writer:)`; `WordTimingDAO.words(forAudiobook:)`.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/SourceBackedAlignmentCoordinatorTests.swift`. The fixture mirrors `WordTimingMaterializerTests` (real `audiobook` + `epub_block` rows) plus `standalone_transcript` rows whose words match the source so DTW produces strong runs:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentCoordinatorTests {
    /// A 6-word source paragraph + a matching 6-word ASR segment. Long enough
    /// to clear AnchorSelector's minRunLength = 3 gate, so one anchor lands on
    /// the block and DTW retimes its words.
    private func seedAligned(_ db: DatabaseService, book: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Book', 100)",
                arguments: [book])
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0', ?, 'c.xhtml', 0, 0, 0, 'paragraph',
                            'alpha bravo charlie delta echo foxtrot', 0)
                    """,
                arguments: [book])
        }
        let words = (0..<6).map { i -> StandaloneTranscribedWord in
            let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
            return StandaloneTranscribedWord(
                word: names[i], start: Double(i) + 1.0, end: Double(i) + 1.4, confidence: 0.9)
        }
        let json = String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s0', ?, 0, 0, 'alpha bravo charlie delta echo foxtrot',
                            1.0, 6.4, ?, 'now')
                    """,
                arguments: [book, json])
        }
    }

    @Test func writesTranscriptAlignmentAnchorsAndRefinesWordTiming() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)

        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: "bk")
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy {
            $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue
        })
        #expect(anchors.allSatisfy {
            $0.anchorKind == AlignmentAnchorRecord.AnchorKind.point.rawValue
        })

        // Word timings exist and at least one carries the DTW-derived source/time.
        let words = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(words.count == 6)
        #expect(words.contains { $0.source == "dtw" })
        if let alpha = words.first(where: { $0.word == "alpha" }) {
            #expect(abs(alpha.audioStartTime - 1.0) < 0.1)
        }
    }

    /// Re-running clears only `.transcriptAlignment` anchors — a hand-placed
    /// moveToNow anchor on a different block survives.
    @Test func reRunClearsOnlyOwnAnchors() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(AlignmentAnchorRecord(
            id: "human-1", audiobookID: "bk", epubBlockID: "b0", audioTime: 99,
            audioEndTime: nil, anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.moveToNow.rawValue, note: nil,
            createdAt: AlignmentService.isoFormatter.string(from: Date()), modifiedAt: nil))

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let firstRunTranscriptIDs = try dao.anchors(for: "bk")
            .filter { $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue }
            .map(\.id)
        #expect(!firstRunTranscriptIDs.isEmpty)

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let all = try dao.anchors(for: "bk")
        // Human anchor survived both runs…
        #expect(all.contains { $0.id == "human-1" })
        // …and the first run's transcript anchors were replaced (UUIDs differ).
        let secondRunTranscriptIDs = all
            .filter { $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue }
            .map(\.id)
        #expect(Set(firstRunTranscriptIDs).isDisjoint(with: Set(secondRunTranscriptIDs)))
    }

    /// Source text is canonical: alignment never rewrites epub_block.text.
    @Test func sourceTextRemainsCanonical() async throws {
        let db = try DatabaseService(inMemory: ())
        try seedAligned(db, book: "bk")
        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)
        let block = try EPubBlockDAO(db: db.writer).blocks(for: "bk").first { $0.id == "b0" }
        #expect(block?.text == "alpha bravo charlie delta echo foxtrot")
    }
}
```
- [ ] **Step 2: Run the suite (expect FAIL — `align` does not exist).**
  `make build-tests`
  then `make test-only FILTER=EchoTests/SourceBackedAlignmentCoordinatorTests` → FAIL (no member `align`).
- [ ] **Step 3: Implement `align`.** In `EchoCore/Services/SourceBackedAlignmentCoordinator.swift`, add after `audioTokens(...)`:
```swift
    /// Source value stamped on every anchor this coordinator writes — the
    /// queryable identity used to clear only its own anchors on re-run.
    static let anchorSource = AlignmentAnchorRecord.Source.transcriptAlignment.rawValue

    /// Aligns the book's persisted ASR to its source blocks, writes
    /// `.transcriptAlignment` anchors (replacing only prior ones of that
    /// source), and refines `word_timing` from the DTW word matches. No-ops
    /// quietly when there is nothing to align (no source tokens, no audio
    /// tokens, or no selectable anchors) so a partial book is safe to re-run.
    static func align(audiobookID: String, dbService: DatabaseService) async throws {
        let epub = try epubTokens(audiobookID: audiobookID, dbService: dbService)
        let audio = try audioTokens(audiobookID: audiobookID, dbService: dbService)
        guard !epub.isEmpty, !audio.isEmpty else { return }

        let candidates = TokenDTW.alignWithBisection(epub: epub, audio: audio)
        let selected = AnchorSelector.select(candidates: candidates)

        // Always clear our own prior anchors first so a re-run that now selects
        // fewer (or zero) anchors converges instead of leaving stale rows.
        let anchorDAO = AlignmentAnchorDAO(db: dbService.writer)
        _ = try anchorDAO.deleteAnchors(for: audiobookID, source: anchorSource)

        guard !selected.isEmpty else { return }

        let now = AlignmentService.isoFormatter.string(from: Date())
        let records = selected.map { candidate in
            AlignmentAnchorRecord(
                id: UUID().uuidString, audiobookID: audiobookID,
                epubBlockID: candidate.blockID, audioTime: candidate.time,
                audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: anchorSource,
                note: "Source-backed transcript alignment (TokenDTW + AnchorSelector)",
                createdAt: now, modifiedAt: nil)
        }

        // `insertAnchors` recalculates the timeline AND materializes interpolated
        // word timings (materializeWordTimings: true by default), so the refine
        // step below has interpolated rows to override.
        let service = AlignmentService(db: dbService.writer, audiobookID: audiobookID)
        try service.insertAnchors(records)

        // Override matched words with their DTW-derived audio times.
        let matches = TokenDTW.wordMatchesWithBisection(epub: epub, audio: audio)
        let matchesByBlock = Dictionary(grouping: matches, by: { $0.blockID })
        try WordTimingMaterializer.refine(
            audiobookID: audiobookID, dtwMatchesByBlock: matchesByBlock, writer: dbService.writer)
    }
```
- [ ] **Step 4: Re-run the suite (expect PASS).** `make test-only FILTER=EchoTests/SourceBackedAlignmentCoordinatorTests` → PASS. Verify SPDX line 1 in both files. If `writesTranscriptAlignmentAnchorsAndRefinesWordTiming` fails on the `"dtw"` source assertion, confirm the fixture's 6 matching words form a run ≥ `minRunLength` (3) — the names are deliberately distinct, ≥2 chars, non-numeric, so `TokenDTW.normalize` preserves them 1:1; do not lower `minRunLength`.
- [ ] **Step 5: Commit.** `git add EchoCore/Services/SourceBackedAlignmentCoordinator.swift EchoTests/SourceBackedAlignmentCoordinatorTests.swift && git commit -m "feat(alignment): SourceBackedAlignmentCoordinator.align writes transcriptAlignment anchors + refines word timing"`

---

## Task 5 — Flag low-confidence transcript-derived spans

**Acceptance criterion** "low-confidence spans flagged" — implemented additively over the existing `word_timing.confidence` stamping: words DTW retimed get 0.85 (`refine`'s `dtwConfidence`); words that stayed interpolated keep 0.5. M2 surfaces these as a queryable count so callers/debug UI can flag spans, without inventing a new column.

**Files**
- Modify: `EchoCore/Services/SourceBackedAlignmentCoordinator.swift` (add a `lowConfidenceWordCount` helper).
- Create: `EchoTests/SourceBackedAlignmentConfidenceTests.swift`.

**Interfaces**
- Produces: `static func lowConfidenceWordCount(audiobookID: String, dbService: DatabaseService, threshold: Double = 0.75) throws -> Int` — count of `word_timing` rows for the book whose `confidence < threshold` (0.75 sits between interpolated 0.5 and DTW 0.85).
- Consumes: `WordTimingDAO.words(forAudiobook:)`.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/SourceBackedAlignmentConfidenceTests.swift`. Reuse a small aligned fixture and assert that after `align`, the unmatched-word count is reported as low-confidence:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentConfidenceTests {
    /// Source has 7 words; ASR matches only the first 6 (a trailing source word
    /// the narrator never said). After align, the 6 matched words are DTW-timed
    /// (conf 0.85) and the 7th stays interpolated (conf 0.5) → flagged.
    @Test func reportsLowConfidenceWordsForUnmatchedSourceTail() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph',
                            'alpha bravo charlie delta echo foxtrot golf', 0)
                    """)
        }
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let words = names.enumerated().map { i, w in
            StandaloneTranscribedWord(
                word: w, start: Double(i) + 1.0, end: Double(i) + 1.4, confidence: 0.9)
        }
        let json = String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s0','bk',0,0,'alpha bravo charlie delta echo foxtrot',
                            1.0, 6.4, ?, 'now')
                    """,
                arguments: [json])
        }

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)

        let lowConf = try SourceBackedAlignmentCoordinator.lowConfidenceWordCount(
            audiobookID: "bk", dbService: db)
        // The unmatched 7th source word ("golf") stays interpolated → flagged.
        #expect(lowConf >= 1)

        // And the matched words are NOT flagged at the default threshold.
        let total = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk").count
        #expect(total == 7)
        #expect(lowConf < total)
    }
}
```
- [ ] **Step 2: Run the suite (expect FAIL — helper does not exist).**
  `make build-tests`
  then `make test-only FILTER=EchoTests/SourceBackedAlignmentConfidenceTests` → FAIL (no member `lowConfidenceWordCount`).
- [ ] **Step 3: Implement the helper.** In `EchoCore/Services/SourceBackedAlignmentCoordinator.swift`, add after `align(...)`:
```swift
    /// Number of `word_timing` rows for the book whose confidence is below
    /// `threshold` — the spans that stayed interpolated (0.5) rather than being
    /// retimed by a real DTW audio match (0.85). Callers/debug UI use this to
    /// flag likely-misaligned regions; the default 0.75 separates the two.
    static func lowConfidenceWordCount(
        audiobookID: String, dbService: DatabaseService, threshold: Double = 0.75
    ) throws -> Int {
        let words = try WordTimingDAO(db: dbService.writer).words(forAudiobook: audiobookID)
        return words.filter { $0.confidence < threshold }.count
    }
```
- [ ] **Step 4: Re-run the suite (expect PASS).** `make test-only FILTER=EchoTests/SourceBackedAlignmentConfidenceTests` → PASS. Verify SPDX line 1 in both files.
- [ ] **Step 5: Commit.** `git add EchoCore/Services/SourceBackedAlignmentCoordinator.swift EchoTests/SourceBackedAlignmentConfidenceTests.swift && git commit -m "feat(alignment): flag low-confidence transcript-derived word spans"`

---

## Task 6 — Cross-platform parity + doc-sync

This milestone touches `Shared/` (`AlignmentAnchorRecord`, `AlignmentAnchorDAO`) and `EchoCore/Services` (`SourceBackedAlignmentCoordinator`). All are pure logic with no UIKit/`PlayerModel` import, so they auto-bundle into iOS, macOS, watchOS, Widget, and echo-cli — **no `project.pbxproj` target exclusions are needed** (verify this claim before closing the task). The new behaviour (source-backed transcript alignment + a new anchor source) is an architecture/data-flow addition, so the docs need a note.

**Files**
- Modify: `ARCHITECTURE.md` (alignment subsystem section — add the source-backed transcript-alignment path).
- Modify: `CHANGELOG.md` (Unreleased/nightly section).
- No code changes in this task.

Steps:

- [ ] **Step 1: Run the full alignment suite as a regression gate.** Confirm no neighbouring alignment suite broke:
  `make build-tests && make test-only FILTER=EchoTests/SourceBackedAlignmentCoordinatorTests && make test-only FILTER=EchoTests/SourceBackedAlignmentInputsTests && make test-only FILTER=EchoTests/SourceBackedAlignmentConfidenceTests && make test-only FILTER=EchoTests/AlignmentAnchorDeleteBySourceTests && make test-only FILTER=EchoTests/AlignmentAnchorTranscriptSourceTests && make test-only FILTER=EchoTests/WordTimingMaterializerTests && make test-only FILTER=EchoTests/AlignmentAnchorDAOTests`
  Expected: all PASS.
- [ ] **Step 2: Verify no target exclusion is required.** Confirm `SourceBackedAlignmentCoordinator.swift` imports only `Foundation`/`GRDB` (no `UIKit`, no `PlayerModel`): `grep -nE "import UIKit|PlayerModel" EchoCore/Services/SourceBackedAlignmentCoordinator.swift` → expect no output. Then run the `cross-platform-parity-reviewer` agent over the `Shared/` and `EchoCore` diff to confirm macOS/watchOS/Widget/echo-cli coverage and that no file needs gating.
- [ ] **Step 3: Update `ARCHITECTURE.md`.** In the alignment subsystem section, add a subsection describing `SourceBackedAlignmentCoordinator`: it reuses the pure `TokenDTW` + `AnchorSelector` + `WordTimingMaterializer` engine (like `MacAlignmentService`) but reads audio tokens from persisted `standalone_transcript` rows; writes `alignment_anchor` rows with the new `Source.transcriptAlignment` (cleared/protected by the source column via `AlignmentAnchorDAO.deleteAnchors(for:source:)`); refines `word_timing` without ever writing `epub_block.text`; low-confidence spans remain at interpolated confidence and are surfaced via `lowConfidenceWordCount`.
- [ ] **Step 4: Update `CHANGELOG.md`.** Add under the nightly/Unreleased section: "Added source-backed transcript alignment for books with both source text and audio (`SourceBackedAlignmentCoordinator`): aligns on-device ASR words to canonical EPUB/PDF blocks, persists `transcriptAlignment` anchors and refines word timings; re-runs clear only their own anchors and never modify source text." Optionally run the `doc-sync` skill to confirm `README.md`/`ROADMAP.md` need no further edits.
- [ ] **Step 5: Commit + open PR.** `git add ARCHITECTURE.md CHANGELOG.md && git commit -m "docs(alignment): document source-backed transcript alignment (M2)"`, then (after the heads-up the workflow requires) `git fetch origin && git rebase origin/nightly` and `gh pr create --base nightly --title "M2: Source-backed transcript alignment" --body "<summary + verification>"`. Never target `main`.
