# Mac Word-Timing Sidecars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GitHub issue #421 by exporting quality-preserving word timings from both Mac sidecar producers without corrupting multi-file audiobook timebases.

**Architecture:** Extend the optional sidecar word contract with per-word confidence, then add one pure `AlignmentSidecarAssembler` that joins anchors to ordered `word_timing` rows and applies the same offset to anchor and word times. The Mac DTW path will perform the word-refinement pass it currently omits; both Mac alignment and Mac narration will use the assembler. Single-container audio receives portable word-bearing sidecars, while multi-file folders are explicitly prevented from emitting a misleading cross-track sidecar until the format carries track identity.

**Tech Stack:** Swift 6, Swift Testing, GRDB, AVFoundation, WhisperKit, Xcode 26.6.

## Global Constraints

- Preserve iOS 18.0, macOS 15.0, and watchOS 11.0 deployment targets.
- Preserve Swift 6.0 and Main Actor default isolation.
- Add no third-party dependencies and make no visible UI changes.
- Keep legacy anchors-only JSON and existing synthesis-word JSON decodable in both directions.
- Treat generated `.alignment.json` files as local artefacts; never commit real-book sidecars.
- Run all `xcodebuild` and `make build|test` commands through `$HOME/.claude/bin/xcode-build-gate.sh --wait`; keep tests serial and do not add uncapped `-jobs`.
- Work from current `origin/nightly`, commit coherent Conventional Commit checkpoints, rebase onto current `origin/nightly`, and open a ready PR back to `nightly`.
- Do not close #421 until the implementation PR is merged and current hosted `Build gate + tests` is green.

## Audit Context

- #297 and #305 were already fixed by PR #321 and were tracker-cleanup items.
- #421 is the sole unresolved issue in the 2026-07-11 issue audit.
- PR #423 added optional `words` to the shared sidecar contract but explicitly left both Mac exporters anchors-only.
- `MacAlignmentService` currently materializes interpolated `word_timing` rows but never calls `TokenDTW.wordMatchesWithBisection` or `WordTimingMaterializer.refine`; the issue body's assumption that DTW rows already exist is stale.
- `FolderAudioScanner` queues each audio file separately under a folder-derived audiobook ID, so writing one portable sidecar from each zero-based track can overwrite prior track data and violate global monotonicity.

---

### Task 1: Preserve optional per-word quality through encode, verify, and import

**Files:**
- Modify: `EchoCore/Services/AlignmentSidecar.swift`
- Modify: `EchoCore/Services/WordTimingMaterializer.swift`
- Modify: `EchoCore/Services/EstimatedAlignmentSidecar.swift`
- Test: `EchoTests/AlignmentSidecarTests.swift`
- Test: `EchoTests/DocumentImportFinalizerTests.swift`
- Test: `EchoTests/EstimatedAlignmentSidecarTests.swift`

**Interfaces:**
- Produces: `AlignmentSidecar.Anchor.Word.init(word:start:end:confidence:)`, where `confidence` is optional.
- Produces: `AlignmentSidecar.write(_:forEPUB:)` for `[AlignmentSidecar.Anchor]`.
- Produces: sidecar import semantics in which a missing confidence retains legacy `0.9`, a valid `0...1` value is preserved, and an invalid value falls back conservatively to `0.5`.

- [ ] **Step 1: Add failing sidecar-contract tests.**

Add these cases to `AlignmentSidecarTests`:

```swift
@Test func wordConfidenceRoundTripsWhileLegacyWordsRemainCompatible() throws {
    let current = AlignmentSidecar.Anchor(
        blockId: "s0-b0", timestamp: 10, confidence: 0.7,
        words: [
            .init(word: "matched", start: 10, end: 10.4, confidence: 0.85),
            .init(word: "estimated", start: 10.4, end: 10.9, confidence: 0.5),
        ])
    let decoded = try AlignmentSidecar.decode(AlignmentSidecar.encode([current]))
    #expect(decoded == [current])

    let legacy = Data(
        #"[{"blockId":"s0-b0","timestamp":10,"words":[{"word":"legacy","start":10,"end":10.4}]}]"#.utf8)
    #expect(try AlignmentSidecar.decode(legacy)[0].words?[0].confidence == nil)
}

@Test func anchorWriteOverloadWritesPortableWordBearingSidecar() throws {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "sidecar-write-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let epub = folder.appending(path: "Book.epub")
    let anchors = [
        AlignmentSidecar.Anchor(
            blockId: "s0-b0", timestamp: 2, confidence: 0.85,
            words: [.init(word: "Book", start: 2, end: 2.4, confidence: 0.85)])
    ]
    let url = try AlignmentSidecar.write(anchors, forEPUB: epub)
    #expect(try AlignmentSidecar.decode(Data(contentsOf: url)) == anchors)
}
```

