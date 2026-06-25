# Deck Import Source Anchors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deck import vNext support for portable EPUB source anchors (`s<i>-b<j>`) so JSON and APKG imports can resolve anchors to the local `epub_block.id` and persist them in `flashcard.source_block_id`.

**Architecture:** Keep legacy importer APIs as compatibility wrappers. Add shared import result and warning types, a source-anchor resolver backed by GRDB, JSON importer vNext, APKG sidecar vNext, and focused reader/timeline hardening. Unresolved anchors never fail the import; they produce warnings and fall back to existing timestamp/manual placement.

**Tech Stack:** Swift 5 language mode (project setting; default actor isolation is MainActor — strict-concurrency violations surface as warnings, not errors), Swift Testing, GRDB, Codable, existing Echo database records and DAOs. No new dependencies.

## Global Constraints

- Follow repository `AGENTS.md` and existing Swift concurrency conventions.
- Base this work on `origin/nightly` *before editing*: `git merge-base --is-ancestor origin/nightly HEAD || (git fetch origin nightly && git reset --hard origin/nightly)`. Open the eventual PR with `--base nightly` (never `main`).
- Make targeted file edits; do not rewrite unrelated regions, and do not modify unrelated dirty files.
- Do not add a database migration for `flashcard.source_block_id`; the column already exists (`Shared/Database/Schema_V1.swift` — `flashcard.source_block_id`, `.text`, no foreign key).
- Do not add a foreign key from `flashcard.source_block_id` to `epub_block.id`.
- Do not reparse EPUBs during deck import.
- Do not introduce `href#fragment` anchors.
- Keep existing `importDeck(from:db:) -> Int` and `import(from:into:) -> Int` APIs working.
- Return warnings from vNext APIs; unresolved anchors should not abort imports.
- Run build/test verification from the main agent only. Do not run concurrent `xcodebuild` invocations.

---

## Task 1: Add Import Result, Warning, and Source Anchor Resolver

**Files:**
- Create `EchoCore/Services/DeckImportResult.swift`
- Create `EchoCore/Services/EPUBSourceAnchorResolver.swift`
- Create `EchoTests/EPUBSourceAnchorResolverTests.swift`

**Purpose:** Establish the shared contract used by both importers.

### Steps

- [ ] Create `EchoCore/Services/DeckImportResult.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ImportDeckResult: Equatable, Sendable {
    let importedCount: Int
    let anchoredCount: Int
    let warningCount: Int
    let warnings: [ImportDeckWarning]

    init(importedCount: Int, anchoredCount: Int, warnings: [ImportDeckWarning]) {
        self.importedCount = importedCount
        self.anchoredCount = anchoredCount
        self.warningCount = warnings.count
        self.warnings = warnings
    }
}

enum ImportDeckWarning: Equatable, Sendable {
    case sourceAnchorUnresolved(cardReference: String, sourceAnchor: String)
    case sourceAnchorWrongBook(cardReference: String, sourceAnchor: String)
    case sourceAnchorMalformed(cardReference: String, sourceAnchor: String)
    case targetAudiobookHasNoEPUBBlocks(targetMediaID: String)
    case apkgSidecarMissingTargetMediaID
    case apkgSidecarCardNotFound(cardReference: String)
    case apkgSidecarDecodeFailed(reason: String)
}
```

- [ ] Create `EchoCore/Services/EPUBSourceAnchorResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct EPUBSourceAnchorResolver: Sendable {
    private let dbReader: any DatabaseReader

    init(dbReader: any DatabaseReader) {
        self.dbReader = dbReader
    }

    func hasBlocks(for targetMediaID: String) throws -> Bool {
        try dbReader.read { db in
            try Self.hasBlocks(for: targetMediaID, in: db)
        }
    }

    static func hasBlocks(for targetMediaID: String, in db: Database) throws -> Bool {
        try EPubBlockRecord
            .filter(Column("audiobook_id") == targetMediaID)
            .fetchCount(db) > 0
    }

    func resolve(
        sourceAnchor: String?,
        targetMediaID: String,
        cardReference: String
    ) throws -> EPUBSourceAnchorResolution {
        try dbReader.read { db in
            try Self.resolve(
                sourceAnchor: sourceAnchor,
                targetMediaID: targetMediaID,
                cardReference: cardReference,
                in: db
            )
        }
    }

    static func resolve(
        sourceAnchor: String?,
        targetMediaID: String,
        cardReference: String,
        in db: Database
    ) throws -> EPUBSourceAnchorResolution {
        guard let rawAnchor = sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAnchor.isEmpty
        else {
            return .none
        }

        let portableSuffix = AlignmentSidecar.portableSuffix(of: rawAnchor)
        guard Self.isValidPortableSuffix(portableSuffix) else {
            return .unresolved(.sourceAnchorMalformed(cardReference: cardReference, sourceAnchor: rawAnchor))
        }

        let localBlockID = AlignmentSidecar.localBlockID(portableSuffix, audiobookID: targetMediaID)

        if try Self.blockExists(db, id: localBlockID, audiobookID: targetMediaID) {
            return .resolved(localBlockID)
        }

        if rawAnchor.hasPrefix("epub-"),
           try Self.blockExistsInDifferentBook(db, id: rawAnchor, targetMediaID: targetMediaID) {
            return .unresolved(.sourceAnchorWrongBook(cardReference: cardReference, sourceAnchor: rawAnchor))
        }

        return .unresolved(.sourceAnchorUnresolved(cardReference: cardReference, sourceAnchor: rawAnchor))
    }

    private static func isValidPortableSuffix(_ suffix: String) -> Bool {
        suffix.range(of: #"^s[0-9]+-b[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func blockExists(_ db: Database, id: String, audiobookID: String) throws -> Bool {
        try EPubBlockRecord
            .filter(Column("id") == id && Column("audiobook_id") == audiobookID)
            .fetchOne(db) != nil
    }

    private static func blockExistsInDifferentBook(_ db: Database, id: String, targetMediaID: String) throws -> Bool {
        try EPubBlockRecord
            .filter(Column("id") == id && Column("audiobook_id") != targetMediaID)
            .fetchOne(db) != nil
    }
}

enum EPUBSourceAnchorResolution: Equatable, Sendable {
    case none
    case resolved(String)
    case unresolved(ImportDeckWarning)
}
```

