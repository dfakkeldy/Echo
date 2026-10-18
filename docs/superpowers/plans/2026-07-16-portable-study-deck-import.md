# Portable Echo Study-Deck Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Echo export a device-independent source identity and safely import one portable, source-anchored learning-book deck against a user-selected local book on iOS and macOS.

**Architecture:** Echo computes one immutable signature from canonical EPUB parser output and emits it in `export-blocks` v2. Portable deck import is a distinct fail-closed path: decode and classify, bind to the selected local book, verify signature and every anchor, stage images, then replace the stable deck ID in one database transaction. Legacy JSON import remains behaviorally unchanged, and imported `manualOnly` cards continue through the existing session/FSRS path.

**Tech Stack:** Swift 6 language mode, complete strict concurrency, Swift Testing, GRDB, CryptoKit, SwiftUI, Xcode 26, iOS 18, macOS 15, existing `echo-cli` Xcode target.

## Global Constraints

- Base the feature branch on `origin/nightly`; open the ready PR into `nightly` and never push directly to `nightly`, `weekly`, or `main`.
- Preserve iOS 18.0, macOS 15.0, and watchOS 11.0 deployment targets.
- Preserve Swift 6 language mode, complete strict-concurrency checking, and Main Actor default isolation.
- Add no third-party dependency and add no database migration; `deck.id` is already a text primary key.
- Use `triggerTiming: "manualOnly"`; imported cards must enter ordinary session/FSRS review and must never trigger during playback.
- Require `formatVersion: 2`, `targetBinding: "selectedBook"`, a stable portable `deckID`, and a selected local audiobook ID for portable decks.
- Never persist a portable `targetMediaID` sentinel as an audiobook ID.
- Fail before deck/card/timeline database mutation on a wrong signature, missing selected book, malformed v2 document, unresolved source anchor, invalid declared image, or unsafe image path.
- Keep legacy decks without portable-v2 fields on the current embedded-target, name-based import path.
- Treat every image reference present in a final deck as required at import. Optional image fallback happens during authoring before final review, by removing the reference from the shipped deck.
- On iOS, a portable deck containing `imageFile` is selected as its containing bundle directory, which grants one security-scoped resource for the JSON and sibling `deck-images/`; direct JSON selection is accepted only when the deck has no `imageFile` cards.
- Use Unicode scalar count for the 160-scalar front and 240-scalar back limits so Swift and Python validators agree.
- The full `.echo` archive remains out of scope.
- Run every `xcodebuild`, `make build`, or `make test` command behind `"$HOME/.claude/bin/xcode-build-gate.sh" --wait` and keep test parallelism capped.

## Contract Correction Locked by This Plan

The first approved draft called the signature `echo-visible-blocks-v1` and included persisted `chapterIndex`. Live mapping showed that `chapterIndex` changes when the same EPUB is paired with different audiobook chapters, while `isHidden` is user-mutable. That would violate the approved cross-device requirement. The approved specification has now been corrected, and this plan implements its frozen first algorithm, `echo-canonical-blocks-v1`: it hashes canonical parser blocks regardless of current visibility and excludes `chapterIndex`, `isHidden`, audiobook ID, paths, and timestamps. The v2 export may still report `chapterIndex` as authoring metadata, but that field is not source identity.

The exact canonical field stream is:

1. algorithm string;
2. decimal block count;
3. for each block sorted by `(sequenceIndex, portableID)`: portable ID, block kind, exact text or empty string, `isFrontMatter` as `1` or `0`, decimal sequence index, and decimal word count or the literal `null`.

Every UTF-8 value is prefixed with its unsigned 64-bit big-endian byte length. The result is full SHA-256, lowercase hexadecimal, prefixed with `sha256:`.

---

### Task 1: Canonical Source Signature and `export-blocks` v2

**Files:**
- Create: `EchoCore/Services/EchoSourceSignature.swift`
- Create: `EchoTests/EchoSourceSignatureTests.swift`
- Modify: `EchoCore/Services/BlockExportDocument.swift:8-68`
- Modify: `EchoCore/Services/SidecarSourceBlockLoader.swift:39-103`
- Modify: `EchoTests/BlockExportDocumentTests.swift`

**Interfaces:**
- Consumes: `[EPubBlockRecord]` returned by Echo's parser/importer.
- Produces: `EchoSourceSignature.make(records:) -> EchoSourceSignature`, `EchoSourceSignature.currentAlgorithm == "echo-canonical-blocks-v1"`, and `BlockExportDocument` JSON version 2 with `sourceSignature` and `isFrontMatter`.

- [ ] **Step 1: Create the implementation worktree from current `nightly`**

After this plan's documentation PR is merged, run:

```bash
git fetch origin
git worktree add \
  /Users/dfakkeldy/.codex/worktrees/portable-study-deck-import/Echo \
  -b codex/portable-study-deck-import origin/nightly
cd /Users/dfakkeldy/.codex/worktrees/portable-study-deck-import/Echo
git status --short --branch
```

Expected: a clean branch named `codex/portable-study-deck-import` based on the latest `origin/nightly` and containing this plan.

- [ ] **Step 2: Add the golden-vector signature tests**

Add helpers that construct records whose local audiobook IDs, paths, chapter assignments, and hidden state vary while canonical fields stay fixed. The primary assertion must be:

```swift
@Test func goldenVectorUsesLengthPrefixedCanonicalFields() {
    let records = [
        makeBlock(id: "epub-local-a-s0-b0", kind: "heading", text: "Opening",
                  sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
        makeBlock(id: "epub-local-a-s0-b1", kind: "paragraph", text: "Exact café text.",
                  sequenceIndex: 1, isFrontMatter: false, wordCount: 3),
    ]

    let signature = EchoSourceSignature.make(records: records)

    #expect(signature.algorithm == "echo-canonical-blocks-v1")
    #expect(signature.value == "sha256:59edb2bf3a7b0ad4bd891c5d015dd3c68af797b63ed6ea726baa99de7f062863")
}
```

Use this complete helper in the new suite so every canonical and excluded field is explicit:

```swift
private func makeBlock(
    id: String,
    kind: String,
    text: String?,
    sequenceIndex: Int,
    isFrontMatter: Bool,
    wordCount: Int?,
    audiobookID: String = "local-a",
    chapterIndex: Int? = 0,
    isHidden: Bool = false,
    imagePath: String? = nil
) -> EPubBlockRecord {
    EPubBlockRecord(
        id: id,
        audiobookID: audiobookID,
        spineHref: "chapter.xhtml",
        spineIndex: 0,
        blockIndex: sequenceIndex,
        sequenceIndex: sequenceIndex,
        blockKind: kind,
        text: text,
        htmlContent: nil,
        cardColor: nil,
        chapterThemeColor: nil,
        imagePath: imagePath,
        chapterIndex: chapterIndex,
        isHidden: isHidden,
        hiddenReason: isHidden ? "user" : nil,
        isFrontMatter: isFrontMatter,
        wordCount: wordCount,
        markers: nil,
        textFormats: nil,
        narrationText: nil,
        createdAt: nil,
        modifiedAt: nil
    )
}
```

