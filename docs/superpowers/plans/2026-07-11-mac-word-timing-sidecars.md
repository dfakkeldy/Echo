# Mac Word-Timing Sidecars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GitHub issue #421 by exporting quality-preserving word timings from both Mac sidecar producers without blocking the Mac UI or corrupting multi-file audiobook state.

**Architecture:** Reuse the already-tested `AutoAlignmentWorker` for normalized, cancellable DTW work on the concurrent executor; extract a DB-backed persistence helper so the Mac and source-backed paths share “replace anchors → materialize → refine” ordering; and add one pure sidecar assembler for anchors, ordered words, confidence, and offsets. Mac DTW exports unknown anchor confidence as `nil` rather than inventing a probability, while Mac narration exports exact anchor confidence `1.0`. Because the current portable sidecar lacks track identity and the existing per-file queue overwrites one folder-derived audiobook, multi-file alignment fails before import or database mutation with a clear error.

**Tech Stack:** Swift 6, Swift Testing, GRDB, AVFoundation, WhisperKit, Xcode 26.6.

## Global Constraints

- Preserve iOS 18.0, macOS 15.0, and watchOS 11.0 deployment targets.
- Preserve Swift 6.0 and Main Actor default isolation.
- Add no third-party dependencies and make no visible UI changes.
- Keep legacy anchors-only JSON and existing synthesis-word JSON decodable in both directions.
- Treat generated `.alignment.json` files as local artefacts; never commit real-book sidecars.
- Run every `xcodebuild` and `make build|test` command through `$HOME/.claude/bin/xcode-build-gate.sh --wait`; keep tests serial and do not add uncapped `-jobs`.
- Work from current `origin/nightly`, commit coherent Conventional Commit checkpoints, rebase onto current `origin/nightly`, and open a ready PR back to `nightly`.
- Do not close #421 until its implementation PR is merged and current hosted `Build gate + tests` is green.

## Audit Context

- #297 and #305 were already fixed by PR #321 and were closed during the 2026-07-11 tracker-cleanup pass.
- #421 is the sole unresolved issue from that audit.
- PR #423 added optional sidecar `words`, import, and verification, but explicitly left both Mac exporters anchors-only.
- `MacAlignmentService` currently passes whole paragraphs and mostly raw Whisper words into token-level DTW, runs synchronous DTW from an `@MainActor` type, and never performs `WordTimingMaterializer.refine`.
- `FolderAudioScanner` currently queues sibling tracks separately under one folder-derived audiobook ID; each alignment replaces the previous automatic anchors and word rows. Merely skipping the sidecar write would still corrupt Mac-local state.

---

### Task 1: Preserve optional per-word quality through encode, verification, and import

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
- Produces: import semantics where missing confidence retains legacy synthesis quality `0.9`, valid `0...1` confidence is preserved, and invalid confidence falls back conservatively to `0.5`.

- [ ] **Step 1: Add failing contract tests.**

Add to `AlignmentSidecarTests`:

```swift
@Test func wordConfidenceRoundTripsWhileLegacyWordsRemainCompatible() throws {
    let current = AlignmentSidecar.Anchor(
        blockId: "s0-b0", timestamp: 10, confidence: nil,
        words: [
            .init(word: "matched", start: 10, end: 10.4, confidence: 0.85),
            .init(word: "estimated", start: 10.4, end: 10.9, confidence: 0.5),
        ])
    #expect(try AlignmentSidecar.decode(AlignmentSidecar.encode([current])) == [current])

    let legacy = Data(
        #"[{"blockId":"s0-b0","timestamp":10,"words":[{"word":"legacy","start":10,"end":10.4}]}]"#.utf8)
    #expect(try AlignmentSidecar.decode(legacy)[0].words?[0].confidence == nil)
}

@Test func anchorWriteOverloadWritesWordBearingSidecar() throws {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "sidecar-write-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let epub = folder.appending(path: "Book.epub")
    let anchors = [
        AlignmentSidecar.Anchor(
            blockId: "s0-b0", timestamp: 2, confidence: nil,
            words: [.init(word: "Book", start: 2, end: 2.4, confidence: 0.85)])
    ]
    let url = try AlignmentSidecar.write(anchors, forEPUB: epub)
    #expect(try AlignmentSidecar.decode(Data(contentsOf: url)) == anchors)
}
```