- [ ] Use the `static` `resolve(sourceAnchor:targetMediaID:cardReference:in:)` (and `static hasBlocks(for:in:)`) when resolving inside an existing GRDB write transaction — they take the open `Database` and use no instance state. Do **not** call the reader-backed `resolve`/`hasBlocks` overloads from inside `writer.write`: re-entrant access to a `DatabaseQueue` traps at runtime. Because the `in:` overloads are `static`, nothing reader-bearing (no `any DatabaseReader`) is captured into the `@Sendable` write closure.

- [ ] If `any DatabaseReader` causes a sendability warning in this project, replace the stored property with the concrete reader type already used by the caller. Keep the public behavior unchanged.

- [ ] Create `EchoTests/EPUBSourceAnchorResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
@testable import Echo

struct EPUBSourceAnchorResolverTests {
    @Test
    func resolvesPortableSuffixToLocalEPUBBlockID() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "s0-b0",
            targetMediaID: "book-a",
            cardReference: "card-1"
        )

        #expect(resolution == .resolved("epub-book-a-s0-b0"))
    }

    @Test
    func stripsLegacyFullBlockIDAndRehomesToTargetBook() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-b", blockIDs: ["epub-book-b-s1-b2"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "epub-original-book-s1-b2",
            targetMediaID: "book-b",
            cardReference: "card-2"
        )

        #expect(resolution == .resolved("epub-book-b-s1-b2"))
    }

    @Test
    func reportsMalformedAnchor() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "chapter-1-paragraph-2",
            targetMediaID: "book-a",
            cardReference: "card-3"
        )

        #expect(resolution == .unresolved(.sourceAnchorMalformed(cardReference: "card-3", sourceAnchor: "chapter-1-paragraph-2")))
    }

    @Test
    func reportsWrongBookForFullIDThatExistsElsewhere() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        try seedBook(dbService, audiobookID: "book-b", blockIDs: ["epub-book-b-s9-b9"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "epub-book-a-s0-b0",
            targetMediaID: "book-b",
            cardReference: "card-4"
        )

        #expect(resolution == .unresolved(.sourceAnchorWrongBook(cardReference: "card-4", sourceAnchor: "epub-book-a-s0-b0")))
    }

    private func seedBook(_ dbService: DatabaseService, audiobookID: String, blockIDs: [String]) throws {
        try dbService.write { db in
            var audiobook = AudiobookRecord(
                id: audiobookID,
                title: audiobookID,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)

            for (index, blockID) in blockIDs.enumerated() {
                var block = EPubBlockRecord(
                    id: blockID,
                    audiobookID: audiobookID,
                    spineHref: "Text/chapter.xhtml",
                    spineIndex: index,
                    blockIndex: index,
                    sequenceIndex: index,
                    blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                    text: "Block \(index)",
                    htmlContent: nil,
                    cardColor: nil,
                    chapterThemeColor: nil,
                    imagePath: nil,
                    chapterIndex: index,
                    isHidden: false,
                    hiddenReason: nil,
                    isFrontMatter: false,
                    wordCount: nil,
                    markers: nil,
                    textFormats: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                try block.insert(db)
            }
        }
    }
}
```

- [ ] Keep seeded model values deterministic. If the repository changes model initializers before implementation, update only the argument labels needed to match the current `AudiobookRecord` and `EPubBlockRecord` definitions.

### Verification

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/EPUBSourceAnchorResolverTests
```

Expected result: build succeeds and all resolver tests pass.

---

## Task 2: Add JSON Deck Import vNext

**Files:**
- Modify `EchoCore/Models/FlashcardDeckImport.swift`
- Modify `EchoCore/Services/DeckImportService.swift`
- Modify `EchoTests/DeckImportServiceTests.swift`

**Purpose:** Allow generated JSON decks to include `sourceAnchor` and import cards with resolved `sourceBlockID`.

### Steps

- [ ] Add optional `sourceAnchor` to `FlashcardDeckImport.ImportedCard`:

```swift
let sourceAnchor: String?
```

Keep it optional so all existing deck JSON fixtures still decode.

- [ ] Add vNext API to `DeckImportService` while preserving the legacy wrapper:

```swift
func importDeckVNext(from url: URL, db writer: DatabaseWriter) throws -> ImportDeckResult {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw DeckImportError.fileReadFailed(error)
    }

    let deck: FlashcardDeckImport
    do {
        deck = try JSONDecoder().decode(FlashcardDeckImport.self, from: data)
    } catch {
        throw DeckImportError.invalidJSON(error)
    }

    guard !deck.cards.isEmpty else {
        throw DeckImportError.emptyDeck
    }

    for (index, card) in deck.cards.enumerated() {
        guard !card.frontText.isEmpty, !card.backText.isEmpty else {
            throw DeckImportError.emptyCardText(cardIndex: index)
        }
        guard card.startTime >= 0, card.endTime > card.startTime else {
            throw DeckImportError.invalidTimeRange(cardIndex: index)
        }
        guard validTriggerTimings.contains(card.triggerTiming.rawValue) else {
            throw DeckImportError.invalidTriggerTiming(card.triggerTiming.rawValue, cardIndex: index)
        }
    }

    var warnings: [ImportDeckWarning] = []
    var anchoredCount = 0
    var resolvedSourceBlockIDs = Array<String?>(repeating: nil, count: deck.cards.count)

    let resolver = EPUBSourceAnchorResolver(dbReader: writer)
    let targetHasBlocks = try resolver.hasBlocks(for: deck.targetMediaID)
    if !targetHasBlocks {
        warnings.append(.targetAudiobookHasNoEPUBBlocks(targetMediaID: deck.targetMediaID))
    }

    if targetHasBlocks {
        for (index, importedCard) in deck.cards.enumerated() {
            let cardReference = "json-card-\(index)"
            switch try resolver.resolve(
                sourceAnchor: importedCard.sourceAnchor,
                targetMediaID: deck.targetMediaID,
                cardReference: cardReference
            ) {
            case .none:
                resolvedSourceBlockIDs[index] = nil
            case .resolved(let blockID):
                resolvedSourceBlockIDs[index] = blockID
                anchoredCount += 1
            case .unresolved(let warning):
                resolvedSourceBlockIDs[index] = nil
                warnings.append(warning)
            }
        }
    }

    let deckID: String
    if let existingID = try findDeck(named: deck.deckName, db: writer) {
        deckID = existingID
    } else {
        deckID = UUID().uuidString
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES (?, ?, 'json_import', ?, ?)
                    """,
                arguments: [
                    deckID, deck.deckName, Date().ISO8601Format(), Date().ISO8601Format(),
                ]
            )
        }
    }

    try writer.write { db in
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
                VALUES (?, ?, 'json_import', 0, ?)
                """,
            arguments: [deck.targetMediaID, deck.deckName, Date().ISO8601Format()]
        )
    }

    let dao = FlashcardDAO(db: writer)
    for (index, card) in deck.cards.enumerated() {
        let flashcard = Flashcard(
            id: UUID().uuidString,
            audiobookID: deck.targetMediaID,
            frontText: card.frontText,
            backText: card.backText,
            mediaTimestamp: card.startTime,
            endTimestamp: card.endTime,
            triggerTiming: card.triggerTiming,
            nextReviewDate: Date().ISO8601Format(),
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: deckID,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: resolvedSourceBlockIDs[index],
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        try dao.insert(flashcard)
    }

    return ImportDeckResult(
        importedCount: deck.cards.count,
        anchoredCount: anchoredCount,
        warnings: warnings
    )
}