- [ ] **Step 2: Add failing importer and verifier tests.**

In the existing `sidecarWordsBecomeSidecarSourcedWordTimingRows` test, give the first anchor's three words explicit confidences and leave the second anchor's words without confidence:

```swift
words: [
    AlignmentSidecar.Anchor.Word(
        word: "one", start: 0.0, end: 0.4, confidence: 0.85),
    AlignmentSidecar.Anchor.Word(
        word: "two", start: 0.4, end: 0.9, confidence: 0.5),
    AlignmentSidecar.Anchor.Word(
        word: "three", start: 0.9, end: 1.5, confidence: 0.85),
]

// After finalize:
#expect(first.map(\.confidence) == [0.85, 0.5, 0.85])
#expect(first.allSatisfy { $0.source == "sidecar" })
#expect(second.allSatisfy { $0.confidence == 0.9 })
```

The second anchor in that test is the legacy compatibility case: its omitted values must continue to import at `0.9`.

In `EstimatedAlignmentSidecarTests`, add an anchor whose word confidence is `1.2` and assert that verification reports:

```swift
.wordConfidenceOutOfRange(blockID: "s0-b0", wordIndex: 0, confidence: 1.2)
```

- [ ] **Step 3: Run the focused suites and confirm the new assertions fail.**

Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test \
  -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/EchoIssue421DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:EchoTests/AlignmentSidecarTests \
  -only-testing:EchoTests/DocumentImportFinalizerTests \
  -only-testing:EchoTests/EstimatedAlignmentSidecarTests
```

Expected: failures because `Word.confidence`, the `[Anchor]` write overload, quality-preserving import, and verifier issue do not exist yet.

- [ ] **Step 4: Extend the optional word contract.**

Change `AlignmentSidecar.Anchor.Word` to:

```swift
struct Word: Codable, Equatable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?

    init(
        word: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double? = nil
    ) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
```

Add the shared write overload and make the record overload call it:

```swift
@discardableResult
static func write(_ anchors: [Anchor], forEPUB epubURL: URL) throws -> URL {
    let destination = url(forEPUB: epubURL)
    try encode(anchors).write(to: destination, options: .atomic)
    return destination
}

@discardableResult
static func write(
    _ anchors: [AlignmentAnchorRecord],
    forEPUB epubURL: URL
) throws -> URL {
    try write(
        anchors.map {
            Anchor(
                blockId: portableSuffix(of: $0.epubBlockID),
                timestamp: $0.audioTime,
                confidence: 1.0)
        },
        forEPUB: epubURL)
}
```

- [ ] **Step 5: Preserve valid confidence on import.**

In `WordTimingMaterializer`, replace the fixed `sidecarConfidence` assignment inside `applySidecarWords` with:

```swift
private static let legacySidecarConfidence = 0.9
private static let invalidSidecarConfidence = 0.5

private static func importedSidecarConfidence(
    _ confidence: Double?
) -> Double {
    guard let confidence else { return legacySidecarConfidence }
    guard confidence.isFinite, (0.0...1.0).contains(confidence) else {
        return invalidSidecarConfidence
    }
    return confidence
}
```

Then set:

```swift
updated.confidence = importedSidecarConfidence(word.confidence)
updated.source = "sidecar"
```

- [ ] **Step 6: Validate present confidence values.**

Add this verifier issue and its description:

```swift
case wordConfidenceOutOfRange(
    blockID: String,
    wordIndex: Int,
    confidence: Double
)
```

Inside `wordIssues`, add:

```swift
if let confidence = word.confidence,
    !confidence.isFinite || !(0.0...1.0).contains(confidence)
{
    issues.append(
        .wordConfidenceOutOfRange(
            blockID: anchor.blockId,
            wordIndex: index,
            confidence: confidence))
}
```

- [ ] **Step 7: Re-run the three suites and confirm they pass.**

Run the Step 3 command. Expected: all selected tests pass with no failures.

- [ ] **Step 8: Commit the sidecar-contract checkpoint.**

```bash
git add EchoCore/Services/AlignmentSidecar.swift \
  EchoCore/Services/WordTimingMaterializer.swift \
  EchoCore/Services/EstimatedAlignmentSidecar.swift \
  EchoTests/AlignmentSidecarTests.swift \
  EchoTests/DocumentImportFinalizerTests.swift \
  EchoTests/EstimatedAlignmentSidecarTests.swift
