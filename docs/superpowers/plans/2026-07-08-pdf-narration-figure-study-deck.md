# PDF Narration + Figure-Rich Study Deck — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrate `Day 1 v3.pdf` (the Vibe-Coding whitepaper) on the iOS simulator with accurate by-construction read-along, add a durable in-app capability to extract a PDF's figures and attach images (in-book figures or bundled Codex-generated pics) to study cards, then author and deliver a figure-rich deck.

**Architecture:** Figures are extracted during PDF import and stored as first-class `epub_block` image blocks (reusing `image_path`, portable `s<i>-b<j>` anchors, and `EPUBAssetStorage`); a card attaches an image either by `imageAnchor` (an in-book figure) or `imageFile` (a bundled PNG copied into Echo storage), both resolving to `flashcard.media_json`; the general study cards render that image via a shared image view. Narration uses the existing `HeadlessNarrationRunner`/`OnnxKokoroEngine`; alignment is diagnosed and, only if this book needs it, improved with a tractable partial-retiming fix.

**Tech Stack:** Swift 6, SwiftUI, GRDB, CoreGraphics/PDFKit, ONNX Runtime (Kokoro), Swift Testing, `xcodebuild` on the iOS Simulator.

## Global Constraints

- **No schema migration.** Reuse `epub_block.image_path`/`block_kind='image'`, `pdf_block_page`, `flashcard.media_json`. No `Schema_Vxx`, no `registerMigration`, no edits under `Shared/Database/Migrations/`. (`main` is at V35; a new migration is the top collision risk and is out of scope.)
- **Branch base:** `nightly`. Work on `claude/ios-pdf-narration-study-deck-fae1f8` (history includes `origin/nightly`). Never push to `main`/`weekly`/`nightly` directly; PR targets `nightly`.
- **Build/test:** iOS sim only. `SIM_DEST = platform=iOS Simulator,name=iPhone 17`, `CODE_SIGNING_ALLOWED=NO`. Loop: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. Never enable uncapped parallel testing or `-jobs`. Builds gated by `~/.claude/bin/xcode-build-gate.sh` (memory pressure) — prefix with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&` when queuing.
- **SwiftUI/Swift house rules:** `foregroundStyle` not `foregroundColor`; `clipShape(.rect(cornerRadius:))`; new UI strings via views not force-sized fonts; `@Observable`/`@State`/`@Bindable`; async/await only; SPDX header `// SPDX-License-Identifier: GPL-3.0-or-later` as line 1 of every new file. A PostToolUse SwiftFormat hook reflows whole files on edit — re-verify SPDX stays line 1 after edits.
- **DI pattern:** concrete-type + constructor/closure injection, unit-tested with `DatabaseService(inMemory: ())`. No new protocols/mocks.
- **Deliverable package** → `~/Library/Mobile Documents/com~apple~CloudDocs/Books/Books to test echo`. Large audio/scratch under `~/Developer/echo-overnight` (off-git).

## File Structure

**Create:**
- `EchoCore/Views/StudyLocalImageView.swift` — the extracted, internal image view (+ decorated/placeholder helpers) reused by all card views.
- `EchoCore/Services/PDFFigureExtractor.swift` — CoreGraphics figure extraction (`ExtractedFigure`, `extractFigures(from:)`).
- `EchoCore/Services/PDFFigureImporter.swift` — inserts extracted figures as `epub_block` image rows + `pdf_block_page` entries; emits a figure manifest.
- `EchoTests/PDFFigureExtractorTests.swift`, `EchoTests/PDFFigureImporterTests.swift`, `EchoTests/DeckImportImageTests.swift`, `EchoTests/GeneralCardImageRenderTests.swift`, `EchoTests/WordTimingSynthesisRetimeTests.swift`, `EchoTests/PDFNarrationSimIT.swift` (gated).

**Modify:**
- `EchoCore/Views/StudyAssignmentCardView.swift` — drop the private image views (now shared); use `StudyCardMedia.imagePath(fromMediaJSON:)`.
- `EchoCore/Views/FlashcardReviewCard.swift` — add `imagePath` + render it.
- `EchoCore/Views/StudySessionView.swift` — add `imagePath` to `StudyInlineReviewCard`; forward it from `StudySessionCardView`.
- `Shared/Study/StudyPlanTypes.swift` — add `StudyCardMedia.imagePath(fromMediaJSON:)` helper.
- `EchoCore/Models/FlashcardDeckImport.swift` — add `imageAnchor`/`imageFile` to `ImportedCard`.
- `EchoCore/Services/DeckImportService.swift` — resolve card image → `mediaJSON`; new error case.
- `EchoCore/Services/EPUBAssetStorage.swift` — add `writeImageData(_:audiobookID:filename:)`.
- `EchoCore/Services/PDFAutoImportScanner.swift` — call figure extraction/import during PDF import.
- `EchoCore/Services/WordTimingMaterializer.swift` — (conditional) partial synthesis retiming.

---

## Phase 1 — Durable, unit-testable code

### Task 1: Extract the image view into a shared internal file

**Files:**
- Create: `EchoCore/Views/StudyLocalImageView.swift`
- Modify: `EchoCore/Views/StudyAssignmentCardView.swift` (remove the 3 private structs at lines 158–206; keep the call site)

**Interfaces:**
- Produces: `struct StudyLocalImageView: View { init(path: String?, accessibilityLabel: String) }` (internal), plus internal `StudyDecoratedImageView`, `StudyUnavailableImagePlaceholder`.

- [ ] **Step 1: Create the shared file** (verbatim move of the current private structs, made internal)

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Loads a local image file for a study card. Shared by assignment cards and
/// the general review cards. Shows a placeholder when the path is nil/missing.
struct StudyLocalImageView: View {
    let path: String?
    let accessibilityLabel: String