In `DocumentImportFinalizerTests.sidecarWordsBecomeSidecarSourcedWordTimingRows`, assign explicit confidences `[0.85, 0.5, 0.85]` to the first anchor's words, leave the second anchor's words without confidence, and assert:

```swift
#expect(first.map(\.confidence) == [0.85, 0.5, 0.85])
#expect(first.allSatisfy { $0.source == "sidecar" })
#expect(second.allSatisfy { $0.confidence == 0.9 })
```

In `EstimatedAlignmentSidecarTests`, verify that a present value `1.2` produces:

```swift
.wordConfidenceOutOfRange(blockID: "s0-b0", wordIndex: 0, confidence: 1.2)
```

- [ ] **Step 2: Run the focused suites and confirm failure.**

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

Expected: failures because per-word confidence, the `[Anchor]` writer, quality-preserving import, and the verifier issue do not exist.

- [ ] **Step 3: Extend the optional word contract and writer.**

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

Add:

```swift
@discardableResult
static func write(_ anchors: [Anchor], forEPUB epubURL: URL) throws -> URL {
    let destination = url(forEPUB: epubURL)
    try encode(anchors).write(to: destination, options: .atomic)
    return destination
}
```

Keep the record-based overload for legacy callers, but route its mapped `[Anchor]` through this writer.

- [ ] **Step 4: Preserve valid confidence during import.**

In `WordTimingMaterializer` add:

```swift
private static func importedSidecarConfidence(_ confidence: Double?) -> Double {
    guard let confidence else { return 0.9 }
    guard confidence.isFinite, (0.0...1.0).contains(confidence) else { return 0.5 }
    return confidence
}
```

Inside `applySidecarWords`, set:

```swift
updated.confidence = importedSidecarConfidence(word.confidence)
updated.source = "sidecar"
```

- [ ] **Step 5: Validate present confidence values.**

Add the verifier case:

```swift
case wordConfidenceOutOfRange(
    blockID: String,
    wordIndex: Int,
    confidence: Double)
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

- [ ] **Step 6: Re-run the Task 1 suites and commit.**

Expected: all selected tests pass.

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

### Task 2: Share DB-backed DTW persistence and refinement

**Files:**
- Create: `EchoCore/Services/DTWAlignmentPersistence.swift`
- Modify: `EchoCore/Services/SourceBackedAlignmentCoordinator.swift`
- Create: `EchoTests/DTWAlignmentPersistenceTests.swift`
- Modify: `EchoTests/SourceBackedAlignmentCoordinatorTests.swift`

**Interfaces:**
- Consumes: selected `TokenDTW.AnchorCandidate` values and grouped `TokenDTW.WordMatch` values.
- Produces: `DTWAlignmentPersistence.replaceAndRefine(audiobookID:source:note:selectedCandidates:wordMatchesByBlock:writer:) -> [AlignmentAnchorRecord]`.
- Guarantees: clear only the named automatic source; write anchors; materialize baseline words; refine matched words; preserve unrelated human/source anchors.

- [ ] **Step 1: Write a failing DB-backed test.**

Create an in-memory `DatabaseService`; insert audiobook `book`, two text blocks (`alpha bravo charlie`, `delta echo foxtrot`), one prior `.transcriptAlignment` anchor, and one `.moveToNow` human anchor. Call the new helper with a selected candidate for the first block and three `WordMatch` values at `10.0`, `10.4`, and `10.8`. Assert:

```swift
#expect(records.count == 1)
#expect(records[0].source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue)
let words = try WordTimingDAO(db: database.writer)
    .words(forAudiobook: "book", blockID: firstBlock.id)