func importDeck(from url: URL, db writer: DatabaseWriter) throws -> Int {
    try importDeckVNext(from: url, db: writer).importedCount
}
```

- [ ] Add `importDeckVNext` as the new implementation and make `importDeck` a thin wrapper returning `importDeckVNext(...).importedCount` (as written above). The snippet already carries over the existing validations (`emptyDeck`, `emptyCardText`, `invalidTimeRange`, `invalidTriggerTiming`), the `findDeck` dedup, and the placeholder-audiobook `INSERT OR IGNORE` — keep those verbatim. This is a **replacement** of `importDeck`, not a second code path: do not leave the old `importDeck` body in place alongside the wrapper.

- [ ] Add JSON tests to `EchoTests/DeckImportServiceTests.swift`:

```swift
@Test
func importDeckVNextResolvesSourceAnchor() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
    let url = try writeDeckJSON("""
    {
      "deckName": "Anchored Deck",
      "targetMediaID": "book-a",
      "cards": [
        {
          "frontText": "Question",
          "backText": "Answer",
          "startTime": 0,
          "endTime": 5,
          "sourceAnchor": "s1-b2",
          "triggerTiming": "beginning"
        }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 1)
    #expect(result.warningCount == 0)

    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.count == 1)
    #expect(cards.first?.sourceBlockID == "epub-book-a-s1-b2")
}
```

```swift
@Test
func importDeckVNextRehomesFullLegacyBlockID() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-b", blockIDs: ["epub-book-b-s0-b0"])
    let url = try writeDeckJSON("""
    {
      "deckName": "Rehomed Deck",
      "targetMediaID": "book-b",
      "cards": [
        {
          "frontText": "Question",
          "backText": "Answer",
          "startTime": 0,
          "endTime": 5,
          "triggerTiming": "manualOnly",
          "sourceAnchor": "epub-old-book-s0-b0"
        }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.anchoredCount == 1)
    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.sourceBlockID == "epub-book-b-s0-b0")
}
```

```swift
@Test
func importDeckVNextImportsUnresolvedAnchorWithWarning() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
    let url = try writeDeckJSON("""
    {
      "deckName": "Partially Anchored Deck",
      "targetMediaID": "book-a",
      "cards": [
        {
          "frontText": "Question",
          "backText": "Answer",
          "startTime": 0,
          "endTime": 5,
          "triggerTiming": "manualOnly",
          "sourceAnchor": "s9-b9"
        }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 0)
    #expect(result.warnings == [.sourceAnchorUnresolved(cardReference: "json-card-0", sourceAnchor: "s9-b9")])

    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.sourceBlockID == nil)
}
```

```swift
@Test
func importDeckVNextImportsMalformedAnchorWithWarning() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
    let url = try writeDeckJSON("""
    {
      "deckName": "Malformed Anchor Deck",
      "targetMediaID": "book-a",
      "cards": [
        {
          "frontText": "Question",
          "backText": "Answer",
          "startTime": 0,
          "endTime": 5,
          "triggerTiming": "manualOnly",
          "sourceAnchor": "chapter-1-paragraph-2"
        }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 0)
    #expect(result.warnings == [
        .sourceAnchorMalformed(cardReference: "json-card-0", sourceAnchor: "chapter-1-paragraph-2")
    ])

    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.sourceBlockID == nil)
}
```

```swift
@Test
func importDeckVNextImportsWrongBookAnchorWithWarning() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
    try seedBookWithBlocks(writer, targetID: "book-b", blockIDs: ["epub-book-b-s1-b1"])
    let url = try writeDeckJSON("""
    {
      "deckName": "Wrong Book Anchor Deck",
      "targetMediaID": "book-b",
      "cards": [
        {
          "frontText": "Question",
          "backText": "Answer",
          "startTime": 0,
          "endTime": 5,
          "triggerTiming": "manualOnly",
          "sourceAnchor": "epub-book-a-s0-b0"
        }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 0)
    #expect(result.warnings == [
        .sourceAnchorWrongBook(cardReference: "json-card-0", sourceAnchor: "epub-book-a-s0-b0")
    ])

    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.sourceBlockID == nil)
}
```

```swift
@Test
func importDeckVNextReportsTargetWithoutEPUBBlocksOnce() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedAudiobook(writer, id: "book-without-blocks")
    let url = try writeDeckJSON("""
    {
      "deckName": "No Blocks Deck",
      "targetMediaID": "book-without-blocks",
      "cards": [
        { "frontText": "One", "backText": "Answer", "startTime": 0, "endTime": 5, "triggerTiming": "manualOnly", "sourceAnchor": "s0-b0" },
        { "frontText": "Two", "backText": "Answer", "startTime": 5, "endTime": 10, "triggerTiming": "manualOnly", "sourceAnchor": "s0-b1" }
      ]
    }
    """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 2)
    #expect(result.anchoredCount == 0)
    #expect(result.warnings == [.targetAudiobookHasNoEPUBBlocks(targetMediaID: "book-without-blocks")])

    let cards = try writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.map(\.sourceBlockID) == [nil, nil])
}
```

- [ ] Add or reuse helpers inside `DeckImportServiceTests`:

```swift
private func seedAudiobook(_ writer: DatabaseWriter, id: String) throws {
    try writer.write { db in
        var audiobook = AudiobookRecord(
            id: id,
            title: id,
            author: "Test Author",
            duration: 0,
            fileCount: nil,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
        )
        try audiobook.insert(db)
    }
}

private func seedBookWithBlocks(_ writer: DatabaseWriter, targetID: String, blockIDs: [String]) throws {
    try writer.write { db in
        var audiobook = AudiobookRecord(
            id: targetID,
            title: targetID,
            author: "Test Author",
            duration: 0,
            fileCount: nil,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
        )
        try audiobook.insert(db)

        for (index, blockID) in blockIDs.enumerated() {
            var block = EPubBlockRecord(
                id: blockID,
                audiobookID: targetID,
                spineHref: "Text/chapter.xhtml",
                spineIndex: index,
                blockIndex: index,
                sequenceIndex: index,
                blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                text: "Block \(index)",
                htmlContent: nil,
                cardColor: nil,
                chapterThemeColor: nil,
                imagePath: nil,
                chapterIndex: index,
                isHidden: false,
                hiddenReason: nil,
                isFrontMatter: false,
                wordCount: nil,
                markers: nil,
                textFormats: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            try block.insert(db)
        }
    }
}
```

### Verification

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/DeckImportServiceTests
```

Expected result: existing JSON importer tests still pass, and vNext tests cover resolved, rehomed, unresolved, malformed, wrong-book, and no-block warnings.

---

## Task 3: Harden Timeline Sync and Reader Placement

**Files:**
- Modify `Shared/Database/DAOs/FlashcardDAO.swift`
- Modify `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Extend `EchoTests/FlashcardDAOSchedulerTests.swift` (add the DAO timeline test there — see the scoping note below; do **not** create a standalone file)
- Modify `EchoTests/ReaderFeedViewModelAccordionTests.swift`

**Purpose:** Ensure imported anchored cards carry their block IDs into timeline rows and reader placement remains scoped to the active audiobook.

### Steps

- [ ] In `FlashcardDAO.syncToTimeline`, set the timeline row block field from the card:

```swift
epubBlockID: card.sourceBlockID,
```

Add this named argument in the `TimelineItem` initializer used for flashcard timeline sync. Preserve existing timestamps and item IDs.

- [ ] In `ReaderFeedViewModel`, scope block lookup to the current audiobook. If the existing method is:

```swift
private func lookupChapter(ofBlock blockID: String) -> Int?
```

change it to:

```swift
private func lookupChapter(ofBlock blockID: String, audiobookID: String) -> Int?
```

and update the query to include both columns:

```swift
let block = try EPubBlockRecord
    .filter(Column("id") == blockID && Column("audiobook_id") == audiobookID)
    .fetchOne(db)
```

Update the call site in `placement(sourceBlockID:mediaTimestamp:)` to pass the active audiobook ID already available in the view model.

- [ ] Add this DAO timeline test **inside `FlashcardDAOSchedulerTests`** — it reuses that suite's `private` helpers `makeCard(id:repetitions:intervalDays:)` and `seedAudiobook(in:)`, which a separate test struct cannot see. Creating a standalone `FlashcardDAOTimelineTests.swift` would leave those helpers out of scope and fail to compile:

```swift
@Test
func syncToTimelineCopiesSourceBlockID() throws {
    let service = try DatabaseService(inMemory: ())
    let dao = FlashcardDAO(db: service.writer)
    try seedAudiobook(in: service)
    try service.write { db in
        try db.execute(
            sql: """
                INSERT INTO epub_block
                  (id, audiobook_id, spine_href, spine_index, block_index,
                   sequence_index, block_kind, chapter_index, is_hidden)
                VALUES ('epub-book-s0-b0', 'book', 'Text/chapter.xhtml', 0, 0,
                        0, 'paragraph', 0, 0)
                """)
    }

    var card = makeCard(id: "anchored-card", repetitions: 0, intervalDays: 0)
    card.sourceBlockID = "epub-book-s0-b0"
    try dao.insert(card)

    let timelineItem = try service.read { db in
        try TimelineItem.fetchOne(db, key: "ankiCard-anchored-card")
    }

    #expect(timelineItem?.epubBlockID == "epub-book-s0-b0")
}
```

- [ ] Add reader placement regression in `ReaderFeedViewModelAccordionTests`:

```swift
@Test
func anchoredFlashcardAppearsAfterSourceBlock() throws {
    let db = try seed()
    let stamp = Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
    try db.write { db in
        try db.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES ('deck-a', 'Deck', 'test', ?, ?)
                """,
            arguments: [stamp, stamp])
        try db.execute(
            sql: """
                INSERT INTO flashcard
                  (id, audiobook_id, front_text, back_text, media_timestamp,
                   end_timestamp, trigger_timing, interval_days, ease_factor,
                   repetitions, is_enabled, deck_id, source_block_id,
                   created_at, modified_at, card_type)
                VALUES ('anchored-card', 'bk', 'Front', 'Back', 9999,
                        NULL, 'manualOnly', 0, 2.5,
                        0, 1, 'deck-a', 'c0-p',
                        ?, ?, 'normal')
                """,
            arguments: [stamp, stamp])
    }

    let viewModel = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
    viewModel.reload()
    viewModel.toggleChapter(0)

    let items = viewModel.displaySections.flatMap(\.items)
    let blockIndex = try #require(items.firstIndex { item in
        if case .block(let block) = item {
            return block.id == "c0-p"
        }
        return false
    })

    #expect(blockIndex + 1 < items.count)
    if case .ankiCard(let card) = items[blockIndex + 1] {
        #expect(card.id == "anchored-card")
    } else {
        Issue.record("Expected anchored flashcard immediately after its source block")
    }
}
```

- [ ] Align helper and initializer names with existing `ReaderFeedViewModelAccordionTests` code. The assertion must pattern-match item cases instead of relying on display IDs.

### Verification

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests
make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
```

