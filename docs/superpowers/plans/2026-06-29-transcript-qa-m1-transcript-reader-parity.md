# M1 — Transcript Reader Parity (audio-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** Let an audio-only audiobook (no EPUB/PDF) be transcribed on-device and then open in the *existing* read-along reader with active segment + word highlight, search-to-seek, tap-to-seek, and study anchoring, with true resume (no duplicate rows) and persistence across relaunch.

**Architecture:** A user action runs `StandaloneTranscriptionService` (WhisperKit ASR → `standalone_transcript` raw-audit rows, now keyed by the canonical `folderURL` audiobook id and resumable). On completion a pure `TranscriptMaterializer` projects those rows into `epub_block` (paragraph, `block_kind=paragraph`) + `timeline_item` (timestamped) + `word_timing` (per-ASR-word, source `transcript`), and the book's `audiobook.text_origin` is set to `"transcript"`. Because the materialized rows live in the canonical reader tables, the existing `ReaderTab`/`ReaderFeedViewModel`/`ParagraphCardCell` highlight/search/seek/study machinery works unchanged — `model.hasEPUB` (visible `epub_block` rows exist) routes the book to `ReaderTab`. The materializer is idempotent: it deletes the book's `transcript-%` projection before rewrite, and the service skips chapters whose rows already exist.

**Tech Stack:** Swift 6 (MainActor default isolation on iOS target), SwiftUI, GRDB (SQLite), Swift Testing (`@Suite`/`@Test`/`#expect`), WhisperKit (on-device CoreML ASR), `os.Logger`. Tests run via `make build-tests` then `make test-only FILTER=EchoTests/<Suite>` under `CODE_SIGNING_ALLOWED=NO`.

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

## Task 0 — Confirm the branch base (verify-only — do NOT reset)

This worktree is ALREADY based on `origin/nightly` (verified during planning: `git merge-base --is-ancestor origin/nightly HEAD` succeeds). The branch also carries the approved design + plan commits for this program — that is EXPECTED. **Do NOT `git reset --hard`** here: it would discard those committed docs. This task is verification only.

**Files:** none (git only).

- [ ] **Step 1: Verify the base includes nightly.** Run:
  ```
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c fetch origin nightly
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c merge-base --is-ancestor origin/nightly HEAD && echo "ON NIGHTLY (good)" || echo "NOT ON NIGHTLY — STOP"
  ```
  Expected: "ON NIGHTLY (good)". If it prints "NOT ON NIGHTLY — STOP", stop and report — do NOT force a reset while the branch has commits.
- [ ] **Step 2: Re-verify the next free migration version.** Run:
  ```
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c show origin/nightly:Shared/Database/DatabaseService.swift | grep registerMigration
  ```
  Expected: the latest registered is `v28_pdf_block_page`, so this milestone claims **V29**. If a `v29_*` already exists upstream, renumber this milestone's migration to the next free version and adjust every `V29`/`v29_` reference in this plan accordingly.

---

## Task 1 — Schema_V29: add `audiobook.text_origin` (provenance marker)

**Files:**
- Create `Shared/Database/Migrations/Schema_V29.swift`
- Modify `Shared/Database/DatabaseService.swift` (register migration in `runMigrations`, after the `v28_pdf_block_page` block at lines 114-116, before `try migrator.migrate(writer)` at line 117)
- Modify `Shared/Database/DAOs/AudiobookDAO.swift` (add `textOrigin` stored property + CodingKey to `AudiobookRecord`, struct at lines 49-86)
- Create `EchoTests/SchemaV29Tests.swift`

**Interfaces:**
- Produces: `enum Schema_V29 { nonisolated static func migrate(_ db: Database) throws }`
- Produces: `AudiobookRecord.textOrigin: String?` (column `text_origin`; values `"epub"` | `"pdf"` | `"transcript"`; nil = legacy)

- [ ] **Step 1: Write the failing schema test.** Create `EchoTests/SchemaV29Tests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB
  import Testing

  @testable import Echo

  @MainActor @Suite struct SchemaV29Tests {
      private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
          try db.writer.read { database in
              let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
              return Set(rows.compactMap { $0["name"] as? String })
          }
      }

      @Test func v29AddsTextOriginColumn() throws {
          let db = try DatabaseService(inMemory: ())
          let cols = try columnNames(table: "audiobook", db: db)
          #expect(cols.contains("text_origin"))
      }

      @Test func audiobookRecordRoundTripsTextOrigin() throws {
          let db = try DatabaseService(inMemory: ())
          let dao = AudiobookDAO(db: db.writer)
          try dao.insert(
              AudiobookRecord(
                  id: "file:///b1/", title: "Book", author: nil, duration: 100,
                  addedAt: "2026-06-29T00:00:00Z", textOrigin: "transcript"))
          let fetched = try dao.get("file:///b1/")
          #expect(fetched?.textOrigin == "transcript")
      }

      @Test func legacyAudiobookHasNilTextOrigin() throws {
          let db = try DatabaseService(inMemory: ())
          try db.writer.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('file:///legacy/', 'Old', 60, '2026-06-29T00:00:00Z')")
          }
          let fetched = try AudiobookDAO(db: db.writer).get("file:///legacy/")
          #expect(fetched?.textOrigin == nil)
      }
  }
  ```