git commit -m "feat(alignment): preserve sidecar word confidence"
```

---

### Task 2: Add one pure anchor-and-word sidecar assembler

**Files:**
- Create: `EchoCore/Services/AlignmentSidecarAssembler.swift`
- Create: `EchoTests/AlignmentSidecarAssemblerTests.swift`

**Interfaces:**
- Produces: `AlignmentSidecarAssembler.assemble(anchors:wordRows:tokenCountByBlockID:offsetByBlockID:) -> [AlignmentSidecar.Anchor]`.
- Guarantees: portable block IDs; one words array per block; word-index ordering; token-count safety; identical anchor/word offset; mean per-word anchor confidence; monotonic output ordering.

- [ ] **Step 1: Write failing pure assembler tests.**

Cover these exact behaviors:

```swift
@Suite struct AlignmentSidecarAssemblerTests {
    private func makeAnchor(
        blockID: String,
        time: TimeInterval,
        id: String = UUID().uuidString
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id,
            audiobookID: "book",
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
            note: nil,
            createdAt: "2026-07-11T00:00:00Z",
            modifiedAt: nil)
    }

    private func makeWord(
        blockID: String,
        index: Int,
        word: String = "one",
        start: TimeInterval = 4,
        end: TimeInterval = 4.4,
        confidence: Double = 0.5,
        source: String = "interpolated"
    ) -> WordTimingRecord {
        WordTimingRecord(
            audiobookID: "book",
            epubBlockID: blockID,
            wordIndex: index,
            word: word,
            audioStartTime: start,
            audioEndTime: end,
            confidence: confidence,
            source: source)
    }

    @Test func assemblesMixedDTWAndInterpolatedRowsWithOneSharedOffset() {
        let anchor = makeAnchor(blockID: "epub-book-s1-b2", time: 3)
        let rows = [
            makeWord(blockID: anchor.epubBlockID, index: 1, word: "two", start: 3.4, end: 3.8, confidence: 0.5, source: "interpolated"),
            makeWord(blockID: anchor.epubBlockID, index: 0, word: "one", start: 3.0, end: 3.4, confidence: 0.85, source: "dtw"),
        ]

        let result = AlignmentSidecarAssembler.assemble(
            anchors: [anchor],
            wordRows: rows,
            tokenCountByBlockID: [anchor.epubBlockID: 2],
            offsetByBlockID: [anchor.epubBlockID: 100])

        #expect(result[0].blockId == "s1-b2")
        #expect(result[0].timestamp == 103)
        #expect(abs((result[0].confidence ?? 0) - 0.675) < 0.000_001)
        #expect(result[0].words?.map(\.word) == ["one", "two"])
        #expect(result[0].words?.map(\.start) == [103.0, 103.4])
        #expect(result[0].words?.map(\.confidence) == [0.85, 0.5])
    }

    @Test func countMismatchKeepsAnchorButOmitsWordsAndQuality() {
        let anchor = makeAnchor(blockID: "epub-book-s0-b0", time: 4)
        let result = AlignmentSidecarAssembler.assemble(
            anchors: [anchor],
            wordRows: [makeWord(blockID: anchor.epubBlockID, index: 0)],
            tokenCountByBlockID: [anchor.epubBlockID: 2])
        #expect(result[0].words == nil)
        #expect(result[0].confidence == nil)
    }

    @Test func outputSortsByOffsetTimestampAndAttachesWordsOnlyOncePerBlock() {
        let repeatedBlock = "epub-book-s1-b2"
        let earlierBlock = "epub-book-s0-b0"
        let anchors = [
            makeAnchor(blockID: repeatedBlock, time: 4, id: "first"),
            makeAnchor(blockID: earlierBlock, time: 10, id: "earlier-after-offset"),
            makeAnchor(blockID: repeatedBlock, time: 5, id: "duplicate"),
        ]
        let rows = [
            makeWord(blockID: repeatedBlock, index: 0, start: 4, end: 4.4),
            makeWord(blockID: earlierBlock, index: 0, start: 10, end: 10.4),
        ]
        let result = AlignmentSidecarAssembler.assemble(
            anchors: anchors,
            wordRows: rows,
            tokenCountByBlockID: [repeatedBlock: 1, earlierBlock: 1],
            offsetByBlockID: [repeatedBlock: 20, earlierBlock: 0])

        #expect(result.map(\.blockId) == ["s0-b0", "s1-b2", "s1-b2"])
        #expect(result.map(\.timestamp) == [10, 24, 25])
        #expect(result.compactMap(\.words).count == 2)
        #expect(result.filter { $0.blockId == "s1-b2" }.compactMap(\.words).count == 1)
    }
}
```

- [ ] **Step 2: Run the new suite and confirm it fails to compile because the assembler is absent.**

Use the Task 1 command with `-only-testing:EchoTests/AlignmentSidecarAssemblerTests`.

- [ ] **Step 3: Implement the pure assembler.**

Create `AlignmentSidecarAssembler.swift` with this implementation:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum AlignmentSidecarAssembler {
    static func assemble(
        anchors: [AlignmentAnchorRecord],
        wordRows: [WordTimingRecord],
        tokenCountByBlockID: [String: Int],
        offsetByBlockID: [String: TimeInterval] = [:]
    ) -> [AlignmentSidecar.Anchor] {
        let rowsByBlockID = Dictionary(grouping: wordRows, by: \.epubBlockID)
        let sortedAnchors = anchors.sorted {
            let lhs = $0.audioTime + (offsetByBlockID[$0.epubBlockID] ?? 0)
            let rhs = $1.audioTime + (offsetByBlockID[$1.epubBlockID] ?? 0)
            if lhs != rhs { return lhs < rhs }
            return $0.epubBlockID < $1.epubBlockID
        }
        var wordBearingBlocks: Set<String> = []

        return sortedAnchors.map { anchor in
            let offset = offsetByBlockID[anchor.epubBlockID] ?? 0
            let rows = (rowsByBlockID[anchor.epubBlockID] ?? [])
                .sorted { $0.wordIndex < $1.wordIndex }
            let expectedCount = tokenCountByBlockID[anchor.epubBlockID]
            let canAttachWords =
                !rows.isEmpty
                && rows.count == expectedCount
                && wordBearingBlocks.insert(anchor.epubBlockID).inserted
            let words: [AlignmentSidecar.Anchor.Word]? = canAttachWords
                ? rows.map {
                    .init(
                        word: $0.word,
                        start: $0.audioStartTime + offset,
                        end: $0.audioEndTime + offset,
                        confidence: $0.confidence)
                }
                : nil
            let confidence: Double? = canAttachWords
                ? rows.map(\.confidence).reduce(0, +) / Double(rows.count)
                : nil

            return AlignmentSidecar.Anchor(
                blockId: AlignmentSidecar.portableSuffix(of: anchor.epubBlockID),
                timestamp: anchor.audioTime + offset,
                confidence: confidence,
                words: words)
        }
    }
}
```

