# M4 — Pronunciation Repair Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** Turn an accepted narration-QA fix into a per-book or global pronunciation override that changes the next render's input, then targetedly regenerate the affected chapter, re-run QA on it, and persist the issue's resolved status.

**Architecture:** Activate the inert per-book seam in `PronunciationOverrideStore` (book-wins merge over the global map, backed by `Pronunciations/books/<sha256(bookID)>.json`), then thread the canonical audiobook id (`folderURL.absoluteString`) through the three production render call sites so each book reads its own merged overrides. A new pure-EchoCore `PronunciationRepairService` (concrete-type + constructor injection, no protocol) owns `applyFix(issue:scope:)`: it writes the override, deletes the affected chapter's cached audio + its `narration_quality_issue` rows, re-renders that one chapter via the existing `NarrationService.renderChapter`, re-runs M3's `NarrationQAService` on just that chapter, and flips the original issue to `resolved`. M4 is code-only — it adds no migration (it consumes M3's `narration_quality_issue` schema).

**Tech Stack:** Swift 6 / SwiftUI, GRDB (SQLite), Swift Testing, CryptoKit (SHA-256 for the per-book filename), the on-device Kokoro ONNX TTS engine, and (consumed, not built here) M3's `NarrationQAService` + WhisperKit re-transcription. Tests run on the iOS simulator via `make`.

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

## Task 0 — Branch hygiene (no code)

**Files:** none.

- [ ] **Step 1: Confirm the branch is based on `nightly`.** Run:
  ```
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c status --short --branch
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c fetch origin nightly
  git -C /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c merge-base --is-ancestor origin/nightly HEAD && echo "BASED-ON-NIGHTLY" || echo "NEEDS-REBASE"
  ```
  If it prints `NEEDS-REBASE` and the worktree has no own commits, run `git reset --hard origin/nightly`. M4 adds NO migration, so no version-collision check is needed — but confirm M3's `narration_quality_issue` table (`Schema_V30`) and `NarrationQualityIssueRecord`/`NarrationQualityIssueDAO` are present on the branch (they are M4's dependency):
  ```
  grep -rn "narration_quality_issue" /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c/Shared /Users/dfakkeldy/Developer/Echo/.claude/worktrees/naughty-proskuriakova-5d9d8c/EchoCore | head
  ```
  If absent, STOP — M4 cannot proceed until M3 has merged to `nightly`.

---

## Task 1 — Per-book pronunciation storage in `PronunciationOverrideStore`

Activate the inert per-book seam: add `set(word:ipa:forBookID:)`, `remove(word:forBookID:)`, a private `bookEntries` cache + `persistBook(_:)`, and make `overrides(forBookID:)` return `PronunciationOverrides.merging(global:book:)`. Per-book JSON lives at `<directory>/books/<sha256(bookID)>.json` (a `[String:String]` map), mirroring the existing `global.json` round-trip.

**Files:**
- Modify `EchoCore/Services/Narration/PronunciationOverrideStore.swift` (struct body; `overrides(forBookID:)` is the stub at :65; the `init(directory:)` at :35; `persist()` at :71).
- Modify `EchoTests/PronunciationOverrideStoreTests.swift` (add tests; existing suite at :6).

**Interfaces:**
- Consumes: `PronunciationOverrides.merging(global: [String:String], book: [String:String]) -> PronunciationOverrides` (`EchoCore/Services/Narration/PronunciationOverrides.swift:64`); `PronunciationOverrides.withBuiltInDefaults(_:) -> PronunciationOverrides` (:84).
- Produces:
  - `func set(word: String, ipa: String, forBookID bookID: String) throws`
  - `func remove(word: String, forBookID bookID: String) throws`
  - `func overrides(forBookID bookID: String) -> PronunciationOverrides` (replace stub; book-wins merge over the global/built-in map)

Steps:

- [ ] **Step 1: Write the failing test.** Append to `EchoTests/PronunciationOverrideStoreTests.swift`, inside the existing `@Suite struct PronunciationOverrideStoreTests`:
  ```swift
  @MainActor
  @Test func perBookEntryWinsOverGlobalInMergedOverrides() throws {
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }

      let store = PronunciationOverrideStore(directory: tmp)
      try store.set(word: "Gandalf", ipa: "ɡˈændɑːlf")               // global
      try store.set(word: "Gandalf", ipa: "ɡˈændælf", forBookID: "file:///Books/LOTR/")  // per-book wins

      let merged = store.overrides(forBookID: "file:///Books/LOTR/")
      #expect(merged.entries["Gandalf"] == "ɡˈændælf")
      // A different book sees only the global value.
      let other = store.overrides(forBookID: "file:///Books/Other/")
      #expect(other.entries["Gandalf"] == "ɡˈændɑːlf")
  }

  @MainActor
  @Test func perBookEntriesRoundTripThroughDisk() throws {
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }

      let store = PronunciationOverrideStore(directory: tmp)
      try store.set(word: "Frodo", ipa: "frˈoʊdoʊ", forBookID: "file:///Books/LOTR/")

      // A fresh store over the same directory rehydrates the per-book map lazily.
      let reloaded = PronunciationOverrideStore(directory: tmp)
      #expect(reloaded.overrides(forBookID: "file:///Books/LOTR/").entries["Frodo"] == "frˈoʊdoʊ")
  }

  @MainActor
  @Test func removeForBookDropsOnlyThatBooksEntry() throws {
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }

      let store = PronunciationOverrideStore(directory: tmp)
      try store.set(word: "Bree", ipa: "briː", forBookID: "file:///Books/LOTR/")
      try store.set(word: "Bree", ipa: "brˈeɪ", forBookID: "file:///Books/Other/")
      try store.remove(word: "Bree", forBookID: "file:///Books/LOTR/")

      #expect(store.overrides(forBookID: "file:///Books/LOTR/").entries["Bree"] == nil)
      #expect(store.overrides(forBookID: "file:///Books/Other/").entries["Bree"] == "brˈeɪ")
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL — compile error: no `forBookID:` overloads; `overrides(forBookID:)` returns empty).**
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  make test-only FILTER=EchoTests/PronunciationOverrideStoreTests
  ```
