# Anchor-First JSON Deck Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let JSON deck imports accept cards whose timing is supplied by a resolved EPUB `sourceAnchor` instead of a valid `startTime`/`endTime` range.

**Architecture:** Keep the existing schema and persistence path: `flashcard.media_timestamp` remains non-optional, so source-only cards use `0` as a compatibility placeholder and `nil` for `endTimestamp`. Move JSON import validation to an anchor-first flow: validate text/trigger values, resolve anchors, then require either a valid authored time range or a resolved `sourceBlockID`. APKG sidecars already model optional timing and are not changed.

**Tech Stack:** Swift, Swift Testing, GRDB, Xcode project tests through `xcodebuild`.

## Global Constraints

- Base work on the `nightly` branch in an isolated worktree.
- Preserve current deployment targets: iOS 18.0, macOS 15.0, watchOS 11.0.
- Preserve current Swift setting: `SWIFT_VERSION = 5.0` with Main Actor default isolation enabled.
- Do not introduce third-party frameworks.
- Do not run concurrent `xcodebuild`; keep `-parallel-testing-enabled NO` and bounded `-jobs`.
- Follow TDD: write failing regression tests before importer changes.
- Keep JSON fallback behavior conservative: unresolved/malformed/wrong-book anchors still require a valid time range.

---

### Task 1: Regression Tests for Anchor-Only JSON Cards

**Files:**
- Modify: `EchoTests/DeckImportServiceTests.swift`

**Interfaces:**
- Consumes: `DeckImportService.importDeckVNext(from:db:) -> ImportDeckResult`
- Consumes: `Flashcard.sourceBlockID`, `Flashcard.mediaTimestamp`, `Flashcard.endTimestamp`
- Produces: Test coverage for missing timestamps, degenerate `0/0` timestamps, and unresolved-anchor rejection.

- [ ] **Step 1: Add the missing-timestamp regression test**

Insert this test in the `vNext anchor resolution tests` section after `importDeckVNextResolvesSourceAnchor()`:

```swift
@Test
func importDeckVNextAllowsResolvedSourceAnchorWithoutTimestamps() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
    let url = try writeDeckJSON(
        """
        {
          "deckName": "Anchor Only Deck",
          "targetMediaID": "book-a",
          "cards": [
            {
              "frontText": "Question",
              "backText": "Answer",
              "sourceAnchor": "s1-b2",
              "triggerTiming": "manualOnly"
            }
          ]
        }
        """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 1)
    #expect(result.warningCount == 0)

    let card = try writer.read { db in try Flashcard.fetchOne(db) }
    #expect(card?.sourceBlockID == "epub-book-a-s1-b2")
    #expect(card?.mediaTimestamp == 0)
    #expect(card?.endTimestamp == nil)
}
```

- [ ] **Step 2: Add the EchoDeckBuilder `0/0` regression test**

Insert this test after the missing-timestamp test:

```swift
@Test
func importDeckVNextAllowsResolvedSourceAnchorWithDegenerateZeroRange() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
    let url = try writeDeckJSON(
        """
        {
          "deckName": "Builder Deck",
          "targetMediaID": "book-a",
          "cards": [
            {
              "frontText": "Question",
              "backText": "Answer",
              "startTime": 0,
              "endTime": 0,
              "sourceAnchor": "s1-b2",
              "triggerTiming": "manualOnly"
            }
          ]
        }
        """)

    let result = try DeckImportService().importDeckVNext(from: url, db: writer)

    #expect(result.importedCount == 1)
    #expect(result.anchoredCount == 1)
    #expect(result.warningCount == 0)

    let card = try writer.read { db in try Flashcard.fetchOne(db) }
    #expect(card?.sourceBlockID == "epub-book-a-s1-b2")
    #expect(card?.mediaTimestamp == 0)
    #expect(card?.endTimestamp == nil)
}
```

- [ ] **Step 3: Add the unresolved-anchor rejection test**

Insert this test after the degenerate-zero-range test:

```swift
@Test
func importDeckVNextRejectsSourceOnlyCardWhenAnchorDoesNotResolve() throws {
    let writer = try DatabaseService(inMemory: ()).writer
    try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
    let url = try writeDeckJSON(
        """
        {
          "deckName": "Unresolved Anchor Only Deck",
          "targetMediaID": "book-a",
          "cards": [
            {
              "frontText": "Question",
              "backText": "Answer",
              "sourceAnchor": "s9-b9",
              "triggerTiming": "manualOnly"
            }
          ]
        }
        """)

    #expect {
        try DeckImportService().importDeckVNext(from: url, db: writer)
    } throws: { error in
        guard case DeckImportError.invalidTimeRange(cardIndex: 0) = error else {
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Run targeted test and confirm red**

Run:

```bash
xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/DeckImportServiceTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because decoding rejects missing `startTime`/`endTime` or validation rejects `0/0`.

### Task 2: Anchor-First JSON Import Semantics

**Files:**
- Modify: `EchoCore/Models/FlashcardDeckImport.swift`
- Modify: `EchoCore/Services/DeckImportService.swift`

**Interfaces:**
- Produces: `FlashcardDeckImport.ImportedCard.startTime: Double?`
- Produces: `FlashcardDeckImport.ImportedCard.endTime: Double?`
- Produces: `DeckImportService.hasValidTimeRange(_:) -> Bool`
- Produces: `DeckImportService.startTimestamp(for:) -> Double`
- Produces: `DeckImportService.endTimestamp(for:) -> Double?`