Add named tests for audiobook-ID independence, chapter-index independence, hidden-state independence, path independence, input-order independence, exact-text sensitivity, `isFrontMatter` sensitivity, word-count null distinction, and stable tie-breaking by portable ID.

- [ ] **Step 3: Run the new signature suite and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && \
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=EchoTest-iPhone-17' \
  -only-testing:EchoTests/EchoSourceSignatureTests \
  -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: build failure because `EchoSourceSignature` does not exist.

- [ ] **Step 4: Implement the pure signature value**

Create this public contract and keep the framing implementation private in the same file:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated struct EchoSourceSignature: Codable, Equatable, Sendable {
    static let currentAlgorithm = "echo-canonical-blocks-v1"

    let algorithm: String
    let value: String

    static func make(records: [EPubBlockRecord]) -> Self {
        let ordered = records.sorted {
            if $0.sequenceIndex != $1.sequenceIndex {
                return $0.sequenceIndex < $1.sequenceIndex
            }
            return AlignmentSidecar.portableSuffix(of: $0.id)
                < AlignmentSidecar.portableSuffix(of: $1.id)
        }
        var encoder = CanonicalSourceEncoder()
        encoder.append(currentAlgorithm)
        encoder.append(String(ordered.count))
        for record in ordered {
            encoder.append(AlignmentSidecar.portableSuffix(of: record.id))
            encoder.append(record.blockKind)
            encoder.append(record.text ?? "")
            encoder.append(record.isFrontMatter ? "1" : "0")
            encoder.append(String(record.sequenceIndex))
            encoder.append(record.wordCount.map(String.init) ?? "null")
        }
        let digest = SHA256.hash(data: encoder.data)
        return Self(
            algorithm: currentAlgorithm,
            value: "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

private nonisolated struct CanonicalSourceEncoder {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
```

- [ ] **Step 5: Run the signature suite and verify GREEN**

Run the Step 3 command. Expected: all `EchoSourceSignatureTests` pass.

- [ ] **Step 6: Make block export v2 fail first**

Update `BlockExportDocumentTests` to assert `version == 2`, the exact signature object, `isFrontMatter` on every block, and image blocks remaining in the export. Add a regression that two documents with different `epubName`, audiobook IDs, chapter indices, hidden flags, and image storage paths have equal signatures.

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/BlockExportDocumentTests
```

Expected: failures because the document is still version 1 and has no signature/front-matter fields.

- [ ] **Step 7: Emit the v2 contract from every source-loader variant**

Change `BlockExportDocument` to this shape:

```swift
nonisolated struct BlockExportDocument: Encodable {
    static let currentVersion = 2

    struct Source: Encodable { let epub: String }

    struct Block: Encodable {
        let id: String
        let kind: String
        let text: String
        let chapterIndex: Int?
        let sequenceIndex: Int
        let wordCount: Int?
        let isFrontMatter: Bool
        let imagePath: String?
    }

    let version: Int
    let source: Source
    let sourceSignature: EchoSourceSignature
    let blocks: [Block]
}
```

Construct `sourceSignature` from the same complete record array used to construct `blocks`. In `SidecarSourceBlockLoader`, make expanded EPUB, EPUB file, and PDF branches all query `EPubBlockDAO.allBlocks(for:)` after import; do not return the expanded importer array directly and do not filter on mutable `isHidden`.

- [ ] **Step 8: Verify export v2 and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/EchoSourceSignatureTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/BlockExportDocumentTests
git diff --check
git add EchoCore/Services/EchoSourceSignature.swift \
  EchoCore/Services/BlockExportDocument.swift \
  EchoCore/Services/SidecarSourceBlockLoader.swift \
  EchoTests/EchoSourceSignatureTests.swift \
  EchoTests/BlockExportDocumentTests.swift
git commit -m "feat: add canonical source signatures"
```

Expected: both suites pass, `git diff --check` is silent, and the commit succeeds.

### Task 2: Portable-v2 Model Classification and Strict Card Validation

**Files:**
- Modify: `EchoCore/Models/FlashcardDeckImport.swift:26-77`
- Create: `EchoCore/Models/ValidatedDeckImport.swift`
- Create: `EchoTests/PortableDeckImportTests.swift`
- Modify: `EchoTests/StudyDeckFileExporterTests.swift`

**Interfaces:**
- Consumes: decoded `FlashcardDeckImport` with optional additive v2 fields.
- Produces: `ValidatedDeckImport.decode(_:) throws -> ValidatedDeckImport`, `.legacy(FlashcardDeckImport)`, `.portable(PortableDeckImport)`, and actionable `DeckImportError` cases.

- [ ] **Step 1: Write classification and boundary tests**

The first tests must prove a complete v2 document classifies as portable while the current exporter fixture classifies as legacy:

```swift
@Test func completeV2ClassifiesAsPortable() throws {
    let validated = try ValidatedDeckImport.decode(Data(portableDeckJSON.utf8))
    guard case .portable(let deck) = validated else {
        Issue.record("Expected portable deck")
        return
    }
    #expect(deck.deckID == "com.kinnoki.book.edition.core")
    #expect(deck.cards[0].sourceAnchor == "s1-b2")
}

@Test func currentLegacyShapeRemainsLegacy() throws {
    let validated = try ValidatedDeckImport.decode(Data(legacyDeckJSON.utf8))
    guard case .legacy = validated else {
        Issue.record("Expected legacy deck")
        return
    }
}
```

Add named failure tests for unsupported `formatVersion`, any partial-v2 top-level field set, missing selected binding, a target sentinel outside `^echo-portable:[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9.-]*$`, deck IDs longer than 128 ASCII bytes or outside `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`, empty cards, whitespace-only text, front text over 160 Unicode scalars, back text over 240 Unicode scalars, missing source anchor, timestamps present, timing other than `manualOnly`, malformed source/image anchors, and both image fields present.

- [ ] **Step 2: Run the portable model tests and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImportTests
```

Expected: build failure because `ValidatedDeckImport` and v2 fields do not exist.

- [ ] **Step 3: Add additive decoding fields without changing legacy JSON**

Extend `FlashcardDeckImport` with optional fields and an explicit initializer so `StudyDeckFileExporter` retains its existing source-compatible construction:

```swift
let formatVersion: Int?
let deckID: String?
let deckName: String
let targetBinding: String?
let targetMediaID: String
let sourceSignature: EchoSourceSignature?
let cards: [ImportedCard]

init(
    formatVersion: Int? = nil,
    deckID: String? = nil,
    deckName: String,
    targetBinding: String? = nil,
    targetMediaID: String,
    sourceSignature: EchoSourceSignature? = nil,
    cards: [ImportedCard]
) {
    self.formatVersion = formatVersion
    self.deckID = deckID
    self.deckName = deckName
    self.targetBinding = targetBinding
    self.targetMediaID = targetMediaID
    self.sourceSignature = sourceSignature
    self.cards = cards
}
```

Do not add custom unknown-key or duplicate-key parsing to Echo. The production tooling rejects those deterministically; Echo validates the semantic v2 contract after `JSONDecoder` and remains tolerant of future additive fields.

- [ ] **Step 4: Implement one authoritative classifier**

Create these types in `ValidatedDeckImport.swift`:

```swift
nonisolated enum ValidatedDeckImport: Sendable {
    case legacy(FlashcardDeckImport)
    case portable(PortableDeckImport)

    static func decode(_ data: Data) throws -> Self {
        let raw: FlashcardDeckImport
        do {
            raw = try JSONDecoder().decode(FlashcardDeckImport.self, from: data)
        } catch {
            throw DeckImportError.invalidJSON(error)
        }
        let v2Markers = [
            raw.formatVersion != nil,
            raw.deckID != nil,
            raw.targetBinding != nil,
            raw.sourceSignature != nil,
        ]
        guard v2Markers.contains(true) else { return .legacy(raw) }
        guard v2Markers.allSatisfy({ $0 }),
              let deckID = raw.deckID,
              let sourceSignature = raw.sourceSignature else {
            throw DeckImportError.incompletePortableDeck
        }
        guard raw.formatVersion == 2 else {
            throw DeckImportError.unsupportedPortableVersion(raw.formatVersion)
        }
        guard !raw.deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeckImportError.emptyDeckName
        }
        guard raw.targetBinding == "selectedBook" else {
            throw DeckImportError.invalidPortableBinding(raw.targetBinding)
        }
        guard matches("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", deckID),
              deckID.unicodeScalars.allSatisfy(\.isASCII) else {
            throw DeckImportError.invalidPortableDeckID(deckID)
        }
        guard matches(
            "^echo-portable:[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9.-]*$",
            raw.targetMediaID
        ) else {
            throw DeckImportError.invalidPortableTarget(raw.targetMediaID)
        }
        guard sourceSignature.algorithm == EchoSourceSignature.currentAlgorithm,
              matches("^sha256:[0-9a-f]{64}$", sourceSignature.value) else {
            throw DeckImportError.invalidSourceSignature
        }
        guard !raw.cards.isEmpty else { throw DeckImportError.emptyDeck }
        for (index, card) in raw.cards.enumerated() {
            try validatePortableCard(card, index: index)
        }
        return .portable(PortableDeckImport(
            deckID: deckID,
            deckName: raw.deckName,
            targetMediaID: raw.targetMediaID,
            sourceSignature: sourceSignature,
            cards: raw.cards
        ))
    }

    private static func validatePortableCard(
        _ card: FlashcardDeckImport.ImportedCard,
        index: Int
    ) throws {
        let front = card.frontText.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = card.backText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty else {
            throw DeckImportError.emptyCardText(cardIndex: index)
        }
        guard card.frontText.unicodeScalars.count <= 160,
              card.backText.unicodeScalars.count <= 240 else {
            throw DeckImportError.portableTextTooLong(cardIndex: index)
        }
        guard card.startTime == nil, card.endTime == nil else {
            throw DeckImportError.portableTimestampsForbidden(cardIndex: index)
        }
        guard card.triggerTiming == FlashcardTriggerTiming.manualOnly.rawValue else {
            throw DeckImportError.portableTimingMustBeManualOnly(cardIndex: index)
        }
        guard let sourceAnchor = card.sourceAnchor,
              matches("^s[0-9]+-b[0-9]+$", sourceAnchor) else {
            throw DeckImportError.invalidPortableSourceAnchor(cardIndex: index)
        }
        if let imageAnchor = card.imageAnchor,
           !matches("^s[0-9]+-b[0-9]+$", imageAnchor) {
            throw DeckImportError.invalidPortableImageAnchor(cardIndex: index)
        }
        if card.imageAnchor != nil, card.imageFile != nil {
            throw DeckImportError.conflictingImageFields(cardIndex: index)
        }
        if let imageFile = card.imageFile {
            let parts = imageFile.split(separator: "/", omittingEmptySubsequences: false)
            guard imageFile.hasPrefix("deck-images/"),
                  !imageFile.hasPrefix("/"),
                  !imageFile.contains("\\"),
                  !parts.contains(where: { $0 == ".." || $0.isEmpty }) else {
                throw DeckImportError.invalidPortableImageFile(cardIndex: index)
            }
        }
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

nonisolated struct PortableDeckImport: Sendable {
    let deckID: String
    let deckName: String
    let targetMediaID: String
    let sourceSignature: EchoSourceSignature
    let cards: [FlashcardDeckImport.ImportedCard]
}
```

Add the named `DeckImportError` cases used above. Their localized messages are exact and actionable: unsupported version says `Portable study decks require formatVersion 2.`; incomplete v2 says `Portable study deck metadata is incomplete.`; invalid binding says `Portable study decks require targetBinding selectedBook.`; invalid target says `The portable targetMediaID sentinel is invalid.`; invalid deck ID says `deckID must be 1-128 ASCII letters, numbers, dots, underscores, or hyphens.`; invalid signature says `The source signature is missing or malformed.`; card-indexed anchor/image/timestamp/timing/length errors name `Card N` and the violated rule. Tests compare every full message.

- [ ] **Step 5: Verify model parity and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImportTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/StudyDeckFileExporterTests
git diff --check
git add EchoCore/Models/FlashcardDeckImport.swift \
  EchoCore/Models/ValidatedDeckImport.swift \
  EchoTests/PortableDeckImportTests.swift \
  EchoTests/StudyDeckFileExporterTests.swift
git commit -m "feat: validate portable deck documents"
```

Expected: both suites pass and legacy exporter JSON remains unchanged.

### Task 3: Selected-Book Preflight and Typed Anchor Resolution

**Files:**
- Create: `EchoCore/Services/PortableDeckPreflight.swift`
- Modify: `EchoCore/Services/DeckImportService.swift:16-300`
- Modify: `EchoCore/Services/EPUBSourceAnchorResolver.swift:43-95`
- Create: `EchoTests/PortableDeckPreflightTests.swift`
- Modify: `EchoTests/DeckImportServiceTests.swift`

**Interfaces:**
- Consumes: `PortableDeckImport`, selected local audiobook ID, all persisted canonical blocks, and deck file URL.
- Produces: `PortableDeckPreflight.prepare(deck:targetAudiobookID:deckURL:dbReader:) throws -> PortableDeckWritePlan` with fully resolved source IDs and image inputs; no database writes.

- [ ] **Step 1: Write zero-mutation preflight tests**

Seed a selected audiobook and canonical blocks, snapshot counts from `audiobook`, `deck`, `flashcard`, and `timeline_item`, and exercise each failure. The signature-mismatch test must use this shape:

```swift
let before = try databaseCounts(writer)
#expect {
    try DeckImportService().importDeckVNext(
        from: deckURL,
        targetAudiobookID: "local-book",
        db: writer
    )
} throws: { error in
    guard case DeckImportError.sourceSignatureMismatch = error else { return false }
    return true
}
#expect(try databaseCounts(writer) == before)
```

Add named zero-mutation tests for missing selected ID, nonexistent selected audiobook, no canonical blocks, wrong signature, unresolved source anchor, source anchor resolving to `.image`, source anchor resolving to front matter, malformed anchor, unresolved image anchor, image anchor resolving to text, and sentinel never appearing in `audiobook.id`.

- [ ] **Step 2: Run the preflight suite and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckPreflightTests
```

Expected: build failure because the selected-target overload and preflight type do not exist.

- [ ] **Step 3: Add a pure preflight write plan**

Create these immutable values:

```swift
nonisolated struct PortableDeckWritePlan: Sendable {
    struct Card: Sendable {
        let imported: FlashcardDeckImport.ImportedCard
        let sourceBlockID: String
        let media: PreparedCardMedia?
    }

    let deckID: String
    let deckName: String
    let targetAudiobookID: String
    let sourceSignature: EchoSourceSignature
    let sourceBlockIDs: [String]
    let cards: [Card]
}

nonisolated enum PreparedCardMedia: Sendable {
    case sourceImage(path: String)
    case stagedFile(source: URL, relativePath: String)
}
```

`prepare` must read the selected audiobook row, load `EPubBlockDAO.allBlocks`, recompute `EchoSourceSignature`, compare the algorithm and value exactly, create a portable-suffix dictionary, and require every `sourceAnchor` to resolve to a non-front-matter heading/paragraph/sentence. `imageAnchor` must resolve to an image block with a nonempty stored image path. Ignore mutable `isHidden` throughout.

- [ ] **Step 4: Add the selected-target overload and preserve the legacy wrapper**

The public boundary must be:

```swift
func importDeckVNext(
    from url: URL,
    targetAudiobookID: String,
    db writer: DatabaseWriter
) throws -> ImportDeckResult

func importDeckVNext(
    from url: URL,
    db writer: DatabaseWriter
) throws -> ImportDeckResult
```

The selected-target overload rejects legacy input with an actionable error rather than changing legacy semantics. The existing overload classifies the document: legacy documents continue through the old implementation; portable documents fail with `selectedBookRequired`. Never create a placeholder audiobook for portable input.

- [ ] **Step 5: Revalidate the selected source snapshot at mutation time**

Add a private transaction helper with this exact boundary:

```swift
private func verifySourceSnapshot(
    _ plan: PortableDeckWritePlan,
    in database: Database
) throws {
    let records = try EPubBlockRecord
        .filter(Column("audiobook_id") == plan.targetAudiobookID)
        .order(Column("sequence_index"))
        .fetchAll(database)
    guard EchoSourceSignature.make(records: records) == plan.sourceSignature else {
        throw DeckImportError.sourceChangedDuringImport
    }
}
```

This closes the preflight-to-write race and must run before any delete/update/insert in the final transaction.

- [ ] **Step 6: Verify preflight behavior and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckPreflightTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/DeckImportServiceTests
git diff --check
git add EchoCore/Services/PortableDeckPreflight.swift \
  EchoCore/Services/DeckImportService.swift \
  EchoCore/Services/EPUBSourceAnchorResolver.swift \
  EchoTests/PortableDeckPreflightTests.swift \
  EchoTests/DeckImportServiceTests.swift
git commit -m "feat: preflight portable decks against selected books"
```

Expected: new fail-closed tests and all legacy import tests pass.

### Task 4: Stable Deck Identity and Atomic Database Replacement

**Files:**
- Modify: `EchoCore/Services/DeckImportService.swift`
- Create: `EchoTests/PortableDeckPersistenceTests.swift`

**Interfaces:**
- Consumes: a successful `PortableDeckWritePlan`.
- Produces: stable `deck.id == portable deckID`, `source == "json_import_v2"`, fully replaced cards/timeline rows, or no database change.

- [ ] **Step 1: Write atomic persistence tests**

Add named tests proving: same ID plus renamed deck updates the name and replaces cards; same name plus different IDs coexist; reimport to a different selected local copy rebinds the same deck instead of duplicating it; collision with a non-v2 deck ID fails; a database trigger that raises `ABORT` when the second replacement card's front text is `FAIL-SECOND-INSERT` leaves the old deck/cards/timeline unchanged; and a source-snapshot race leaves the old deck unchanged. The trigger keeps fault injection in the test database rather than adding a production-only failure hook.

The idempotence assertion must read both deck and card tables:

```swift
try writer.read { database in
    #expect(try String.fetchOne(
        database,
        sql: "SELECT name FROM deck WHERE id = ?",
        arguments: [deckID]
    ) == "Renamed Core Review")
    #expect(try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM deck WHERE id = ?",
        arguments: [deckID]
    ) == 1)
    #expect(try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
        arguments: [deckID]
    ) == replacementCardCount)
}
```

- [ ] **Step 2: Run persistence tests and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckPersistenceTests
```