- [ ] **Step 2: Build the test target.** Run (once for this milestone's edit→test loop):
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile (`AudiobookRecord` has no `textOrigin`; `Schema_V29` undefined). This confirms the test exercises the new symbols.
- [ ] **Step 3: Write the migration.** Create `Shared/Database/Migrations/Schema_V29.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import GRDB

  /// V29 — per-book text provenance marker.
  ///
  /// `text_origin` distinguishes books whose reader text is canonical source
  /// (`epub` / `pdf`) from books whose reader text was materialized from ASR
  /// (`transcript`). M1 sets `transcript` after transcript materialization so
  /// M2/labelling never treats an ASR-derived book as canonical source.
  /// nil = legacy book imported before this column existed.
  enum Schema_V29 {
      nonisolated static func migrate(_ db: Database) throws {
          let hasTextOrigin = try db.columns(in: "audiobook").contains { column in
              column.name == "text_origin"
          }
          if !hasTextOrigin {
              try db.alter(table: "audiobook") { table in
                  table.add(column: "text_origin", .text)
              }
          }
      }
  }
  ```
- [ ] **Step 4: Register the migration.** In `Shared/Database/DatabaseService.swift`, add immediately after the `v28_pdf_block_page` block (after line 116, before `try migrator.migrate(writer)`):
  ```swift
          migrator.registerMigration("v29_audiobook_text_origin") { db in
              try Schema_V29.migrate(db)
          }
  ```
- [ ] **Step 5: Add the field to `AudiobookRecord`.** In `Shared/Database/DAOs/AudiobookDAO.swift`, add a stored property after `var sourceRootID: String? = nil` (line 66):
  ```swift
      var textOrigin: String? = nil
  ```
  and add to `CodingKeys` (after `case sourceRootID = "source_root_id"`, line 84):
  ```swift
          case textOrigin = "text_origin"
  ```
  Verify SPDX is still line 1 of the file after the SwiftFormat hook runs.
- [ ] **Step 6: Re-run the schema test.** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/SchemaV29Tests
  ```
  Expected: PASS (3 tests).
- [ ] **Step 7: Run `schema-migration-reviewer`** on `Shared/Database/Migrations/Schema_V29.swift` + the `DatabaseService` registration. Address any flagged issue, then commit:
  ```
  git add Shared/Database/Migrations/Schema_V29.swift Shared/Database/DatabaseService.swift Shared/Database/DAOs/AudiobookDAO.swift EchoTests/SchemaV29Tests.swift
  git commit -m "feat(db): add Schema_V29 audiobook.text_origin provenance marker"
  ```

---

## Task 2 — `TranscriptMaterializer`: standalone_transcript → epub_block + timeline_item + word_timing (idempotent)

**Files:**
- Create `EchoCore/Services/TranscriptMaterializer.swift` (pure `EchoCore/Services` logic, no UIKit import → auto-bundles into all targets; no `project.pbxproj` exclusion needed)
- Create `EchoTests/TranscriptMaterializerTests.swift`

**Interfaces:**
- Consumes: `StandaloneTranscriptRecord` (`Shared/StandaloneTranscriptRecord.swift`), `StandaloneTranscribedWord { word; start; end; confidence: Float }`, `WordTokenizer.words(in:)`, `EPubBlockDAO`, `TimelineDAO.ingest`, `WordTimingDAO.insert`, `EPubBlockRecord` (`Kind.paragraph`), `TimelineItem` (`granularityLevel .paragraph`, `TimestampSource.transcript`, `AlignmentStatus.lockedAnchor`), `WordTimingRecord`.
- Produces: `enum TranscriptMaterializer { static func materialize(audiobookID: String, writer: DatabaseWriter) throws }`

Design notes the implementation must honor:
- Block id = `transcript-<audiobookID>-c<chapterIndex>-s<segmentIndex>`; `blockKind = EPubBlockRecord.Kind.paragraph.rawValue`; `isHidden = false`.
- Block `text` = the segment's ASR words joined by single spaces (from `words_json` when present, else fall back to the segment's `text`), so `WordTokenizer.words(in: block.text)` indexes 1:1 with `words_json`.
- `sequenceIndex` monotonically increasing across all segments in `(chapterIndex, segmentIndex)` order (use the running counter).
- TimelineItem id = `epub-<block.id>`; `audioStartTime = segment.startTime`; `audioEndTime = segment.endTime`; `sourceTable = "standalone_transcript"`; `epubBlockID = block.id`; `timestampSource = .transcript`; `alignmentStatus = .lockedAnchor`; `itemType = .textSegment`; `granularityLevel = .paragraph`.
- WordTimingRecord per ASR word: `wordIndex` = its position over `WordTokenizer.words(in: block.text)` (== JSON index by construction); `word` = the ASR word; `audioStartTime/End` from the JSON; `source = "transcript"`; `confidence = Double(jsonWord.confidence)`.
- Idempotent: before rewrite, delete this book's `transcript-%` projection — `epub_block` rows whose `id LIKE 'transcript-%' AND audiobook_id = ?`, `timeline_item` rows whose `source_table = 'standalone_transcript' AND audiobook_id = ?`, and `word_timing` rows whose `epub_block_id LIKE 'transcript-%' AND audiobook_id = ?`. (Scope the prefix delete to this book only so a real EPUB book's rows are never touched.)

- [ ] **Step 1: Write the failing materializer test.** Create `EchoTests/TranscriptMaterializerTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB
  import Testing

  @testable import Echo

  @MainActor @Suite struct TranscriptMaterializerTests {
      private let bookID = "file:///book/"

      private func makeDB() throws -> DatabaseService {
          let db = try DatabaseService(inMemory: ())
          try db.writer.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'Test', 100, '2026-06-29T00:00:00Z')",
                  arguments: [bookID])
          }
          return db
      }

      private func seedSegment(
          _ writer: DatabaseWriter, chapterIndex: Int, segmentIndex: Int,
          text: String, start: TimeInterval, end: TimeInterval,
          words: [StandaloneTranscribedWord]
      ) throws {
          let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
          try writer.write { db in
              var rec = StandaloneTranscriptRecord(
                  id: "seg-\(chapterIndex)-\(segmentIndex)", audiobookID: bookID,
                  chapterIndex: chapterIndex, segmentIndex: segmentIndex, text: text,
                  startTime: start, endTime: end, wordsJSON: json,
                  createdAt: "2026-06-29T00:00:00Z")
              try rec.insert(db)
          }
      }

      @Test func materializesBlocksTimelineAndWordTimings() throws {
          let db = try makeDB()
          try seedSegment(
              db.writer, chapterIndex: 0, segmentIndex: 0,
              text: "Hello world.", start: 1.0, end: 2.0,
              words: [
                  .init(word: "Hello", start: 1.0, end: 1.4, confidence: 0.9),
                  .init(word: "world.", start: 1.4, end: 2.0, confidence: 0.8),
              ])

          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)

          let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
          #expect(blocks.count == 1)
          #expect(blocks[0].id == "transcript-\(bookID)-c0-s0")
          #expect(blocks[0].blockKind == EPubBlockRecord.Kind.paragraph.rawValue)
          #expect(blocks[0].text == "Hello world.")

          let items = try TimelineDAO(db: db.writer).items(for: bookID)
          #expect(items.count == 1)
          #expect(items[0].audioStartTime == 1.0)
          #expect(items[0].audioEndTime == 2.0)
          #expect(items[0].epubBlockID == "transcript-\(bookID)-c0-s0")
          #expect(items[0].timestampSource == TimestampSource.transcript.rawValue)
          #expect(items[0].isTimestamped)

          let words = try WordTimingDAO(db: db.writer)
              .words(forAudiobook: bookID, blockID: "transcript-\(bookID)-c0-s0")
          #expect(words.count == 2)
          #expect(words[0].wordIndex == 0)
          #expect(words[0].word == "Hello")
          #expect(words[0].audioStartTime == 1.0)
          #expect(words[0].source == "transcript")
          #expect(words[1].wordIndex == 1)
          #expect(words[1].audioEndTime == 2.0)
          #expect(abs(words[1].confidence - 0.8) < 0.001)
      }

      @Test func wordIndicesMatchWordTokenizer() throws {
          let db = try makeDB()
          try seedSegment(
              db.writer, chapterIndex: 0, segmentIndex: 0,
              text: "one two three", start: 0.0, end: 3.0,
              words: [
                  .init(word: "one", start: 0.0, end: 1.0, confidence: 0.9),
                  .init(word: "two", start: 1.0, end: 2.0, confidence: 0.9),
                  .init(word: "three", start: 2.0, end: 3.0, confidence: 0.9),
              ])
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          let block = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)[0]
          let tokenized = WordTokenizer.words(in: block.text ?? "").map(String.init)
          let words = try WordTimingDAO(db: db.writer)
              .words(forAudiobook: bookID, blockID: block.id)
          #expect(words.map(\.word) == tokenized)
          #expect(words.map(\.wordIndex) == Array(tokenized.indices))
      }

      @Test func isIdempotentNoDuplicateRows() throws {
          let db = try makeDB()
          try seedSegment(
              db.writer, chapterIndex: 0, segmentIndex: 0,
              text: "Hello world.", start: 1.0, end: 2.0,
              words: [
                  .init(word: "Hello", start: 1.0, end: 1.4, confidence: 0.9),
                  .init(word: "world.", start: 1.4, end: 2.0, confidence: 0.8),
              ])
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 1)
          #expect(try TimelineDAO(db: db.writer).items(for: bookID).count == 1)
          #expect(
              try WordTimingDAO(db: db.writer).words(forAudiobook: bookID).count == 2)
      }

      @Test func sequenceIndexMonotonicAcrossSegments() throws {
          let db = try makeDB()
          try seedSegment(
              db.writer, chapterIndex: 0, segmentIndex: 0, text: "a", start: 0, end: 1,
              words: [.init(word: "a", start: 0, end: 1, confidence: 0.9)])
          try seedSegment(
              db.writer, chapterIndex: 0, segmentIndex: 1, text: "b", start: 1, end: 2,
              words: [.init(word: "b", start: 1, end: 2, confidence: 0.9)])
          try seedSegment(
              db.writer, chapterIndex: 1, segmentIndex: 0, text: "c", start: 2, end: 3,
              words: [.init(word: "c", start: 2, end: 3, confidence: 0.9)])
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
          #expect(blocks.map(\.sequenceIndex) == [0, 1, 2])
          #expect(blocks.map(\.text) == ["a", "b", "c"])
      }
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile (`TranscriptMaterializer` undefined).
- [ ] **Step 3: Write the materializer.** Create `EchoCore/Services/TranscriptMaterializer.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB

  /// Projects an audio-only book's raw ASR rows (`standalone_transcript`) into the
  /// canonical reader tables so the existing read-along reader (highlight, search,
  /// tap-to-seek, study anchoring) drives it unchanged. The raw rows are retained
  /// as the audit copy; these projected rows are the reader projection.
  ///
  /// Each VAD segment becomes one paragraph `epub_block`, one timestamped
  /// `timeline_item`, and one `word_timing` row per ASR word (real start/end times,
  /// not interpolated). Block text is the ASR words joined by single spaces, so its
  /// `WordTokenizer` token sequence is 1:1 with `words_json` — the reader's word
  /// highlight lands on the right token.
  ///
  /// Idempotent: deletes this book's `transcript-%` projection before rewrite, so
  /// re-transcribe converges to a single clean copy.
  enum TranscriptMaterializer {
      static func materialize(audiobookID: String, writer: DatabaseWriter) throws {
          let segments = try writer.read { db in
              try StandaloneTranscriptRecord
                  .filter(Column("audiobook_id") == audiobookID)
                  .order(Column("chapter_index"), Column("segment_index"))
                  .fetchAll(db)
          }

          try deleteProjection(audiobookID: audiobookID, writer: writer)
          guard !segments.isEmpty else { return }

          var blocks: [EPubBlockRecord] = []
          var items: [TimelineItem] = []
          var wordTimings: [WordTimingRecord] = []
          let now = ISO8601DateFormatter().string(from: Date())

          for (sequence, segment) in segments.enumerated() {
              let asrWords = decodeWords(segment.wordsJSON)
              let blockText =
                  asrWords.isEmpty
                  ? segment.text
                  : asrWords.map(\.word).joined(separator: " ")
              let blockID = "transcript-\(audiobookID)-c\(segment.chapterIndex)-s\(segment.segmentIndex)"

              blocks.append(
                  EPubBlockRecord(
                      id: blockID,
                      audiobookID: audiobookID,
                      spineHref: "transcript",
                      spineIndex: segment.chapterIndex,
                      blockIndex: segment.segmentIndex,
                      sequenceIndex: sequence,
                      blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                      text: blockText,
                      htmlContent: nil,
                      cardColor: nil,
                      chapterThemeColor: nil,
                      imagePath: nil,
                      chapterIndex: segment.chapterIndex,
                      isHidden: false,
                      hiddenReason: nil,
                      wordCount: WordTokenizer.words(in: blockText).count,
                      markers: nil,
                      textFormats: nil,
                      createdAt: now,
                      modifiedAt: nil))

              items.append(
                  TimelineItem(
                      id: "epub-\(blockID)",
                      audiobookID: audiobookID,
                      itemType: .textSegment,
                      title: blockText,
                      subtitle: nil,
                      textPayload: blockText,
                      imagePath: nil,
                      audioStartTime: segment.startTime,
                      audioEndTime: segment.endTime,
                      epubSequenceIndex: sequence,
                      granularityLevel: .paragraph,
                      playlistPosition: nil,
                      isEnabled: true,
                      sourceTable: "standalone_transcript",
                      sourceRowid: segment.id,
                      metadataJSON: nil,
                      epubBlockID: blockID,
                      timestampSource: TimestampSource.transcript.rawValue,
                      alignmentStatus: AlignmentStatus.lockedAnchor.rawValue,
                      alignmentConfidence: nil,
                      createdAt: now,
                      modifiedAt: nil))

              // word_index is the position over WordTokenizer of the block text.
              // Because blockText joins the ASR words by single spaces, that token
              // sequence is identical to asrWords — so the JSON index IS the
              // tokenizer index. Enforce the invariant by zipping against the
              // tokenizer so a stray space in an ASR word can't desync the highlight.
              let tokens = WordTokenizer.words(in: blockText)
              for (index, asr) in asrWords.enumerated() where index < tokens.count {
                  wordTimings.append(
                      WordTimingRecord(
                          audiobookID: audiobookID,
                          epubBlockID: blockID,
                          wordIndex: index,
                          word: String(tokens[index]),
                          audioStartTime: asr.start,
                          audioEndTime: asr.end,
                          confidence: Double(asr.confidence),
                          source: "transcript"))
              }
          }

          try EPubBlockDAO(db: writer).insertAll(blocks)
          try TimelineDAO(db: writer).ingest(items)
          try WordTimingDAO(db: writer).insert(wordTimings)
      }

      private static func decodeWords(_ json: String?) -> [StandaloneTranscribedWord] {
          guard let json, let data = json.data(using: .utf8) else { return [] }
          return (try? JSONDecoder().decode([StandaloneTranscribedWord].self, from: data)) ?? []
      }

      /// Deletes only THIS book's transcript projection (prefix-scoped to the book
      /// id), never an EPUB/PDF book's canonical rows.
      private static func deleteProjection(audiobookID: String, writer: DatabaseWriter) throws {
          try writer.write { db in
              try db.execute(
                  sql: """
                      DELETE FROM word_timing
                      WHERE audiobook_id = ? AND epub_block_id LIKE 'transcript-%'
                      """, arguments: [audiobookID])
              try db.execute(
                  sql: """
                      DELETE FROM timeline_item
                      WHERE audiobook_id = ? AND source_table = 'standalone_transcript'
                      """, arguments: [audiobookID])
              try db.execute(
                  sql: """
                      DELETE FROM epub_block
                      WHERE audiobook_id = ? AND id LIKE 'transcript-%'
                      """, arguments: [audiobookID])
          }
      }
  }
  ```