- [ ] **Step 3: Implement the per-book storage.** In `EchoCore/Services/Narration/PronunciationOverrideStore.swift`:

  Add a per-book directory + cache. Change the stored properties block (after `private let fileURL: URL` at :22) to add:
  ```swift
          private let fileURL: URL
          /// Directory holding per-book override maps: `<base>/books/<sha256(bookID)>.json`.
          /// Kept separate from `global.json` so book-scoped fixes never leak across books.
          private let booksDirectory: URL
          /// Lazily-rehydrated per-book maps, keyed by the canonical audiobook id
          /// (`folderURL.absoluteString`). Loaded from disk on first read of a book.
          private var bookEntries: [String: [String: String]] = [:]
  ```

  In `init(directory:)` (:35), after the `global.json` block, set up the books directory:
  ```swift
          init(directory: URL) {
              try? FileManager.default.createDirectory(
                  at: directory, withIntermediateDirectories: true)
              self.fileURL = directory.appendingPathComponent("global.json")
              self.booksDirectory = directory.appendingPathComponent("books", isDirectory: true)
              try? FileManager.default.createDirectory(
                  at: booksDirectory, withIntermediateDirectories: true)
              if let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
              {
                  self.entries = decoded
              }
          }
  ```

  Add the per-book mutators after `remove(word:)` (:54):
  ```swift
          /// Set a pronunciation that applies only to `bookID`. Book entries win over
          /// the global map at merge time (see `overrides(forBookID:)`).
          func set(word: String, ipa: String, forBookID bookID: String) throws {
              var book = loadedBookEntries(bookID)
              book[word] = ipa
              bookEntries[bookID] = book
              try persistBook(bookID)
          }

          /// Remove a per-book pronunciation. Leaves the global map and other books untouched.
          func remove(word: String, forBookID bookID: String) throws {
              var book = loadedBookEntries(bookID)
              book[word] = nil
              bookEntries[bookID] = book
              try persistBook(bookID)
          }
  ```

  Replace the `overrides(forBookID:)` stub (:65-67) with the real merge:
  ```swift
          /// Per-book overrides: the global map (with Echo's built-in defaults) merged
          /// with this book's entries, book-wins on conflict — the map `NarrationService`
          /// applies before G2P for a specific book.
          func overrides(forBookID bookID: String) -> PronunciationOverrides {
              let global = PronunciationOverrides.withBuiltInDefaults(entries).entries
              return PronunciationOverrides.merging(global: global, book: loadedBookEntries(bookID))
          }
  ```

  Add the private helpers next to `persist()` (:71):
  ```swift
          /// The on-disk file for a book's override map. SHA-256 of the canonical
          /// audiobook id keeps the filename stable and filesystem-safe regardless of
          /// the id's characters (URLs contain `/`, `:`, etc.).
          private func bookFileURL(_ bookID: String) -> URL {
              let hash = SHA256.hash(data: Data(bookID.utf8))
                  .compactMap { String(format: "%02x", $0) }.joined()
              return booksDirectory.appendingPathComponent("\(hash).json")
          }

          /// Return this book's map, rehydrating from disk into the cache on first access.
          private func loadedBookEntries(_ bookID: String) -> [String: String] {
              if let cached = bookEntries[bookID] { return cached }
              let loaded: [String: String]
              if let data = try? Data(contentsOf: bookFileURL(bookID)),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
              {
                  loaded = decoded
              } else {
                  loaded = [:]
              }
              bookEntries[bookID] = loaded
              return loaded
          }

          private func persistBook(_ bookID: String) throws {
              let data = try JSONEncoder().encode(bookEntries[bookID] ?? [:])
              try data.write(to: bookFileURL(bookID), options: .atomic)
              logger.info(
                  "Saved \(self.bookEntries[bookID]?.count ?? 0, privacy: .public) per-book pronunciation overrides.")
          }
  ```

  Add `import CryptoKit` under the existing imports inside the `#if os(iOS) || os(macOS)` block (after `import os.log` at :4):
  ```swift
      import CryptoKit
  ```
- [ ] **Step 4: Run the test (expect PASS).**
  ```
  make test-only FILTER=EchoTests/PronunciationOverrideStoreTests
  ```
  After the SwiftFormat hook reflows the file, verify `// SPDX-License-Identifier: GPL-3.0-or-later` is still line 1 of `PronunciationOverrideStore.swift`.
- [ ] **Step 5: Commit.**
  ```
  git add EchoCore/Services/Narration/PronunciationOverrideStore.swift EchoTests/PronunciationOverrideStoreTests.swift
  git commit -m "feat(narration): per-book pronunciation overrides with book-wins merge"
  ```

---

## Task 2 — Rewire the three render call sites to per-book overrides

Each `NarrationService` construction currently injects `{ PronunciationOverrideStore.shared.overrides() }`. Thread the canonical audiobook id available at each site into `overrides(forBookID:)` so a render reads the book's merged map.

**Files:**
- Modify `EchoCore/ViewModels/PlayerModel+Narration.swift:78` (`audiobookID` is the local at :40, `folderURL?.absoluteString`).
- Modify `EchoCore/Services/Narration/HeadlessNarrationRunner.swift:219` (`audiobookID` is the local at :177, `"runner-\(stem)-\(...)"`).
- Modify `Echo macOS/Services/MacBatchProcessingService.swift:283` (`audiobookID` is the local at :245, `epubURL.absoluteString`).
- Modify `EchoTests/NarrationPronunciationTests.swift` (add a render-input parity test; existing suite present).