Expected: failures because portable persistence is not yet atomic or ID-based.

- [ ] **Step 3: Lock the existing in-transaction insertion seam with a regression**

`FlashcardDAO` already exposes the required static boundary:

```swift
static func insert(_ card: Flashcard, in database: Database) throws {
    var copy = card
    try copy.insert(database)
    try syncToTimeline(database, card: copy)
}
```

Add a focused assertion that calling it inside one writer transaction inserts both the flashcard and its timeline row. Do not add a second DAO API or change its current writer-backed wrapper. This existing seam prevents nested transactions while preserving timeline synchronization.

- [ ] **Step 4: Persist the complete portable write set in one transaction**

Use one helper whose `mediaJSONByCardIndex` array is all `nil` in Task 4 and populated by Task 5:

```swift
private func persistPortable(
    _ plan: PortableDeckWritePlan,
    mediaJSONByCardIndex: [String?],
    in writer: DatabaseWriter,
    now: Date
) throws {
    guard mediaJSONByCardIndex.count == plan.cards.count else {
        throw DeckImportError.internalCardPreparationMismatch
    }
    try writer.write { database in
        try verifySourceSnapshot(plan, in: database)
        let existingSource = try String.fetchOne(
            database,
            sql: "SELECT source FROM deck WHERE id = ?",
            arguments: [plan.deckID]
        )
        if let existingSource, existingSource != "json_import_v2" {
            throw DeckImportError.deckIDCollision(plan.deckID)
        }
        let timestamp = now.ISO8601Format()
        try database.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'json_import_v2', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    source = excluded.source,
                    modified_at = excluded.modified_at
                """,
            arguments: [plan.deckID, plan.deckName, timestamp, timestamp]
        )
        try database.execute(
            sql: """
                DELETE FROM timeline_item
                WHERE source_table = 'flashcard'
                  AND source_rowid IN (
                    SELECT id FROM flashcard WHERE deck_id = ?
                  )
                """,
            arguments: [plan.deckID]
        )
        try database.execute(
            sql: "DELETE FROM flashcard WHERE deck_id = ?",
            arguments: [plan.deckID]
        )
        for (index, prepared) in plan.cards.enumerated() {
            let card = Flashcard(
                id: UUID().uuidString,
                audiobookID: plan.targetAudiobookID,
                frontText: prepared.imported.frontText,
                backText: prepared.imported.backText,
                mediaTimestamp: 0,
                endTimestamp: nil,
                triggerTiming: .manualOnly,
                nextReviewDate: timestamp,
                intervalDays: 0,
                easeFactor: 2.5,
                repetitions: 0,
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: true,
                deckID: plan.deckID,
                tags: nil,
                mediaJSON: mediaJSONByCardIndex[index],
                sourceBlockID: prepared.sourceBlockID,
                playlistPosition: nil,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
            try FlashcardDAO.insert(card, in: database)
        }
    }
}
```

