# Deck Import Source Anchors Design

## Goal

Echo should import generated decks in a form that is ready for the reader feed. Imported cards should be able to carry a portable EPUB source anchor, resolve that anchor to the local `epub_block.id`, and store it in `flashcard.source_block_id` so reader placement uses the same precise block-first path as study-plan-generated cards.

The canonical source anchor format for vNext is Echo's portable block suffix: `s<i>-b<j>`.

## Current State

- `flashcard.source_block_id` already exists and maps to `Flashcard.sourceBlockID`, but both current importers set it to `nil`.
- `DeckImportService` imports JSON decks with `targetMediaID`, timestamps, and trigger timing only.
- `ApkgImportService` imports Anki cards under the fixed audiobook ID `apkg-import`, with timestamp `0`, `.manualOnly`, and no source block.
- `ReaderFeedViewModel` already prefers `Flashcard.sourceBlockID` when placing cards, then falls back to timestamp-derived placement.
- EPUB block IDs are device-local full IDs shaped as `epub-<audiobookID>-s<i>-b<j>`. The `s<i>-b<j>` suffix is content-stable for the same EPUB parse and already has precedent in `AlignmentSidecar`.
- XHTML fragment IDs are not persisted after EPUB import, so native `href#fragment` anchors are out of scope for this vNext.

## Design

### Import Contract

JSON deck import gains an optional `sourceAnchor` per card:

```json
{
  "deckName": "Chapter 4 Review",
  "targetMediaID": "file:///.../Book/",
  "cards": [
    {
      "frontText": "What is the core claim?",
      "backText": "That constraints shape behavior.",
      "startTime": 412.5,
      "endTime": 428.0,
      "triggerTiming": "manualOnly",
      "sourceAnchor": "s4-b12"
    }
  ]
}
```

APKG import gains an optional archive-root sidecar named `echo-import.json`:

```json
{
  "formatVersion": 1,
  "targetMediaID": "file:///.../Book/",
  "cards": [
    {
      "cardID": 1712345678901,
      "noteGUID": "anki-note-guid",
      "sourceAnchor": "s4-b12",
      "startTime": 412.5,
      "endTime": 428.0,
      "triggerTiming": "manualOnly"
    }
  ]
}
```

Sidecar entries may identify cards by Anki `cardID`, `noteGUID`, or both. `cardID` is the most precise match. `noteGUID` is the fallback for generated decks that know notes but not Anki card IDs.

### Resolver

Add a shared `EPUBSourceAnchorResolver` with one responsibility: convert an optional imported source anchor into a validated local `epub_block.id`.

Resolution rules:

- Accept canonical suffixes like `s4-b12`.
- Accept legacy/full IDs like `epub-<old-audiobookID>-s4-b12` by stripping to the portable suffix.
- Rebuild the local ID as `epub-\(targetMediaID)-\(suffix)`.
- Validate with both `id` and `audiobook_id`.
- Return a result that can distinguish resolved, missing, malformed, and wrong-book anchors.

The resolver must never let a foreign full block ID leak directly into `flashcard.source_block_id`.

### Import Results

vNext import paths should return a structured result instead of only an `Int`:

```swift
struct ImportDeckResult: Sendable {
    let importedCount: Int
    let anchoredCount: Int
    let warningCount: Int
    let warnings: [ImportDeckWarning]
}
```

Existing `-> Int` import methods can remain as compatibility wrappers that return `importedCount`.

Warnings are non-fatal. If an anchor cannot be resolved, the card still imports with `sourceBlockID: nil` and falls back to timestamp/manual placement.

Warnings:

- `sourceAnchorUnresolved(cardReference, sourceAnchor)`
- `sourceAnchorWrongBook(cardReference, sourceAnchor)`
- `sourceAnchorMalformed(cardReference, sourceAnchor)`
- `targetAudiobookHasNoEPUBBlocks(targetMediaID)`
- `apkgSidecarMissingTargetMediaID`
- `apkgSidecarCardNotFound(cardReference)`
- `apkgSidecarDecodeFailed(reason)`

### JSON Import

`FlashcardDeckImport.ImportedCard` adds optional `sourceAnchor`.

`DeckImportService` resolves each card's `sourceAnchor` against `deck.targetMediaID` before constructing `Flashcard`. Existing JSON without `sourceAnchor` remains valid.

The service should avoid a preflight failure when the target book has no EPUB blocks. Instead, it reports `targetAudiobookHasNoEPUBBlocks` once and imports every card unanchored.

### APKG Import

`ApkgImportService` continues to support normal `.apkg` files without Echo metadata.

For vNext, it looks for `echo-import.json` at the archive root after extraction:

- If present and valid, it supplies target audiobook ID, per-card anchors, and optional timing/trigger overrides.
- If missing, the importer keeps existing APKG behavior.
- If invalid, the importer continues normal APKG import and reports `apkgSidecarDecodeFailed`.
- If the sidecar has no `targetMediaID` and the caller does not provide an import target, the importer keeps `apkg-import`, skips anchor resolution, and reports `apkgSidecarMissingTargetMediaID`.

The vNext API should accept an optional import context for APKG, so UI flows can eventually import an APKG into the current Echo book even when the sidecar omits `targetMediaID`.

### Reader And Timeline Hardening

Reader placement already reads `flashcard.sourceBlockID` directly, so the main behavior appears once imports populate that field.

Hardening:

- Tighten block lookup helpers used for imported source anchors to include `audiobook_id` scope.
- Keep reader fallback behavior unchanged: unknown or missing anchors fall back to timestamp placement, then front-matter tail.
- Update `FlashcardDAO.syncToTimeline` so anchored cards set `TimelineItem.epubBlockID = card.sourceBlockID`.
- Do not add a foreign key to `flashcard.source_block_id` in this vNext. Existing nullable rows and fallback behavior make importer validation the safer boundary.

## Out Of Scope

- Native EPUB `href#fragment` anchors.
- Persisting XHTML element-ID to block-ID maps.
- Reparsing EPUBs during deck import.
- UI redesign for deck import. The service result is designed so UI can later show "Imported N cards, M anchored, W warnings."
- Changing study-plan generation, which already writes `sourceBlockID`.

## Testing

Unit tests should cover:

- JSON vNext resolves `sourceAnchor: "s1-b2"` to the local full `epub_block.id`.
- JSON accepts a full legacy block ID by stripping to its suffix and re-prefixing locally.
- JSON unresolved/malformed/wrong-book anchors import unanchored and report warnings.
- JSON import with no EPUB blocks imports unanchored and reports one book-level warning.
- APKG sidecar maps by `cardID`.
- APKG sidecar maps by `noteGUID` when `cardID` is absent.
- APKG invalid sidecar does not break normal APKG import and returns a warning.
- Anchored imported flashcards appear immediately after their target reader block.
- `FlashcardDAO.syncToTimeline` writes `epub_block_id` for anchored card timeline rows.

## Success Criteria

- Echo-ready generated JSON decks can carry portable block suffixes and import with populated `flashcard.source_block_id`.
- Echo-ready generated APKG decks can carry equivalent source anchors through `echo-import.json`.
- Bad anchors never corrupt persisted source-block IDs.
- Import warnings make degraded placement visible without blocking the user from studying the deck.
- Existing JSON and APKG files keep importing.