- [ ] **Step 4: Run the test (expect PASS).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/TranscriptMaterializerTests
  ```
  Expected: PASS (4 tests).
- [ ] **Step 5: Commit.** Run:
  ```
  git add EchoCore/Services/TranscriptMaterializer.swift EchoTests/TranscriptMaterializerTests.swift
  git commit -m "feat(reader): add TranscriptMaterializer projecting standalone transcript into reader tables"
  ```

---

## Task 3 — `StandaloneTranscriptionService`: canonical audiobook id + buildRecords FK fix

**Files:**
- Modify `EchoCore/Services/StandaloneTranscriptionService.swift` (`start` signature at :39; call site at :151-156 passing `audiobookID: audioFileURL.absoluteString` — THE FK BUG; `transcribeChapter` private :102; `buildRecords` :177)
- Modify `EchoTests/StandaloneTranscriptionServiceTests.swift` (add buildRecords-via-public-path coverage — but buildRecords is private/WhisperKit-coupled, so test the *id derivation* through a new pure helper, see below)

**Interfaces:**
- Produces: `func start(audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true) async` (new `audiobookID` parameter; `audioFileURL` kept for audio reads only)
- Produces: private `transcribeChapter(audiobookID:audioFileURL:chapter:chapterIndex:db:)` and `buildRecords(from:captureStart:chapterIndex:audiobookID:)` now fed the canonical id from the caller.

Rationale: today `buildRecords` is called with `audiobookID: audioFileURL.absoluteString` (line 155). `standalone_transcript.audiobook_id` is a FK to `audiobook(id)` which is `folderURL.absoluteString` — so the inserted rows point at a non-existent parent and never match `hasStandaloneTranscript`/the reader JOIN. Threading the canonical `audiobookID` from the caller fixes this without changing how audio bytes are read (still from `audioFileURL`).

- [ ] **Step 1: Write the failing id-derivation test.** Append to `EchoTests/StandaloneTranscriptionServiceTests.swift` (inside the existing struct):
  ```swift
      // MARK: - Canonical id (FK) — empty-chapters fast path keys nothing wrong

      @Test func startWithNoChaptersDoesNotRunAndKeepsCanonicalIdSeam() async throws {
          let db = try makeTestDB()
          // Parent keyed by the canonical folder id, NOT the audio file id.
          try db.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('file:///book/', 'Test', 60, '2026-06-29T00:00:00Z')")
          }
          let service = StandaloneTranscriptionService(db: db)
          await service.start(
              audiobookID: "file:///book/",
              audioFileURL: URL(fileURLWithPath: "/tmp/book/audio.m4b"),
              chapters: [])
          #expect(service.progress.isRunning == false)
          // No chapters → no rows, and crucially the call compiles against the new
          // signature that carries the canonical id separately from the audio URL.
          let count = try db.read { database in
              try StandaloneTranscriptRecord
                  .filter(Column("audiobook_id") == "file:///book/")
                  .fetchCount(database)
          }
          #expect(count == 0)
      }
  ```
- [ ] **Step 2: Run the test (expect FAIL).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile — `start(audiobookID:audioFileURL:chapters:)` does not exist (current signature is `start(audioFileURL:chapters:)`).
- [ ] **Step 3: Change the `start` signature and thread the id.** In `EchoCore/Services/StandaloneTranscriptionService.swift`, change the declaration at :39 to:
  ```swift
      func start(
          audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true
      ) async {
  ```
  Update both `transcribeChapter(...)` call sites (the foreground chapter-0 call ~:51 and the background loop call ~:74) to pass `audiobookID: audiobookID`. Change `transcribeChapter`'s signature (:102) to add `audiobookID: String` as the first parameter, and change the `buildRecords` call (:151-156) from `audiobookID: audioFileURL.absoluteString` to `audiobookID: audiobookID`. (Leave `resume` unused for now — Task 4 wires it.)
- [ ] **Step 4: Run the test (expect PASS).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/StandaloneTranscriptionServiceTests
  ```
  Expected: PASS (existing tests + the new one). Verify SPDX line 1 survived the edit.
- [ ] **Step 5: Commit.** Run:
  ```
  git add EchoCore/Services/StandaloneTranscriptionService.swift EchoTests/StandaloneTranscriptionServiceTests.swift
  git commit -m "fix(transcription): key standalone_transcript by canonical folder id (FK fix)"
  ```

---

## Task 4 — True resume, `clearTranscript`, and `pause()`=stop (no isCancelled)

**Files:**
- Modify `EchoCore/Services/StandaloneTranscriptionService.swift` (add a `chapterHasRows` check before transcribing when `resume`; add `resume()` and `clearTranscript(audiobookID:)`; change `pause()` so it stops without setting `progress.isCancelled`)
- Modify `EchoTests/StandaloneTranscriptionServiceTests.swift` (resume skip-logic + clear)

**Interfaces:**
- Produces: resume skip — when `resume`, `transcribeChapter` returns early if `standalone_transcript` already has a row for `(audiobook_id, chapter_index)`.
- Produces: `func resume()` — restarts the background loop from the first incomplete chapter (re-invokes `start(..., resume: true)` with the cached args).
- Produces: `func clearTranscript(audiobookID: String) async` — deletes the book's `standalone_transcript` rows AND its materialized projection (`TranscriptMaterializer` projection), then resets progress.
- Produces: `func pause()` stops the running task without setting `progress.isCancelled`.

To support `resume()`, store the last-start args in `@ObservationIgnored private var lastStartArgs: (audiobookID: String, audioFileURL: URL, chapters: [Chapter])?` set at the top of `start`.

- [ ] **Step 1: Write the failing resume/clear test.** Append to `EchoTests/StandaloneTranscriptionServiceTests.swift`:
  ```swift
      // MARK: - Resume skip-logic + clear

      private func seedSegmentRow(
          _ db: DatabaseWriter, audiobookID: String, chapterIndex: Int
      ) throws {
          try db.write { database in
              var rec = StandaloneTranscriptRecord(
                  id: "seg-\(chapterIndex)", audiobookID: audiobookID,
                  chapterIndex: chapterIndex, segmentIndex: 0, text: "x",
                  startTime: 0, endTime: 1, wordsJSON: nil,
                  createdAt: "2026-06-29T00:00:00Z")
              try rec.insert(database)
          }
      }

      @Test func pauseDoesNotSetCancelled() throws {
          let db = try makeTestDB()
          let service = StandaloneTranscriptionService(db: db)
          service.progress.isRunning = true
          service.pause()
          #expect(service.progress.isCancelled == false)
      }

      @Test func clearTranscriptRemovesRowsAndProjection() async throws {
          let db = try makeTestDB()
          let bookID = "file:///book/"
          try db.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                  arguments: [bookID])
          }
          // Seed one raw segment with a word so the projection has all three tables.
          let words = [StandaloneTranscribedWord(word: "x", start: 0, end: 1, confidence: 0.9)]
          let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
          try db.write { database in
              var rec = StandaloneTranscriptRecord(
                  id: "seg-0", audiobookID: bookID, chapterIndex: 0, segmentIndex: 0,
                  text: "x", startTime: 0, endTime: 1, wordsJSON: json,
                  createdAt: "2026-06-29T00:00:00Z")
              try rec.insert(database)
          }
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db)
          #expect(try EPubBlockDAO(db: db).count(for: bookID) == 1)

          let service = StandaloneTranscriptionService(db: db)
          await service.clearTranscript(audiobookID: bookID)

          let raw = try db.read { database in
              try StandaloneTranscriptRecord
                  .filter(Column("audiobook_id") == bookID).fetchCount(database)
          }
          #expect(raw == 0)
          #expect(try EPubBlockDAO(db: db).count(for: bookID) == 0)
          #expect(try TimelineDAO(db: db).items(for: bookID).isEmpty)
          #expect(try WordTimingDAO(db: db).words(forAudiobook: bookID).isEmpty)
      }
  ```
- [ ] **Step 2: Run the test (expect FAIL).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile (`clearTranscript` undefined; `pauseDoesNotSetCancelled` only passes once `pause()` is decoupled from `cancel()`).
- [ ] **Step 3: Implement resume skip, `resume()`, `clearTranscript`, and `pause()`=stop.** In `EchoCore/Services/StandaloneTranscriptionService.swift`:
  - Add stored property near `progress` (line 18 area):
    ```swift
        @ObservationIgnored private var lastStartArgs:
            (audiobookID: String, audioFileURL: URL, chapters: [Chapter])?
    ```
  - At the top of `start`, after `guard let db else { return }`, cache args:
    ```swift
            lastStartArgs = (audiobookID, audioFileURL, chapters)
    ```
  - In `transcribeChapter`, before reading audio, add the resume guard (using the new `audiobookID` parameter and a `resume` parameter threaded down — add `resume: Bool` to `transcribeChapter`'s signature and pass `resume` from both call sites):
    ```swift
            if resume {
                let existing = try? await db.read { database in
                    try StandaloneTranscriptRecord
                        .filter(Column("audiobook_id") == audiobookID)
                        .filter(Column("chapter_index") == chapterIndex)
                        .fetchCount(database)
                }
                if let existing, existing > 0 {
                    logger.debug("Resume: chapter \(chapterIndex) already has rows; skipping")
                    return
                }
            }
    ```
  - Change `pause()` (:86) to NOT set `isCancelled`:
    ```swift
        /// Stops the running pipeline without marking it cancelled, so it can be
        /// resumed from the first incomplete chapter via `resume()`.
        func pause() {
            currentTask.cancel()
            progress.isRunning = false
        }
    ```
  - Add `resume()`:
    ```swift
        /// Continues from the first chapter without persisted rows, reusing the
        /// last `start(...)` arguments. No-op if nothing was started yet.
        func resume() {
            guard let args = lastStartArgs else { return }
            Task { @MainActor in
                await self.start(
                    audiobookID: args.audiobookID,
                    audioFileURL: args.audioFileURL,
                    chapters: args.chapters,
                    resume: true)
            }
        }
    ```
  - Add `clearTranscript`:
    ```swift
        /// Deletes the book's raw ASR rows and its materialized reader projection,
        /// then resets progress so a subsequent `start(resume:false)`-style run
        /// produces a single clean copy.
        func clearTranscript(audiobookID: String) async {
            guard let db else { return }
            do {
                try await db.write { database in
                    try StandaloneTranscriptRecord
                        .filter(Column("audiobook_id") == audiobookID)
                        .deleteAll(database)
                    try database.execute(
                        sql: "DELETE FROM word_timing WHERE audiobook_id = ? AND epub_block_id LIKE 'transcript-%'",
                        arguments: [audiobookID])
                    try database.execute(
                        sql: "DELETE FROM timeline_item WHERE audiobook_id = ? AND source_table = 'standalone_transcript'",
                        arguments: [audiobookID])
                    try database.execute(
                        sql: "DELETE FROM epub_block WHERE audiobook_id = ? AND id LIKE 'transcript-%'",
                        arguments: [audiobookID])
                }
                progress.reset()
            } catch {
                logger.error("clearTranscript failed: \(error.localizedDescription)")
            }
        }
    ```
- [ ] **Step 4: Run the test (expect PASS).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/StandaloneTranscriptionServiceTests
  ```
  Expected: PASS. Verify SPDX line 1 survived.
- [ ] **Step 5: Commit.** Run:
  ```
  git add EchoCore/Services/StandaloneTranscriptionService.swift EchoTests/StandaloneTranscriptionServiceTests.swift
  git commit -m "feat(transcription): true resume, clearTranscript, and pause=stop"
  ```

---

## Task 5 — `TranscribeBookCoordinator`: run → materialize → set text_origin (MainActor model)

**Files:**
- Create `EchoCore/ViewModels/TranscribeBookCoordinator.swift` (guard the whole file with `#if os(iOS)` — it owns `StandaloneTranscriptionService` which is `@MainActor` and is consumed only by the iOS reader UI; this keeps it out of the macOS/echo-cli builds without a `project.pbxproj` edit). *If* SwiftFormat/compiler still bundles it into macOS, exclude it from BOTH `Echo macOS` and `echo-cli` target source lists in `Echo.xcodeproj/project.pbxproj` per the parity constraint.
- Create `EchoTests/TranscribeBookCoordinatorTests.swift`

**Interfaces:**
- Consumes: `StandaloneTranscriptionService(db:)`, `TranscriptMaterializer.materialize(audiobookID:writer:)`, `AudiobookDAO.save(_:)` / `get(_:)`, `Chapter`.
- Produces:
  ```swift
  @MainActor @Observable final class TranscribeBookCoordinator {
      let service: StandaloneTranscriptionService
      private(set) var isFinalizing: Bool
      init(db: DatabaseWriter)
      func transcribe(audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true) async
      func finalize(audiobookID: String) async
  }
  ```
- `transcribe` calls `service.start(...)` then, when the service finishes (`!service.progress.isRunning`), calls `finalize`.
- `finalize` runs `TranscriptMaterializer.materialize` then sets `audiobook.text_origin = "transcript"` via `AudiobookDAO` (read-modify-save preserving other fields).

Note: `finalize` is separately testable (no WhisperKit needed) — the test seeds raw rows, calls `finalize`, and asserts the projection exists and `text_origin == "transcript"`.

- [ ] **Step 1: Write the failing finalize test.** Create `EchoTests/TranscribeBookCoordinatorTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  #if os(iOS)
      import Foundation
      import GRDB
      import Testing

      @testable import Echo

      @MainActor @Suite struct TranscribeBookCoordinatorTests {
          private let bookID = "file:///book/"

          private func makeDB() throws -> DatabaseService {
              let db = try DatabaseService(inMemory: ())
              try db.writer.write { database in
                  try database.execute(
                      sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                      arguments: [bookID])
                  var rec = StandaloneTranscriptRecord(
                      id: "seg-0", audiobookID: bookID, chapterIndex: 0, segmentIndex: 0,
                      text: "Hello world.", startTime: 0, endTime: 2,
                      wordsJSON: String(
                          data: try JSONEncoder().encode([
                              StandaloneTranscribedWord(word: "Hello", start: 0, end: 1, confidence: 0.9),
                              StandaloneTranscribedWord(word: "world.", start: 1, end: 2, confidence: 0.8),
                          ]), encoding: .utf8),
                      createdAt: "2026-06-29T00:00:00Z")
                  try rec.insert(database)
              }
              return db
          }

          @Test func finalizeMaterializesAndSetsTextOrigin() async throws {
              let db = try makeDB()
              let coordinator = TranscribeBookCoordinator(db: db.writer)
              await coordinator.finalize(audiobookID: bookID)

              #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 1)
              #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin == "transcript")
              #expect(coordinator.isFinalizing == false)
          }

          @Test func finalizePreservesOtherAudiobookFields() async throws {
              let db = try makeDB()
              try AudiobookDAO(db: db.writer).save(
                  AudiobookRecord(
                      id: bookID, title: "Keep Me", author: "Author", duration: 60,
                      addedAt: "2026-06-29T00:00:00Z"))
              await TranscribeBookCoordinator(db: db.writer).finalize(audiobookID: bookID)
              let book = try AudiobookDAO(db: db.writer).get(bookID)
              #expect(book?.title == "Keep Me")
              #expect(book?.author == "Author")
              #expect(book?.textOrigin == "transcript")
          }
      }
  #endif
  ```
- [ ] **Step 2: Run the test (expect FAIL).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile (`TranscribeBookCoordinator` undefined).
- [ ] **Step 3: Write the coordinator.** Create `EchoCore/ViewModels/TranscribeBookCoordinator.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  #if os(iOS)
      import Foundation
      import GRDB
      import Observation
      import os.log

      /// Owns the audio-only transcription flow for one book: runs the WhisperKit
      /// pipeline, then projects the result into the reader tables and marks the
      /// book's provenance so the reader picks it up. iOS-only: it owns the
      /// `@MainActor` `StandaloneTranscriptionService` consumed by the reader UI.
      @MainActor
      @Observable
      final class TranscribeBookCoordinator {
          let service: StandaloneTranscriptionService
          private(set) var isFinalizing = false

          @ObservationIgnored private let writer: DatabaseWriter
          private let logger = Logger(category: "TranscribeBookCoordinator")

          init(db: DatabaseWriter) {
              self.writer = db
              self.service = StandaloneTranscriptionService(db: db)
          }

          /// Runs the pipeline and, on natural completion (not cancellation),
          /// finalizes the book into the reader.
          func transcribe(
              audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true
          ) async {
              await service.start(
                  audiobookID: audiobookID, audioFileURL: audioFileURL,
                  chapters: chapters, resume: resume)
              // Chapter 0 runs inline; the rest run in a detached task. Only finalize
              // once the whole run has settled and was not cancelled.
              guard !service.progress.isRunning, !service.progress.isCancelled else { return }
              await finalize(audiobookID: audiobookID)
          }

          /// Projects raw ASR rows into the reader tables and stamps provenance.
          func finalize(audiobookID: String) async {
              isFinalizing = true
              defer { isFinalizing = false }
              do {
                  try TranscriptMaterializer.materialize(audiobookID: audiobookID, writer: writer)
                  let dao = AudiobookDAO(db: writer)
                  if var book = try dao.get(audiobookID) {
                      book.textOrigin = "transcript"
                      try dao.save(book)
                  }
              } catch {
                  logger.error("finalize failed: \(error.localizedDescription)")
              }
          }
      }
  #endif
  ```
- [ ] **Step 4: Run the test (expect PASS).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/TranscribeBookCoordinatorTests
  ```
  Expected: PASS (2 tests). Verify SPDX line 1 survived.
- [ ] **Step 5: Add the new file to the Xcode targets.** The new `EchoCore/ViewModels/TranscribeBookCoordinator.swift` must be a member of the iOS app target and the iOS test target (it compiles under `#if os(iOS)`; on macOS/echo-cli it compiles to an empty file, so it may stay in those membership lists or be excluded — either is parity-safe). Confirm `make build-tests` (iOS) already picked it up in Step 4 (a missing target membership would have produced "cannot find 'TranscribeBookCoordinator'"). If it was NOT picked up, add it to the iOS `Sources` build phase in `Echo.xcodeproj/project.pbxproj` next to `Views/AutoAlignmentProgressView.swift`. Re-run Step 4 to confirm.
- [ ] **Step 6: Commit.** Run:
  ```
  git add EchoCore/ViewModels/TranscribeBookCoordinator.swift EchoTests/TranscribeBookCoordinatorTests.swift Echo.xcodeproj/project.pbxproj
  git commit -m "feat(transcription): add TranscribeBookCoordinator (run, materialize, set provenance)"
  ```

---

## Task 6 — User-facing transcribe action + progress UI in the Read tab

**Files:**
- Create `EchoCore/Views/TranscribeProgressView.swift` (iOS-only SwiftUI sheet; mirror `AutoAlignmentProgressView`. Add to iOS app + test targets next to it in `project.pbxproj`.)
- Modify `EchoCore/Views/RootTabView.swift` (the `.read` branch at lines 196-215: present a "Transcribe this book" action + progress when the book is audio-only — `!model.hasEPUB && !model.hasPDF` — and route to `ReaderTab` once `model.hasEPUB` becomes true after materialization)
- Create `EchoTests/TranscribeProgressViewTests.swift` (light: progress-formatting helper test against `StandaloneProgressState`, no UI host)

**Interfaces:**
- Consumes: `TranscribeBookCoordinator`, `StandaloneProgressState`, `model.tracks[model.currentIndex].url` (audio file URL), `model.alignmentPickerChapters` (or `model.chapters`) for `[Chapter]`, `model.folderURL!.absoluteString` (canonical id), `model.databaseService`.
- Produces: `TranscribeProgressView` showing `progress.chaptersComplete / progress.chaptersTotal`, an `isFinalizing` state, and Cancel/Done. The Read tab's empty state for audio-only books gains a "Transcribe Audiobook" button that builds a `TranscribeBookCoordinator` and runs `transcribe(...)`.

Because `RootTabView` reads `model.hasEPUB` (which registers `documentIngestionTrigger` and counts visible `epub_block`), and `finalize` inserts `epub_block` rows, the view re-evaluates and routes to `ReaderTab` automatically after materialization — *provided* `documentIngestionTrigger` is bumped. So the action's completion handler must bump the trigger: `model.bumpDocumentIngestionTrigger()` (add a tiny pass-through on `PlayerModel` that does `state.documentIngestionTrigger += 1`, mirroring the bumps already in `PlayerModel+Bookmarks.swift:174,203`).

- [ ] **Step 1: Write the failing progress-formatting test.** Create `EchoTests/TranscribeProgressViewTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  #if os(iOS)
      import Foundation
      import Testing

      @testable import Echo

      @MainActor @Suite struct TranscribeProgressViewTests {
          @Test func progressFractionZeroChaptersIsZero() {
              let state = StandaloneProgressState()
              #expect(TranscribeProgressView.fraction(for: state) == 0.0)
          }

          @Test func progressFractionHalfway() {
              let state = StandaloneProgressState()
              state.chaptersTotal = 4
              state.chaptersComplete = 2
              #expect(TranscribeProgressView.fraction(for: state) == 0.5)
          }

          @Test func progressFractionCapsAtOne() {
              let state = StandaloneProgressState()
              state.chaptersTotal = 2
              state.chaptersComplete = 5
              #expect(TranscribeProgressView.fraction(for: state) == 1.0)
          }
      }
  #endif
  ```
- [ ] **Step 2: Run the test (expect FAIL).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: FAIL to compile (`TranscribeProgressView` undefined).
- [ ] **Step 3: Write the progress view with the testable static helper.** Create `EchoCore/Views/TranscribeProgressView.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  #if os(iOS)
      import SwiftUI

      /// Sheet shown while an audio-only book is transcribed on-device, then
      /// materialized into the reader. Mirrors `AutoAlignmentProgressView`'s shape.
      struct TranscribeProgressView: View {
          let progress: StandaloneProgressState
          let isFinalizing: Bool
          var onCancel: (() -> Void)?
          @Environment(\.dismiss) private var dismiss

          /// Fraction complete (0...1). Static + pure so it is unit-testable.
          static func fraction(for state: StandaloneProgressState) -> Double {
              guard state.chaptersTotal > 0 else { return 0.0 }
              return min(1.0, Double(state.chaptersComplete) / Double(state.chaptersTotal))
          }

          private var isDone: Bool {
              !progress.isRunning && !isFinalizing && progress.chaptersTotal > 0
                  && progress.chaptersComplete >= progress.chaptersTotal
          }

          var body: some View {
              VStack(spacing: 12) {
                  Image(systemName: "text.bubble")
                      .font(.system(size: 32))
                      .foregroundStyle(Color.accentColor)
                      .symbolEffect(.pulse, isActive: progress.isRunning || isFinalizing)

                  Text("Transcribing Audiobook")
                      .font(.title3.bold())

                  ProgressView(value: Self.fraction(for: progress)) {
                      Text(
                          isFinalizing
                              ? String(localized: "Building reader…")
                              : String(
                                  localized:
                                      "Chapter \(progress.chaptersComplete) of \(progress.chaptersTotal)"))
                          .font(.caption)
                          .foregroundStyle(.secondary)
                  }
                  .padding(.horizontal)

                  if isDone {
                      Button("Done") { dismiss() }
                          .buttonStyle(.borderedProminent)
                  } else {
                      Button("Cancel") {
                          onCancel?()
                          dismiss()
                      }
                      .buttonStyle(.bordered)
                  }
              }
              .padding()
              .frame(minWidth: 360, idealWidth: 400)
          }
      }
  #endif
  ```
- [ ] **Step 4: Run the test (expect PASS).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/TranscribeProgressViewTests
  ```
  Expected: PASS (3 tests). Add the new file to the iOS app + test targets in `project.pbxproj` next to `Views/AutoAlignmentProgressView.swift` if Step 4 reports it missing, then re-run.
- [ ] **Step 5: Add the trigger-bump pass-through on PlayerModel.** In `EchoCore/ViewModels/PlayerModel.swift`, add near the `hasStandaloneTranscript` accessor (after line 463):
  ```swift
      /// Bumps the document-ingestion trigger so reader routing re-evaluates after
      /// transcript materialization inserts `epub_block` rows (`hasEPUB` flips true).
      func bumpDocumentIngestionTrigger() {
          state.documentIngestionTrigger += 1
      }
  ```
- [ ] **Step 6: Wire the action into the Read tab.** In `EchoCore/Views/RootTabView.swift`, the `.read` branch (lines 196-215): when none of `hasEPUB`/`hasPDF`/`hasStandaloneTranscript` is true but a book is loaded and `model.databaseService != nil`, render `ReaderEmptyState` with a new "Transcribe Audiobook" primary action; when `hasStandaloneTranscript` is true but `hasEPUB` is false (transcribed but not yet materialized — e.g. a partially-transcribed or legacy book), also offer the transcribe/finish action. The action:
  - builds `let coordinator = TranscribeBookCoordinator(db: db.writer)` (held in `@State` on `RootTabView`),
  - presents `TranscribeProgressView(progress: coordinator.service.progress, isFinalizing: coordinator.isFinalizing, onCancel: { coordinator.service.cancel() })` in a `.sheet`,
  - runs:
    ```swift
    Task { @MainActor in
        guard let folder = model.folderURL,
              model.tracks.indices.contains(model.currentIndex) else { return }
        await coordinator.transcribe(
            audiobookID: folder.absoluteString,
            audioFileURL: model.tracks[model.currentIndex].url,
            chapters: model.alignmentPickerChapters,
            resume: true)
        model.bumpDocumentIngestionTrigger()
    }
    ```
  Add the `@State private var transcribeCoordinator: TranscribeBookCoordinator?` and `@State private var showingTranscribeProgress = false` to `RootTabView`. Keep all of this inside the existing `#if`/iOS context of `RootTabView` (it is an iOS view). Use `String(localized:)` for the button title `"Transcribe Audiobook"`.
- [ ] **Step 7: Build the iOS app + tests to confirm the wiring compiles.** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  ```
  Expected: PASS (compiles). Re-run the two suites touched:
  ```
  make test-only FILTER=EchoTests/TranscribeProgressViewTests
  make test-only FILTER=EchoTests/TranscribeBookCoordinatorTests
  ```
  Expected: PASS. Verify SPDX line 1 on every edited/created file.
- [ ] **Step 8: Commit.** Run:
  ```
  git add EchoCore/Views/TranscribeProgressView.swift EchoCore/Views/RootTabView.swift EchoCore/ViewModels/PlayerModel.swift EchoTests/TranscribeProgressViewTests.swift Echo.xcodeproj/project.pbxproj
  git commit -m "feat(reader): add user-facing transcribe action + progress wiring for audio-only books"
  ```

---

## Task 7 — Persistence / relaunch integration test (no duplicate rows; survives reopen)

**Files:**
- Create `EchoTests/TranscriptReaderParityTests.swift` (uses `DatabaseService(inMemory: ())` — "relaunch" is simulated by re-reading the same writer after the projection write, which is the persistence seam the reader reads through; an on-disk relaunch is covered by manual verification noted in Task 8)

**Interfaces:**
- Consumes: `TranscriptMaterializer`, `EPubBlockDAO.visibleBlocks`/`searchBlocks`, `TimelineDAO`, `WordTimingDAO`, `AudiobookDAO`.
- Produces: end-to-end assertions that the materialized projection supports the reader contracts (visible blocks, search hit, word timing for highlight, timestamped timeline for tap-to-seek) and that re-materialize keeps exactly one copy.

- [ ] **Step 1: Write the integration test.** Create `EchoTests/TranscriptReaderParityTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB
  import Testing

  @testable import Echo

  @MainActor @Suite struct TranscriptReaderParityTests {
      private let bookID = "file:///book/"

      private func makeDBWithTwoSegments() throws -> DatabaseService {
          let db = try DatabaseService(inMemory: ())
          try db.writer.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                  arguments: [bookID])
          }
          func insert(_ ci: Int, _ si: Int, _ text: String, _ start: Double, _ end: Double,
                      _ words: [StandaloneTranscribedWord]) throws {
              let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
              try db.writer.write { database in
                  var rec = StandaloneTranscriptRecord(
                      id: "seg-\(ci)-\(si)", audiobookID: bookID, chapterIndex: ci,
                      segmentIndex: si, text: text, startTime: start, endTime: end,
                      wordsJSON: json, createdAt: "2026-06-29T00:00:00Z")
                  try rec.insert(database)
              }
          }
          try insert(0, 0, "The quick fox.", 0.0, 2.0, [
              .init(word: "The", start: 0.0, end: 0.5, confidence: 0.9),
              .init(word: "quick", start: 0.5, end: 1.2, confidence: 0.9),
              .init(word: "fox.", start: 1.2, end: 2.0, confidence: 0.9),
          ])
          try insert(0, 1, "Lazy dog runs.", 2.0, 4.0, [
              .init(word: "Lazy", start: 2.0, end: 2.6, confidence: 0.9),
              .init(word: "dog", start: 2.6, end: 3.2, confidence: 0.9),
              .init(word: "runs.", start: 3.2, end: 4.0, confidence: 0.9),
          ])
          return db
      }

      @Test func materializedBookSupportsReaderContracts() throws {
          let db = try makeDBWithTwoSegments()
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          AudiobookDAO(db: db.writer).save(
              try { var b = try AudiobookDAO(db: db.writer).get(bookID)!; b.textOrigin = "transcript"; return b }())

          // hasEPUB-style: visible blocks exist → reader routes here.
          let visible = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
          #expect(visible.count == 2)

          // search-to-seek: a search term resolves to a block.
          let hits = try EPubBlockDAO(db: db.writer).searchBlocks(for: bookID, query: "dog")
          #expect(hits.count == 1)
          #expect(hits[0].id == "transcript-\(bookID)-c0-s1")

          // tap-to-seek: that block's timeline row is timestamped.
          let items = try TimelineDAO(db: db.writer).items(for: bookID)
          let dogItem = items.first { $0.epubBlockID == hits[0].id }
          #expect(dogItem?.isTimestamped == true)
          #expect(dogItem?.audioStartTime == 2.0)

          // word highlight: per-word timings exist and index 1:1 with the tokens.
          let words = try WordTimingDAO(db: db.writer)
              .words(forAudiobook: bookID, blockID: hits[0].id)
          #expect(words.map(\.word) == ["Lazy", "dog", "runs."])
          #expect(words[1].audioStartTime == 2.6)

          // provenance is queryable.
          #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin == "transcript")
      }

      @Test func reMaterializeKeepsSingleCopyAndPreservesData() throws {
          let db = try makeDBWithTwoSegments()
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 2)
          #expect(try TimelineDAO(db: db.writer).items(for: bookID).count == 2)
          #expect(try WordTimingDAO(db: db.writer).words(forAudiobook: bookID).count == 6)
      }

      @Test func materializeDoesNotTouchAnUnrelatedEpubBook() throws {
          let db = try makeDBWithTwoSegments()
          let otherID = "file:///other/"
          try db.writer.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'Other', 60, '2026-06-29T00:00:00Z')",
                  arguments: [otherID])
          }
          // A real (non-transcript) EPUB block id for the other book.
          try EPubBlockDAO(db: db.writer).insert(
              EPubBlockRecord(
                  id: "epub-\(otherID)-s0-b0", audiobookID: otherID, spineHref: "c1.xhtml",
                  spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                  blockKind: EPubBlockRecord.Kind.paragraph.rawValue, text: "Canonical.",
                  isHidden: false))
          try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
          #expect(try EPubBlockDAO(db: db.writer).count(for: otherID) == 1)
      }
  }
  ```
- [ ] **Step 2: Run the test (expect PASS — implementation already exists from Tasks 2/5).** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/TranscriptReaderParityTests
  ```
  Expected: PASS (3 tests). If a contract assertion fails, fix the materializer (Task 2) — the integration test is the acceptance gate, not new product code.