Use the selected local audiobook ID, never the sentinel. Do not change legacy name-based helpers.

- [ ] **Step 5: Verify persistence and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckPersistenceTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/DeckImportServiceTests
git diff --check
git add EchoCore/Services/DeckImportService.swift \
  EchoTests/PortableDeckPersistenceTests.swift
git commit -m "feat: replace portable decks atomically"
```

Expected: all persistence and legacy tests pass.

### Task 5: Required Image Resolution, Safe Staging, and Result Counts

**Files:**
- Create: `EchoCore/Services/PortableDeckImageStager.swift`
- Modify: `EchoCore/Services/PortableDeckPreflight.swift`
- Modify: `EchoCore/Services/DeckImportService.swift`
- Modify: `EchoCore/Services/DeckImportResult.swift:7-30`
- Create: `EchoTests/PortableDeckImageTests.swift`
- Modify: `EchoTests/DeckImportImageTests.swift`
- Modify: `EchoTests/FlashcardDeckImportImageFieldsTests.swift`

**Interfaces:**
- Consumes: validated `imageAnchor` or `imageFile` fields and a security-scoped deck URL.
- Produces: `ImportDeckResult.imageCount`, collision-safe media paths, and rollback-safe staged image publication.

- [ ] **Step 1: Write strict image and rollback tests**

Add tests for valid `imageAnchor`, valid nested `deck-images/cue.png`, absolute path, `..`, escaping symlink, directory, missing file, empty file, unsupported extension, two same-basename files, staging-copy failure, database failure after staging, stale-image removal on successful reimport, and legacy text-only degradation remaining unchanged.

The escaping-symlink test must assert both the error and unchanged database counts. The successful result must assert:

```swift
#expect(result.importedCount == 2)
#expect(result.anchoredCount == 2)
#expect(result.imageCount == 1)
#expect(result.warningCount == 0)
```

- [ ] **Step 2: Run image tests and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImageTests
```