#expect(words.prefix(3).allSatisfy { $0.source == "dtw" })
#expect(words.prefix(3).map(\.confidence) == [0.85, 0.85, 0.85])
let anchors = try AlignmentAnchorDAO(db: database.writer).anchors(for: "book")
#expect(anchors.contains { $0.source == AlignmentAnchorRecord.Source.moveToNow.rawValue })
#expect(anchors.filter { $0.source == AlignmentAnchorRecord.Source.transcriptAlignment.rawValue }.count == 1)
```

Run `EchoTests/DTWAlignmentPersistenceTests`; expected: compile failure because the helper does not exist.

- [ ] **Step 2: Implement the shared persistence order.**

Create:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

@MainActor enum DTWAlignmentPersistence {
    static func replaceAndRefine(
        audiobookID: String,
        source: AlignmentAnchorRecord.Source,
        note: String,
        selectedCandidates: [TokenDTW.AnchorCandidate],
        wordMatchesByBlock: [String: [TokenDTW.WordMatch]],
        writer: DatabaseWriter
    ) throws -> [AlignmentAnchorRecord] {
        let sourceValue = source.rawValue
        _ = try AlignmentAnchorDAO(db: writer)
            .deleteAnchors(for: audiobookID, source: sourceValue)
        guard !selectedCandidates.isEmpty else { return [] }

        let createdAt = AlignmentService.isoFormatter.string(from: Date())
        let records = selectedCandidates.map { candidate in
            AlignmentAnchorRecord(
                id: UUID().uuidString,
                audiobookID: audiobookID,
                epubBlockID: candidate.blockID,
                audioTime: candidate.time,
                audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: sourceValue,
                note: note,
                createdAt: createdAt,
                modifiedAt: nil)
        }
        let service = AlignmentService(db: writer, audiobookID: audiobookID)
        try service.insertAnchors(records)
        try WordTimingMaterializer.refine(
            audiobookID: audiobookID,
            dtwMatchesByBlock: wordMatchesByBlock,
            writer: writer)
        return records
    }
}
```

- [ ] **Step 3: Refactor `SourceBackedAlignmentCoordinator.align` to call the helper.**

Keep its existing token acquisition and `AutoAlignmentWorker`/DTW selection behavior. Replace its hand-written clear/record/insert/refine tail with:

```swift
_ = try DTWAlignmentPersistence.replaceAndRefine(
    audiobookID: audiobookID,
    source: .transcriptAlignment,
    note: "Source-backed transcript alignment (TokenDTW + AnchorSelector)",
    selectedCandidates: selected,
    wordMatchesByBlock: matchesByBlock,
    writer: dbService.writer)
```

- [ ] **Step 4: Run DB-backed and existing source-alignment suites.**

Select:

```text
EchoTests/DTWAlignmentPersistenceTests
EchoTests/SourceBackedAlignmentCoordinatorTests
EchoTests/SourceBackedAlignmentConfidenceTests
EchoTests/WordTimingMaterializerTests
```

Expected: all selected tests pass; source-backed behavior remains unchanged.

- [ ] **Step 5: Commit the persistence checkpoint.**

```bash
git add EchoCore/Services/DTWAlignmentPersistence.swift \
  EchoCore/Services/SourceBackedAlignmentCoordinator.swift \
  EchoTests/DTWAlignmentPersistenceTests.swift \
  EchoTests/SourceBackedAlignmentCoordinatorTests.swift
git commit -m "refactor(alignment): share DTW persistence and refinement"
```

---

### Task 3: Add a Sendable, pure sidecar assembler with explicit anchor confidence

**Files:**
- Modify: `Shared/Database/WordTimingRecord.swift`
- Create: `EchoCore/Services/AlignmentSidecarAssembler.swift`
- Create: `EchoTests/AlignmentSidecarAssemblerTests.swift`

**Interfaces:**
- Produces: `WordTimingRecord: Sendable` (all stored fields are Sendable value types).
- Produces: `AlignmentSidecarAssembler.assemble(anchors:wordRows:tokenCountByBlockID:offsetByBlockID:anchorConfidenceByBlockID:) -> [AlignmentSidecar.Anchor]`.
- Guarantees: portable IDs; word-index ordering; one words array per block; token-count safety; identical anchor/word offsets; caller-supplied anchor confidence only; monotonic output sorting.

- [ ] **Step 1: Write failing assembler tests with complete local fixtures.**