- [ ] **Step 4: Run the assembler and contract suites.**

Run the Task 1 command with these selectors:

```text
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/AlignmentSidecarTests
EchoTests/EstimatedAlignmentSidecarTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the assembler checkpoint.**

```bash
git add EchoCore/Services/AlignmentSidecarAssembler.swift \
  EchoTests/AlignmentSidecarAssemblerTests.swift
git commit -m "feat(alignment): assemble portable word sidecars"
```

---

### Task 3: Refine and export Mac DTW word timings

**Files:**
- Modify: `Echo macOS/Services/MacAlignmentService.swift`
- Create: `EchoTests/MacAlignmentSidecarWiringTests.swift`

**Interfaces:**
- Consumes: `AlignmentSidecarAssembler.assemble` from Task 2.
- Produces: `MacAlignmentService.align(..., exportPortableSidecar: Bool = true)`.
- Produces: DTW-refined `word_timing` rows before sidecar export.

- [ ] **Step 1: Add a failing macOS wiring contract test.**

Use the repo's `MacSource` convention because the macOS target is not linked into `EchoTests`:

```swift
@Suite struct MacAlignmentSidecarWiringTests {
    @Test func alignmentRefinesWordsBeforeSharedSidecarAssembly() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(source.contains("TokenDTW.wordMatchesWithBisection"))
        #expect(source.contains("WordTimingMaterializer.refine"))
        #expect(source.contains("AlignmentSidecarAssembler.assemble"))
        #expect(source.contains("AlignmentSidecar.write(sidecarAnchors"))
        #expect(!source.contains("AlignmentSidecar.write(records"))
    }
}
```

- [ ] **Step 2: Run the wiring test and confirm it fails.**

Run the Task 1 command with `-only-testing:EchoTests/MacAlignmentSidecarWiringTests`.

- [ ] **Step 3: Add the missing DTW word-refinement pass.**

Immediately after `insertAnchors(records)` in `MacAlignmentService.align`, add:

```swift
let wordMatches = TokenDTW.wordMatchesWithBisection(
    epub: epubTokens,
    audio: audioTokens)