Expected: failures because portable image references currently degrade silently and are not staged.

- [ ] **Step 3: Implement safe file preparation**

Create this implementation:

```swift
import CryptoKit
import Foundation

nonisolated struct PortableDeckImageStager {
    struct StagedSet: Sendable {
        let stagingRoot: URL
        let finalRoot: URL
        let backupRoot: URL
        let mediaPathByRelativePath: [String: String]
    }

    struct PublishedSet: Sendable {
        let staged: StagedSet
        let hadPreviousDirectory: Bool
    }

    func stage(
        relativePaths: [String],
        beside deckURL: URL,
        deckID: String
    ) throws -> StagedSet {
        let manager = FileManager.default
        let bundleRoot = deckURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let mediaRoot = URL.applicationSupportDirectory
            .appending(path: "DeckMediaV2", directoryHint: .isDirectory)
        let safeDeckID = SHA256.hash(data: Data(deckID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let finalRoot = mediaRoot.appending(path: safeDeckID, directoryHint: .isDirectory)
        let transactionID = UUID().uuidString
        let stagingRoot = mediaRoot.appending(
            path: ".staging-\(safeDeckID)-\(transactionID)",
            directoryHint: .isDirectory
        )
        let backupRoot = mediaRoot.appending(
            path: ".backup-\(safeDeckID)-\(transactionID)",
            directoryHint: .isDirectory
        )
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            var paths: [String: String] = [:]
            for relativePath in relativePaths.sorted() {
                let source = bundleRoot.appending(path: relativePath)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard source.path.hasPrefix(bundleRoot.path + "/") else {
                    throw DeckImportError.unsafeImagePath(relativePath)
                }
                let values = try source.resourceValues(forKeys: [
                    .isRegularFileKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw DeckImportError.invalidImageFile(relativePath)
                }
                let fileExtension = source.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "webp", "heic"].contains(fileExtension) else {
                    throw DeckImportError.unsupportedImageType(relativePath)
                }
                let filename = SHA256.hash(data: Data(relativePath.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                    + "." + fileExtension
                let stagedURL = stagingRoot.appending(path: filename)
                try manager.copyItem(at: source, to: stagedURL)
                paths[relativePath] = finalRoot.appending(path: filename).path
            }
            return StagedSet(
                stagingRoot: stagingRoot,
                finalRoot: finalRoot,
                backupRoot: backupRoot,
                mediaPathByRelativePath: paths
            )
        } catch let stagingError {
            do {
                try removeIfPresent(stagingRoot, using: manager)
            } catch let cleanupError {
                throw DeckImportError.imageStagingCleanupFailed(
                    primary: stagingError,
                    cleanup: cleanupError
                )
            }
            throw stagingError
        }
    }

    func publish(_ staged: StagedSet) throws -> PublishedSet {
        let manager = FileManager.default
        try manager.createDirectory(
            at: staged.finalRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let hadPrevious = manager.fileExists(atPath: staged.finalRoot.path)
        if hadPrevious {
            try manager.moveItem(at: staged.finalRoot, to: staged.backupRoot)
        }
        do {
            try manager.moveItem(at: staged.stagingRoot, to: staged.finalRoot)
            return PublishedSet(staged: staged, hadPreviousDirectory: hadPrevious)
        } catch let publicationError {
            do {
                if hadPrevious {
                    try manager.moveItem(at: staged.backupRoot, to: staged.finalRoot)
                }
            } catch let recoveryError {
                throw DeckImportError.imagePublicationRecoveryFailed(
                    primary: publicationError,
                    recovery: recoveryError
                )
            }
            throw publicationError
        }
    }

    func commit(_ published: PublishedSet) throws {
        if published.hadPreviousDirectory {
            try removeIfPresent(
                published.staged.backupRoot,
                using: FileManager.default
            )
        }
    }

    func rollback(_ published: PublishedSet) throws {
        let manager = FileManager.default
        try removeIfPresent(published.staged.finalRoot, using: manager)
        if published.hadPreviousDirectory {
            try manager.moveItem(
                at: published.staged.backupRoot,
                to: published.staged.finalRoot
            )
        }
    }

    func discard(_ staged: StagedSet) throws {
        let manager = FileManager.default
        try removeIfPresent(staged.stagingRoot, using: manager)
        try removeIfPresent(staged.backupRoot, using: manager)
    }

    private func removeIfPresent(_ url: URL, using manager: FileManager) throws {
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
}
```