**Interfaces:**
- Consumes: `PronunciationOverrideStore.overrides(forBookID:) -> PronunciationOverrides` (Task 1); `NarrationService.init(..., pronunciationOverrides: @escaping () -> PronunciationOverrides)` (`NarrationService.swift:67`); `PronunciationOverrides.apply(to:) -> String` (`PronunciationOverrides.swift:15`).
- Produces: no new symbol; behavior change only.

Steps:

- [ ] **Step 1: Write the failing test.** Add a focused test that proves the rewired closure feeds the per-book map into the rendered text. Because the three call sites are UI/orchestration code that can't run headless in a unit test, assert the closure-to-`apply` contract directly. Append to `EchoTests/NarrationPronunciationTests.swift` inside its existing `@Suite`:
  ```swift
  @MainActor
  @Test func perBookOverrideClosureRewritesBookSpecificWord() throws {
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }

      let store = PronunciationOverrideStore(directory: tmp)
      let bookID = "file:///Books/Dune/"
      try store.set(word: "Arrakis", ipa: "ɑˈɹɑːkɪs", forBookID: bookID)

      // The render call sites build exactly this closure (with `.shared`); here we
      // bind a test store to prove the per-book id threads into `apply`.
      let overridesClosure: () -> PronunciationOverrides = { store.overrides(forBookID: bookID) }
      let rewritten = overridesClosure().apply(to: "The sands of Arrakis are endless.")
      #expect(rewritten == "The sands of [Arrakis](/ɑˈɹɑːkɪs/) are endless.")

      // A book without the entry leaves the word untouched.
      let bare = store.overrides(forBookID: "file:///Books/Empty/")
          .apply(to: "The sands of Arrakis are endless.")
      #expect(bare == "The sands of Arrakis are endless.")
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL — `set(word:ipa:forBookID:)` resolves from Task 1, but this test is new; it fails only if Task 1 regressed, so primarily this guards the contract. If Task 1 passed it may compile-pass — in that case treat this step as the regression guard and proceed; the real failing assertion is on the call sites in Step 3, which the test file cannot exercise directly).** Run:
  ```
  make test-only FILTER=EchoTests/NarrationPronunciationTests
  ```
- [ ] **Step 3: Rewire the call sites.**

  In `EchoCore/ViewModels/PlayerModel+Narration.swift:78`, change:
  ```swift
                  pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })
  ```
  to:
  ```swift
                  pronunciationOverrides: {
                      PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
                  })
  ```
  (`audiobookID` is the canonical `folderURL?.absoluteString` captured at :40.)

  In `EchoCore/Services/Narration/HeadlessNarrationRunner.swift:219`, change:
  ```swift
              pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })
  ```
  to:
  ```swift
              pronunciationOverrides: {
                  PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
              })
  ```
  (`audiobookID` is the `runner-…` local at :177; the headless runner's in-memory book id is its own canonical id within that run.)

  In `Echo macOS/Services/MacBatchProcessingService.swift:283`, change:
  ```swift
                          pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })
  ```
  to:
  ```swift
                          pronunciationOverrides: {
                              PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
                          })
  ```
  (`audiobookID` is `epubURL.absoluteString` captured at :245.)
- [ ] **Step 4: Run the test (expect PASS) and verify the macOS + echo-cli targets still build (the macOS site lives in `Echo macOS`, which the iOS test target does not compile).**
  ```
  make test-only FILTER=EchoTests/NarrationPronunciationTests
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
  ```
  Confirm both end with `** BUILD SUCCEEDED **`. After the format hook runs, verify SPDX is still line 1 of all three edited files (`PlayerModel+Narration.swift`'s SPDX is on line 2 inside its `#if os(iOS)` — keep that pre-existing structure; the hook must not have moved it below an import).
- [ ] **Step 5: Commit.**
  ```
  git add EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift "Echo macOS/Services/MacBatchProcessingService.swift" EchoTests/NarrationPronunciationTests.swift
  git commit -m "feat(narration): thread per-book id through render override call sites"
  ```

---

## Task 3 — Map a quality issue to its chapter (chapter resolver)

`applyFix` must regenerate the chapter that contains the issue's `sourceBlockID`, but `NarrationQualityIssueRecord` carries no chapter index. Add a pure helper that resolves a block id to its `epub_block.chapter_index`. Keeping it standalone makes it testable against `DatabaseService(inMemory: ())` before wiring the heavier repair flow.

**Files:**
- Create `EchoCore/Services/Narration/PronunciationRepairService.swift` (resolver only in this task; the full service body lands in Task 4).
- Create `EchoTests/PronunciationRepairServiceTests.swift`.

**Interfaces:**
- Consumes: `EPubBlockRecord` (`Shared/Database/EPubBlockRecord.swift:8`, has `id`, `chapterIndex: Int?`); GRDB `DatabaseWriter`.
- Produces: `enum FixScope: Equatable { case book(String); case global }`; `static func chapterIndex(forBlockID blockID: String, audiobookID: String, db: DatabaseWriter) throws -> Int?`.

Steps:

- [ ] **Step 1: Write the failing test.** Create `EchoTests/PronunciationRepairServiceTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB
  import Testing
  @testable import Echo

  @MainActor
  @Suite struct PronunciationRepairServiceTests {

      /// Seed one audiobook + one chapter-7 block so the resolver has a real FK row.
      private func seedBlock(
          audiobookID: String, blockID: String, chapterIndex: Int, db: DatabaseService
      ) throws {
          try db.writer.write { database in
              try database.execute(
                  sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
                  arguments: [audiobookID, "Book"])
          }
          var block = EPubBlockRecord(
              id: blockID, audiobookID: audiobookID, spineHref: "ch.xhtml",
              spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
              blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
              text: "Hello Arrakis.", htmlContent: nil, cardColor: nil,
              chapterThemeColor: nil, imagePath: nil, chapterIndex: chapterIndex,
              isHidden: false, hiddenReason: nil, isFrontMatter: false,
              wordCount: 2, markers: nil, textFormats: nil,
              createdAt: nil, modifiedAt: nil)
          try EPubBlockDAO(db: db.writer).insert(block)
          _ = block  // silence unused-var if insert copies
      }

      @Test func resolvesChapterIndexForBlock() throws {
          let db = try DatabaseService(inMemory: ())
          let bookID = "file:///Books/Dune/"
          try seedBlock(audiobookID: bookID, blockID: "epub-\(bookID)-s0-b0", chapterIndex: 7, db: db)

          let idx = try PronunciationRepairService.chapterIndex(
              forBlockID: "epub-\(bookID)-s0-b0", audiobookID: bookID, db: db.writer)
          #expect(idx == 7)
      }

      @Test func returnsNilForUnknownBlock() throws {
          let db = try DatabaseService(inMemory: ())
          let idx = try PronunciationRepairService.chapterIndex(
              forBlockID: "nope", audiobookID: "file:///Books/Dune/", db: db.writer)
          #expect(idx == nil)
      }
  }
  ```
  (Confirm the `EPubBlockRecord` memberwise-init argument order against `Shared/Database/EPubBlockRecord.swift:8` when writing — the field order in the contract is the source of truth.)
- [ ] **Step 2: Run the test (expect FAIL — `PronunciationRepairService` does not exist).**
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
- [ ] **Step 3: Implement the resolver.** Create `EchoCore/Services/Narration/PronunciationRepairService.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import GRDB

  /// Scope for a pronunciation fix: a specific book or the global dictionary.
  enum FixScope: Equatable {
      case book(String)
      case global
  }

  /// Turns an accepted narration-QA fix into a pronunciation override, regenerates
  /// the affected chapter, re-runs QA on it, and resolves the issue. Pure EchoCore
  /// (no UIKit / no `PlayerModel`) so it bundles into iOS, macOS, and echo-cli
  /// unchanged. Concrete-type + constructor injection (no protocol): there is one
  /// implementation.
  @MainActor
  final class PronunciationRepairService {

      /// Resolve the `epub_block.chapter_index` for a block id. Used to scope
      /// regeneration to the single chapter that contains a flagged issue.
      static func chapterIndex(
          forBlockID blockID: String, audiobookID: String, db: DatabaseWriter
      ) throws -> Int? {
          try db.read { database in
              try Int.fetchOne(
                  database,
                  sql: """
                      SELECT chapter_index FROM epub_block
                      WHERE id = ? AND audiobook_id = ?
                      """,
                  arguments: [blockID, audiobookID])
          }
      }
  }
  ```
  This file imports neither UIKit nor `PlayerModel`, so per the Global Constraints it auto-bundles into all targets and needs NO `project.pbxproj` exclusion.