```swift
@Suite struct AlignmentSidecarAssemblerTests {
    private func anchor(_ blockID: String, _ time: TimeInterval) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: UUID().uuidString, audiobookID: "book", epubBlockID: blockID,
            audioTime: time, audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
            note: nil, createdAt: "2026-07-11T00:00:00Z", modifiedAt: nil)
    }

    private func word(
        _ blockID: String, _ index: Int, _ text: String,
        _ start: TimeInterval, _ confidence: Double, _ source: String
    ) -> WordTimingRecord {
        WordTimingRecord(
            audiobookID: "book", epubBlockID: blockID, wordIndex: index,
            word: text, audioStartTime: start, audioEndTime: start + 0.4,
            confidence: confidence, source: source)
    }

    @Test func appliesOneOffsetToAnchorAndMixedQualityWords() {
        let blockID = "epub-book-s1-b2"
        let result = AlignmentSidecarAssembler.assemble(
            anchors: [anchor(blockID, 3)],
            wordRows: [
                word(blockID, 1, "two", 3.4, 0.5, "interpolated"),
                word(blockID, 0, "one", 3.0, 0.85, "dtw"),
            ],
            tokenCountByBlockID: [blockID: 2],
            offsetByBlockID: [blockID: 100],
            anchorConfidenceByBlockID: [:])
        #expect(result[0].blockId == "s1-b2")
        #expect(result[0].timestamp == 103)
        #expect(result[0].confidence == nil)
        #expect(result[0].words?.map(\.start) == [103.0, 103.4])
        #expect(result[0].words?.map(\.confidence) == [0.85, 0.5])
    }

    @Test func exactCallerConfidenceIsPreservedWithoutDerivingItFromWords() {
        let blockID = "epub-book-s0-b0"
        let result = AlignmentSidecarAssembler.assemble(
            anchors: [anchor(blockID, 1)],
            wordRows: [word(blockID, 0, "one", 1, 0.9, "synthesis")],
            tokenCountByBlockID: [blockID: 1],
            anchorConfidenceByBlockID: [blockID: 1.0])
        #expect(result[0].confidence == 1.0)
    }

    @Test func countMismatchKeepsAnchorAndOmitsWords() {
        let blockID = "epub-book-s0-b0"
        let result = AlignmentSidecarAssembler.assemble(
            anchors: [anchor(blockID, 1)],
            wordRows: [word(blockID, 0, "one", 1, 0.5, "interpolated")],
            tokenCountByBlockID: [blockID: 2])
        #expect(result[0].words == nil)
    }
}
```

- [ ] **Step 2: Run the new suite and confirm compile failure.**

Expected: the assembler and `WordTimingRecord.Sendable` conformance are absent.

- [ ] **Step 3: Add the conformance and assembler.**

Add `Sendable` to `WordTimingRecord`'s conformance list, then create:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum AlignmentSidecarAssembler {
    static func assemble(
        anchors: [AlignmentAnchorRecord],
        wordRows: [WordTimingRecord],
        tokenCountByBlockID: [String: Int],
        offsetByBlockID: [String: TimeInterval] = [:],
        anchorConfidenceByBlockID: [String: Double] = [:]
    ) -> [AlignmentSidecar.Anchor] {
        let rowsByBlockID = Dictionary(grouping: wordRows, by: \.epubBlockID)
        var usedBlocks: Set<String> = []
        return anchors.sorted {
            $0.audioTime + (offsetByBlockID[$0.epubBlockID] ?? 0)
                < $1.audioTime + (offsetByBlockID[$1.epubBlockID] ?? 0)
        }.map { anchor in
            let offset = offsetByBlockID[anchor.epubBlockID] ?? 0
            let rows = (rowsByBlockID[anchor.epubBlockID] ?? [])
                .sorted { $0.wordIndex < $1.wordIndex }
            let attach = !rows.isEmpty
                && rows.count == tokenCountByBlockID[anchor.epubBlockID]
                && usedBlocks.insert(anchor.epubBlockID).inserted
            let words = attach ? rows.map {
                AlignmentSidecar.Anchor.Word(
                    word: $0.word,
                    start: $0.audioStartTime + offset,
                    end: $0.audioEndTime + offset,
                    confidence: $0.confidence)
            } : nil
            return AlignmentSidecar.Anchor(
                blockId: AlignmentSidecar.portableSuffix(of: anchor.epubBlockID),
                timestamp: anchor.audioTime + offset,
                confidence: anchorConfidenceByBlockID[anchor.epubBlockID],
                words: words)
        }
    }
}
```

- [ ] **Step 4: Run assembler and contract suites, then commit.**

Select `AlignmentSidecarAssemblerTests`, `AlignmentSidecarTests`, and `EstimatedAlignmentSidecarTests`. Expected: pass.

```bash
git add Shared/Database/WordTimingRecord.swift \
  EchoCore/Services/AlignmentSidecarAssembler.swift \
  EchoTests/AlignmentSidecarAssemblerTests.swift