The relative-path validator from Task 2 runs before this code. The stager then resolves every source symlink before containment checking, requires a nonempty regular file under the security-scoped bundle root, derives collision-safe filenames, and never uses raw `deckID` as a filesystem component.

- [ ] **Step 4: Coordinate filesystem and database rollback**

Before the database transaction, stage all files and call `publish`. Build `mediaJSONByCardIndex`, then call `persistPortable`. If the database transaction throws, call throwing `rollback`; if rollback also fails, surface `DeckImportError.imageRollbackFailed(primary:recovery:)` so recovery failure is never hidden. If the database transaction succeeds, call throwing `commit`. A commit cleanup failure leaves the new database rows and final media directory valid; convert that exact condition into one result warning and retain the uniquely named backup for the next launch's tested orphan-cleanup pass. A no-`imageFile` deck skips the stager and passes source-image or nil media JSON directly. `imageAnchor` uses the selected book's stored image path and does not copy the image. A declared image failure is a `DeckImportError`, never a warning or silent text-only downgrade.

Add launch-safe orphan cleanup to `DeckImportService`: remove only `.staging-` directories older than 24 hours and `.backup-<safeDeckID>-<UUID>` directories whose corresponding final directory exists. Never delete a backup when its final directory is absent. Cover cleanup selection, age boundaries, and deletion failures in `PortableDeckImageTests`; deletion failures become logged warnings and do not block unrelated imports.

Convert prepared media into persisted JSON through one throwing helper before constructing each `Flashcard`:

```swift
private func mediaJSON(
    for media: PreparedCardMedia?,
    staged: PortableDeckImageStager.StagedSet?
) throws -> String? {
    let imagePath: String
    switch media {
    case .none:
        return nil
    case .sourceImage(let path):
        imagePath = path
    case .stagedFile(_, let relativePath):
        guard let staged,
              let resolved = staged.mediaPathByRelativePath[relativePath] else {
            throw DeckImportError.stagedImageMissing(relativePath)
        }
        imagePath = resolved
    }
    let data = try JSONEncoder().encode(StudyCardMedia(imagePath: imagePath))
    return String(decoding: data, as: UTF8.self)
}
```

The database transaction maps every `PortableDeckWritePlan.Card` through this helper. Therefore `imageFile` paths are never copied or resolved inside the insertion loop, and every media path in the database points at the atomically published final directory.

- [ ] **Step 5: Extend the result without breaking callers**

Use this initializer so APKG/legacy callers can omit the new value:

```swift
init(
    importedCount: Int,
    anchoredCount: Int,
    imageCount: Int = 0,
    warnings: [ImportDeckWarning]
) {
    self.importedCount = importedCount
    self.anchoredCount = anchoredCount
    self.imageCount = imageCount
    self.warningCount = warnings.count
    self.warnings = warnings
}
```

- [ ] **Step 6: Verify images and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImageTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/DeckImportImageTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/FlashcardDeckImportImageFieldsTests
git diff --check
git add EchoCore/Services/PortableDeckImageStager.swift \
  EchoCore/Services/PortableDeckPreflight.swift \
  EchoCore/Services/DeckImportService.swift \
  EchoCore/Services/DeckImportResult.swift \
  EchoTests/PortableDeckImageTests.swift \
  EchoTests/DeckImportImageTests.swift \
  EchoTests/FlashcardDeckImportImageFieldsTests.swift
git commit -m "feat: import portable deck images safely"
```

Expected: strict portable image tests and unchanged legacy image tests pass.

### Task 6: Session, FSRS, Playback, and Sync Invariants

**Files:**
- Create: `EchoTests/PortableDeckStudyFlowTests.swift`
- Modify only if a test exposes a real regression: `Shared/Database/DAOs/FlashcardDAO.swift`, `EchoCore/ViewModels/StudySessionViewModel.swift`, or `Shared/SourceAnchoredCardTriggerResolver.swift`

**Interfaces:**
- Consumes: a successfully imported portable `manualOnly` flashcard.
- Produces: executable proof that the existing due-card/session/FSRS/sync path includes it while playback triggering excludes it.

- [ ] **Step 1: Write the integrated study-flow test**

Import a one-card portable deck, then assert all four behaviors:

```swift
let now = Date()
let due = try FlashcardDAO(db: writer).allDueCards(now: now)
#expect(due.map(\.deckID) == [deckID])

let queue = try StudyQueueBuilder(db: writer).build(now: now)
#expect(queue.entries.compactMap(\.flashcard.deckID).contains(deckID))

let triggerResult = SourceAnchoredCardTriggerResolver.resolve(
    previousBlockID: nil,
    activeBlockID: due[0].sourceBlockID,
    cards: due,
    state: .init()
)
#expect(triggerResult.cardsToTrigger.isEmpty)

try FlashcardDAO(db: writer).grade(
    cardID: due[0].id,
    grade: ReviewGrade.good.rawValue,
    now: now
)
let reviewed = try writer.read { database in
    try Flashcard.fetchOne(database, key: due[0].id)
}
#expect(reviewed?.repetitions == 1)
#expect(reviewed?.nextReviewDate != nil)
```

Also assert the persisted flashcard carries the deck ID, selected local audiobook ID, enabled state, trigger timing, and source block ID. Assert the synchronized timeline row carries the selected local audiobook ID and EPUB block ID; `TimelineItem` does not duplicate deck ID or trigger timing. Portability means the same deck file can be imported against matching local copies on multiple devices; this task does not add an automatic deck-sync format.

- [ ] **Step 2: Run the integrated test and verify existing production behavior**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckStudyFlowTests
```

Expected: PASS without production changes. If it fails, make only the smallest correction in the existing DAO/queue/trigger seam and retain a regression test for the exact failure.

- [ ] **Step 3: Run neighboring scheduler suites and commit proof**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/FlashcardDAOSchedulerTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/StudyQueueBuilderTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/SourceAnchoredCardTriggerResolverTests
git diff --check
git add EchoTests/PortableDeckStudyFlowTests.swift \
  Shared/Database/DAOs/FlashcardDAO.swift \
  EchoCore/ViewModels/StudySessionViewModel.swift \
  Shared/SourceAnchoredCardTriggerResolver.swift