Expected result: timeline rows now preserve `epub_block_id`, and reader feed placement prefers source block over timestamp.

---

## Task 4: Add APKG Echo Sidecar Import vNext

**Files:**
- Modify `EchoCore/Services/ApkgImportService.swift`
- Modify `EchoTests/ApkgImportServiceTests.swift`

**Purpose:** Let APKG archives optionally include `echo-import.json` with source anchors keyed by Anki `cardID` or `noteGUID`.

### Sidecar Contract

`echo-import.json` lives at the APKG archive root:

```json
{
  "formatVersion": 1,
  "targetMediaID": "book-a",
  "cards": [
    {
      "cardID": 1712345678001,
      "noteGUID": "echo-note-guid",
      "sourceAnchor": "s0-b1",
      "startTime": 10.5,
      "endTime": 15.25,
      "triggerTiming": "beginning"
    }
  ]
}
```

### Steps

- [ ] Add public vNext context and result API:

```swift
struct ApkgImportContext: Sendable {
    var targetMediaID: String?

    init(targetMediaID: String? = nil) {
        self.targetMediaID = targetMediaID
    }
}

func importVNext(
    from url: URL,
    into writer: DatabaseWriter,
    context: ApkgImportContext = .init()
) async throws -> ImportDeckResult {
    let tmpDir = try extractSafely(apkgURL: url)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    guard let (collectionURL, formatName) = findCollection(in: tmpDir) else {
        throw ImportError.notAnApkg
    }

    let collection = try await openCollection(at: collectionURL, formatName: formatName)
    let sidecarResult = readEchoImportSidecar(in: tmpDir)

    let sidecar: EchoImportSidecar?
    var warnings: [ImportDeckWarning] = []
    switch sidecarResult {
    case .success(let decodedSidecar):
        sidecar = decodedSidecar
    case .failure(let warning):
        sidecar = nil
        warnings.append(warning)
    }

    // Preserve the legacy `import` behavior: an empty collection creates no
    // deck/audiobook rows (the legacy path returned 0 before `importCards`).
    // Any sidecar-decode warning collected above is still surfaced.
    guard !collection.notes.isEmpty else {
        return ImportDeckResult(importedCount: 0, anchoredCount: 0, warnings: warnings)
    }

    let importOptions = try makeImportOptions(
        sidecar: sidecar,
        context: context,
        writer: writer,
        warnings: &warnings
    )

    let importOutcome = try await writer.write { db in
        try importCards(collection: collection, db: db, options: importOptions)
    }
    warnings.append(contentsOf: importOutcome.warnings)

    return ImportDeckResult(
        importedCount: importOutcome.importedCount,
        anchoredCount: importOutcome.anchoredCount,
        warnings: warnings
    )
}

func `import`(from url: URL, into writer: DatabaseWriter) async throws -> Int {
    try await importVNext(from: url, into: writer).importedCount
}
```