- [ ] **Step 4: Run the test (expect PASS).**
  ```
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
- [ ] **Step 5: Commit.**
  ```
  git add EchoCore/Services/Narration/PronunciationRepairService.swift EchoTests/PronunciationRepairServiceTests.swift
  git commit -m "feat(narration): add PronunciationRepairService block-to-chapter resolver"
  ```

---

## Task 4 — `applyFix(issue:scope:)`: write override + regenerate + re-QA + resolve

Wire the full repair loop onto `PronunciationRepairService`. `applyFix` (1) writes the override derived from the issue's `suggestedFixJSON`, scoped per `FixScope`; (2) deletes the affected chapter's cached audio file + that chapter's open `narration_quality_issue` rows so re-QA starts clean; (3) re-renders the one chapter via the injected `NarrationService.renderChapter` (which reads the just-updated overrides via its closure); (4) re-runs M3's `NarrationQAService` on that single chapter; (5) flips the original issue to `.resolved`.

**Files:**
- Modify `EchoCore/Services/Narration/PronunciationRepairService.swift` (add stored deps + `applyFix`).
- Modify `EchoTests/PronunciationRepairServiceTests.swift` (add the repair-flow tests).

**Interfaces:**
- Consumes:
  - `NarrationQualityIssueRecord` (M3 contract: `id, audiobookID, sourceBlockID?, sourceWordStart?, sourceWordEnd?, audioStartTime, audioEndTime, expectedText, heardText, issueType, confidence, suggestedFixJSON?, status, createdAt, resolvedAt?`).
  - `NarrationQualityIssueDAO` (M3): `func issues(for:status:) -> [NarrationQualityIssueRecord]`, `func updateStatus(id:status:resolvedAt:)`, `func deleteAll(for:blockIDs:)`.
  - `enum NarrationQAIssueStatus: String { open, resolved, ignored }` (M3).
  - `DivergenceClassification { issueType; suggestedSpokenForm: String?; suggestedIPA: String?; confidence: Double }` (M3) — JSON-encoded in `suggestedFixJSON`.
  - `PronunciationOverrideStore.set(word:ipa:)` / `set(word:ipa:forBookID:)` (Task 1).
  - `NarrationService.renderChapter(chapterIndex:chapterNumber:blocks:voice:chapterTitle:onBlockProgress:)` (`NarrationService.swift:105`).
  - `NarrationQAService.runQA(audiobookID:chapters:)` (M3): `chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]`.
  - `EPubBlockDAO.blocks(for:chapterIndex:)` (`EchoCore/.../EPubBlockDAO.swift:64`); `EPubBlockDAO.visibleBlocks(for:)` (:75).
  - `NarrationFileNaming.chapterFileName(audiobookID:chapterIndex:voice:)` (`NarrationFileNaming.swift:35`); `NarrationCache.directory()`.
- Produces:
  - `init(store: PronunciationOverrideStore, issueDAO: NarrationQualityIssueDAO, db: DatabaseWriter, narration: NarrationService, qa: NarrationQAService, cacheDirectory: URL, voice: VoiceID)`
  - `func applyFix(issue: NarrationQualityIssueRecord, scope: FixScope) async throws`

Steps:

- [ ] **Step 1: Write the failing tests.** Add to `EchoTests/PronunciationRepairServiceTests.swift`. Use lightweight test doubles for the two heavy collaborators (`NarrationService` render, `NarrationQAService` re-QA) — both are real concrete classes, so wrap them with closure injection seams the test can drive. Since `applyFix` orchestrates several effects, split into two tests: one asserting the override write + status flip given a no-op render/QA, one asserting the cached file is deleted before re-render.

  Because `NarrationService` and `NarrationQAService` are `@MainActor final class`es with non-trivial real init, inject them as the small closures `applyFix` actually needs rather than the whole objects (this is the concrete-closure DI the repo prefers — no protocol). Adjust the `init`/`applyFix` signature to take two closures instead of the live services:
  ```swift
  @MainActor
  @Test func applyFixWritesPerBookOverrideAndResolvesIssue() async throws {
      let db = try DatabaseService(inMemory: ())
      let bookID = "file:///Books/Dune/"
      let blockID = "epub-\(bookID)-s0-b0"
      try seedBlock(audiobookID: bookID, blockID: blockID, chapterIndex: 3, db: db)

      // Persist an open issue with a suggested IPA fix for "Arrakis".
      let fix = DivergenceClassification(
          issueType: .pronunciation, suggestedSpokenForm: "Arrakis",
          suggestedIPA: "ɑˈɹɑːkɪs", confidence: 0.9)
      let fixJSON = String(data: try JSONEncoder().encode(fix), encoding: .utf8)
      let issue = NarrationQualityIssueRecord(
          id: "iss-1", audiobookID: bookID, sourceBlockID: blockID,
          sourceWordStart: 1, sourceWordEnd: 1,
          audioStartTime: 0, audioEndTime: 2,
          expectedText: "Arrakis", heardText: "a rockis",
          issueType: NarrationQAIssueType.pronunciation.rawValue,
          confidence: 0.4, suggestedFixJSON: fixJSON,
          status: NarrationQAIssueStatus.open.rawValue,
          createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
      let issueDAO = NarrationQualityIssueDAO(db: db.writer)
      issueDAO.insert([issue])

      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }
      let store = PronunciationOverrideStore(directory: tmp)

      var renderedChapters: [Int] = []
      var reQAChapters: [Int] = []
      let svc = PronunciationRepairService(
          store: store, issueDAO: issueDAO, db: db.writer,
          cacheDirectory: tmp, voice: VoiceCatalog.default.id,
          renderChapter: { chapterIndex in renderedChapters.append(chapterIndex) },
          reRunQA: { chapterIndex in reQAChapters.append(chapterIndex) })

      try await svc.applyFix(issue: issue, scope: .book(bookID))

      // Override written, book-scoped.
      #expect(store.overrides(forBookID: bookID).entries["Arrakis"] == "ɑˈɹɑːkɪs")
      // The chapter containing the block (3) was regenerated and re-QA'd.
      #expect(renderedChapters == [3])
      #expect(reQAChapters == [3])
      // Issue resolved + persisted.
      let resolved = issueDAO.issues(for: bookID, status: NarrationQAIssueStatus.resolved.rawValue)
      #expect(resolved.contains { $0.id == "iss-1" })
      #expect(issueDAO.issues(for: bookID, status: NarrationQAIssueStatus.open.rawValue).isEmpty)
  }

  @MainActor
  @Test func applyFixGlobalScopeWritesGlobalOverride() async throws {
      let db = try DatabaseService(inMemory: ())
      let bookID = "file:///Books/Dune/"
      let blockID = "epub-\(bookID)-s0-b0"
      try seedBlock(audiobookID: bookID, blockID: blockID, chapterIndex: 0, db: db)
      let fix = DivergenceClassification(
          issueType: .pronunciation, suggestedSpokenForm: nil,
          suggestedIPA: "θˈɛstɹəl", confidence: 0.8)
      let issue = NarrationQualityIssueRecord(
          id: "iss-2", audiobookID: bookID, sourceBlockID: blockID,
          sourceWordStart: 0, sourceWordEnd: 0, audioStartTime: 0, audioEndTime: 1,
          expectedText: "Thestral", heardText: "thestrel",
          issueType: NarrationQAIssueType.pronunciation.rawValue,
          confidence: 0.4,
          suggestedFixJSON: String(data: try JSONEncoder().encode(fix), encoding: .utf8),
          status: NarrationQAIssueStatus.open.rawValue,
          createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
      let issueDAO = NarrationQualityIssueDAO(db: db.writer)
      issueDAO.insert([issue])
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }
      let store = PronunciationOverrideStore(directory: tmp)
      let svc = PronunciationRepairService(
          store: store, issueDAO: issueDAO, db: db.writer,
          cacheDirectory: tmp, voice: VoiceCatalog.default.id,
          renderChapter: { _ in }, reRunQA: { _ in })

      try await svc.applyFix(issue: issue, scope: .global)
      #expect(store.entries["Thestral"] == "θˈɛstɹəl")
      // Book-scoped lookup also sees it (global is the base of the merge).
      #expect(store.overrides(forBookID: bookID).entries["Thestral"] == "θˈɛstɹəl")
  }
  ```
- [ ] **Step 2: Run the tests (expect FAIL — `PronunciationRepairService` has no `init(store:…)` / `applyFix`).**
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
- [ ] **Step 3: Implement `applyFix` + init.** Add to `EchoCore/Services/Narration/PronunciationRepairService.swift` (above the closing brace of the class). The two collaborator effects are injected as `async`-throwing closures keyed by chapter index — concrete-closure DI, no protocol; the production call site (Task 5) binds them to the real `NarrationService.renderChapter` + `NarrationQAService.runQA`:
  ```swift
      private let store: PronunciationOverrideStore
      private let issueDAO: NarrationQualityIssueDAO
      private let db: DatabaseWriter
      private let cacheDirectory: URL
      private let voice: VoiceID
      /// Re-render exactly the given chapter index with the live override map.
      private let renderChapter: (Int) async throws -> Void
      /// Re-run narration QA over exactly the given chapter index.
      private let reRunQA: (Int) async throws -> Void

      init(
          store: PronunciationOverrideStore,
          issueDAO: NarrationQualityIssueDAO,
          db: DatabaseWriter,
          cacheDirectory: URL,
          voice: VoiceID,
          renderChapter: @escaping (Int) async throws -> Void,
          reRunQA: @escaping (Int) async throws -> Void
      ) {
          self.store = store
          self.issueDAO = issueDAO
          self.db = db
          self.cacheDirectory = cacheDirectory
          self.voice = voice
          self.renderChapter = renderChapter
          self.reRunQA = reRunQA
      }

      /// Apply an accepted pronunciation fix end to end: write the override for the
      /// chosen scope, drop the affected chapter's cached audio + open issues, re-render
      /// that one chapter (which now reads the new override), re-run QA on it, and mark
      /// the original issue resolved. Throws if the issue has no usable suggested fix.
      func applyFix(issue: NarrationQualityIssueRecord, scope: FixScope) async throws {
          // 1. Decode the suggested fix → (word, ipa).
          guard let json = issue.suggestedFixJSON,
              let data = json.data(using: .utf8),
              let fix = try? JSONDecoder().decode(DivergenceClassification.self, from: data),
              let ipa = fix.suggestedIPA, !ipa.isEmpty
          else {
              throw NarrationRepairError.noUsableFix
          }
          // Prefer the model's suggested spoken form for the override key; fall back to
          // the expected source text (whole-word matched by PronunciationOverrides).
          let word = (fix.suggestedSpokenForm?.isEmpty == false
              ? fix.suggestedSpokenForm! : issue.expectedText)
              .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !word.isEmpty else { throw NarrationRepairError.noUsableFix }

          // 2. Write the override in the chosen scope.
          switch scope {
          case .book(let bookID):
              try store.set(word: word, ipa: ipa, forBookID: bookID)
          case .global:
              try store.set(word: word, ipa: ipa)
          }

          // 3. Resolve the chapter to regenerate.
          guard let blockID = issue.sourceBlockID,
              let chapterIndex = try Self.chapterIndex(
                  forBlockID: blockID, audiobookID: issue.audiobookID, db: db)
          else {
              // No block/chapter to regenerate — still resolve the issue so the queue
              // doesn't keep re-surfacing a fix the user accepted.
              issueDAO.updateStatus(
                  id: issue.id, status: NarrationQAIssueStatus.resolved.rawValue,
                  resolvedAt: ISO8601DateFormatter().string(from: Date()))
              return
          }

          // 4. Clear stale cached audio + that chapter's open issues so re-QA is clean.
          let cachedFile = cacheDirectory.appendingPathComponent(
              NarrationFileNaming.chapterFileName(
                  audiobookID: issue.audiobookID, chapterIndex: chapterIndex, voice: voice))
          try? FileManager.default.removeItem(at: cachedFile)
          let chapterBlockIDs = try EPubBlockDAO(db: db)
              .blocks(for: issue.audiobookID, chapterIndex: chapterIndex)
              .map(\.id)
          if !chapterBlockIDs.isEmpty {
              issueDAO.deleteAll(for: issue.audiobookID, blockIDs: chapterBlockIDs)
          }

          // 5. Re-render the chapter (reads the new override via NarrationService's
          //    pronunciationOverrides closure) then re-run QA over it.
          try await renderChapter(chapterIndex)
          try await reRunQA(chapterIndex)

          // 6. The original issue's block was cleared in step 4; if it survived
          //    (block outside the chapter set), resolve it explicitly.
          issueDAO.updateStatus(
              id: issue.id, status: NarrationQAIssueStatus.resolved.rawValue,
              resolvedAt: ISO8601DateFormatter().string(from: Date()))
      }
  ```
  Add the error enum at file scope (below `enum FixScope`):
  ```swift
  /// Thrown when an issue carries no actionable pronunciation suggestion.
  enum NarrationRepairError: Error, Equatable {
      case noUsableFix
  }
  ```
  Note: step 4's `deleteAll(for:blockIDs:)` already removes the original issue's row when its block is in-chapter; step 6's `updateStatus` is a no-op in that case and the resolve survives for the out-of-chapter edge. The test asserts the resolved set contains `iss-1` — since `deleteAll` removes the open row, the test's `seedBlock` puts the block in chapter 3, so the test must reconcile: to keep `iss-1` queryable as resolved rather than deleted, the production code resolves the SPECIFIC issue BEFORE the chapter-wide delete. Reorder so step 6 runs before step 4's `deleteAll`:
  - Move the `issueDAO.updateStatus(id: issue.id, status: .resolved, …)` call to run immediately after step 3 resolves the chapter index, BEFORE the `deleteAll(for:blockIDs:)`, and have `deleteAll` skip already-resolved rows by only deleting `status = open`. If M3's `deleteAll(for:blockIDs:)` deletes regardless of status, instead keep `updateStatus` AFTER `deleteAll` and adjust the test to assert the OPEN set is empty (issue gone) rather than the resolved set contains it. Choose based on M3's actual DAO semantics: read `Shared/Database/DAOs/NarrationQualityIssueDAO.swift` and pick the ordering that makes the test's `resolved.contains { $0.id == "iss-1" }` true. The simplest reconciliation: resolve `issue.id` first, then delete only the OTHER chapter blocks' open issues — i.e. `deleteAll(for:blockIDs: chapterBlockIDs)` filtered to exclude `issue.sourceBlockID`. Implement that filter:
    ```swift
    let otherBlockIDs = chapterBlockIDs.filter { $0 != issue.sourceBlockID }
    if !otherBlockIDs.isEmpty {
        issueDAO.deleteAll(for: issue.audiobookID, blockIDs: otherBlockIDs)
    }
    ```
    and resolve `issue.id` via `updateStatus` (keeping the row, marked resolved). This keeps the test green and is the correct product behavior (the accepted fix's issue becomes an auditable resolved record; sibling open issues on the same chapter are cleared so re-QA repopulates only genuine remaining divergences).
- [ ] **Step 4: Run the tests (expect PASS).**
  ```
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
  Verify SPDX is still line 1 of `PronunciationRepairService.swift` after the format hook.