let matchesByBlock = Dictionary(grouping: wordMatches, by: \.blockID)
try WordTimingMaterializer.refine(
    audiobookID: audiobookID,
    dtwMatchesByBlock: matchesByBlock,
    writer: dbService.writer)
```

- [ ] **Step 4: Replace the anchors-only writer with shared assembly.**

Change the signature to accept `exportPortableSidecar: Bool = true`. When true, fetch all book words, derive token counts from the parsed blocks, assemble, and write:

```swift
if exportPortableSidecar {
    do {
        let wordRows = try WordTimingDAO(db: dbService.writer)
            .words(forAudiobook: audiobookID)
            .filter { $0.source == "dtw" || $0.source == "interpolated" }
        let tokenCounts = Dictionary(
            uniqueKeysWithValues: parsed.blocks.map {
                ($0.id, WordTokenizer.words(in: $0.text ?? "").count)
            })
        let sidecarAnchors = AlignmentSidecarAssembler.assemble(
            anchors: records,
            wordRows: wordRows,
            tokenCountByBlockID: tokenCounts)
        let sidecarURL = try AlignmentSidecar.write(sidecarAnchors, forEPUB: epubURL)
        logger.info("Wrote alignment sidecar: \(sidecarURL.lastPathComponent)")
    } catch {
        logger.error("Failed to write alignment sidecar: \(error.localizedDescription)")
    }
}
```

The assembler's mean word confidence replaces the false `1.0`: a mixed block reports a value between interpolation `0.5` and DTW `0.85`; a block whose word count cannot be trusted has no words and no confidence.

- [ ] **Step 5: Run the wiring, assembler, and word-refiner suites.**

Select:

```text
EchoTests/MacAlignmentSidecarWiringTests
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/WordTimingRefinerTests
EchoTests/WordTimingMaterializerTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Build the macOS target.**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build \
  -project Echo.xcodeproj -scheme 'Echo macOS' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/EchoIssue421MacDerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet
```

Expected: `** BUILD SUCCEEDED **` and exit code 0.

- [ ] **Step 7: Commit the Mac alignment checkpoint.**

```bash
git add 'Echo macOS/Services/MacAlignmentService.swift' \
  EchoTests/MacAlignmentSidecarWiringTests.swift
git commit -m "feat(mac): export DTW word timing sidecars"
```

---

### Task 4: Route Mac narration sidecars through the shared assembler

**Files:**
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/MacAlignmentSidecarWiringTests.swift`

**Interfaces:**
- Consumes: the Task 2 assembler.
- Produces: Mac-narrated sidecars with synthesis words and the same cumulative chapter offset applied to anchors and every word range.

- [ ] **Step 1: Extend the failing wiring test.**

Add:

```swift
@Test func batchNarrationUsesSharedWordAssembler() throws {
    let source = try MacSource.read("Services/MacBatchProcessingService.swift")
    #expect(source.contains("AlignmentSidecarAssembler.assemble"))
    #expect(source.contains("$0.source == \"synthesis\""))
    #expect(source.contains("offsetByBlockID"))
    #expect(!source.contains("timestamp: a.audioTime + off, confidence: 1.0"))
}
```

- [ ] **Step 2: Run the wiring test and confirm this new case fails.**

- [ ] **Step 3: Replace the hand-built narration array.**

Inside the narration sidecar `do` block, keep the existing track-duration accumulation, then build per-block offsets and fetch anchors, words, and block token counts:

```swift
let offsetByBlockID = Dictionary(
    uniqueKeysWithValues: chapterOfBlock.compactMap { blockID, chapterIndex in
        offset[chapterIndex].map { (blockID, $0) }
    })
let anchors = ((try? AlignmentAnchorDAO(db: dbService.writer).anchors(for: audiobookID)) ?? [])
    .filter { $0.source == AlignmentAnchorRecord.Source.synthesized.rawValue }
let words = ((try? WordTimingDAO(db: dbService.writer).words(forAudiobook: audiobookID)) ?? [])
    .filter { $0.source == "synthesis" }
let tokenCounts = Dictionary(
    uniqueKeysWithValues: blocks.map {
        ($0.id, WordTokenizer.words(in: $0.text ?? "").count)
    })
let sidecar = AlignmentSidecarAssembler.assemble(
    anchors: anchors,
    wordRows: words,
    tokenCountByBlockID: tokenCounts,
    offsetByBlockID: offsetByBlockID)
if !sidecar.isEmpty {
    let sidecarURL = try AlignmentSidecar.write(sidecar, forEPUB: epubURL)
    logger.info("Wrote narration sidecar: \(sidecarURL.lastPathComponent, privacy: .public)")
}
```

Use the `blocks` value already loaded for the narration job; do not reparse the EPUB.

- [ ] **Step 4: Run the wiring, assembler, headless-runner, and import suites.**

Select:

```text
EchoTests/MacAlignmentSidecarWiringTests
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/HeadlessNarrationRunnerTests
EchoTests/DocumentImportFinalizerTests
```

Expected: all selected tests pass and existing CLI narration semantics remain unchanged.

- [ ] **Step 5: Rebuild `Echo macOS`.**

Run Task 3 Step 6. Expected: build succeeds.

- [ ] **Step 6: Commit the Mac narration checkpoint.**

```bash
git add 'Echo macOS/Services/MacBatchProcessingService.swift' \
  EchoTests/MacAlignmentSidecarWiringTests.swift
git commit -m "feat(mac): include synthesis words in batch sidecars"
```

---

### Task 5: Make multi-file timebase safety explicit and document the shipped boundary

**Files:**
- Modify: `Echo macOS/Services/FolderAudioScanner.swift`
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/MacAlignmentSidecarWiringTests.swift`
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `FolderAudioScanner.audioFilesAlongside(_:) -> [URL]`.
- Consumes: `MacAlignmentService.align(..., exportPortableSidecar:)` from Task 3.
- Guarantees: a folder with multiple direct audio siblings does not emit a portable sidecar whose timestamps reset or overwrite another track.

- [ ] **Step 1: Add a failing timebase-policy wiring test.**

```swift
@Test func multiFileFoldersDisablePortableSidecarExport() throws {
    let scanner = try MacSource.read("Services/FolderAudioScanner.swift")
    let batch = try MacSource.read("Services/MacBatchProcessingService.swift")
    #expect(scanner.contains("static func audioFilesAlongside"))
    #expect(batch.contains("let exportPortableSidecar = siblingAudioFiles.count == 1"))
    #expect(batch.contains("exportPortableSidecar: exportPortableSidecar"))
    #expect(batch.contains("portable sidecar skipped for multi-file book"))
}
```

- [ ] **Step 2: Run the wiring suite and confirm this case fails.**

- [ ] **Step 3: Add the direct-sibling helper.**

In `FolderAudioScanner`, centralize the extension set and add:

```swift
private static let audioExtensions = Set(["m4b", "mp3", "m4a", "aax", "wav", "flac"])

static func audioFilesAlongside(_ audioURL: URL) -> [URL] {
    let directory = audioURL.deletingLastPathComponent()
    let siblings = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles)) ?? []
    return siblings
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}
```

Use the same `audioExtensions` constant in `scanForAudioFiles`.

- [ ] **Step 4: Gate only the portable export.**

Before calling `alignmentService.align`, add:

```swift
let siblingAudioFiles = FolderAudioScanner.audioFilesAlongside(url)
let exportPortableSidecar = siblingAudioFiles.count == 1
if !exportPortableSidecar {
    logger.warning(
        "Alignment will remain Mac-local; portable sidecar skipped for multi-file book because alignment.json does not carry track identity"
    )
}
try await alignmentService.align(
    audiobookID: audiobookID,
    audioURL: url,
    epubURL: epubURL,
    dbService: dbService,
    exportPortableSidecar: exportPortableSidecar)