git commit -m "feat(alignment): assemble portable word sidecars"
```

---

### Task 4: Move Mac DTW work off Main Actor and export refined words

**Files:**
- Modify: `Echo macOS/Services/MacAlignmentService.swift`
- Create: `EchoTests/MacAlignmentSidecarWiringTests.swift`
- Modify: `EchoTests/AutoAlignmentWorkerTests.swift`

**Interfaces:**
- Consumes: `AutoAlignmentWorker.alignChapter`, `DTWAlignmentPersistence`, and `AlignmentSidecarAssembler`.
- Produces: normalized, cancellable whole-book Mac alignment and word-bearing sidecar export.
- Confidence rule: Mac DTW anchor confidence is `nil` because `exactRunLength` is evidence, not a calibrated probability; word rows retain `0.85` DTW or `0.5` interpolation.

- [ ] **Step 1: Strengthen the behavioral worker test.**

Add this case to `AutoAlignmentWorkerTests`; it proves the worker normalizes a whole source block and punctuation-bearing Whisper words, including digit-to-word expansion, before the Mac path adopts it:

```swift
@Test func workerNormalizesWholeBlockAndPunctuatedTranscriptWords() async throws {
    let output = try await AutoAlignmentWorker.alignChapter(
        AutoAlignmentWorker.Input(
            words: [
                word("Chapter,", 2.0),
                word("2", 2.4),
                word("Beginning.", 2.8),
            ],
            alignmentBlocks: [block("chapter", "Chapter 2: Beginning")],
            anchoredBlockIDs: [],
            windowStart: 0,
            windowEnd: 10,
            lastGlobalAnchorTime: 0,
            minAnchorRunLength: 3))

    #expect(output.selectedCandidates.map(\.blockID) == ["chapter"])
    #expect(output.wordMatchesByBlock["chapter"]?.count == 3)
    #expect(output.audioTokenCount == 3)
    #expect(output.epubTokenCount == 3)
}
```

- [ ] **Step 2: Add a narrow wiring-order test.**

```swift
@Suite struct MacAlignmentSidecarWiringTests {
    @Test func MacAlignmentUsesConcurrentWorkerThenSharedPersistenceAndAssembly() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        let worker = try #require(source.range(of: "try await AutoAlignmentWorker.alignChapter"))
        let persist = try #require(source.range(of: "DTWAlignmentPersistence.replaceAndRefine"))
        let assemble = try #require(source.range(of: "AlignmentSidecarAssembler.assemble"))
        #expect(worker.lowerBound < persist.lowerBound)
        #expect(persist.lowerBound < assemble.lowerBound)
        #expect(!source.contains("TokenDTW.alignWithBisection(epub:"))
        #expect(!source.contains("AlignmentSidecar.write(records"))
    }
}
```

The behavioral worker, persistence, and assembler suites carry correctness; this source test only locks Mac-target integration order.

- [ ] **Step 3: Replace raw `AudioToken` accumulation with `TranscribedWord`.**

Inside each chunk result loop, append:

```swift
transcribedWords.append(
    TranscribedWord(
        text: token.word,
        start: chunkStartTime + token.start))
```

Do not pre-normalize in the Mac target; `AutoAlignmentWorker` owns normalization for both streams.

- [ ] **Step 4: Await the concurrent cancellable worker.**

```swift
let alignmentBlocks = parsed.blocks.map {
    AutoAlignmentWorker.AlignmentBlock(
        id: $0.id,
        text: $0.text,
        isHidden: $0.isHidden)
}
let output = try await AutoAlignmentWorker.alignChapter(
    AutoAlignmentWorker.Input(
        words: transcribedWords,
        alignmentBlocks: alignmentBlocks,
        anchoredBlockIDs: [],
        windowStart: 0,
        windowEnd: totalDuration,
        lastGlobalAnchorTime: 0,
        minAnchorRunLength: 3))