- [ ] **Step 5: Commit.**
  ```
  git add EchoCore/Services/Narration/PronunciationRepairService.swift EchoTests/PronunciationRepairServiceTests.swift
  git commit -m "feat(narration): applyFix writes override, regenerates chapter, re-QAs, resolves"
  ```

---

## Task 5 — Bind the production render + re-QA closures (iOS review-action wiring)

Wire the M3 `NarrationQAReviewModel` "save override → regenerate" action to construct a `PronunciationRepairService` whose `renderChapter`/`reRunQA` closures call the real `NarrationService.renderChapter` and `NarrationQAService.runQA` for one chapter, using the canonical audiobook id and the user's narration voice. This is the only place `applyFix` is invoked in production.

**Files:**
- Modify `EchoCore/ViewModels/NarrationQAReviewModel.swift` (M3-created; add an `acceptFix(issue:scope:)` method that builds and drives `PronunciationRepairService`). Read the file first to match its existing dependencies (db writer, audiobookID, settings/voice access).
- Modify `EchoTests/PronunciationRepairServiceTests.swift` (add an integration-shaped test that builds the real chapter-render closure against an in-memory DB with a tiny TTS double, asserting a regenerated chapter file appears — only if `NarrationQAReviewModel` exposes a headless-constructable seam; otherwise assert the closure factory in isolation).