```

Continue to align and materialize local word timing; only the unsafe cross-device file write is suppressed.

- [ ] **Step 5: Update durable architecture and release notes.**

In `ARCHITECTURE.md` replace “The Mac DTW paths remain anchors-only” with a paragraph that states:

- Mac DTW now exports mixed DTW/interpolated words with optional per-word confidence.
- Mac narration exports synthesis words through the same assembler.
- Missing word confidence is legacy synthesis quality `0.9`; present confidence survives import.
- Anchor confidence is the mean attached word confidence rather than a hardcoded probability.
- Multi-file folders remain Mac-local because the current portable contract lacks track identity; the exporter logs and skips instead of writing a corrupt sidecar.

Add the same behavior, compatibility statement, and multi-file boundary under the current Unreleased section in `CHANGELOG.md`.

- [ ] **Step 6: Run all focused suites.**

Run one serial test invocation selecting:

```text
EchoTests/AlignmentSidecarTests
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/DocumentImportFinalizerTests
EchoTests/EstimatedAlignmentSidecarTests
EchoTests/MacAlignmentSidecarWiringTests
EchoTests/WordTimingMaterializerTests
EchoTests/WordTimingRefinerTests
EchoTests/HeadlessNarrationRunnerTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 7: Run final builds and static checks.**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build \
  -project Echo.xcodeproj -scheme 'Echo macOS' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/EchoIssue421MacDerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet

"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build \
  -project Echo.xcodeproj -scheme echo-cli \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/EchoIssue421CLIDerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet

git diff --check origin/nightly...HEAD
swift format lint --recursive \
  EchoCore/Services/AlignmentSidecar.swift \
  EchoCore/Services/AlignmentSidecarAssembler.swift \
  EchoCore/Services/WordTimingMaterializer.swift \
  EchoCore/Services/EstimatedAlignmentSidecar.swift \
  'Echo macOS/Services/MacAlignmentService.swift' \
  'Echo macOS/Services/MacBatchProcessingService.swift' \
  'Echo macOS/Services/FolderAudioScanner.swift' \
  EchoTests/AlignmentSidecarTests.swift \
  EchoTests/AlignmentSidecarAssemblerTests.swift \
  EchoTests/DocumentImportFinalizerTests.swift \
  EchoTests/EstimatedAlignmentSidecarTests.swift \
  EchoTests/MacAlignmentSidecarWiringTests.swift
```

Expected: both builds exit 0; `git diff --check` is silent; formatter lint reports no actionable errors in changed files.

- [ ] **Step 8: Commit documentation and safety policy.**

```bash
git add 'Echo macOS/Services/FolderAudioScanner.swift' \
  'Echo macOS/Services/MacBatchProcessingService.swift' \
  EchoTests/MacAlignmentSidecarWiringTests.swift \
  ARCHITECTURE.md CHANGELOG.md
git commit -m "docs(alignment): define Mac sidecar timebase safety"
```

- [ ] **Step 9: Publish and close the loop.**

```bash
git fetch origin nightly
git rebase origin/nightly
git push -u origin codex/mac-word-timing-sidecars
gh pr create --base nightly --head codex/mac-word-timing-sidecars \
  --title "feat(alignment): export Mac word timing sidecars" \
  --body-file /tmp/echo-issue-421-pr.md
```

The PR body must say `Fixes #421`, list the single-container support boundary, and include focused test/build counts. Watch hosted checks with `gh pr checks`; if `Build gate + tests` fails, inspect the failing job logs before changing code. After the PR merges, re-read #421, add a closure explanation that names the confidence contract and multi-file safety behavior, close it as completed, and verify `gh issue list --state open` no longer contains #421.

## Self-Review

- **Spec coverage:** Tasks 1–4 cover word export, quality preservation, honest anchor confidence, both Mac producers, importer compatibility, and verifier behavior. Task 5 resolves the multi-file ambiguity safely without inventing a track-aware sidecar contract.
- **Placeholder scan:** The plan contains concrete file paths, signatures, code, commands, expected outcomes, and commit boundaries; no implementation step is left undefined.
- **Type consistency:** Both producers consume the single assembler signature defined in Task 2. `Word.confidence` stays optional end-to-end. `exportPortableSidecar` is introduced in Task 3 and consumed by Task 5.