- [ ] **Step 1: Make imported JSON timing optional**

Change `ImportedCard` to:

```swift
struct ImportedCard: Codable, Sendable {
    let frontText: String
    let backText: String
    let startTime: Double?
    let endTime: Double?
    let triggerTiming: FlashcardTriggerTiming
    let sourceAnchor: String?
}
```

- [ ] **Step 2: Update the JSON model example and error copy**

Change the card example to include `"sourceAnchor": "s1-b2"` and explain that `startTime`/`endTime` are optional when `sourceAnchor` resolves. Change the invalid-time error to:

```swift
"Card \(index + 1): startTime must be less than endTime and both must be non-negative unless sourceAnchor resolves to an EPUB block."
```

- [ ] **Step 3: Split validation from time placement**

In `DeckImportService.importDeckVNext`, keep the text and trigger checks before anchor resolution, and remove the pre-resolution time-range guard:

```swift
for (index, card) in deck.cards.enumerated() {
    guard !card.frontText.isEmpty, !card.backText.isEmpty else {
        throw DeckImportError.emptyCardText(cardIndex: index)
    }
    guard validTriggerTimings.contains(card.triggerTiming.rawValue) else {
        throw DeckImportError.invalidTriggerTiming(
            card.triggerTiming.rawValue, cardIndex: index)
    }
}
```

- [ ] **Step 4: Require resolved anchor or valid time after resolution**

After the anchor-resolution loop, add:

```swift
for (index, card) in deck.cards.enumerated() {
    guard hasValidTimeRange(card) || resolvedSourceBlockIDs[index] != nil else {
        throw DeckImportError.invalidTimeRange(cardIndex: index)
    }
}
```

- [ ] **Step 5: Persist valid time ranges and source-only placeholders**

Change flashcard construction to:

```swift
mediaTimestamp: startTimestamp(for: card),
endTimestamp: endTimestamp(for: card),
```

Add these helpers inside `DeckImportService`:

```swift
private func hasValidTimeRange(_ card: FlashcardDeckImport.ImportedCard) -> Bool {
    guard let startTime = card.startTime, let endTime = card.endTime else {
        return false
    }
    return startTime >= 0 && endTime > startTime
}

private func startTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double {
    guard hasValidTimeRange(card), let startTime = card.startTime else {
        return 0
    }
    return startTime
}

private func endTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double? {
    guard hasValidTimeRange(card) else {
        return nil
    }
    return card.endTime
}
```

- [ ] **Step 6: Run targeted test and confirm green**

Run:

```bash
xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/DeckImportServiceTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: PASS for `DeckImportServiceTests`.

### Task 3: Documentation Sync

**Files:**
- Modify: `ARCHITECTURE.md`

**Interfaces:**
- Consumes: importer behavior from Task 2.
- Produces: documented contract for EchoDeckBuilder and other JSON producers.

- [ ] **Step 1: Update the deck import architecture section**

In `Deck Import Source Anchors (June 2026)`, add that JSON `startTime`/`endTime` are optional when `sourceAnchor` resolves, and that source-only JSON cards persist with a `0` timestamp placeholder plus `nil` `endTimestamp` for current schema compatibility.

- [ ] **Step 2: Document conservative fallback**

In the same paragraph, add that unresolved anchors fall back to timestamp placement only when the JSON card supplies a valid time range; source-only cards with unresolved anchors fail validation.

- [ ] **Step 3: Run targeted test again**

Run:

```bash
xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/DeckImportServiceTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: PASS for `DeckImportServiceTests`.

### Task 4: Final Review

**Files:**
- Inspect: `EchoTests/DeckImportServiceTests.swift`
- Inspect: `EchoCore/Models/FlashcardDeckImport.swift`
- Inspect: `EchoCore/Services/DeckImportService.swift`
- Inspect: `ARCHITECTURE.md`

**Interfaces:**
- Consumes: all task outputs.
- Produces: verified branch state ready for review.

- [ ] **Step 1: Review diff**

Run:

```bash
git diff -- EchoTests/DeckImportServiceTests.swift EchoCore/Models/FlashcardDeckImport.swift EchoCore/Services/DeckImportService.swift ARCHITECTURE.md
```

Expected: Diff only touches JSON import timing tests, model optionality, importer validation/persistence, and the deck import architecture paragraph.

- [ ] **Step 2: Run final targeted verification**

Run:

```bash
xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/DeckImportServiceTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: PASS for `DeckImportServiceTests`.

- [ ] **Step 3: Commit the completed slice**

Run:

```bash
git add EchoTests/DeckImportServiceTests.swift EchoCore/Models/FlashcardDeckImport.swift EchoCore/Services/DeckImportService.swift ARCHITECTURE.md docs/superpowers/plans/2026-06-26-anchor-first-json-deck-import.md
git commit -m "feat: allow anchor-first JSON deck import"
```

Expected: One conventional commit on `codex/anchor-first-deck-import`.

## Self-Review

- **Spec coverage:** The plan covers the requested source-anchor-first JSON import path and explicitly keeps APKG unchanged because it already supports optional sidecar timing. Playback prompting from active EPUB block ranges is out of scope for this import-contract slice.
- **Placeholder scan:** The plan contains concrete tests, code changes, commands, and expected outcomes.
- **Type consistency:** Optional JSON model fields feed `DeckImportService` helpers that return non-optional database-compatible timestamp values.