- [ ] **Step 3: Commit.** Run:
  ```
  git add EchoTests/TranscriptReaderParityTests.swift
  git commit -m "test(reader): integration coverage for transcript reader parity + idempotent re-materialize"
  ```

---

## Task 8 — Cross-platform parity + doc-sync

**Files:**
- Modify `ARCHITECTURE.md` (add the transcript-materialization subsystem; note `text_origin` provenance)
- Modify `CHANGELOG.md` (note Schema V29 + audio-only reader parity)
- Verify `Echo.xcodeproj/project.pbxproj` target membership for every new file

**Interfaces:** none (docs + verification).

- [ ] **Step 1: Run the parity reviewer.** Run the `cross-platform-parity-reviewer` agent over the diff (`Shared/Database/Migrations/Schema_V29.swift`, `Shared/Database/DAOs/AudiobookDAO.swift`, `EchoCore/Services/TranscriptMaterializer.swift`, `EchoCore/ViewModels/TranscribeBookCoordinator.swift`, `EchoCore/Views/TranscribeProgressView.swift`, `EchoCore/Views/RootTabView.swift`, `EchoCore/ViewModels/PlayerModel.swift`). Confirm: `Schema_V29` + `AudiobookRecord.textOrigin` + `TranscriptMaterializer` are shared (no UIKit, bundle into all targets); the iOS-only `TranscribeBookCoordinator`/`TranscribeProgressView` are `#if os(iOS)`-guarded so macOS/echo-cli compile them to empty files (parity-safe) — and if any is NOT guarded/empty there, exclude it from BOTH `Echo macOS` and `echo-cli` source lists in `project.pbxproj`.
- [ ] **Step 2: Build macOS + echo-cli to catch masked breaks** (CI step order hides these behind iOS tests). Run, one xcodebuild at a time:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallelizeTargets NO 2>&1 | tail -30
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "echo-cli" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallelizeTargets NO 2>&1 | tail -30
  ```
  Expected: both BUILD SUCCEEDED. Fix any "cannot find type" by excluding the iOS-only file from that target.
- [ ] **Step 3: doc-sync.** Run the `doc-sync` skill. In `ARCHITECTURE.md`, add a subsection (near the alignment/reader subsystems) describing: audio-only books are transcribed by `StandaloneTranscriptionService` (now keyed by the canonical `folderURL` id, resumable), then `TranscriptMaterializer` projects raw rows into `epub_block`/`timeline_item`/`word_timing` (`transcript-<id>-c<n>-s<n>` block ids, `word_timing.source = "transcript"`), and `audiobook.text_origin = "transcript"` marks provenance so M2 never treats the book as canonical source. In `CHANGELOG.md`, add an entry under the unreleased/nightly section: "Added: on-device transcription of audio-only books now opens them in the read-along reader with word highlight, search-to-seek, tap-to-seek, and study anchoring (Schema V29: `audiobook.text_origin`)."
- [ ] **Step 4: Run the full milestone suite once more.** Run:
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests \
    && make test-only FILTER=EchoTests/SchemaV29Tests \
    && make test-only FILTER=EchoTests/TranscriptMaterializerTests \
    && make test-only FILTER=EchoTests/StandaloneTranscriptionServiceTests \
    && make test-only FILTER=EchoTests/TranscribeBookCoordinatorTests \
    && make test-only FILTER=EchoTests/TranscribeProgressViewTests \
    && make test-only FILTER=EchoTests/TranscriptReaderParityTests
  ```
  Expected: all PASS.
- [ ] **Step 5: Commit + open PR.** Run:
  ```
  git add ARCHITECTURE.md CHANGELOG.md Echo.xcodeproj/project.pbxproj
  git commit -m "docs(reader): document transcript materialization + text_origin (M1)"
  ```
  Then push the feature branch and open the PR (heads-up to the owner first per workflow):
  ```
  git push -u origin HEAD
  gh pr create --base nightly --title "M1: Transcript reader parity (audio-only)" --body "<summary + risks + verification>"
  ```
  After opening, check CI with `gh pr checks`; if `Build gate + tests` fails, inspect the failing job logs, fix the concrete blocker, push, and re-check until green. **Manual verification to note in the PR body (cannot be unit-tested):** transcribe a real audio-only book on device/sim, force-quit and relaunch, confirm the reader still highlights/searches/seeks; confirm "clear & re-transcribe" yields a single clean copy.