- [ ] Extract the existing collection-open logic into a helper used by vNext:

```swift
private func openCollection(at collectionURL: URL, formatName: String) async throws -> CollectionData {
    do {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: collectionURL.path, configuration: config)
        return try await queue.read { db in
            try readCollection(db, format: formatName)
        }
    } catch {
        throw ImportError.dbOpenFailed(error)
    }
}
```

- [ ] Add private sidecar models inside `ApkgImportService`:

```swift
private struct EchoImportSidecar: Decodable, Sendable {
    var formatVersion: Int
    var targetMediaID: String?
    var cards: [Card]

    struct Card: Decodable, Sendable {
        var cardID: Int64?
        var noteGUID: String?
        var sourceAnchor: String?
        var startTime: TimeInterval?
        var endTime: TimeInterval?
        var triggerTiming: FlashcardTriggerTiming?
    }
}

private struct EchoImportSidecarIndex: Sendable {
    var byCardID: [Int64: EchoImportSidecar.Card]
    var byNoteGUID: [String: EchoImportSidecar.Card]

    init(cards: [EchoImportSidecar.Card]) {
        var byCardID: [Int64: EchoImportSidecar.Card] = [:]
        var byNoteGUID: [String: EchoImportSidecar.Card] = [:]
        for card in cards {
            if let cardID = card.cardID, byCardID[cardID] == nil {
                byCardID[cardID] = card
            }
            if let noteGUID = card.noteGUID, !noteGUID.isEmpty, byNoteGUID[noteGUID] == nil {
                byNoteGUID[noteGUID] = card
            }
        }
        self.byCardID = byCardID
        self.byNoteGUID = byNoteGUID
    }

    func metadata(cardID: Int64, noteGUID: String?) -> EchoImportSidecar.Card? {
        if let card = byCardID[cardID] {
            return card
        }
        if let noteGUID, let card = byNoteGUID[noteGUID] {
            return card
        }
        return nil
    }
}
```

- [ ] Add private import option and outcome types:

```swift
private struct APKGImportOptions: Sendable {
    var targetMediaID: String
    var sidecarIndex: EchoImportSidecarIndex?
    var canResolveAnchors: Bool
}

private struct APKGImportOutcome: Sendable {
    var importedCount: Int
    var anchoredCount: Int
    var warnings: [ImportDeckWarning]
}
```

- [ ] Decode optional sidecar after archive extraction:

```swift
private func readEchoImportSidecar(in directory: URL) -> Result<EchoImportSidecar?, ImportDeckWarning> {
    let sidecarURL = directory.appending(path: "echo-import.json")
    guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
        return .success(nil)
    }

    do {
        let data = try Data(contentsOf: sidecarURL)
        return .success(try JSONDecoder().decode(EchoImportSidecar.self, from: data))
    } catch {
        return .failure(.apkgSidecarDecodeFailed(reason: String(describing: error)))
    }
}
```

- [ ] Determine the target media ID in this order:

```swift
let sidecarTargetMediaID = sidecar?.targetMediaID?.trimmingCharacters(in: .whitespacesAndNewlines)
let contextTargetMediaID = context.targetMediaID?.trimmingCharacters(in: .whitespacesAndNewlines)
let resolvedTargetMediaID = [sidecarTargetMediaID, contextTargetMediaID]
    .compactMap { value in
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
    .first
```

- [ ] Implement target and resolver preparation with this helper:

```swift
private func makeImportOptions(
    sidecar: EchoImportSidecar?,
    context: ApkgImportContext,
    writer: DatabaseWriter,
    warnings: inout [ImportDeckWarning]
) throws -> APKGImportOptions {
    let fallbackTargetMediaID = "apkg-import"
    let sidecarTargetMediaID = sidecar?.targetMediaID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let contextTargetMediaID = context.targetMediaID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTargetMediaID = [sidecarTargetMediaID, contextTargetMediaID]
        .compactMap { value in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }
        .first

    guard let sidecar else {
        return APKGImportOptions(
            targetMediaID: resolvedTargetMediaID ?? fallbackTargetMediaID,
            sidecarIndex: nil,
            canResolveAnchors: false
        )
    }

    let sidecarIndex = EchoImportSidecarIndex(cards: sidecar.cards)
    guard let targetMediaID = resolvedTargetMediaID else {
        warnings.append(.apkgSidecarMissingTargetMediaID)
        return APKGImportOptions(
            targetMediaID: fallbackTargetMediaID,
            sidecarIndex: sidecarIndex,
            canResolveAnchors: false
        )
    }

    // Preflight OUTSIDE the write transaction with a reader-backed resolver.
    // Anchor resolution itself runs inside the transaction via the static
    // `EPUBSourceAnchorResolver.resolve(...in:)`, so no resolver instance
    // (and no `any DatabaseReader`) is captured into the @Sendable write closure.
    let targetHasBlocks = try EPUBSourceAnchorResolver(dbReader: writer).hasBlocks(for: targetMediaID)
    if !targetHasBlocks {
        warnings.append(.targetAudiobookHasNoEPUBBlocks(targetMediaID: targetMediaID))
    }

    return APKGImportOptions(
        targetMediaID: targetMediaID,
        sidecarIndex: sidecarIndex,
        canResolveAnchors: targetHasBlocks
    )
}
```