    var body: some View {
        #if canImport(UIKit)
            if let path, let image = UIImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(uiImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #elseif canImport(AppKit)
            if let path, let image = NSImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(nsImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #else
            StudyUnavailableImagePlaceholder()
        #endif
    }
}

struct StudyDecoratedImageView: View {
    let image: Image
    let accessibilityLabel: String

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct StudyUnavailableImagePlaceholder: View {
    var body: some View {
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

- [ ] **Step 2: Delete the now-duplicate private structs** from `StudyAssignmentCardView.swift` (the `private struct StudyLocalImageView`, `private struct StudyDecoratedImageView`, `private struct StudyUnavailableImagePlaceholder` at lines 158–206). Leave the call site (`StudyLocalImageView(path: imagePath, accessibilityLabel:)`) unchanged — it now binds to the shared view.

- [ ] **Step 3: Build**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: BUILD SUCCEEDED (no "invalid redeclaration", no "cannot find StudyLocalImageView").

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/StudyLocalImageView.swift EchoCore/Views/StudyAssignmentCardView.swift
git commit -m "refactor(study): extract StudyLocalImageView into shared internal view"
```

---

### Task 2: Render an image on the general review cards

**Files:**
- Modify: `Shared/Study/StudyPlanTypes.swift` (add decode helper), `EchoCore/Views/FlashcardReviewCard.swift`, `EchoCore/Views/StudySessionView.swift`
- Test: `EchoTests/GeneralCardImageRenderTests.swift`

**Interfaces:**
- Consumes: `StudyLocalImageView(path:accessibilityLabel:)` (Task 1), `StudyCardMedia` (existing).
- Produces: `StudyCardMedia.imagePath(fromMediaJSON: String?) -> String?`; `FlashcardReviewCard(frontText:backText:imagePath:onGrade:)`; `StudyInlineReviewCard(frontText:backText:imagePath:onGrade:)`.

- [ ] **Step 1: Add the shared decode helper** to `StudyCardMedia` in `Shared/Study/StudyPlanTypes.swift` (after the existing `init`, inside the struct):

```swift
    /// Decode a `flashcard.media_json` string into its image path, if any.
    /// Returns nil when the JSON is absent, malformed, or has no image.
    static func imagePath(fromMediaJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
            let media = try? JSONDecoder().decode(StudyCardMedia.self, from: data)
        else { return nil }
        return media.imagePath
    }
```

- [ ] **Step 2: Write the failing test** `EchoTests/GeneralCardImageRenderTests.swift`

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct GeneralCardImageRenderTests {
    @Test func decodesImagePathFromMediaJSON() {
        let json = #"{"imagePath":"/tmp/fig.png"}"#
        #expect(StudyCardMedia.imagePath(fromMediaJSON: json) == "/tmp/fig.png")
    }

    @Test func returnsNilForAbsentOrMalformedMediaJSON() {
        #expect(StudyCardMedia.imagePath(fromMediaJSON: nil) == nil)
        #expect(StudyCardMedia.imagePath(fromMediaJSON: "not json") == nil)
        #expect(StudyCardMedia.imagePath(fromMediaJSON: #"{"retirePromptShownAt":"x"}"#) == nil)
    }
}
```

- [ ] **Step 2b: Run to verify it fails**

Run: `make test-only FILTER=EchoTests/GeneralCardImageRenderTests`
Expected: FAIL — "type 'StudyCardMedia' has no member 'imagePath'" (until Step 1 compiles) or assertion failure.

- [ ] **Step 3: Add `imagePath` to `FlashcardReviewCard`** — modify `EchoCore/Views/FlashcardReviewCard.swift`. Add the stored property and render the image above the card face:

```swift
struct FlashcardReviewCard: View {
    let frontText: String
    let backText: String
    var imagePath: String? = nil          // NEW — default keeps previews/callers valid
    let onGrade: (Int) -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            if let imagePath {            // NEW — figure/mnemonic above the Q&A
                StudyLocalImageView(path: imagePath, accessibilityLabel: frontText)
                    .frame(maxHeight: 220)
                    .padding(.bottom, 8)
            }
            // Card face — Button for proper accessibility, keyboard nav, and hit-testing.
            Button {
```

(Everything from `Button {` downward is unchanged.)

- [ ] **Step 4: Add `imagePath` to `StudyInlineReviewCard`** (macOS) in `EchoCore/Views/StudySessionView.swift`:

```swift
private struct StudyInlineReviewCard: View {
    let frontText: String
    let backText: String
    var imagePath: String? = nil          // NEW
    let onGrade: (ReviewGrade) -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 16) {
            if let imagePath {            // NEW
                StudyLocalImageView(path: imagePath, accessibilityLabel: frontText)
                    .frame(maxHeight: 220)
            }
            Button {
```

(Rest unchanged.)

- [ ] **Step 5: Forward `imagePath` from the router** `StudySessionCardView` in `StudySessionView.swift`. In both the `#if os(macOS)` and `#else` branches add the argument:

```swift
            #if os(macOS)
                StudyInlineReviewCard(
                    frontText: entry.flashcard.frontText,
                    backText: entry.flashcard.backText,
                    imagePath: StudyCardMedia.imagePath(fromMediaJSON: entry.flashcard.mediaJSON),
                    onGrade: { viewModel.gradeCurrent($0) }
                )
            #else
                FlashcardReviewCard(
                    frontText: entry.flashcard.frontText,
                    backText: entry.flashcard.backText,
                    imagePath: StudyCardMedia.imagePath(fromMediaJSON: entry.flashcard.mediaJSON),
                    onGrade: { grade in
                        if let reviewGrade = ReviewGrade(rawValue: grade) {
                            viewModel.gradeCurrent(reviewGrade)
                        }
                    }
                )
            #endif
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/GeneralCardImageRenderTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add Shared/Study/StudyPlanTypes.swift EchoCore/Views/FlashcardReviewCard.swift EchoCore/Views/StudySessionView.swift EchoTests/GeneralCardImageRenderTests.swift
git commit -m "feat(study): render card image on general review cards"
```

---

### Task 3: Add `imageAnchor`/`imageFile` to the deck import model

**Files:**
- Modify: `EchoCore/Models/FlashcardDeckImport.swift`
- Test: covered by Task 5's decode tests (fold in here — no separate test file)

**Interfaces:**
- Produces: `ImportedCard` gains `let imageAnchor: String?` and `let imageFile: String?`.

- [ ] **Step 1: Add the two optional fields** to `ImportedCard` (synthesized Codable makes them optional keys automatically):

```swift
    nonisolated struct ImportedCard: Codable, Sendable {
        let frontText: String
        let backText: String
        let startTime: Double?
        let endTime: Double?
        let triggerTiming: String
        let sourceAnchor: String?
        /// Portable `s<i>-b<j>` anchor of an in-book figure block (an extracted
        /// PDF figure). Mutually exclusive with `imageFile`.
        let imageAnchor: String?
        /// Path (relative to the deck bundle's folder) of a bundled image file,
        /// e.g. a Codex-generated mnemonic. Mutually exclusive with `imageAnchor`.
        let imageFile: String?
    }
```

- [ ] **Step 2: Build**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: BUILD SUCCEEDED (existing decode call sites still compile — new keys are optional).

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Models/FlashcardDeckImport.swift
git commit -m "feat(deck): add optional imageAnchor/imageFile to ImportedCard"
```

---

### Task 4: `EPUBAssetStorage.writeImageData` (figure byte storage)

**Files:**
- Modify: `EchoCore/Services/EPUBAssetStorage.swift`
- Test: `EchoTests/PDFFigureImporterTests.swift` (created in Task 7; add a focused test here)

**Interfaces:**
- Consumes: existing `directory(for:)`, `prepare(for:)`.
- Produces: `func writeImageData(_ data: Data, audiobookID: String, filename: String) -> String?` returning the absolute local path (usable by `UIImage(contentsOfFile:)`), nil on failure.

- [ ] **Step 1: Write the failing test** `EchoTests/EPUBAssetStorageWriteTests.swift`

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBAssetStorageWriteTests {
    @Test func writesImageDataAndReturnsLoadablePath() throws {
        let db = try DatabaseService(inMemory: ())
        let storage = EPUBAssetStorage(databaseService: db)
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])  // "\x89PNG" — enough for a file write
        let path = try #require(
            storage.writeImageData(pngBytes, audiobookID: "book-A", filename: "fig-0.png"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == pngBytes)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test-only FILTER=EchoTests/EPUBAssetStorageWriteTests`
Expected: FAIL — "value of type 'EPUBAssetStorage' has no member 'writeImageData'".

- [ ] **Step 3: Implement** `writeImageData` in `EPUBAssetStorage.swift` (mirrors `copyImage` but takes bytes, not a source file):

```swift
    /// Writes raw image bytes into per-book asset storage and returns the
    /// absolute local path (usable by `UIImage(contentsOfFile:)`). Used for PDF
    /// figures, which have no source file on disk. Nil on failure.
    func writeImageData(_ data: Data, audiobookID: String, filename: String) -> String? {
        do {
            try prepare(for: audiobookID)
        } catch {
            logger.error("Cannot write image data: \(error.localizedDescription)")
            return nil
        }
        guard let dir = directory(for: audiobookID) else { return nil }
        let safeFilename = filename.replacingOccurrences(of: "/", with: "_")
        let destinationURL = dir.appendingPathComponent(safeFilename)
        do {
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL.path
        } catch {
            logger.error("Failed to write image \(safeFilename): \(error.localizedDescription)")
            return nil
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/EPUBAssetStorageWriteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/EPUBAssetStorage.swift EchoTests/EPUBAssetStorageWriteTests.swift
git commit -m "feat(assets): add EPUBAssetStorage.writeImageData for byte-sourced images"
```

---

### Task 5: Resolve a card's image → `mediaJSON` in DeckImportService

**Files:**
- Modify: `EchoCore/Services/DeckImportService.swift` (and its `DeckImportError` enum)
- Test: `EchoTests/DeckImportImageTests.swift`

**Interfaces:**
- Consumes: `EPUBSourceAnchorResolver.resolve(...)`, `EPubBlockRecord`, `StudyCardMedia`, `ImportedCard.imageAnchor/imageFile`.
- Produces: private `resolveCardImageJSON(card:targetMediaID:bundleDir:deckID:writer:) throws -> String?`; new error `DeckImportError.conflictingImageFields(cardIndex: Int)`.

- [ ] **Step 1: Write the failing tests** `EchoTests/DeckImportImageTests.swift`

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct DeckImportImageTests {
    /// Insert one figure image block so an imageAnchor can resolve to it.
    private func seedFigureBlock(_ db: DatabaseService, audiobookID: String, imagePath: String) throws {
        try db.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                       block_kind, text, image_path, is_hidden, is_front_matter)
                    VALUES (?, ?, 'pdf', 9, 0, 0, 'image', NULL, ?, 0, 0)
                    """,
                arguments: ["epub-\(audiobookID)-s9-b0", audiobookID, imagePath])
        }
    }

    private func writeDeckBundle(_ dir: URL, json: String, images: [String: Data]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("deck.echo-deck.json"))
        let imagesDir = dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        for (name, bytes) in images { try bytes.write(to: imagesDir.appendingPathComponent(name)) }
    }

    @Test func imageAnchorResolvesToFigureBlockImagePath() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-1"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/tmp/EPUBAssets/book-1/fig-0.png")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageAnchor":"s9-b0"}]}
            """
        try writeDeckBundle(dir, json: json, images: [:])
        let service = DeckImportService()
        _ = try service.importDeckVNext(
            from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        let media = try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT media_json FROM flashcard LIMIT 1")
        }
        #expect(media?.contains("/tmp/EPUBAssets/book-1/fig-0.png") == true)
    }

    @Test func imageFileCopiesIntoStorageAndSetsMediaJSON() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-2"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/unused")  // gives target blocks
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageFile":"images/card-0.png"}]}
            """
        try writeDeckBundle(dir, json: json, images: ["card-0.png": Data([0x89, 0x50, 0x4E, 0x47])])
        let service = DeckImportService()
        _ = try service.importDeckVNext(
            from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        let media = try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT media_json FROM flashcard LIMIT 1")
        }
        let path = try #require(StudyCardMedia.imagePath(fromMediaJSON: media))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func bothImageFieldsSetThrows() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-3"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/x")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageAnchor":"s9-b0","imageFile":"images/x.png"}]}
            """
        try writeDeckBundle(dir, json: json, images: [:])
        let service = DeckImportService()
        #expect(throws: DeckImportError.self) {
            _ = try service.importDeckVNext(
                from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test-only FILTER=EchoTests/DeckImportImageTests`
Expected: FAIL — cards import with `media_json` NULL (anchor/file ignored); both-set does not throw.

- [ ] **Step 3: Add the error case** to `DeckImportError` (find its declaration in `DeckImportService.swift`; add):

```swift
    case conflictingImageFields(cardIndex: Int)
```

- [ ] **Step 4: Add the resolver helper** in `DeckImportService` (private), which produces the `mediaJSON` string for a card:

```swift
    /// Produces the `media_json` value for a card's image, or nil if it has none.
    /// `imageAnchor` -> the in-book figure block's `image_path`; `imageFile` ->
    /// a bundled PNG copied into per-deck storage. Both set is a conflict.
    private func resolveCardImageJSON(
        card: FlashcardDeckImport.ImportedCard,
        cardIndex: Int,
        targetMediaID: String,
        bundleDir: URL,
        deckID: String,
        writer: DatabaseWriter
    ) throws -> String? {
        let hasAnchor = !(card.imageAnchor?.isEmpty ?? true)
        let hasFile = !(card.imageFile?.isEmpty ?? true)
        if hasAnchor && hasFile { throw DeckImportError.conflictingImageFields(cardIndex: cardIndex) }

        let imagePath: String?
        if hasAnchor, let anchor = card.imageAnchor {
            imagePath = try figureImagePath(anchor: anchor, targetMediaID: targetMediaID, writer: writer)
        } else if hasFile, let rel = card.imageFile {
            imagePath = try copyBundledImage(relativePath: rel, bundleDir: bundleDir, deckID: deckID)
        } else {
            imagePath = nil
        }
        guard let imagePath else { return nil }  // missing/unresolved -> card imports text-only
        let data = try JSONEncoder().encode(StudyCardMedia(imagePath: imagePath))
        return String(decoding: data, as: UTF8.self)
    }

    private func figureImagePath(
        anchor: String, targetMediaID: String, writer: DatabaseWriter
    ) throws -> String? {
        switch try EPUBSourceAnchorResolver(dbReader: writer).resolve(
            sourceAnchor: anchor, targetMediaID: targetMediaID, cardReference: "image-anchor")
        {
        case .resolved(let blockID):
            return try writer.read { db in
                try EPubBlockRecord.filter(Column("id") == blockID).fetchOne(db)?.imagePath
            }
        case .none, .unresolved:
            return nil
        }
    }

    private func copyBundledImage(
        relativePath: String, bundleDir: URL, deckID: String
    ) throws -> String? {
        let source = bundleDir.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destRoot = URL.applicationSupportDirectory
            .appending(path: "DeckMedia", directoryHint: .isDirectory)
            .appending(path: deckID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let dest = destRoot.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest.path
    }
```

- [ ] **Step 5: Wire the helper into `importDeckVNext`.** Two edits: (a) validate both-set up-front in the existing per-card validation loop; (b) pass the computed `mediaJSON` into the `Flashcard(...)` construction (replace `mediaJSON: nil` at line 141).

(a) In the first `for (index, card) in deck.cards.enumerated()` validation loop, add after the trigger-timing check:

```swift
            if !(card.imageAnchor?.isEmpty ?? true) && !(card.imageFile?.isEmpty ?? true) {
                throw DeckImportError.conflictingImageFields(cardIndex: index)
            }
```

(b) Compute the bundle dir once before the insert loop:

```swift
        let bundleDir = url.deletingLastPathComponent()
```

and in the final insert loop, replace `mediaJSON: nil,` with:

```swift
                mediaJSON: try resolveCardImageJSON(
                    card: card, cardIndex: index, targetMediaID: deck.targetMediaID,
                    bundleDir: bundleDir, deckID: deckID, writer: writer),
```

- [ ] **Step 6: Run to verify passing**

Run: `make build-tests && make test-only FILTER=EchoTests/DeckImportImageTests`
Expected: PASS (3 tests). Also run `make test-only FILTER=EchoTests/DeckImportServiceTests` (existing) — Expected: still PASS (back-compat).

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/DeckImportService.swift EchoTests/DeckImportImageTests.swift
git commit -m "feat(deck): attach card images via imageAnchor (figure) or imageFile (bundled)"
```

---

### Task 6: `PDFFigureExtractor` — extract embedded figures

**Files:**
- Create: `EchoCore/Services/PDFFigureExtractor.swift`
- Test: `EchoTests/PDFFigureExtractorTests.swift`

**Interfaces:**
- Produces:
  - `struct ExtractedFigure: Sendable { let pageIndex: Int; let order: Int; let pngData: Data }`
  - `enum PDFFigureExtractor { static func extractFigures(from pdfURL: URL, minPointSize: CGFloat = 72, renderScale: CGFloat = 2.0) -> [ExtractedFigure] }`

**Approach (rect-rasterization, codec-proof):** For each page, use a `CGPDFScanner` with a `CGPDFOperatorTable` handling `cm` (concat CTM) / `q`/`Q` (save/restore) / `Do` (XObject draw) to compute each drawn image XObject's on-page rect (unit square transformed by the current CTM). Filter tiny placements (< `minPointSize` on a side). Render the whole page to a bitmap at `renderScale`, then crop each figure rect (converted to bitmap coordinates) and PNG-encode it. This rasterizes the composited result, so JPEG-2000 + soft-mask figures "just work."

- [ ] **Step 1: Write the failing test** `EchoTests/PDFFigureExtractorTests.swift` (build a 1-page PDF with one embedded image via CoreGraphics, then extract):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

struct PDFFigureExtractorTests {
    /// Writes a 1-page PDF (612x792) with a 200x200 solid-color image drawn at (100,100).
    private func makeFixturePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        // Build a 200x200 red CGImage.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bmp.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try #require(bmp.makeImage())
        ctx.draw(image, in: CGRect(x: 100, y: 100, width: 200, height: 200))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test func extractsOneFigureFromSinglePagePDF() throws {
        let pdf = try makeFixturePDF()
        let figures = PDFFigureExtractor.extractFigures(from: pdf)
        #expect(figures.count == 1)
        let fig = try #require(figures.first)
        #expect(fig.pageIndex == 0)
        #expect(fig.pngData.count > 0)
        // Confirm the PNG decodes.
        let src = try #require(CGImageSourceCreateWithData(fig.pngData as CFData, nil))
        #expect(CGImageSourceGetCount(src) == 1)
    }

    @Test func returnsEmptyForTextOnlyPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        #expect(PDFFigureExtractor.extractFigures(from: url).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test-only FILTER=EchoTests/PDFFigureExtractorTests`
Expected: FAIL — "cannot find 'PDFFigureExtractor'".

- [ ] **Step 3: Implement** `EchoCore/Services/PDFFigureExtractor.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// One figure rasterized from a PDF page. `pngData` is the cropped, composited
/// figure (codec-proof: rendered from the page, so JPEG-2000 + soft masks work).
struct ExtractedFigure: Sendable {
    let pageIndex: Int  // 0-based
    let order: Int      // order on the page, top-to-bottom
    let pngData: Data
}

/// Finds embedded image placements per page (content-stream scan for `Do` +
/// CTM tracking), filters tiny/decorative ones, and rasterizes each rect from
/// the rendered page. Pure/synchronous CoreGraphics — run inside a detached task.
enum PDFFigureExtractor {
    private static let logger = Logger(subsystem: "Echo", category: "PDFFigureExtractor")

    static func extractFigures(
        from pdfURL: URL, minPointSize: CGFloat = 72, renderScale: CGFloat = 2.0
    ) -> [ExtractedFigure] {
        guard let doc = CGPDFDocument(pdfURL as CFURL) else { return [] }
        var out: [ExtractedFigure] = []
        for pageNumber in 1...max(1, doc.numberOfPages) {
            guard doc.numberOfPages >= pageNumber, let page = doc.page(at: pageNumber) else { continue }
            let rects = imageRects(on: page, minPointSize: minPointSize)
            guard !rects.isEmpty else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            for (order, rect) in rects.enumerated() {
                if let png = rasterize(page: page, rect: rect, mediaBox: mediaBox, scale: renderScale) {
                    out.append(ExtractedFigure(pageIndex: pageNumber - 1, order: order, pngData: png))
                }
            }
        }
        return out
    }

    // MARK: content-stream scan for image XObject placements

    private final class ScanState {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
    }

    private static func imageRects(on page: CGPDFPage, minPointSize: CGFloat) -> [CGRect] {
        let state = ScanState()
        let table = CGPDFOperatorTableCreate()

        // `cm`: concatenate matrix.
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            var f = [CGFloat](repeating: 0, count: 6)
            for i in (0..<6).reversed() {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { return }
                f[i] = CGFloat(v)
            }
            let m = CGAffineTransform(a: f[0], b: f[1], c: f[2], d: f[3], tx: f[4], ty: f[5])
            s.ctm = m.concatenating(s.ctm)
        }
        // `q` / `Q`: save/restore graphics state (CTM).
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            if let top = s.stack.popLast() { s.ctm = top }
        }
        // `Do`: draw XObject. In PDF, an image XObject is the unit square under the CTM.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name) else { return }
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm)
            s.rects.append(unit)
        }

        let info = Unmanaged.passUnretained(state).toOpaque()
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)

        // Keep only sizable placements (drop icons/rules). Note: `Do` also covers
        // form XObjects; the size filter removes most non-figure noise, and the
        // rasterizer simply renders whatever is under the rect.
        return state.rects.filter { $0.width >= minPointSize && $0.height >= minPointSize }
    }

    // MARK: rasterize a page rect to PNG

    private static func rasterize(
        page: CGPDFPage, rect: CGRect, mediaBox: CGRect, scale: CGFloat
    ) -> Data? {
        let clamped = rect.intersection(mediaBox)
        guard !clamped.isNull, clamped.width > 1, clamped.height > 1 else { return nil }
        let pxW = Int((clamped.width * scale).rounded())
        let pxH = Int((clamped.height * scale).rounded())
        guard pxW > 0, pxH > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        // Map the figure rect to the bitmap origin at `scale`.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -clamped.origin.x, y: -clamped.origin.y)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/PDFFigureExtractorTests`
Expected: PASS (2 tests). If `extractsOneFigureFromSinglePagePDF` finds >1 rect (form XObjects), tighten `minPointSize` or assert `>= 1` and that a red-dominant figure exists — adjust the test to the real behavior, keeping the text-only-returns-empty invariant.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/PDFFigureExtractor.swift EchoTests/PDFFigureExtractorTests.swift
git commit -m "feat(pdf): add PDFFigureExtractor (content-stream rect rasterization)"
```

---

### Task 7: Import figures as `epub_block` image rows during PDF import

**Files:**
- Create: `EchoCore/Services/PDFFigureImporter.swift`
- Modify: `EchoCore/Services/PDFAutoImportScanner.swift`
- Test: `EchoTests/PDFFigureImporterTests.swift`

**Interfaces:**
- Consumes: `ExtractedFigure` (Task 6), `EPUBAssetStorage.writeImageData` (Task 4), `EPubBlockRecord`, `PDFBlockPageRecord`/`PDFBlockPageDAO`, `PDFBlockPageMapper`.
- Produces:
  - `struct FigureManifestEntry: Codable, Sendable { let pageIndex: Int; let portableAnchor: String; let imagePath: String }`
  - `enum PDFFigureImporter { static func importFigures(_ figures: [ExtractedFigure], audiobookID: String, textBlocks: [EPubBlockRecord], pageMapping: [(blockID: String, pageIndex: Int)], databaseService: DatabaseService) -> [FigureManifestEntry] }`

**Design:** All figures go into a synthetic spine `s<maxSpine+1>` with `blockIndex = globalFigureOrdinal` → IDs `epub-<id>-s<S>-b<k>` (unique, contiguous, never colliding with text blocks). Each figure's `chapterIndex` is inherited from a text block on the same page (via `pageMapping`); `sequenceIndex` large so it sorts after that page's text. Bytes written via `EPUBAssetStorage.writeImageData`; `text = nil` (guarantees narration skips it). A `pdf_block_page` row is added with the figure's real page. Returns manifest entries (portable `s<S>-b<k>` anchors) for deck authoring.

- [ ] **Step 1: Write the failing test** `EchoTests/PDFFigureImporterTests.swift`

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct PDFFigureImporterTests {
    private func seedTextBlock(
        _ db: DatabaseService, audiobookID: String, id: String, spine: Int, block: Int,
        chapter: Int
    ) throws {
        try db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                       block_kind, text, chapter_index, is_hidden, is_front_matter)
                    VALUES (?, ?, 'pdf', ?, ?, ?, 'paragraph', 'hello', ?, 0, 0)
                    """,
                arguments: [id, audiobookID, spine, block, block, chapter])
        }
    }

    @Test func insertsFigureBlockWithImagePathAndReturnsAnchor() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-F"
        try seedTextBlock(db, audiobookID: book, id: "epub-\(book)-s0-b0", spine: 0, block: 0, chapter: 3)
        let figures = [ExtractedFigure(pageIndex: 0, order: 0, pngData: Data([0x89, 0x50, 0x4E, 0x47]))]
        let manifest = PDFFigureImporter.importFigures(
            figures, audiobookID: book,
            textBlocks: try db.writer.read { try EPubBlockRecord.fetchAll($0) },
            pageMapping: [(blockID: "epub-\(book)-s0-b0", pageIndex: 0)],
            databaseService: db)

        #expect(manifest.count == 1)
        let entry = try #require(manifest.first)
        #expect(entry.portableAnchor.range(of: #"^s[0-9]+-b[0-9]+$"#, options: .regularExpression) != nil)
        #expect(FileManager.default.fileExists(atPath: entry.imagePath))

        let row = try db.writer.read { d in
            try EPubBlockRecord.filter(Column("block_kind") == "image").fetchOne(d)
        }
        let fig = try #require(row)
        #expect(fig.text == nil)
        #expect(fig.imagePath == entry.imagePath)
        #expect(fig.chapterIndex == 3)  // inherited from the page's text block
    }

    @Test func figureBlockIsExcludedFromNarrationCandidates() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-G"
        try seedTextBlock(db, audiobookID: book, id: "epub-\(book)-s0-b0", spine: 0, block: 0, chapter: 0)
        _ = PDFFigureImporter.importFigures(
            [ExtractedFigure(pageIndex: 0, order: 0, pngData: Data([0x1]))],
            audiobookID: book,
            textBlocks: try db.writer.read { try EPubBlockRecord.fetchAll($0) },
            pageMapping: [(blockID: "epub-\(book)-s0-b0", pageIndex: 0)],
            databaseService: db)
        let all = try db.writer.read { try EPubBlockRecord.fetchAll($0) }
        // The render planner keeps only text?.isEmpty == false && !isHidden.
        let candidates = all.filter { ($0.text?.isEmpty == false) && !$0.isHidden }
        #expect(candidates.allSatisfy { $0.blockKind != "image" })
        #expect(candidates.count == 1)  // just the text block
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test-only FILTER=EchoTests/PDFFigureImporterTests`
Expected: FAIL — "cannot find 'PDFFigureImporter'".

- [ ] **Step 3: Implement** `EchoCore/Services/PDFFigureImporter.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os

/// A figure's stable, portable anchor + its stored image path, for deck authoring.
struct FigureManifestEntry: Codable, Sendable {
    let pageIndex: Int
    let portableAnchor: String  // s<i>-b<j>
    let imagePath: String
}

/// Persists extracted PDF figures as first-class `epub_block` image blocks
/// (text == nil → silent to narration; image_path set → renderable) and a
/// `pdf_block_page` row each. Returns a manifest for deck authoring.
enum PDFFigureImporter {
    private static let logger = Logger(subsystem: "Echo", category: "PDFFigureImporter")

    static func importFigures(
        _ figures: [ExtractedFigure],
        audiobookID: String,
        textBlocks: [EPubBlockRecord],
        pageMapping: [(blockID: String, pageIndex: Int)],
        databaseService: DatabaseService
    ) -> [FigureManifestEntry] {
        guard !figures.isEmpty else { return [] }
        let storage = EPUBAssetStorage(databaseService: databaseService)
        let figureSpine = (textBlocks.map(\.spineIndex).max() ?? 0) + 1

        // page -> chapterIndex, from the text blocks on that page.
        var chapterByPage: [Int: Int] = [:]
        let chapterByBlockID = Dictionary(uniqueKeysWithValues: textBlocks.map { ($0.id, $0.chapterIndex) })
        for m in pageMapping where chapterByPage[m.pageIndex] == nil {
            if let ch = chapterByBlockID[m.blockID] ?? nil { chapterByPage[m.pageIndex] = ch }
        }

        var manifest: [FigureManifestEntry] = []
        var rows: [EPubBlockRecord] = []
        var pageRows: [PDFBlockPageRecord] = []
        for (ordinal, fig) in figures.enumerated() {
            let filename = "figure-p\(fig.pageIndex)-o\(fig.order).png"
            guard let path = storage.writeImageData(fig.pngData, audiobookID: audiobookID, filename: filename)
            else { continue }
            let blockID = "epub-\(audiobookID)-s\(figureSpine)-b\(ordinal)"
            rows.append(EPubBlockRecord(
                id: blockID, audiobookID: audiobookID, spineHref: "pdf-figures",
                spineIndex: figureSpine, blockIndex: ordinal,
                sequenceIndex: 1_000_000 + ordinal,
                blockKind: EPubBlockRecord.Kind.image.rawValue, text: nil, htmlContent: nil,
                cardColor: nil, chapterThemeColor: nil, imagePath: path,
                chapterIndex: chapterByPage[fig.pageIndex], isHidden: false, hiddenReason: nil,
                isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
                narrationText: nil, createdAt: nil, modifiedAt: nil))
            pageRows.append(PDFBlockPageRecord(
                id: nil, audiobookID: audiobookID, epubBlockID: blockID, pageIndex: fig.pageIndex))
            manifest.append(FigureManifestEntry(
                pageIndex: fig.pageIndex, portableAnchor: "s\(figureSpine)-b\(ordinal)", imagePath: path))
        }

        do {
            try databaseService.writer.write { db in
                for var r in rows { try r.insert(db) }
                for var p in pageRows { try p.insert(db) }
            }
        } catch {
            logger.error("Failed to persist figure blocks: \(error.localizedDescription)")
            return []
        }
        return manifest
    }
}
```

Note: match the exact `EPubBlockRecord(...)` memberwise argument list to the current struct (Task-3 explorer confirmed the fields). If the parser call sites omit `chapterThemeColor`/`narrationText`, still pass them explicitly here (all values above are provided) — the memberwise init accepts the full list.

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/PDFFigureImporterTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire into `PDFAutoImportScanner.importPDFFileOutcome`.** After the `PDFBlockPageMapper.map` block persists page rows (line ~191–201), add figure extraction (detached) + import. Extract on a detached task (CoreGraphics), then import on the MainActor path:

```swift
            // Figures: extract (detached, CoreGraphics) then persist as image blocks.
            let figures = await Task.detached(priority: .userInitiated) {
                PDFFigureExtractor.extractFigures(from: pdfURL)
            }.value
            if !figures.isEmpty {
                let manifest = PDFFigureImporter.importFigures(
                    figures, audiobookID: audiobookID, textBlocks: blocks,
                    pageMapping: mapping.map { (blockID: $0.blockID, pageIndex: $0.pageIndex) },
                    databaseService: databaseService)
                logger.info("Imported \(manifest.count) PDF figures for \(sanitizedPath(audiobookID))")
                Self.writeFigureManifest(manifest, audiobookID: audiobookID, pdfURL: pdfURL)
            }
```

Add a best-effort manifest writer (private static) next to the import — writes `figures.json` beside the PDF's work dir for deck authoring:

```swift
    private static func writeFigureManifest(
        _ manifest: [FigureManifestEntry], audiobookID: String, pdfURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        let url = pdfURL.deletingLastPathComponent().appendingPathComponent("figures.json")
        try? data.write(to: url)
    }
```

- [ ] **Step 6: Build + run the PDF import regression test** (find the existing `PDFAutoImportScanner` test suite name via `grep -rl "PDFAutoImportScanner" EchoTests` and run it):

Run: `make build-tests && make test-only FILTER=EchoTests/PDFAutoImportScannerTests`
Expected: PASS — a figure-less fixture PDF imports exactly as before (extractor returns empty → no behavior change).

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/PDFFigureImporter.swift EchoCore/Services/PDFAutoImportScanner.swift EchoTests/PDFFigureImporterTests.swift
git commit -m "feat(pdf): import extracted figures as epub_block image blocks + manifest"
```

---

## Phase 2 — Alignment: diagnose, then improve only if needed

### Task 8: Add the gated real-engine narration test (committed, off by default)

**Files:**
- Create: `EchoTests/PDFNarrationSimIT.swift`

**Interfaces:**
- Consumes: `HeadlessNarrationRunner`, `NarrationRunConfig`, `OnnxKokoroEngine` (real engine when `tts` omitted).

- [ ] **Step 1: Create the gated test** (mirrors `OnnxKokoroEngineWordTimingTests`'s gating; reads input path + work dir + DB path from env so it is scriptable and commits no absolute paths):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Narrates a real PDF with the REAL on-device ONNX engine on the simulator.
    /// Heavy (downloads the 163 MB model, renders audio). Gated + fully env-driven
    /// so CI stays green and no absolute paths are committed. Drive it with:
    ///   ECHO_NARRATE_PDF=/path/book.pdf ECHO_NARRATE_WORKDIR=/path/work \
    ///   ECHO_NARRATE_DB=/path/book.sqlite ECHO_NARRATE_OUT=/path/book.m4b \
    ///   ECHO_NARRATE_SIDECAR=/path/book.alignment.json ECHO_NARRATE_MAXCH=5
    /// and re-run until it prints DONE (it renders <=MAXCH chapters per run).
    @MainActor struct PDFNarrationSimIT {
        private static var env: [String: String] { ProcessInfo.processInfo.environment }

        @Test(.enabled(if: PDFNarrationSimIT.env["ECHO_NARRATE_PDF"] != nil,
            "set ECHO_NARRATE_PDF to narrate a PDF on the sim"))
        func narratePDFBatch() async throws {
            let e = Self.env
            let pdf = URL(fileURLWithPath: try #require(e["ECHO_NARRATE_PDF"]))
            let work = URL(fileURLWithPath: e["ECHO_NARRATE_WORKDIR"] ?? NSTemporaryDirectory())
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let config = NarrationRunConfig(
                epubURL: pdf,
                outM4BURL: URL(fileURLWithPath: e["ECHO_NARRATE_OUT"] ?? work.appendingPathComponent("book.m4b").path),
                sidecarURL: e["ECHO_NARRATE_SIDECAR"].map { URL(fileURLWithPath: $0) },
                workDir: work,
                voice: VoiceID(e["ECHO_NARRATE_VOICE"] ?? "af_heart"),
                title: e["ECHO_NARRATE_TITLE"] ?? "Narrated PDF",
                author: e["ECHO_NARRATE_AUTHOR"] ?? "Echo",
                maxNewChaptersPerRun: e["ECHO_NARRATE_MAXCH"].flatMap { Int($0) } ?? 5,
                databaseURL: e["ECHO_NARRATE_DB"].map { URL(fileURLWithPath: $0) })

            let result = try await HeadlessNarrationRunner().run(config) { p in
                FileHandle.standardError.write(Data("\(p)\n".utf8))
            }
            FileHandle.standardError.write(Data("RESULT complete=\(result.complete)\n".utf8))
            // Not an assertion on completeness — partial is expected mid-batch.
            #expect(result.capturedThisRun >= 0)
        }
    }
#endif
```

Note: confirm `NarrationRunResult` exposes `complete` and `capturedThisRun` (explorer confirmed these fields on the runner's return path). If a field name differs, adjust to the actual `NarrationRunResult` definition.

- [ ] **Step 2: Build (do not run the gated test in CI)**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: BUILD SUCCEEDED. The test is inert unless `ECHO_NARRATE_PDF` is set.

- [ ] **Step 3: Commit**

```bash
git add EchoTests/PDFNarrationSimIT.swift
git commit -m "test(narration): gated real-engine PDF narration IT for the simulator"
```

---

### Task 9: (CONDITIONAL) Improve synthesis-timing coverage

> **Gate:** Only implement this task if Task 12's narration run reports `overridden/total < 0.80` in the `"Synthesis word timing: X/Y blocks overrode interpolation"` log for the real book. If coverage is ≥ 0.80, SKIP this task and record the measured ratio in the PR description. This keeps the fix evidence-driven per the spec.

**Files:**
- Modify: `EchoCore/Services/WordTimingMaterializer.swift`
- Test: `EchoTests/WordTimingSynthesisRetimeTests.swift`

**Interfaces:**
- Modifies: `refineWithSynthesis` to retime the *matched subset* of words when counts differ (instead of skipping the whole block), leaving unmatched words at their interpolated time.

**Design (tractable, additive):** Guard #2 currently `continue`s a block whenever `rows.count != timings.count`. Replace the all-or-nothing gate with a longest-common-subsequence match on normalized word text between the interpolated `rows` (source words) and the synthesis `timings`' word tokens. Retime only matched pairs at `synthesis` confidence; leave unmatched rows untouched. This raises coverage on abbreviation/number blocks without needing upstream phoneme→source-word plumbing (guard #1 in `KokoroWordTimer` stays as-is; it only affects whether a block *offers* synthesis timings at all).

Precondition: `ChunkWordTiming` must carry the spoken word text for matching. If it does not today, this task is **not tractable without a broader change** — in that case, record that finding in the PR and leave guard #2 as-is (interpolation fallback is acceptable; the spec permits shipping without this fix). Verify first:

- [ ] **Step 1: Verify `ChunkWordTiming` fields** — `grep -n "struct ChunkWordTiming" -A6 EchoCore/Services/Narration/TTSEngine.swift`. If it has no `word`/text field, STOP: mark Task 9 "not tractable this pass," note it in the PR, and rely on interpolation. If it has word text, proceed.

- [ ] **Step 2: Write the failing test** `EchoTests/WordTimingSynthesisRetimeTests.swift` — seed a block with 5 interpolated rows and provide 6 synthesis timings (a number expanded into two spoken words), assert that ≥4 rows are retimed to `source == "synthesis"` (partial match) rather than 0.

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct WordTimingSynthesisRetimeTests {
    @Test func retimesMatchedSubsetWhenCountsDiffer() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-T"
        let block = "epub-\(book)-s0-b0"
        let dao = WordTimingDAO(db: db.writer)
        // 5 interpolated source words: "we saw 80 percent gains"
        let words = ["we", "saw", "80", "percent", "gains"]
        try dao.insert(words.enumerated().map { i, w in
            WordTimingRecord(audiobookID: book, epubBlockID: block, wordIndex: i, word: w,
                audioStartTime: Double(i), audioEndTime: Double(i) + 1, confidence: 0.5,
                source: "interpolated")
        })
        // 6 synthesis timings: "80" spoken as "eighty" + "percent" already there → mismatch.
        let spoken = ["we", "saw", "eighty", "percent", "percent", "gains"]  // example expansion
        let timings = spoken.enumerated().map { i, w in
            ChunkWordTiming(wordIndex: i, start: Double(i) * 0.9, end: Double(i) * 0.9 + 0.8, word: w)
        }
        let n = try WordTimingMaterializer.refineWithSynthesis(
            audiobookID: book, synthesisByBlock: [block: timings], writer: db.writer)
        #expect(n == 1)  // the block counted as (partially) overridden
        let retimed = try dao.words(forAudiobook: book, blockID: block).filter { $0.source == "synthesis" }
        #expect(retimed.count >= 4)  // we/saw/percent/gains matched; expanded number left interpolated
    }
}
```

- [ ] **Step 3: Run to verify it fails** — `make test-only FILTER=EchoTests/WordTimingSynthesisRetimeTests`. Expected: FAIL (current guard skips the block; `n == 0`, retimed count 0).

- [ ] **Step 4: Implement the LCS partial retime** in `refineWithSynthesis` — replace the `guard rows.count == timings.count, !rows.isEmpty else { continue }` block with an LCS over normalized word text, retiming matched pairs. (Add a small private `static func lcsPairs(_:_:) -> [(Int, Int)]` returning matched (rowIndex, timingIndex) pairs by normalized `word`.) Show the full replacement body:

```swift
        for (blockID, timings) in synthesisByBlock {
            let rows = (try dao.words(forAudiobook: audiobookID, blockID: blockID))
                .sorted { $0.wordIndex < $1.wordIndex }
            guard !rows.isEmpty, !timings.isEmpty else { continue }
            let sortedTimings = timings.sorted { $0.wordIndex < $1.wordIndex }
            let pairs: [(Int, Int)]
            if rows.count == sortedTimings.count {
                pairs = Array(0..<rows.count).map { ($0, $0) }  // fast path: exact match
            } else {
                pairs = lcsPairs(
                    rows.map { normalize($0.word) },
                    sortedTimings.map { normalize($0.word) })
                guard !pairs.isEmpty else { continue }
            }
            for (ri, ti) in pairs {
                var updated = rows[ri]
                updated.audioStartTime = sortedTimings[ti].start
                updated.audioEndTime = sortedTimings[ti].end
                updated.confidence = synthesisConfidence
                updated.source = "synthesis"
                updates.append(updated)
            }
            blocksOverridden += 1
        }
```

and add the helpers (private static in `WordTimingMaterializer`):

```swift
    private static func normalize(_ w: String) -> String {
        w.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Longest common subsequence of two word-token arrays, returned as matched
    /// (leftIndex, rightIndex) pairs. Used to retime the words that survived
    /// normalization even when the counts differ.
    private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }
```

Note: if `ChunkWordTiming` needs a `word` field added for matching, add it (with a default so existing constructors compile) as part of Step 1's finding; that is the "broader change" gate.

- [ ] **Step 5: Run to verify passing** — `make build-tests && make test-only FILTER=EchoTests/WordTimingSynthesisRetimeTests`. Expected: PASS. Also re-run the existing materializer suite (`grep -rl "refineWithSynthesis\|WordTimingMaterializer" EchoTests`) — Expected: still PASS (exact-count path unchanged).

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/WordTimingMaterializer.swift EchoTests/WordTimingSynthesisRetimeTests.swift
git commit -m "fix(alignment): partial synthesis retiming on word-count mismatch"
```

---

## Phase 3 — Operational: narrate, author, verify, deliver

These are procedures, not TDD cycles. Run them in order; artifacts live under `~/Developer/echo-overnight/day1-vibe-coding/` (off-git).

### Task 10: Boot the simulator and prime the model

- [ ] **Step 1:** `xcrun simctl boot "iPhone 17" || true` (ignore "already booted").
- [ ] **Step 2:** `make build-tests` (build the test host once, with the new code).
- [ ] **Step 3:** Create the work dir: `mkdir -p ~/Developer/echo-overnight/day1-vibe-coding/{work,out}` and copy the source PDF into it: `cp "/Volumes/Fledging-WD-2TB/Books/Unknown Author/Day 1 v3/Day 1 v3.pdf" ~/Developer/echo-overnight/day1-vibe-coding/`.

### Task 11: Narrate the PDF on the sim (batched loop)

- [ ] **Step 1:** Run the gated IT with env, looping ≤5 chapters/invocation until `RESULT complete=true`. Each invocation:

```bash
D=~/Developer/echo-overnight/day1-vibe-coding
ECHO_NARRATE_PDF="$D/Day 1 v3.pdf" \
ECHO_NARRATE_WORKDIR="$D/work" \
ECHO_NARRATE_DB="$D/book.sqlite" \
ECHO_NARRATE_OUT="$D/out/day1-vibe-coding.m4b" \
ECHO_NARRATE_SIDECAR="$D/out/day1-vibe-coding.alignment.json" \
ECHO_NARRATE_TITLE="The New SDLC With Vibe Coding" \
ECHO_NARRATE_AUTHOR="Osmani, Saboo, Kartakis" \
ECHO_NARRATE_MAXCH=5 \
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test-without-building -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:EchoTests/PDFNarrationSimIT -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected first run: model download (163 MB) then `RESULT complete=false` (batch of 5). Re-run until `RESULT complete=true` and the `.m4b` + `.alignment.json` appear in `out/`. Confirm chapter count from the first run's log (TOC chapters vs synthetic page-chapters) to know how many iterations remain.

- [ ] **Step 2:** Capture the alignment coverage line from the run logs: `xcrun simctl spawn booted log show --last 10m --predicate 'category == "NarrationService"' 2>/dev/null | grep "Synthesis word timing"` (or read it from the test's stderr). Record `overridden/total`.

- [ ] **Step 3 (decision gate):** If `overridden/total < 0.80`, implement **Task 9** now, rebuild, and re-narrate (delete `work/` + `book.sqlite` first to force a clean re-render). Else note the ratio and proceed.

- [ ] **Step 4:** Confirm figures were extracted: `cat "$D/figures.json" | python3 -m json.tool | head` — expect ~16 entries with `portableAnchor` (`s<i>-b<j>`) + `imagePath`. Copy the figure PNGs out for authoring: they are at the `imagePath`s (under Application Support in the sim's data container) — resolve with `xcrun simctl get_app_container booted <bundleID> data` and copy the `EPUBAssets/<book>/figure-*.png` into `$D/figures/`.

### Task 12: Author the study deck bundle

- [ ] **Step 1:** Read the whitepaper text (`pdftotext "$D/Day 1 v3.pdf" "$D/day1.txt"`) and the figure PNGs in `$D/figures/`. Hand-author `~/Developer/echo-overnight/day1-vibe-coding/deck/deck.echo-deck.json` covering the real concepts (vibe coding vs. agentic engineering; context engineering; the harness/factory model; conductor vs. orchestrator; the 80% problem; CapEx/OpEx economics; intelligent model routing; where-to-start). Mix `basic` + `cloze`. Each card: `sourceAnchor` to its source block; **needs-figure** cards get `imageAnchor` = the matching figure's `portableAnchor` from `figures.json`; **needs-mnemonic** cards get `imageFile` = `images/<slug>.png`.
- [ ] **Step 2:** `targetMediaID` = the book's `audiobook_id` from `book.sqlite` (`sqlite3 "$D/book.sqlite" "SELECT id FROM audiobook LIMIT 1;"`).
- [ ] **Step 3:** Emit the mnemonic manifest `~/Developer/echo-overnight/day1-vibe-coding/deck/mnemonic-manifest.json`: `[{ "imageFile": "images/<slug>.png", "prompt": "<memorable-image prompt for the concept>" }, ...]` for every needs-mnemonic card.

### Task 13: Generate mnemonic pics via Codex

- [ ] **Step 1:** Confirm the Codex pic-maker's name/path with the owner (likely `imagegen`). Attempt to drive it from this session via the codex bridge (`codex:rescue`), passing the mnemonic manifest and target `deck/images/`. If the bridge cannot reach the `image_gen` tool, hand the owner `mnemonic-manifest.json` and the target folder and let them run their Codex skill; wait for the PNGs to appear in `deck/images/`.
- [ ] **Step 2:** Verify every `imageFile` referenced by the deck exists in `deck/images/`. Missing files → the card imports text-only (acceptable), but flag them to the owner.

### Task 14: Import the deck + verify end-to-end on the sim

- [ ] **Step 1:** Install the built app on the sim and load the narrated book so its `audiobook_id`/blocks exist in the app's live DB (import the PDF through the app, which now also extracts figures). Alternatively, point the app at `book.sqlite` per the app's DB location.
- [ ] **Step 2:** Import the deck bundle (`deck/deck.echo-deck.json`) through the app's deck-import entry point.
- [ ] **Step 3 (alignment proof):** Open the reader, play, and confirm read-along highlighting tracks the audio at block + word level, including through an abbreviation/number block. Capture screenshots via `xcrun simctl io booted screenshot`.
- [ ] **Step 4 (image proof):** Open the deck; confirm a needs-figure card renders its real diagram and a needs-mnemonic card renders its Codex image. Screenshots.
- [ ] **Step 5:** If read-along mis-highlights or an image is missing, diagnose with `systematic-debugging` (check `word_timing.source`, `pdf_block_page`, `mediaJSON`), fix, rebuild, re-verify.

### Task 15: Package, doc-sync, PR

- [ ] **Step 1:** Assemble the package and copy to iCloud:

```bash
DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Books/Books to test echo/Day 1 - Vibe Coding"
mkdir -p "$DEST"
cp "$D/out/day1-vibe-coding.m4b" "$DEST/"
cp "$D/out/day1-vibe-coding.alignment.json" "$DEST/"
cp -R "$D/deck" "$DEST/"          # deck.echo-deck.json + images/
cp -R "$D/figures" "$DEST/figures/"
cp "$D/Day 1 v3.pdf" "$DEST/"
```

- [ ] **Step 2:** Write `"$DEST/README.md"` explaining: what the package is, that the deck bundle imports via Echo's deck-import (figures resolve by `imageAnchor`, mnemonics ship in `images/`), and how to load the m4b + sidecar.
- [ ] **Step 3:** Run the `doc-sync` skill; update `ARCHITECTURE.md` (PDF figure extraction; deck-image bundle two-mode attach) and `CHANGELOG.md`. Commit docs.
- [ ] **Step 4:** Full test pass: `make build-tests && make test` (Expected: green; the gated IT stays inert). Run SwiftLint if installed (Expected: clean).
- [ ] **Step 5:** Rebase onto latest nightly and open the PR:

```bash
git fetch origin && git rebase origin/nightly
git push -u origin claude/ios-pdf-narration-study-deck-fae1f8   # --force-with-lease if already pushed
gh pr create --base nightly --title "PDF figure study decks: extraction, card images, narration+alignment" \
  --body "<summary: figure extraction as epub_block image blocks (no migration), deck-image bundle (imageAnchor/imageFile), general-card image render, gated PDF narration IT, conditional synthesis-retiming fix; on-sim verification screenshots; alignment coverage ratio>"
```

- [ ] **Step 6:** Follow CI: `gh pr checks`. If red, inspect the failing job log, fix the concrete blocker, push, re-check until green/pending/blocked. Report the PR link + CI status.

---

## Self-Review

**Spec coverage:** A(sim narration)→Tasks 8,10,11. B(alignment fix)→Tasks 9,11-step3. C(figure extraction)→Tasks 4,6,7. D(deck-image + render)→Tasks 1,2,3,5. E(deck+pics+verify+deliver)→Tasks 12,13,14,15. No-migration constraint honored (no `Schema_Vxx`). Delivery to iCloud→Task 15. All spec sections map to a task.

**Placeholder scan:** Operational tasks (10–15) are procedures with concrete commands, not TDD stubs — acceptable per the skill (code tasks carry full code). The two genuinely deferred items are explicitly gated, not vague: Task 9 is conditional on a measured ratio; Task 13's Codex skill path is confirmed with the owner at runtime. No "TBD/handle errors/similar to" placeholders in code steps.

**Type consistency:** `StudyLocalImageView(path:accessibilityLabel:)` (Task 1) used identically in Tasks 2. `StudyCardMedia.imagePath(fromMediaJSON:)` defined in Task 2, reused in Task 5's tests. `ExtractedFigure`/`extractFigures` (Task 6) consumed by `PDFFigureImporter.importFigures` (Task 7) with matching signature. `FigureManifestEntry.portableAnchor` (Task 7) is the `imageAnchor` value authored in Task 12 and resolved in Task 5. `DeckImportError.conflictingImageFields(cardIndex:)` defined + thrown + tested consistently (Task 5). `EPUBAssetStorage.writeImageData` signature identical in Tasks 4 and 7.