guard !output.selectedCandidates.isEmpty else { throw AlignmentError.noAnchorsProduced }
```

This call leaves `@MainActor` while the two cancellable DTW passes run, and cancellation propagates back through `align`.

- [ ] **Step 5: Persist/refine, assemble, and write.**

```swift
let records = try DTWAlignmentPersistence.replaceAndRefine(
    audiobookID: audiobookID,
    source: .autoAlignment,
    note: "Mac DTW alignment (TokenDTW + AnchorSelector)",
    selectedCandidates: output.selectedCandidates,
    wordMatchesByBlock: output.wordMatchesByBlock,
    writer: dbService.writer)
let words = try WordTimingDAO(db: dbService.writer)
    .words(forAudiobook: audiobookID)
    .filter { $0.source == "dtw" || $0.source == "interpolated" }
let tokenCounts = Dictionary(
    uniqueKeysWithValues: parsed.blocks.map {
        ($0.id, WordTokenizer.words(in: $0.text ?? "").count)
    })
let sidecarAnchors = AlignmentSidecarAssembler.assemble(
    anchors: records,
    wordRows: words,
    tokenCountByBlockID: tokenCounts,
    anchorConfidenceByBlockID: [:])
_ = try AlignmentSidecar.write(sidecarAnchors, forEPUB: epubURL)
```

Keep sidecar writing best-effort after DB persistence, as it is today.

- [ ] **Step 6: Run behavioral and integration suites.**

Select:

```text
EchoTests/AutoAlignmentWorkerTests
EchoTests/DTWAlignmentPersistenceTests
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/MacAlignmentSidecarWiringTests
EchoTests/WordTimingMaterializerTests
```

Expected: pass with zero failures.

- [ ] **Step 7: Build the macOS target and commit.**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build \
  -project Echo.xcodeproj -scheme 'Echo macOS' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/EchoIssue421MacDerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet

git add 'Echo macOS/Services/MacAlignmentService.swift' \
  EchoTests/MacAlignmentSidecarWiringTests.swift \
  EchoTests/AutoAlignmentWorkerTests.swift
git commit -m "feat(mac): export refined DTW word sidecars"
```

---

### Task 5: Route Mac narration through the same assembler

**Files:**
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `EchoTests/MacAlignmentSidecarWiringTests.swift`

**Interfaces:**
- Consumes: `AlignmentSidecarAssembler`.
- Produces: Mac-narrated sidecars whose synthesis words and anchors receive the same cumulative chapter offset and whose exact anchors carry `1.0` confidence.

- [ ] **Step 1: Add wiring assertions.**

Read `MacBatchProcessingService.swift` via `MacSource` and assert it contains `AlignmentSidecarAssembler.assemble`, filters words with `$0.source == "synthesis"`, supplies `offsetByBlockID`, supplies `anchorConfidenceByBlockID`, and no longer contains `timestamp: a.audioTime + off, confidence: 1.0`.

- [ ] **Step 2: Replace the hand-built narration array.**

Keep the existing cumulative track-duration calculation. Then use:

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
let exactConfidence = Dictionary(
    uniqueKeysWithValues: anchors.map { ($0.epubBlockID, 1.0) })
let sidecar = AlignmentSidecarAssembler.assemble(
    anchors: anchors,
    wordRows: words,
    tokenCountByBlockID: tokenCounts,
    offsetByBlockID: offsetByBlockID,
    anchorConfidenceByBlockID: exactConfidence)
if !sidecar.isEmpty {
    _ = try AlignmentSidecar.write(sidecar, forEPUB: epubURL)
}
```

- [ ] **Step 3: Run `MacAlignmentSidecarWiringTests`, `AlignmentSidecarAssemblerTests`, `HeadlessNarrationRunnerTests`, and `DocumentImportFinalizerTests`.**

Expected: pass; existing CLI narration remains compatible.

- [ ] **Step 4: Rebuild `Echo macOS` and commit.**

```bash
git add 'Echo macOS/Services/MacBatchProcessingService.swift' \
  EchoTests/MacAlignmentSidecarWiringTests.swift