- [ ] If a sidecar exists and `resolvedTargetMediaID == nil`, append `.apkgSidecarMissingTargetMediaID`, import the APKG using the current default `"apkg-import"`, and skip anchor resolution.

- [ ] If no sidecar exists and no context target is provided, preserve current APKG behavior: `audiobookID` remains `"apkg-import"`, timestamps remain `0`, trigger timing remains `.manualOnly`, and warning list is empty.

- [ ] When a sidecar exists and target media ID is known:
  - Preflight `resolver.hasBlocks(for:)`.
  - Append `.targetAudiobookHasNoEPUBBlocks(targetMediaID:)` once if the target has no EPUB blocks.
  - For each imported APKG card, look up sidecar metadata by `cardID`, then `noteGUID`.
  - If sidecar has card entries but a given imported card is not found, append `.apkgSidecarCardNotFound(cardReference: "apkg-card-\(cardID)")`.
  - Resolve `sourceAnchor` through `EPUBSourceAnchorResolver`.
  - Set imported `Flashcard.sourceBlockID` when resolved.
  - Allow sidecar `startTime`, `endTime`, and `triggerTiming` to override APKG defaults.

- [ ] Change `importCards` to return counts and warnings:

```swift
private func importCards(
    collection: CollectionData,
    db: Database,
    options: APKGImportOptions
) throws -> APKGImportOutcome {
    var noteMap: [Int64: AnkiNote] = [:]
    for note in collection.notes {
        noteMap[note.id] = note
    }

    let deckID: String
    if let existingID = try findDeck(named: collection.deckName, db: db) {
        deckID = existingID
    } else {
        deckID = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'apkg_import', ?, ?)
                """,
            arguments: [deckID, collection.deckName, Date().ISO8601Format(), Date().ISO8601Format()])
    }

    try db.execute(
        sql: """
            INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
            VALUES (?, 'Imported from Anki', 'apkg', 0, ?)
            """,
        arguments: [options.targetMediaID, Date().ISO8601Format()])

    var warnings: [ImportDeckWarning] = []
    var anchoredCount = 0
    var importedCount = 0

    for card in collection.cards {
        guard let note = noteMap[card.nid] else { continue }
        let fields = note.flds.components(separatedBy: "\u{1f}")
        let frontText = fields.indices.contains(0) ? fields[0] : note.sfld
        let backText = fields.indices.contains(1) ? fields[1] : ""
        guard !frontText.isEmpty else { continue }

        let cardReference = "apkg-card-\(card.id)"
        let sidecarCard = options.sidecarIndex?.metadata(cardID: card.id, noteGUID: note.guid)
        if options.sidecarIndex != nil, sidecarCard == nil {
            warnings.append(.apkgSidecarCardNotFound(cardReference: cardReference))
        }

        var sourceBlockID: String?
        if let sidecarCard, options.canResolveAnchors {
            switch try EPUBSourceAnchorResolver.resolve(
                sourceAnchor: sidecarCard.sourceAnchor,
                targetMediaID: options.targetMediaID,
                cardReference: cardReference,
                in: db
            ) {
            case .none:
                sourceBlockID = nil
            case .resolved(let blockID):
                sourceBlockID = blockID
                anchoredCount += 1
            case .unresolved(let warning):
                sourceBlockID = nil
                warnings.append(warning)
            }
        }

        let easeFactor = card.factor > 0 ? Double(card.factor) / 1000.0 : 2.5
        var flashcard = Flashcard(
            id: UUID().uuidString,
            audiobookID: options.targetMediaID,
            frontText: frontText,
            backText: backText,
            mediaTimestamp: sidecarCard?.startTime ?? 0,
            endTimestamp: sidecarCard?.endTime,
            triggerTiming: sidecarCard?.triggerTiming ?? .manualOnly,
            nextReviewDate: Date().ISO8601Format(),
            intervalDays: max(0, card.ivl),
            easeFactor: max(1.3, easeFactor),
            repetitions: max(0, card.reps),
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: deckID,
            tags: note.tags.isEmpty ? nil : note.tags,
            mediaJSON: nil,
            sourceBlockID: sourceBlockID,
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        try flashcard.insert(db)
        importedCount += 1
    }

    return APKGImportOutcome(
        importedCount: importedCount,
        anchoredCount: anchoredCount,
        warnings: warnings
    )
}
```

- [ ] In the real `importCards` body, preserve the existing mapping code and replace only these field defaults:
  - `audiobookID`: use `options.targetMediaID`
  - `mediaTimestamp`: use `sidecarCard.startTime ?? 0`
  - `endTimestamp`: use `sidecarCard.endTime`
  - `triggerTiming`: use `sidecarCard.triggerTiming ?? .manualOnly`
  - `sourceBlockID`: use the resolved EPUB block ID or `nil`

- [ ] Do not fail the APKG import for missing, invalid, partial, or unresolved sidecar data.

- [ ] Timeline note: APKG cards are inserted with `flashcard.insert(db)` (the existing raw-record path), which does **not** run `FlashcardDAO.syncToTimeline`. An anchored APKG card therefore persists `source_block_id` on the `flashcard` row (and the reader feed places it correctly via `placement(sourceBlockID:)`), but it does **not** get a `timeline_item` row — matching current APKG behavior. The Task 3 `timeline_item.epub_block_id` enhancement consequently applies to the JSON path only. Do not add timeline sync to the APKG path in this slice; if wanted later, expose a `Database`-taking sync entry point on `FlashcardDAO` and call it here.

- [ ] Add APKG sidecar fixture helper in `ApkgImportServiceTests`:

```swift
private struct FixtureApkgIdentity {
    let cardID: Int64
    let noteGUID: String
}

@discardableResult
private func createFixtureApkg(
    destURL: URL,
    deckName: String = "Test Deck",
    front: String = "Hello",
    back: String = "World",
    format: String = "collection.anki21",
    noteID: Int64 = 1_712_345_678_000,
    cardID: Int64 = 1_712_345_678_001,
    noteGUID: String = "echo-note-guid",
    sidecarJSON: String? = nil
) async throws -> FixtureApkgIdentity {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkg_fixture_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let dbURL = tmpDir.appendingPathComponent(format)
    var config = Configuration()
    config.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode=OFF")
        try db.execute(sql: "PRAGMA synchronous=OFF")
    }
    let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
    try await queue.write { db in
        try db.execute(sql: """
            CREATE TABLE col (
                id INTEGER PRIMARY KEY,
                crt INTEGER NOT NULL, mod INTEGER NOT NULL, scm INTEGER NOT NULL,
                ver INTEGER NOT NULL, dty INTEGER NOT NULL, usn INTEGER NOT NULL,
                ls INTEGER NOT NULL, conf TEXT NOT NULL, models TEXT NOT NULL,
                decks TEXT NOT NULL, dconf TEXT NOT NULL, tags TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY, guid TEXT NOT NULL, mid INTEGER NOT NULL,
                mod INTEGER NOT NULL, usn INTEGER NOT NULL, tags TEXT NOT NULL,
                flds TEXT NOT NULL, sfld TEXT NOT NULL, csum INTEGER NOT NULL,
                flags INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE cards (
                id INTEGER PRIMARY KEY, nid INTEGER NOT NULL, did INTEGER NOT NULL,
                ord INTEGER NOT NULL, mod INTEGER NOT NULL, usn INTEGER NOT NULL,
                type INTEGER NOT NULL, queue INTEGER NOT NULL, due INTEGER NOT NULL,
                ivl INTEGER NOT NULL, factor INTEGER NOT NULL, reps INTEGER NOT NULL,
                lapses INTEGER NOT NULL, left INTEGER NOT NULL, odue INTEGER NOT NULL,
                odid INTEGER NOT NULL, flags INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE revlog (
                id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL,
                ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL,
                factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL
            )
            """)

        let now = 1_712_345_678
        let decksJSON = """
            {"1":{"id":1,"name":"\(deckName)","desc":"","collapsed":false,"conf":1,"dyn":0}}
            """
        let modelsJSON = """
            {"1547929172779":{"id":1547929172779,"name":"Basic","type":0,"mod":\(now),"usn":0,"sortf":0,"did":1,"tags":[],"flds":[{"name":"Front","ord":0},{"name":"Back","ord":1}],"tmpls":[{"name":"Card 1","ord":0,"qfmt":"{{Front}}","afmt":"{{Back}}"}]}}
            """
        try db.execute(sql: """
            INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
            VALUES (1, ?, ?, ?, 21, 0, 0, ?, '{}', ?, ?, '{}', '')
            """, arguments: [now, now, now, now, modelsJSON, decksJSON])

        let fields = "\(front)\u{1f}\(back)"
        try db.execute(sql: """
            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            VALUES (?, ?, 1547929172779, ?, 0, '', ?, ?, 0, 0, '')
            """, arguments: [noteID, noteGUID, now, fields, front])

        try db.execute(sql: """
            INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
            VALUES (?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 2500, 0, 0, 0, 0, 0, 0, '')
            """, arguments: [cardID, noteID, now])
    }

    try "{}".write(to: tmpDir.appendingPathComponent("media"), atomically: true, encoding: .utf8)
    if let sidecarJSON {
        try sidecarJSON.write(
            to: tmpDir.appendingPathComponent("echo-import.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    try? FileManager.default.removeItem(at: destURL)
    let archive = try Archive(url: destURL, accessMode: .create)
    let items = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
    for item in items {
        try archive.addEntry(with: item.lastPathComponent, relativeTo: tmpDir)
    }

    return FixtureApkgIdentity(cardID: cardID, noteGUID: noteGUID)
}
```

- [ ] Add an APKG test helper for EPUB seed rows:

```swift
private func seedBookWithBlocks(_ writer: DatabaseWriter, targetID: String, blockIDs: [String]) async throws {
    try await writer.write { db in
        try db.execute(
            sql: """
                INSERT INTO audiobook (id, title, author, duration, added_at)
                VALUES (?, ?, 'Test Author', 0, ?)
                """,
            arguments: [targetID, targetID, Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()])

        for (index, blockID) in blockIDs.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, chapter_index, is_hidden)
                    VALUES (?, ?, 'Text/chapter.xhtml', ?, ?, ?, 'paragraph', ?, 0)
                    """,
                arguments: [blockID, targetID, index, index, index, index])
        }
    }
}
```

- [ ] Add APKG vNext tests:

```swift
@Test
func importVNextResolvesSidecarCardIDAnchor() async throws {
    let writer = try makeTestDB()
    try await seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b1"])
    let apkgURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidecar_card_id_\(UUID().uuidString).apkg")
    defer { try? FileManager.default.removeItem(at: apkgURL) }
    let identity = try await createFixtureApkg(
        destURL: apkgURL,
        sidecarJSON: """
        {
          "formatVersion": 1,
          "targetMediaID": "book-a",
          "cards": [
            {
              "cardID": \(1_712_345_678_001),
              "sourceAnchor": "s0-b1",
              "startTime": 10.5,
              "endTime": 15.25,
              "triggerTiming": "beginning"
            }
          ]
        }
        """
    )

    #expect(identity.cardID == 1_712_345_678_001)
    let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 1)
    #expect(result.warningCount == 0)

    let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.audiobookID == "book-a")
    #expect(cards.first?.sourceBlockID == "epub-book-a-s0-b1")
    #expect(cards.first?.mediaTimestamp == 10.5)
    #expect(cards.first?.endTimestamp == 15.25)
    #expect(cards.first?.triggerTiming == .beginning)
}
```

```swift
@Test
func importVNextResolvesSidecarNoteGUIDAnchor() async throws {
    let writer = try makeTestDB()
    try await seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b1"])
    let apkgURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidecar_note_guid_\(UUID().uuidString).apkg")
    defer { try? FileManager.default.removeItem(at: apkgURL) }
    let identity = try await createFixtureApkg(
        destURL: apkgURL,
        sidecarJSON: """
        {
          "formatVersion": 1,
          "targetMediaID": "book-a",
          "cards": [
            {
              "noteGUID": "echo-note-guid",
              "sourceAnchor": "s0-b1"
            }
          ]
        }
        """
    )

    #expect(identity.noteGUID == "echo-note-guid")
    let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

    #expect(result.anchoredCount == 1)
    let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.sourceBlockID == "epub-book-a-s0-b1")
}
```