git commit -m "test: prove portable decks use normal review"
```

Stage only production files that actually changed. Expected: all four suites pass.

### Task 7: Low-Friction iOS and macOS Selected-Book Import

**Files:**
- Create: `EchoCore/Services/PortableDeckImportCoordinator.swift`
- Create: `EchoCore/Services/PortableDeckSelectionResolver.swift`
- Modify: `EchoCore/Views/SettingsView.swift:20-23,77-88,164-169,217-240`
- Modify: `EchoCore/Views/BookSettingsView.swift:157-202`
- Modify: `Echo macOS/Views/MacTriPaneView.swift:28-45,94-113,521-551`
- Modify: `Echo macOS/Echo_macOSApp.swift:263-271,577`
- Modify: `EchoCore/Services/Library/LibraryService.swift:328-354`
- Modify: `EchoCore/Localizable.xcstrings`
- Create: `EchoTests/PortableDeckImportCoordinatorTests.swift`
- Create: `EchoTests/PortableDeckSelectionResolverTests.swift`
- Modify: `EchoTests/SettingsExtractionTests.swift`
- Modify: `EchoTests/MacStudyParityTests.swift`
- Modify: `Echo.xcodeproj/project.pbxproj` only if target membership requires it

**Interfaces:**
- Consumes: a picked JSON URL or containing bundle-directory URL, optional active local audiobook ID, and library candidates with canonical source blocks.
- Produces: direct per-book import, global active-book import, or one target chooser; localized success/error presentation with imported/anchored/image/warning counts.

- [ ] **Step 1: Write coordinator and parity tests**

Test these states: legacy deck delegates to legacy import; portable deck plus active book imports immediately; portable deck without active book requests candidates; only books with canonical blocks appear; exact editions are not collapsed; choosing a candidate invokes the selected-target overload; cancel mutates nothing; security scope is balanced exactly once; success presentation includes all counts. Selection-resolver tests cover a direct JSON deck with no `imageFile`, a direct JSON deck with `imageFile` rejected as `bundleDirectoryRequired`, one top-level `*.echo-deck.json` in a selected directory, zero/multiple candidate JSON files, symlink candidates, nested candidate files, and a resolved deck URL escaping the selected directory.

Use this pure coordinator state:

```swift
enum PortableDeckImportRoute: Equatable, Sendable {
    case legacy
    case selectedBook(String)
    case chooseBook([DeckImportBookCandidate])
}

struct DeckImportBookCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let author: String?
}

struct ResolvedDeckSelection: Equatable, Sendable {
    let deckURL: URL
    let bundleRoot: URL
    let selectedDirectory: Bool
}
```

- [ ] **Step 2: Run coordinator/parity tests and verify RED**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckSelectionResolverTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImportCoordinatorTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/MacStudyParityTests
```

Expected: failures because the coordinator and selected-book actions do not exist.

- [ ] **Step 3: Implement one shared routing coordinator**

Implement the selection resolver as a pure file check:

```swift
nonisolated enum PortableDeckSelectionResolver {
    static func resolve(_ selectedURL: URL) throws -> ResolvedDeckSelection {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try selectedURL.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else {
            throw DeckImportError.unsafeDeckSelection
        }
        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(
                at: selectedURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let candidates = try children.filter { child in
                let childValues = try child.resourceValues(forKeys: keys)
                return childValues.isRegularFile == true
                    && childValues.isSymbolicLink != true
                    && child.lastPathComponent.hasSuffix(".echo-deck.json")
            }
            guard candidates.count == 1, let deckURL = candidates.first else {
                throw DeckImportError.bundleMustContainOneDeck(candidates.count)
            }
            return ResolvedDeckSelection(
                deckURL: deckURL,
                bundleRoot: selectedURL,
                selectedDirectory: true
            )
        }
        guard values.isRegularFile == true,
              selectedURL.lastPathComponent.hasSuffix(".json") else {
            throw DeckImportError.invalidDeckSelection
        }
        return ResolvedDeckSelection(
            deckURL: selectedURL,
            bundleRoot: selectedURL.deletingLastPathComponent(),
            selectedDirectory: false
        )
    }
}
```

Implement inspection without importing:

```swift
nonisolated struct PortableDeckImportCoordinator {
    func inspect(
        selection: ResolvedDeckSelection,
        activeAudiobookID: String?,
        db writer: DatabaseWriter
    ) throws -> PortableDeckImportRoute {
        let data = try Data(contentsOf: selection.deckURL)
        switch try ValidatedDeckImport.decode(data) {
        case .legacy:
            return .legacy
        case .portable(let deck):
            if deck.cards.contains(where: { $0.imageFile != nil }),
               !selection.selectedDirectory {
                throw DeckImportError.bundleDirectoryRequired
            }
            if let activeAudiobookID { return .selectedBook(activeAudiobookID) }
            let books = try writer.read { database in
                try AudiobookRecord.fetchAll(
                    database,
                    sql: """
                        SELECT a.* FROM audiobook a
                        WHERE a.is_available = 1
                          AND EXISTS (
                            SELECT 1 FROM epub_block b
                            WHERE b.audiobook_id = a.id
                          )
                        """
                )
            }
            let candidates = books.map {
                DeckImportBookCandidate(id: $0.id, title: $0.title, author: $0.author)
            }.sorted { left, right in
                let titleOrder = left.title.localizedStandardCompare(right.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                let authorOrder = (left.author ?? "").localizedStandardCompare(right.author ?? "")
                if authorOrder != .orderedSame { return authorOrder == .orderedAscending }
                return left.id < right.id
            }
            return .chooseBook(candidates)
        }
    }
}
```

Do not use edition-collapsing `LibraryService.books()`.

Keep the coordinator under `EchoCore/Services`, not `EchoCore/Views`, so filesystem-synchronized target membership does not pull SwiftUI UI into `echo-cli`.

- [ ] **Step 4: Wire direct and global actions**

Add **Import Study Deck for This Book** to iOS Book Settings and the active-book macOS surface. On iOS, guard `let targetAudiobookID = model.folderURL?.absoluteString`; when it is nil, show the existing no-book-loaded error and do not present the importer. Pass that unwrapped ID on iOS and `player.audiobookID` on macOS. Allow the importer to select `.json` or `.folder`; package instructions tell users to choose the containing bundle folder whenever mnemonic image files are present, preserving one file-picker step. The global importer inspects first, uses the active book if present, or presents a target picker. Preserve the old global legacy importer.

Balance security-scoped access around the entire inspect/import operation:

```swift
let didStart = url.startAccessingSecurityScopedResource()
defer {
    if didStart { url.stopAccessingSecurityScopedResource() }
}
```

The success message is localized and reports: `Imported %lld cards, %lld anchored, %lld images, %lld warnings.`

- [ ] **Step 5: Add localized strings and accessibility behavior**

Add these exact English and Dutch catalog values; use the English source text as the existing string-catalog key convention requires:

| English source/key | Dutch value |
|---|---|
| `Import Study Deck for This Book` | `Studiedeck voor dit boek importeren` |
| `Choose a Book for This Study Deck` | `Kies een boek voor dit studiedeck` |
| `Cancel` | `Annuleer` |
| `Import` | `Importeer` |
| `Select a local book before importing this portable study deck.` | `Selecteer een lokaal boek voordat je dit draagbare studiedeck importeert.` |
| `This study deck was made for a different edition. Choose the exact book used to create it.` | `Dit studiedeck is voor een andere editie gemaakt. Kies exact het boek waarmee het is gemaakt.` |
| `Card %lld has an invalid source anchor.` | `Kaart %lld heeft een ongeldige bronverwijzing.` |
| `Card %lld has an invalid image reference.` | `Kaart %lld heeft een ongeldige afbeeldingsverwijzing.` |
| `Choose the containing folder to import a study deck with image files.` | `Kies de bijbehorende map om een studiedeck met afbeeldingsbestanden te importeren.` |
| `Imported %lld cards, %lld anchored, %lld images, %lld warnings.` | `Geïmporteerd: %lld kaarten, %lld gekoppeld, %lld afbeeldingen, %lld waarschuwingen.` |

The picker uses semantic text styles, supports Dynamic Type, exposes book title plus author as one accessible row label, and gives the import button a text label rather than gesture-only handling. Unit tests assert both locales by temporarily selecting the localization bundle rather than relying on the developer machine's preferred language.

- [ ] **Step 6: Verify platform parity and commit**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckSelectionResolverTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/PortableDeckImportCoordinatorTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/SettingsExtractionTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only \
  FILTER=EchoTests/MacStudyParityTests
git diff --check
git add EchoCore/Services/PortableDeckImportCoordinator.swift \
  EchoCore/Services/PortableDeckSelectionResolver.swift \
  EchoCore/Views/SettingsView.swift EchoCore/Views/BookSettingsView.swift \
  'Echo macOS/Views/MacTriPaneView.swift' 'Echo macOS/Echo_macOSApp.swift' \
  EchoCore/Services/Library/LibraryService.swift \
  EchoCore/Localizable.xcstrings \
  EchoTests/PortableDeckImportCoordinatorTests.swift \
  EchoTests/PortableDeckSelectionResolverTests.swift \
  EchoTests/SettingsExtractionTests.swift EchoTests/MacStudyParityTests.swift \
  Echo.xcodeproj/project.pbxproj
git commit -m "feat: import study decks for selected books"
```

Stage `project.pbxproj` only if changed. Expected: all presentation/parity tests pass.

### Task 8: CLI Smoke, Real-Device Image Gate, Full Regression, and PR

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md` if it documents `echo-cli export-blocks`
- Create: `docs/testing/portable-study-deck-import.md`

**Interfaces:**
- Consumes: all prior tasks and the Explainer fixture generated from the same contract.
- Produces: reviewed Echo commit/PR, a known hosted-CI state, and a manual acceptance receipt for Mac/iPhone import.

- [ ] **Step 1: Document the contract and user flow**

Document `export-blocks` v2, `echo-canonical-blocks-v1`, selected-book binding, stable deck replacement, required declared images, legacy compatibility, and why mutable visibility/audio chapter mapping are excluded from identity. Add the exact Mac/iPhone manual flow and state that `.echo` archive packaging remains future work.

- [ ] **Step 2: Build the CLI and smoke-test a real v2 export**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
tmp="$(mktemp -d)"
.build/cli/Build/Products/Release/echo-cli export-blocks \
  --epub EchoTests/Fixtures/minimal-book.epub \
  --out "$tmp/blocks.json"
jq -e '
  .version == 2 and
  .sourceSignature.algorithm == "echo-canonical-blocks-v1" and
  (.sourceSignature.value | test("^sha256:[0-9a-f]{64}$")) and
  (.blocks | length > 0) and
  (all(.blocks[]; has("isFrontMatter")))
' "$tmp/blocks.json"
rm -rf "$tmp"
```

Expected: Release CLI builds, command exits 0, and `jq` exits 0.

- [ ] **Step 3: Run the focused portable regression set**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test \
  -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=EchoTest-iPhone-17' \
  -only-testing:EchoTests/EchoSourceSignatureTests \
  -only-testing:EchoTests/BlockExportDocumentTests \
  -only-testing:EchoTests/PortableDeckImportTests \
  -only-testing:EchoTests/PortableDeckPreflightTests \
  -only-testing:EchoTests/PortableDeckPersistenceTests \
  -only-testing:EchoTests/PortableDeckImageTests \
  -only-testing:EchoTests/PortableDeckStudyFlowTests \
  -only-testing:EchoTests/PortableDeckImportCoordinatorTests \
  -only-testing:EchoTests/DeckImportServiceTests \
  -only-testing:EchoTests/StudyDeckFileExporterTests \
  -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: every selected suite passes and the output reports a nonzero test count.

- [ ] **Step 4: Run full local verification**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build \
  -project Echo.xcodeproj -scheme 'Echo macOS' \
  -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
git diff --check
git status --short --branch
```

Expected: full tests pass, macOS and CLI build, diff check is silent, and only intended files are modified.

- [ ] **Step 5: Perform the Mac/iPhone manual acceptance gate**

Use the same final EPUB and portable deck bundle on both devices. Verify: correct-book import succeeds; wrong-book import fails with zero prior-deck mutation; reimport replaces rather than duplicates; imported cards appear in a normal study session; playback does not trigger them; grading schedules the next review; and an `imageAnchor` renders. For `imageFile`, select the containing bundle directory from Files on a physical iPhone and verify that the JSON plus sibling image import in one security-scoped session. This physical folder-selection test is a release blocker: if it fails, keep the Echo PR open and implement a reviewed in-scope bundle-access correction before claiming cross-device mnemonic-image support.

- [ ] **Step 6: Commit documentation, rebase, push, and open the ready PR**

Run:

```bash
git add docs/ARCHITECTURE.md README.md docs/testing/portable-study-deck-import.md
git commit -m "docs: document portable study deck imports"
git fetch origin
git rebase origin/nightly
git push -u origin codex/portable-study-deck-import
gh pr create --base nightly --head codex/portable-study-deck-import \
  --title "feat: import portable study decks" \
  --body-file /tmp/echo-ready-flashcards-pr.md
```

Before the command, write `/tmp/echo-ready-flashcards-pr.md` with the exact summary, tests, manual gate result, signature correction, and any known image-file limitation. Expected: rebase succeeds, branch pushes, and a ready PR URL is returned.

- [ ] **Step 7: Follow hosted checks to completion**

Run:

```bash
gh pr checks --watch --fail-fast
git status --short --branch
```

Expected: required checks pass. If a required check fails, inspect its job log, fix the concrete failure with a focused test, rebase/push with `--force-with-lease` only if the rebase rewrote an already-pushed branch, and rerun checks. Do not report the feature as complete while CI or the physical-device image gate is unknown.

## Cross-Repository Handoff

After the Echo PR is green and merged into `nightly`, record its exact merge SHA. The Explainer plan must use that exact SHA as the approved Echo provenance gate and must not claim `minimumCompatibleEchoRevision` before an intended tester can install a build containing it. The Explainer implementation may proceed in parallel through schema and authoring tests, but portable-package completion remains fail-closed until this Echo contract is available.