git commit -m "feat(mac): include synthesis words in batch sidecars"
```

---

### Task 6: Reject multi-file alignment before mutation and document the boundary

**Files:**
- Create: `EchoCore/Services/AlignmentSidecarTimebasePolicy.swift`
- Modify: `Echo macOS/Services/FolderAudioScanner.swift`
- Create: `EchoTests/AlignmentSidecarTimebasePolicyTests.swift`
- Modify: `EchoTests/MacAlignmentSidecarWiringTests.swift`
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `AlignmentSidecarTimebasePolicy.Decision` with `.enqueue([URL])` and `.rejectMultiFile([UnsupportedGroup])`.
- Guarantees: the decision is made inside `FolderAudioScanner.enqueueFolder` while the user-selected folder's security scope is active, before any call to `MacBatchProcessingService.enqueue`.
- Guarantees: multi-file groups create no queue record, so import, anchor deletion, word materialization, and sidecar writing never begin.

- [ ] **Step 1: Write the failing two-track behavioral policy test.**

```swift
@Suite struct AlignmentSidecarTimebasePolicyTests {
    @Test func separateSingleFileBooksEnqueueButSiblingTracksRejectAtomically() {
        let bookA = URL(fileURLWithPath: "/library/A/Book A.m4b")
        let bookB = URL(fileURLWithPath: "/library/B/Book B.m4b")
        let track1 = URL(fileURLWithPath: "/library/C/01.mp3")
        let track2 = URL(fileURLWithPath: "/library/C/02.mp3")

        #expect(
            AlignmentSidecarTimebasePolicy.decision(for: [bookB, bookA])
                == .enqueue([bookA, bookB]))
        #expect(
            AlignmentSidecarTimebasePolicy.decision(for: [bookA, track1, track2])
                == .rejectMultiFile([
                    .init(directory: track1.deletingLastPathComponent(), fileCount: 2)
                ]))
    }
}
```

- [ ] **Step 2: Implement the pure policy.**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum AlignmentSidecarTimebasePolicy {
    struct UnsupportedGroup: Equatable, Sendable {
        let directory: URL
        let fileCount: Int
    }

    enum Decision: Equatable, Sendable {
        case enqueue([URL])
        case rejectMultiFile([UnsupportedGroup])
    }

    static func decision(for audioFiles: [URL]) -> Decision {
        let sorted = audioFiles.sorted { $0.path < $1.path }
        let groups = Dictionary(grouping: sorted) {
            $0.deletingLastPathComponent().standardizedFileURL
        }
        let unsupported = groups.compactMap { directory, files in
            files.count > 1
                ? UnsupportedGroup(directory: directory, fileCount: files.count)
                : nil
        }.sorted { $0.directory.path < $1.directory.path }
        return unsupported.isEmpty ? .enqueue(sorted) : .rejectMultiFile(unsupported)
    }
}
```

- [ ] **Step 3: Classify the already-authorized scan before enqueuing.**

Add `import os.log`. Replace the immediate `for audioURL in scanForAudioFiles(in: folderURL)` loop in `FolderAudioScanner.enqueueFolder` with a plan-first switch while `folderURL` access is still active:

```swift
let audioFiles = scanForAudioFiles(in: folderURL)
switch AlignmentSidecarTimebasePolicy.decision(for: audioFiles) {
case .enqueue(let supportedFiles):
    for audioURL in supportedFiles {
        try service.enqueue(
            fileURL: audioURL,
            companionEPUB: companionEPUB(for: audioURL))
    }
case .rejectMultiFile(let groups):
    let summary = groups.map {
        "\($0.directory.lastPathComponent) (\($0.fileCount) tracks)"
    }.joined(separator: ", ")
    logger.error(
        "Rejected multi-file alignment before enqueue: \(summary, privacy: .public)")
    throw ScanError.multiFileAlignmentUnsupported(summary)
}
```

Add a file-local logger and error:

```swift
private static let logger = Logger(category: "FolderAudioScanner")

enum ScanError: LocalizedError {
    case multiFileAlignmentUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .multiFileAlignmentUnsupported(let summary):
            return "Multi-file alignment is not yet portable: \(summary). Combine each book into one M4B before batch alignment."
        }
    }
}
```

- [ ] **Step 4: Prove the folder-scope and no-enqueue ordering.**

Extend `MacAlignmentSidecarWiringTests` to read `FolderAudioScanner.swift` and assert:

```swift
let source = try MacSource.read("Services/FolderAudioScanner.swift")
let scope = try #require(source.range(of: "startAccessingSecurityScopedResource"))
let policy = try #require(source.range(of: "AlignmentSidecarTimebasePolicy.decision"))
let enqueue = try #require(source.range(of: "try service.enqueue"))
#expect(scope.lowerBound < policy.lowerBound)
#expect(policy.lowerBound < enqueue.lowerBound)
#expect(source.contains("case .rejectMultiFile"))
```

The behavioral policy test proves grouping; this integration-order assertion proves the Mac target makes that decision with folder authorization and before the only queue mutation call.

- [ ] **Step 5: Keep failed groups out of the queue entirely.**

Do not add a process-time sibling scan and do not add a `BatchQueueRecord` field. The folder-scoped preflight either computes the complete supported file list and enqueues it, or throws before the loop starts. This avoids both sandbox false negatives and partial queue/database state.

- [ ] **Step 6: Update architecture and release notes.**

Replace “The Mac DTW paths remain anchors-only” with the exact shipped rules:

- Mac DTW reuses normalized, cancellable `AutoAlignmentWorker` computation and shared DB persistence.
- Word arrays preserve per-word quality: `0.85` DTW, `0.5` interpolation, `0.9` synthesis/legacy sidecar.
- Mac DTW anchor confidence is omitted (`nil`) because run length is not a calibrated probability; Mac narration anchors remain exact `1.0`.
- Both Mac producers use one offset-safe assembler.
- Multi-file groups are detected during folder-scoped discovery and rejected before queue mutation until a future track-aware sidecar contract exists; users can combine tracks into one M4B.

Add the same user-facing behavior and compatibility note to the current Unreleased section of `CHANGELOG.md`.

- [ ] **Step 7: Run all focused suites and builds.**

Run one serial test invocation selecting:

```text
EchoTests/AlignmentSidecarTests
EchoTests/AlignmentSidecarAssemblerTests
EchoTests/AlignmentSidecarTimebasePolicyTests
EchoTests/AutoAlignmentWorkerTests
EchoTests/DTWAlignmentPersistenceTests
EchoTests/DocumentImportFinalizerTests
EchoTests/EstimatedAlignmentSidecarTests
EchoTests/MacAlignmentSidecarWiringTests
EchoTests/SourceBackedAlignmentCoordinatorTests
EchoTests/WordTimingMaterializerTests
```

Then run:

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
```

Expected: selected tests pass; both builds exit 0; diff check is silent.

- [ ] **Step 8: Commit documentation and policy.**

```bash
git add EchoCore/Services/AlignmentSidecarTimebasePolicy.swift \
  'Echo macOS/Services/FolderAudioScanner.swift' \
  EchoTests/AlignmentSidecarTimebasePolicyTests.swift \
  EchoTests/MacAlignmentSidecarWiringTests.swift \
  ARCHITECTURE.md CHANGELOG.md
git commit -m "fix(mac): reject unsafe multi-file alignment"
```

- [ ] **Step 9: Publish and close the loop.**

Fetch and rebase onto current `origin/nightly`, push the implementation branch, and open a ready PR to `nightly` whose body says `Fixes #421`. Include focused test counts, macOS/CLI build results, the `nil` DTW-anchor-confidence rule, and the multi-file fail-fast behavior. Watch `Build gate + tests`; inspect failing job logs before changing code. Close #421 only after merge, then verify `gh issue list --state open` no longer contains it.

## Self-Review

- **Spec coverage:** Tasks 1 and 3 cover the sidecar contract and confidence semantics. Tasks 2 and 4 correct the stale assumption that Mac DTW already produces refined words and ensure expensive work is normalized, cancellable, and off Main Actor. Task 5 covers Mac narration offsets. Task 6 prevents both portable and Mac-local multi-track corruption before mutation.
- **Placeholder scan:** Every implementation step names exact files, signatures, code, commands, expected outcomes, and commit boundaries.
- **Type consistency:** `WordTimingRecord` explicitly becomes `Sendable`; the assembler accepts only Sendable value records and explicit anchor confidence; `AutoAlignmentWorker.Output` feeds the persistence helper unchanged; both Mac producers consume the same assembler.