**Interfaces:**
- Consumes: `PronunciationRepairService.init(...)` + `applyFix(issue:scope:)` (Task 4); `NarrationService.renderChapter(...)` (`NarrationService.swift:105`); `NarrationQAService.runQA(audiobookID:chapters:)` (M3); `EPubBlockDAO.blocks(for:chapterIndex:)`; `VoiceCatalog.voice(for:)?.id ?? VoiceCatalog.default.id` (voice resolution mirroring `PlayerModel+Narration.swift:424`).
- Produces: `@MainActor func acceptFix(issue: NarrationQualityIssueRecord, scope: FixScope) async` on `NarrationQAReviewModel` (binds the two closures, calls `applyFix`, surfaces errors into the model's existing error/state surface).

Steps:

- [ ] **Step 1: Read `NarrationQAReviewModel.swift`** to learn its stored db writer, audiobookID, voice/settings access, NarrationService availability, and error-presentation pattern. Confirm whether it already holds (or can construct) a `NarrationService` and a `NarrationQAService`. If M3 did not create this model yet on the branch, STOP and note the dependency (this task cannot land before M3's review model exists).
- [ ] **Step 2: Write the failing test.** Add a test that exercises the closure factory `acceptFix` builds, against `DatabaseService(inMemory: ())` + a trivial `TTSEngine` double that emits one short chunk, asserting the chapter file is (re)written and the issue resolves. If `NarrationQAReviewModel` is not headless-constructable, instead assert the production-shaped closures in `PronunciationRepairServiceTests` directly:
  ```swift
  @MainActor
  @Test func productionRenderClosureWritesChapterFile() async throws {
      let db = try DatabaseService(inMemory: ())
      let bookID = "file:///Books/Dune/"
      let blockID = "epub-\(bookID)-s0-b0"
      try seedBlock(audiobookID: bookID, blockID: blockID, chapterIndex: 0, db: db)

      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }

      let voice = VoiceCatalog.default.id
      let narration = NarrationService(
          db: db.writer, audiobookID: bookID, tts: StubTTSEngine(),
          audioWriter: StubAudioWriter(), cacheDirectory: tmp, state: NarrationState())
      // The render closure the review model builds:
      let renderClosure: (Int) async throws -> Void = { chapterIndex in
          let blocks = try EPubBlockDAO(db: db.writer)
              .blocks(for: bookID, chapterIndex: chapterIndex)
          try await narration.renderChapter(
              chapterIndex: chapterIndex, blocks: blocks, voice: voice)
      }
      try await renderClosure(0)
      let expected = tmp.appendingPathComponent(
          NarrationFileNaming.chapterFileName(
              audiobookID: bookID, chapterIndex: 0, voice: voice))
      #expect(FileManager.default.fileExists(atPath: expected.path))
  }
  ```
  Use the existing narration test doubles if present (search `EchoTests` for an existing `TTSEngine`/`AudioFileWriting` stub before writing new `StubTTSEngine`/`StubAudioWriter`; reuse them to avoid duplication). If a usable double already exists in the narration test suite, import/reuse it instead of defining new ones.
- [ ] **Step 3: Run the test (expect FAIL — `acceptFix`/closure factory not present, or compile error on missing stub).**
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
- [ ] **Step 4: Implement `acceptFix` on `NarrationQAReviewModel`.** Following the file's existing pattern (db writer, audiobookID, voice resolution), add:
  ```swift
      /// User accepted a pronunciation fix from the review queue. Writes the override
      /// in the chosen scope, regenerates the affected chapter with the new
      /// pronunciation, re-runs QA over it, and resolves the issue. Errors surface
      /// through the model's existing error state (no crash).
      @MainActor
      func acceptFix(issue: NarrationQualityIssueRecord, scope: FixScope) async {
          let voice = VoiceCatalog.voice(for: VoiceID(settings.narrationVoiceID))?.id
              ?? VoiceCatalog.default.id
          let bookID = audiobookID
          let writer = db
          let narration = self.narrationService  // the model's NarrationService for this book
          let qa = self.qaService                 // the model's NarrationQAService for this book
          let repair = PronunciationRepairService(
              store: PronunciationOverrideStore.shared,
              issueDAO: NarrationQualityIssueDAO(db: writer),
              db: writer,
              cacheDirectory: NarrationCache.directory(),
              voice: voice,
              renderChapter: { chapterIndex in
                  let blocks = try EPubBlockDAO(db: writer)
                      .blocks(for: bookID, chapterIndex: chapterIndex)
                  try await narration.renderChapter(
                      chapterIndex: chapterIndex, blocks: blocks, voice: voice)
              },
              reRunQA: { chapterIndex in
                  let blocks = try EPubBlockDAO(db: writer)
                      .blocks(for: bookID, chapterIndex: chapterIndex)
                  let fileURL = NarrationCache.directory().appendingPathComponent(
                      NarrationFileNaming.chapterFileName(
                          audiobookID: bookID, chapterIndex: chapterIndex, voice: voice))
                  try await qa.runQA(
                      audiobookID: bookID,
                      chapters: [(chapterIndex: chapterIndex, fileURL: fileURL,
                                  spokenBlockIDs: blocks.map(\.id))])
              })
          do {
              try await repair.applyFix(issue: issue, scope: scope)
              await reload()  // refresh the issue list from the DAO (model's existing reload)
          } catch {
              presentError(error)  // model's existing error surface
          }
      }
  ```
  Replace `settings`, `audiobookID`, `db`, `narrationService`, `qaService`, `reload()`, and `presentError(_:)` with the model's ACTUAL property/method names discovered in Step 1. If the model does not yet own a `NarrationService`/`NarrationQAService` per book, construct them here the same way M3's QA-run action does. `NarrationQAReviewModel` is iOS-only (review UI) — if it imports UIKit or `PlayerModel`, confirm it is ALREADY excluded from the macOS + echo-cli targets (M3 did this); M4 adds no new file here, only a method, so no new exclusion is needed.
- [ ] **Step 5: Run the test (expect PASS) and rebuild macOS + echo-cli to confirm no cross-platform break (the iOS-only model is excluded there; the shared `PronunciationRepairService` must still compile for all targets).**
  ```
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15
  ```
  Both must end `** BUILD SUCCEEDED **`. Verify SPDX line 1 on `NarrationQAReviewModel.swift`.
- [ ] **Step 6: Commit.**
  ```
  git add EchoCore/ViewModels/NarrationQAReviewModel.swift EchoTests/PronunciationRepairServiceTests.swift
  git commit -m "feat(narration): wire QA review accept-fix to PronunciationRepairService"
  ```

---

## Task 6 — Parity review + doc sync + PR

Final gate: cross-platform parity check on the shared changes, documentation updates (M4 changes the narration architecture — pronunciation repair loop becomes a real subsystem), and the PR into `nightly`.

**Files:**
- Modify `ARCHITECTURE.md` (add the M4 pronunciation-repair subsystem; per-book override storage).
- Modify `CHANGELOG.md` (note per-book pronunciation overrides + accept-fix regeneration).

**Interfaces:** none (docs + review).

Steps:

- [ ] **Step 1: Run the full narration-related suites to confirm no regression.**
  ```
  "$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
  make test-only FILTER=EchoTests/PronunciationOverrideStoreTests
  make test-only FILTER=EchoTests/PronunciationOverridesTests
  make test-only FILTER=EchoTests/NarrationPronunciationTests
  make test-only FILTER=EchoTests/PronunciationRepairServiceTests
  ```
  All green.
- [ ] **Step 2: Run `cross-platform-parity-reviewer`** over the touched `EchoCore`/`Shared` surface (`PronunciationOverrideStore.swift`, `PronunciationRepairService.swift`, the three rewired render call sites). Confirm: (a) `PronunciationRepairService.swift` has NO UIKit/`PlayerModel` import and therefore correctly auto-bundles into iOS + macOS + echo-cli with no `project.pbxproj` exclusion; (b) `PronunciationOverrideStore` per-book code is inside the existing `#if os(iOS) || os(macOS)` guard (watchOS/Widget never compile it); (c) the macOS `MacBatchProcessingService` + echo-cli `HeadlessNarrationRunner` sites compile (verified in Tasks 2 & 5). Address any finding before proceeding.
- [ ] **Step 3: Run `doc-sync`** and update `ARCHITECTURE.md` — add to the narration section a short "Pronunciation repair loop (M4)" entry: per-book overrides persist to `NarrationCache.directory()/Pronunciations/books/<sha256(bookID)>.json`, merged book-wins over `global.json`; the three render call sites read `overrides(forBookID:)`; `PronunciationRepairService.applyFix(issue:scope:)` writes the override, drops the chapter's cached audio + sibling open issues, re-renders the chapter, re-runs QA on it, and resolves the issue. Add a `CHANGELOG.md` entry under the unreleased/nightly section:
  ```
  ### Added
  - Per-book pronunciation overrides: a fix saved from the narration QA review can
    target just one book (book-wins over the global dictionary) or all books.
  - Accepting a QA fix now regenerates the affected chapter with the new
    pronunciation, re-runs QA on it, and resolves the issue.
  ```
- [ ] **Step 4: Commit the docs.**
  ```
  git add ARCHITECTURE.md CHANGELOG.md
  git commit -m "docs: document M4 pronunciation repair loop and per-book overrides"
  ```
- [ ] **Step 5: Push and open the PR into `nightly` (heads-up to the owner first per workflow).**
  ```
  git push -u origin HEAD
  gh pr create --base nightly --title "M4: Pronunciation repair loop (per-book overrides + accept-fix regeneration)" --body "Implements M4 of the Transcript Alignment + Narration QA program: per-book pronunciation overrides (book-wins merge), the three render call sites rewired to overrides(forBookID:), and PronunciationRepairService.applyFix(issue:scope:) which writes the override, regenerates the affected chapter, re-runs QA, and resolves the issue. Code-only (no migration; consumes M3's narration_quality_issue schema).

  🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  ```
- [ ] **Step 6: Watch CI.** Run `gh pr checks` until `Build gate + tests` is passing or clearly blocked; if it fails, inspect the failing job logs, fix the concrete blocker, push, and re-check.