```swift
@Test
func importVNextReportsInvalidSidecarButImportsDeck() async throws {
    let writer = try makeTestDB()
    let apkgURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("invalid_sidecar_\(UUID().uuidString).apkg")
    defer { try? FileManager.default.removeItem(at: apkgURL) }
    try await createFixtureApkg(destURL: apkgURL, sidecarJSON: "{ invalid json")

    let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 0)
    #expect(result.warningCount == 1)
    guard case .apkgSidecarDecodeFailed = result.warnings.first else {
        Issue.record("Expected APKG sidecar decode warning")
        return
    }

    let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
    #expect(cards.first?.audiobookID == "apkg-import")
    #expect(cards.first?.sourceBlockID == nil)
}
```

```swift
@Test
func importVNextReportsSidecarMissingTargetMediaID() async throws {
    let writer = try makeTestDB()
    let apkgURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing_target_\(UUID().uuidString).apkg")
    defer { try? FileManager.default.removeItem(at: apkgURL) }
    try await createFixtureApkg(
        destURL: apkgURL,
        sidecarJSON: """
        {
          "formatVersion": 1,
          "cards": [
            { "cardID": 1712345678001, "sourceAnchor": "s0-b1" }
          ]
        }
        """
    )

    let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 0)
    #expect(result.warnings.contains(.apkgSidecarMissingTargetMediaID))
}
```

- [ ] Keep the existing APKG tests unchanged in behavior. The legacy `import(from:into:)` method should still return only the imported count and should produce the same database rows when no sidecar is present.

### Verification

- [ ] Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ApkgImportServiceTests
```

Expected result: legacy APKG tests pass, and vNext sidecar tests cover card ID, note GUID, invalid sidecar, and missing target media ID.

---

## Task 5: Report Warnings Through Import Callers

**Files:**
- Modify `EchoCore/Views/SettingsView.swift`

**Purpose:** Make warnings visible to callers without adding a broad UI redesign.

### Steps

- [ ] In `SettingsView.handleImportResult(_:)`, replace the legacy JSON import count with the vNext result using the existing local variable names:

```swift
let result = try importer.importDeckVNext(from: url, db: db.writer)
importAlert = ("Import Complete", importCompletionMessage(for: result))
```

- [ ] Add this private helper to `SettingsView` near `handleImportResult(_:)`:

```swift
private func importCompletionMessage(for result: ImportDeckResult) -> String {
    if result.warningCount == 0 {
        return "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text."
    }
    return "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text. \(result.warningCount) warnings."
}
```

- [ ] Keep literal strings here because the surrounding import alert currently uses literal strings. Do not edit `EchoCore/Localizable.xcstrings` for this slice.

- [ ] Do not add a warning details screen in this task. The result object carries structured warnings so a future UI can render details.

- [ ] Do not modify APKG UI call sites in this task. Current APKG usage is service/test-only in this repository; APKG warning reporting is satisfied by `ApkgImportService.importVNext(from:into:context:)` returning `ImportDeckResult`.

### Verification

- [ ] Run:

```bash
make build-tests
```

Expected result: import callers can report imported count, anchored count, and warning count.

---

## Task 6: Final Integration Verification

**Purpose:** Prove the full deck import hardening works as a cohesive slice.

### Steps

- [ ] Run all focused suites:

```bash
make build-tests
make test-only FILTER=EchoTests/EPUBSourceAnchorResolverTests
make test-only FILTER=EchoTests/DeckImportServiceTests
make test-only FILTER=EchoTests/ApkgImportServiceTests
make test-only FILTER=EchoTests/FlashcardDAOSchedulerTests
make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
```

- [ ] Inspect changed files:

```bash
git diff -- EchoCore/Models/FlashcardDeckImport.swift EchoCore/Services/DeckImportService.swift EchoCore/Services/ApkgImportService.swift EchoCore/Services/DeckImportResult.swift EchoCore/Services/EPUBSourceAnchorResolver.swift EchoCore/Views/SettingsView.swift Shared/Database/DAOs/FlashcardDAO.swift EchoCore/ViewModels/ReaderFeedViewModel.swift EchoTests
git status --short
```

- [ ] Confirm no unrelated dirty files were modified.

- [ ] Commit the implementation:

```bash
git add EchoCore/Models/FlashcardDeckImport.swift \
  EchoCore/Services/DeckImportService.swift \
  EchoCore/Services/ApkgImportService.swift \
  EchoCore/Services/DeckImportResult.swift \
  EchoCore/Services/EPUBSourceAnchorResolver.swift \
  EchoCore/Views/SettingsView.swift \
  Shared/Database/DAOs/FlashcardDAO.swift \
  EchoCore/ViewModels/ReaderFeedViewModel.swift \
  EchoTests/EPUBSourceAnchorResolverTests.swift \
  EchoTests/DeckImportServiceTests.swift \
  EchoTests/ApkgImportServiceTests.swift \
  EchoTests/FlashcardDAOSchedulerTests.swift \
  EchoTests/ReaderFeedViewModelAccordionTests.swift
git commit -m "Add deck import source anchors"
```

- [ ] Open the PR against `nightly` (never `main`):

```bash
git push -u origin HEAD
gh pr create --base nightly --title "Add deck import source anchors" --fill
```

### Final Expected Behavior

- Generated JSON decks can include `sourceAnchor: "s<i>-b<j>"`.
- APKG archives can include root `echo-import.json` sidecars keyed by `cardID` or `noteGUID`.
- Importers resolve portable anchors to local IDs like `epub-<targetMediaID>-s<i>-b<j>`.
- Imported anchored cards persist `flashcard.source_block_id`.
- Unresolved, malformed, wrong-book, no-block, and sidecar problems produce warnings.
- Legacy import methods still return counts and still work for decks without anchors.
- Reader feed placement prefers the anchored block before timestamp fallback.
- Timeline rows for **JSON-imported** flashcards carry `epub_block_id` when the card has `sourceBlockID`. (APKG cards persist `source_block_id` on the flashcard row but are not timeline-synced, matching current behavior.)
