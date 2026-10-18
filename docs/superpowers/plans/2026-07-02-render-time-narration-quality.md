# Render-Time Narration Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve Echo's generated narration by making the render pipeline plan speech, pauses, retries, timing, and pronunciation discovery explicitly before considering any model replacement.

**Architecture:** Add a pure render-plan layer between `TextNormalizer`/`PronunciationOverrides` and `NarrationService.renderChapter`. The first slice ships intentional silence segments and acoustic retry guardrails; follow-up slices add phoneme-aware chunking, finer synthesis-time word timing, and a per-book pronunciation preflight list.

**Tech Stack:** Swift, SwiftUI-free service code, Swift Testing, GRDB, AVFoundation-backed `AudioFileWriting`, ONNX Kokoro behind the existing `TTSEngine` seam. Preserve current project settings: iOS deployment target 18.0, macOS 15.0, watchOS 11.0, and the current Xcode project Swift language setting; do not add third-party dependencies.

## Global Constraints

- Open implementation PRs against `nightly`, not `main`.
- Keep generated book media, transcript/alignment sidecars, and private text-derived artifacts out of git.
- Prefer pure deterministic units for planning, chunking, quality classification, and preflight scoring.
- Do not change the TTS model, voice asset, database schema, or platform deployment targets in this plan.
- Preserve one `.synthesized` anchor per original speakable EPUB block; section-break silence must not create a fake text anchor.
- Run focused Swift Testing slices first, then `make build-tests`, then a macOS `echo-cli` build when code touches shared narration services.

## TDD Completeness Contract

- Each implementation task starts with a failing Swift Testing slice and states the expected failure before production code is added.
- Each production-code step includes concrete signatures or code blocks for the new or changed API.
- Each task ends with focused green tests and a scoped commit command.
- Follow-up tasks are real implementation slices, not placeholders; skip a task only by removing it from the plan in a review commit.
- Any CLI/reporting work in this plan is local-only and must be backed by a failing test before wiring.

---

## File Structure

**Create:**
- `EchoCore/Services/Narration/NarrationRenderPlan.swift` — pure render-plan types and `NarrationRenderPlanner.make(...)`; owns text normalization, override application, section-break detection, speech subchunk planning, and planned pause durations.
- `EchoCore/Services/Narration/NarrationChunkQuality.swift` — pure quality checks for synthesized speech chunks: empty output, zero/near-zero energy, and implausible duration.
- `EchoTests/NarrationRenderPlanTests.swift` — tests planned speech segments, section-break silence, heading/paragraph pause policy, and override ordering.
- `EchoTests/NarrationChunkQualityTests.swift` — tests quality report classification without the real model.

**Modify in the first slice:**
- `EchoCore/Services/Narration/NarrationService.swift` — consume `NarrationRenderPlan`; append planned silences; retry bad chunks once; preserve anchor spans as speech-only.
- `EchoTests/Mocks/MockTTSEngine.swift` — emit nonzero samples for synthetic speech so quality checks do not reject every mock chunk.
- `EchoTests/NarrationServiceTests.swift` — update expectations for planned inter-block pauses and add retry/section-break regressions.
- `EchoTests/NarrationTextChunkerTests.swift` — keep current tests green; do not delete the existing chunker yet.

**Modify in follow-up slices:**
- `EchoCore/Services/Narration/NarrationTextChunker.swift` — add phoneme-budget planning while preserving the current character-budget API as a compatibility wrapper.
- `EchoCore/Services/Narration/KokoroFrontEnd.swift` or `EchoCore/Services/Narration/KokoroG2P.swift` — expose a cheap phoneme-count/phoneme-string helper for chunk budgeting and preflight.
- `EchoCore/Services/WordTimingMaterializer.swift` — use explicit synthesized block end times before falling back to the next block start; Task 6 then consumes planned speech segment boundaries.
- `EchoCore/Services/Narration/NarrationPronunciationPreflight.swift` — pure scanner for OOV/proper-noun/acronym/empty-phoneme candidates.
- `EchoTests/NarrationTextChunkerTests.swift`, `EchoTests/WordTimingMaterializerTests.swift`, `EchoTests/NarrationPronunciationPreflightTests.swift` — focused follow-up coverage.

---

## Task 1: Add the Pure Render Plan

**Files:**
- Create: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Test: `EchoTests/NarrationRenderPlanTests.swift`

**Interfaces:**
- Consumes: `EPubBlockRecord`, `TextNormalizer.normalize(_:)`, `PronunciationOverrides.apply(to:)`, `NarrationTextChunker.split(_:maxChars:)`.
- Produces: `NarrationRenderPlanner.make(blocks:overrides:maxChars:) -> NarrationRenderPlan`, where `NarrationService` can render each `NarrationPlannedBlock`.

- [ ] **Step 1: Write failing render-plan tests**

Create `EchoTests/NarrationRenderPlanTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationRenderPlanTests {
    private func block(
        id: String,
        text: String?,
        kind: String = "paragraph",
        index: Int
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: index, sequenceIndex: index,
            blockKind: kind, text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func plansSpeechBlocksWithNormalizedOverrideText() {
        let blocks = [
            block(id: "b0", text: "Deploy Kubernetes — now.", index: 0)
        ]
        let overrides = PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])

        let plan = NarrationRenderPlanner.make(blocks: blocks, overrides: overrides, maxChars: 350)

        #expect(plan.blocks.count == 1)
        #expect(plan.blocks[0].blockID == "b0")
        #expect(plan.blocks[0].speechSegments == ["Deploy [Kubernetes](/kuːbərˈnɛtɪs/), now."])
        #expect(plan.blocks[0].trailingSilence == nil)
    }

    @Test func decorativeBlockBecomesSectionBreakSilenceOnly() {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "* * *", index: 1),
            block(id: "b2", text: "After.", index: 2)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks.map(\.blockID) == ["b0", "b1", "b2"])
        #expect(plan.blocks[0].speechSegments == ["Before."])
        #expect(plan.blocks[0].trailingSilence == nil)
        #expect(plan.blocks[1].speechSegments.isEmpty)
        #expect(plan.blocks[1].trailingSilence == .sectionBreak)
        #expect(plan.blocks[2].speechSegments == ["After."])
    }

    @Test func finalSpeakableBlockHasNoTrailingParagraphPause() {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "After.", index: 1)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .paragraph)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func headingGetsLongerPauseThanParagraph() {
        let blocks = [
            block(id: "h", text: "Chapter One", kind: "heading", index: 0),
            block(id: "p", text: "The first paragraph.", index: 1)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .heading)
        #expect(plan.blocks[1].trailingSilence == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationRenderPlanTests`

Expected: build fails because `NarrationRenderPlanner` and `NarrationRenderPlan` are not defined.

- [ ] **Step 3: Add render-plan types and default pause policy**

Create `EchoCore/Services/Narration/NarrationRenderPlan.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationRenderPlan: Equatable, Sendable {
    let blocks: [NarrationPlannedBlock]
}

struct NarrationPlannedBlock: Equatable, Sendable {
    let blockID: String
    let originalBlock: EPubBlockRecord
    let speechSegments: [String]
    let trailingSilence: NarrationPlannedSilence?

    var isSpeakable: Bool { !speechSegments.isEmpty }
}

enum NarrationPlannedSilence: Equatable, Sendable {
    case paragraph
    case heading
    case sectionBreak

    var duration: TimeInterval {
        switch self {
        case .paragraph:
            return 0.18
        case .heading:
            return 0.35
        case .sectionBreak:
            return 0.85
        }
    }
}

enum NarrationRenderPlanner {
    static func make(
        blocks: [EPubBlockRecord],
        overrides: PronunciationOverrides,
        maxChars: Int = 350
    ) -> NarrationRenderPlan {
        let candidates = blocks.filter { block in
            guard block.text?.isEmpty == false else { return false }
            return !block.isHidden
        }

        var planned: [NarrationPlannedBlock] = []
        for block in candidates {
            let normalized = TextNormalizer.normalize(block.text ?? "")
            if isDecorativeSeparator(normalized) {
                planned.append(
                    NarrationPlannedBlock(
                        blockID: block.id,
                        originalBlock: block,
                        speechSegments: [],
                        trailingSilence: .sectionBreak))
                continue
            }

            let rewritten = overrides.apply(to: normalized)
            let speech = NarrationTextChunker.split(rewritten, maxChars: maxChars)
            planned.append(
                NarrationPlannedBlock(
                    blockID: block.id,
                    originalBlock: block,
                    speechSegments: speech,
                    trailingSilence: nil))
        }

        return NarrationRenderPlan(blocks: attachTrailingSilences(to: planned))
    }

    private static func attachTrailingSilences(
        to blocks: [NarrationPlannedBlock]
    ) -> [NarrationPlannedBlock] {
        guard !blocks.isEmpty else { return [] }
        let lastSpeakableIndex = blocks.lastIndex(where: \.isSpeakable)
        return blocks.enumerated().map { index, block in
            if block.trailingSilence == .sectionBreak { return block }
            guard block.isSpeakable, index != lastSpeakableIndex else { return block }
            let nextIsSectionBreak = index + 1 < blocks.count
                && blocks[index + 1].trailingSilence == .sectionBreak
            guard !nextIsSectionBreak else { return block }
            let silence: NarrationPlannedSilence = isHeading(block.originalBlock) ? .heading : .paragraph
            return NarrationPlannedBlock(
                blockID: block.blockID,
                originalBlock: block.originalBlock,
                speechSegments: block.speechSegments,
                trailingSilence: silence)
        }
    }

    private static func isHeading(_ block: EPubBlockRecord) -> Bool {
        block.blockKind.localizedCaseInsensitiveContains("heading")
            || block.blockKind.localizedCaseInsensitiveContains("title")
    }

    private static func isDecorativeSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return false }
        let allowed = CharacterSet(charactersIn: "*-~•·. _")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
```

- [ ] **Step 4: Run focused render-plan tests**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationRenderPlanTests`

Expected: `NarrationRenderPlanTests` passes.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationRenderPlan.swift EchoTests/NarrationRenderPlanTests.swift
git commit -m "feat(narration): add render-time speech plan"
```

---

## Task 2: Wire the Render Plan Into Chapter Rendering

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift:101-177`
- Modify: `EchoTests/NarrationServiceTests.swift`

**Interfaces:**
- Consumes: `NarrationRenderPlanner.make(blocks:overrides:maxChars:)`.
- Produces: chapter audio with planned speech plus intentional silence; anchors span speech only and cursor advances through planned silence.

- [ ] **Step 1: Add failing service tests for planned silence and section breaks**

Append to `EchoTests/NarrationServiceTests.swift`:

```swift
@Test func plannedParagraphPauseAdvancesNextAnchorWithoutStretchingPreviousAnchor() async throws {
    let db = try DatabaseService(inMemory: ())
    let blocks = try seed(db, ["First.", "Second."])
    let svc = makeService(
        db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

    try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

    let anchors = try db.read { db in
        try AlignmentAnchorRecord
            .filter(Column("audiobook_id") == "b1")
            .order(Column("audio_time"))
            .fetchAll(db)
    }
    #expect(anchors.count == 2)
    let firstSpeechDuration = Double("First.".count) * 0.1
    #expect(abs((anchors[0].audioEndTime ?? -1) - firstSpeechDuration) < 0.0001)
    #expect(abs(anchors[1].audioTime - (firstSpeechDuration + NarrationPlannedSilence.paragraph.duration)) < 0.0001)
}

@Test func decorativeSectionBreakCreatesSilenceButNoAnchor() async throws {
    let db = try DatabaseService(inMemory: ())
    let blocks = try seed(db, ["First.", "* * *", "Second."])
    let writer = MockAudioWriter()
    let svc = makeService(
        db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)

    try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

    let anchors = try db.read { db in
        try AlignmentAnchorRecord
            .filter(Column("audiobook_id") == "b1")
            .order(Column("audio_time"))
            .fetchAll(db)
    }
    #expect(anchors.map(\.epubBlockID) == ["blk0", "blk2"])
    #expect((anchors[1].audioTime - (anchors[0].audioEndTime ?? 0)) >= NarrationPlannedSilence.sectionBreak.duration)
}
```

- [ ] **Step 2: Run service tests to verify failure**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationServiceTests`

Expected: new tests fail because `NarrationService` still loops directly over `NarrationTextChunker.split(text)`.

- [ ] **Step 3: Replace direct chunking with the render plan**

In `EchoCore/Services/Narration/NarrationService.swift`, replace the `spoken` setup and block loop with this shape:

```swift
let overrides = pronunciationOverrides()
let plan = NarrationRenderPlanner.make(blocks: blocks, overrides: overrides)
let speakableCount = max(1, plan.blocks.filter(\.isSpeakable).count)
logger.notice("Chapter \(displayNumber): rendering \(plan.blocks.count) planned block(s)…")
var renderedSpeakableBlocks = 0

for plannedBlock in plan.blocks {
    try Task.checkCancellation()

    var blockDuration: TimeInterval = 0
    for subText in plannedBlock.speechSegments {
        try Task.checkCancellation()
        do {
            let chunk = try await tts.synthesize(subText, voice: voice)
            try await stream.append(chunk)
            blockDuration += chunk.duration
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Self.isLengthCapError(error) {
            logger.error(
                "Skipping over-long sub-chunk in block \(plannedBlock.blockID): \(error.localizedDescription)"
            )
            continue
        }
    }

    if blockDuration > 0 {
        anchors.append(
            AlignmentAnchorRecord(
                id: "syn-\(audiobookID)-\(plannedBlock.blockID)",
                audiobookID: audiobookID,
                epubBlockID: plannedBlock.blockID,
                audioTime: cursor,
                audioEndTime: cursor + blockDuration,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                note: nil,
                createdAt: now,
                modifiedAt: now))
        cursor += blockDuration
        renderedSpeakableBlocks += 1
    }

    if let silence = plannedBlock.trailingSilence {
        try await stream.append(.silence(seconds: silence.duration, sampleRate: 24_000))
        cursor += silence.duration
    }

    state.update(
        phase: .preparingChapter,
        progress: Double(renderedSpeakableBlocks) / Double(speakableCount),
        statusMessage: "Preparing chapter \(displayNumber)…")
}
```

Remove the old `spoken` variable and use `plan.blocks.map(\.blockID)` only where the method needs the just-rendered block IDs. For `WordTimingMaterializer.materializeChapter`, pass only speakable block IDs:

```swift
let speakableBlockIDs = plan.blocks.filter(\.isSpeakable).map(\.blockID)
try WordTimingMaterializer.materializeChapter(
    audiobookID: audiobookID, blockIDs: speakableBlockIDs, writer: db)
```

- [ ] **Step 4: Fix service test expectations affected by planned paragraph pauses**

Update earlier `NarrationServiceTests` duration expectations that assumed no inter-block pauses. For two blocks `"abcd"` and `"ef"`, expected duration becomes:

```swift
let expectedDuration = 0.6
    + NarrationPlannedSilence.paragraph.duration
    + NarrationService.leadOutPadSeconds
```

Update anchor-start expectations so the second block begins after the first block's speech plus `.paragraph.duration`.

- [ ] **Step 5: Run focused service and render-plan tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: both suites pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): render planned pauses during synthesis"
```

---

## Task 3: Add Acoustic Chunk Quality and One Retry

**Files:**
- Create: `EchoCore/Services/Narration/NarrationChunkQuality.swift`
- Test: `EchoTests/NarrationChunkQualityTests.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoTests/Mocks/MockTTSEngine.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`

**Interfaces:**
- Consumes: `TTSChunk`, speech text, current `NarrationTextChunker`.
- Produces: `NarrationChunkQuality.evaluate(_:text:) -> NarrationChunkQuality` and one retry path for silent/implausible speech chunks.

- [ ] **Step 1: Write failing quality tests**

Create `EchoTests/NarrationChunkQualityTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationChunkQualityTests {
    @Test func acceptsNonSilentSpeechWithPlausibleDuration() {
        let chunk = TTSChunk(samples: [0.05, -0.04, 0.03], sampleRate: 24_000, duration: 0.6)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello there.")
        #expect(report == .acceptable)
    }

    @Test func rejectsEmptySamplesForSpeakableText() {
        let chunk = TTSChunk(samples: [], sampleRate: 24_000, duration: 0)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello.")
        #expect(report == .rejected(.emptyAudio))
    }

    @Test func rejectsNearSilentSpeech() {
        let chunk = TTSChunk(samples: [0, 0, 0, 0], sampleRate: 24_000, duration: 1)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello.")
        #expect(report == .rejected(.nearSilentAudio))
    }

    @Test func rejectsImplausiblyShortDuration() {
        let chunk = TTSChunk(samples: [0.05, 0.04], sampleRate: 24_000, duration: 0.02)
        let report = NarrationChunkQuality.evaluate(chunk, text: "This is a complete sentence.")
        #expect(report == .rejected(.implausibleDuration))
    }
}
```

- [ ] **Step 2: Add quality classifier**

Create `EchoCore/Services/Narration/NarrationChunkQuality.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum NarrationChunkQuality: Equatable {
    enum RejectionReason: Equatable {
        case emptyAudio
        case nearSilentAudio
        case implausibleDuration
    }

    case acceptable
    case rejected(RejectionReason)

    static func evaluate(_ chunk: TTSChunk, text: String) -> NarrationChunkQuality {
        let hasSpeakableText = text.contains { $0.isLetter || $0.isNumber }
        guard hasSpeakableText else { return .acceptable }
        guard !chunk.samples.isEmpty, chunk.duration > 0 else { return .rejected(.emptyAudio) }

        let meanSquare = chunk.samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(chunk.samples.count)
        let rms = sqrt(meanSquare)
        guard rms > 0.000_01 else { return .rejected(.nearSilentAudio) }

        let wordCount = max(1, text.split(whereSeparator: \.isWhitespace).count)
        let minimumReasonableDuration = min(0.25, Double(wordCount) * 0.05)
        guard chunk.duration >= minimumReasonableDuration else {
            return .rejected(.implausibleDuration)
        }
        return .acceptable
    }
}
```

- [ ] **Step 3: Make mock speech nonzero**

In `EchoTests/Mocks/MockTTSEngine.swift`, change the returned samples from zeros to a small nonzero signal:

```swift
let sampleCount = max(1, text.count)
let samples = (0..<sampleCount).map { index in
    index.isMultiple(of: 2) ? Float(0.05) : Float(-0.05)
}
return TTSChunk(samples: samples, sampleRate: 24_000, duration: duration)
```

- [ ] **Step 4: Add one retry helper inside `NarrationService`**

In `NarrationService`, replace the direct `tts.synthesize` call with a private helper:

```swift
private func synthesizeWithQualityRetry(_ text: String, voice: VoiceID) async throws -> [TTSChunk] {
    let first = try await tts.synthesize(text, voice: voice)
    if NarrationChunkQuality.evaluate(first, text: text) == .acceptable {
        return [first]
    }

    let retryPieces = NarrationTextChunker.split(text, maxChars: max(80, text.count / 2))
    guard retryPieces.count > 1 else { return [first] }

    var accepted: [TTSChunk] = []
    for piece in retryPieces {
        let retry = try await tts.synthesize(piece, voice: voice)
        if NarrationChunkQuality.evaluate(retry, text: piece) == .acceptable {
            accepted.append(retry)
        } else {
            logger.error("Skipping low-quality retry piece in narration block: \(piece.prefix(32), privacy: .public)")
        }
    }
    return accepted.isEmpty ? [first] : accepted
}
```

Then in the render loop:

```swift
let chunks = try await synthesizeWithQualityRetry(subText, voice: voice)
for chunk in chunks {
    try await stream.append(chunk)
    blockDuration += chunk.duration
}
```

- [ ] **Step 5: Add service retry regression**

Extend `MockTTSEngine` with:

```swift
var silentOnText: String?
```

Before returning, add:

```swift
if let silent = silentOnText, text == silent {
    let frames = max(1, text.count)
    return TTSChunk(samples: [Float](repeating: 0, count: frames), sampleRate: 24_000, duration: duration)
}
```

Append this test to `NarrationServiceTests`:

```swift
@Test func silentSpeechChunkRetriesWithSmallerPieces() async throws {
    let db = try DatabaseService(inMemory: ())
    let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
    let blocks = try seed(db, [text])
    let mock = MockTTSEngine(secondsPerChar: 0.1)
    mock.silentOnText = NarrationRenderPlanner.make(
        blocks: blocks,
        overrides: PronunciationOverrides(entries: [:])
    ).blocks[0].speechSegments[0]
    let svc = makeService(db, tts: mock, writer: MockAudioWriter())

    try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

    #expect(mock.calls.count > 1)
}
```

- [ ] **Step 6: Run focused quality tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationChunkQualityTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: quality and service tests pass.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Narration/NarrationChunkQuality.swift EchoCore/Services/Narration/NarrationService.swift EchoTests/NarrationChunkQualityTests.swift EchoTests/NarrationServiceTests.swift EchoTests/Mocks/MockTTSEngine.swift
git commit -m "feat(narration): retry low-quality synthesized chunks"
```

---

## Task 4: Guard Word Timing Against Planned Silence

**Files:**
- Modify: `EchoCore/Services/WordTimingMaterializer.swift:84-119`
- Test: `EchoTests/WordTimingMaterializerTests.swift`

**Interfaces:**
- Consumes: `timeline_item.audio_end_time` generated from synthesized anchors.
- Produces: word timing that ends at a block's explicit speech end instead of stretching words through the planned silence before the next block.

- [ ] **Step 1: Add failing timing regression**

Append to `EchoTests/WordTimingMaterializerTests.swift` a regression with two blocks where block 0 ends before block 1 starts:

```swift
@Test func materializerUsesExplicitBlockEndBeforeNextStart() throws {
    let db = try DatabaseService(inMemory: ())
    try db.write { db in
        try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('bk','Book',10,'2026-07-02T00:00:00Z')")
        try db.execute(sql: """
            INSERT INTO epub_block
            (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, text, chapter_index, is_hidden, is_front_matter)
            VALUES
            ('b0','bk','c.xhtml',0,0,0,'paragraph','first words',0,0,0),
            ('b1','bk','c.xhtml',0,1,1,'paragraph','second words',0,0,0)
            """)
        try db.execute(sql: """
            INSERT INTO timeline_item
            (id, audiobook_id, item_type, title, audio_start_time, audio_end_time, epub_block_id, alignment_status)
            VALUES
            ('t0','bk','epubBlock',NULL,0.0,1.0,'b0','synthesized'),
            ('t1','bk','epubBlock',NULL,2.0,3.0,'b1','synthesized')
            """)
    }

    try WordTimingMaterializer.materializeChapter(
        audiobookID: "bk", blockIDs: ["b0", "b1"], writer: db.writer)

    let firstBlockWords = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
    #expect(firstBlockWords.map(\.audioEndTime).max() == 1.0)
}
```

- [ ] **Step 2: Change block end selection**

In `WordTimingMaterializer.records(from:audiobookID:)`, replace the block-end logic with explicit-end priority:

```swift
let blockEnd: TimeInterval
if let end = block.end, end > block.start {
    blockEnd = end
} else if i + 1 < blocks.count {
    blockEnd = max(block.start, blocks[i + 1].start)
} else {
    blockEnd = block.start + Double(block.text.count) / 15.0
}
```

This is safe for imported/auto-aligned audio because explicit `audio_end_time` is already a stronger bound than "next block starts here." It is essential for synthesized narration because planned pauses intentionally create a gap between one block's speech end and the next block's speech start.

- [ ] **Step 3: Run focused timing tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/WordTimingMaterializerTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: timing and narration service tests pass.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/WordTimingMaterializer.swift EchoTests/WordTimingMaterializerTests.swift
git commit -m "fix(narration): keep word timing out of planned silence"
```

---

## Task 5: Follow-Up A — Phoneme-Aware Chunking

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationTextChunker.swift`
- Modify: `EchoCore/Services/Narration/KokoroG2P.swift`
- Modify: `EchoCore/Services/Narration/NarrationRenderPlan.swift`
- Test: `EchoTests/NarrationTextChunkerTests.swift`

**Interfaces:**
- Consumes: normalized and override-rewritten text.
- Produces: chunks budgeted by estimated phoneme count, with the existing `split(_:maxChars:)` wrapper still available for older tests/callers.

- [ ] **Step 1: Add phoneme-budget tests**

Add tests proving that many short words can merge past 200 chars when phoneme budget permits, and high-expansion override links stay atomic:

```swift
@Test func phonemeBudgetAllowsLongerLowRiskChunks() {
    let text = Array(repeating: "we go", count: 60).joined(separator: ". ") + "."
    let pieces = NarrationTextChunker.splitByEstimatedPhonemes(
        text,
        maxPhonemes: 420,
        phonemeCount: { $0.count / 2 })

    #expect(pieces.count < NarrationTextChunker.split(text, maxChars: 200).count)
    #expect(pieces.allSatisfy { ($0.count / 2) <= 420 })
}

@Test func phonemeBudgetDoesNotSplitPronunciationLinks() {
    let text = Array(repeating: "padding", count: 40).joined(separator: " ")
        + " [Kubernetes](/kuːbərˈnɛtɪs/) "
        + Array(repeating: "padding", count: 40).joined(separator: " ")

    let pieces = NarrationTextChunker.splitByEstimatedPhonemes(
        text,
        maxPhonemes: 120,
        phonemeCount: { $0.count })

    #expect(pieces.joined(separator: " ").contains("[Kubernetes](/kuːbərˈnɛtɪs/)"))
    #expect(!pieces.contains { $0.contains("[Kubernetes]") && !$0.contains("kuːbərˈnɛtɪs") })
}
```

- [ ] **Step 2: Add the new API while preserving the old API**

In `EchoCore/Services/Narration/NarrationTextChunker.swift`, add the phoneme-budget API beside the existing character-budget API. Keep `split(_:maxChars:)` unchanged so Tasks 1-4 remain behavior-preserving.

```swift
static func splitByEstimatedPhonemes(
    _ text: String,
    maxPhonemes: Int = 420,
    phonemeCount: (String) -> Int
) -> [String] {
    guard maxPhonemes > 0 else { return [] }
    let normalized = text.split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard !normalized.isEmpty else { return [] }

    let units = splitIntoSentences(normalized, maxChars: Int.max)
    let pieces = mergeByPhonemeBudget(units, maxPhonemes: maxPhonemes, phonemeCount: phonemeCount)
        .flatMap { unit -> [String] in
            if phonemeCount(unit) <= maxPhonemes { return [unit] }
            return wrapByWords(unit, maxPhonemes: maxPhonemes, phonemeCount: phonemeCount)
        }
    return pieces.filter { chunk in
        let speakable = chunk.filter { $0.isLetter || $0.isNumber }
        return !speakable.isEmpty
    }
}

private static func mergeByPhonemeBudget(
    _ units: [String],
    maxPhonemes: Int,
    phonemeCount: (String) -> Int
) -> [String] {
    var merged: [String] = []
    for unit in units {
        guard let last = merged.last else {
            merged.append(unit)
            continue
        }
        let candidate = last + " " + unit
        if phonemeCount(candidate) <= maxPhonemes {
            merged[merged.count - 1] = candidate
        } else {
            merged.append(unit)
        }
    }
    return merged
}

private static func wrapByWords(
    _ text: String,
    maxPhonemes: Int,
    phonemeCount: (String) -> Int
) -> [String] {
    var pieces: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        let w = String(word)
        if current.isEmpty {
            current = w
            continue
        }
        let candidate = current + " " + w
        if phonemeCount(candidate) <= maxPhonemes {
            current = candidate
        } else {
            pieces.append(current)
            current = w
        }
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
}
```

This implementation deliberately does not hard-split a single word or pronunciation link. If one token exceeds `maxPhonemes`, the engine-level length-cap and quality retry path from Task 3 remains the safety net; splitting IPA links would create worse audio.

- [ ] **Step 3: Expose a G2P estimate helper**

In `KokoroG2P.swift`, add:

```swift
func phonemeCount(for text: String) -> Int {
    phonemes(for: text).count
}
```

Record the focused test runtime and render-plan timing after this task. Add caching only in a separate measured performance slice if repeated `KokoroG2P()` construction is proven expensive.

- [ ] **Step 4: Move the render planner to phoneme-budget chunking**

In `NarrationRenderPlanner.make`, add a `phonemeCount` dependency with a conservative default and use it for speech segmentation. This avoids constructing `KokoroG2P()` inside the pure planner and gives tests a deterministic seam.

```swift
static func make(
    blocks: [EPubBlockRecord],
    overrides: PronunciationOverrides,
    maxChars: Int = 350,
    maxPhonemes: Int = 420,
    phonemeCount: (String) -> Int = { $0.count }
) -> NarrationRenderPlan
```

Then replace:

```swift
let speech = NarrationTextChunker.split(rewritten, maxChars: maxChars)
```

with:

```swift
let speech = NarrationTextChunker.splitByEstimatedPhonemes(
    rewritten,
    maxPhonemes: maxPhonemes,
    phonemeCount: phonemeCount)
```

In `NarrationService.renderChapter`, create the G2P helper once per chapter before building the plan:

```swift
let g2p = KokoroG2P()
let plan = NarrationRenderPlanner.make(
    blocks: blocks,
    overrides: overrides,
    phonemeCount: g2p.phonemeCount(for:))
```

- [ ] **Step 5: Run chunking and render-plan tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationTextChunkerTests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
```

Expected: chunker and render-plan tests pass, and the earlier "periods everywhere" risk is reduced by fewer unnecessary synthetic sentence endings.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/NarrationTextChunker.swift EchoCore/Services/Narration/KokoroG2P.swift EchoCore/Services/Narration/NarrationRenderPlan.swift EchoTests/NarrationTextChunkerTests.swift
git commit -m "feat(narration): chunk speech by phoneme budget"
```

---

## Task 6: Follow-Up B — Synthesis-Time Word Timing

**Files:**
- Create: `EchoCore/Services/Narration/NarrationSynthesisTiming.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/Services/WordTimingMaterializer.swift`
- Test: `EchoTests/NarrationSynthesisTimingTests.swift`
- Test: `EchoTests/WordTimingMaterializerTests.swift`

**Interfaces:**
- Consumes: planned speech segments, their synthesized durations, and silence gaps.
- Produces: per-block timing ranges that know which portions of a block were actually spoken and which portions were inserted silence.

- [ ] **Step 1: Add pure timing model tests**

Create `EchoTests/NarrationSynthesisTimingTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationSynthesisTimingTests {
    @Test func recordsSpeechSegmentsAndSkipsSilence() {
        var timing = NarrationSynthesisTiming(blockID: "b0", blockStart: 10)
        timing.appendSpeech(text: "hello world", duration: 1.2)
        timing.appendSilence(duration: 0.5)
        timing.appendSpeech(text: "again", duration: 0.8)

        #expect(timing.blockEnd == 12.5)
        #expect(timing.speechRanges.map(\.start) == [10.0, 11.7])
        #expect(timing.speechRanges.map(\.end) == [11.2, 12.5])
    }
}
```

- [ ] **Step 2: Create timing accumulator**

Create `EchoCore/Services/Narration/NarrationSynthesisTiming.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationSpeechRange: Equatable, Sendable {
    let blockID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct NarrationSynthesisTiming: Equatable, Sendable {
    let blockID: String
    private(set) var cursor: TimeInterval
    private(set) var speechRanges: [NarrationSpeechRange] = []

    init(blockID: String, blockStart: TimeInterval) {
        self.blockID = blockID
        self.cursor = blockStart
    }

    var blockEnd: TimeInterval { cursor }

    mutating func appendSpeech(text: String, duration: TimeInterval) {
        let end = cursor + duration
        speechRanges.append(NarrationSpeechRange(blockID: blockID, text: text, start: cursor, end: end))
        cursor = end
    }

    mutating func appendSilence(duration: TimeInterval) {
        cursor += duration
    }
}
```

- [ ] **Step 3: Write failing service integration test**

Append to `EchoTests/NarrationServiceTests.swift`:

```swift
@Test func synthesizedWordTimingUsesSpeechRangesNotPauseGaps() async throws {
    let db = try DatabaseService(inMemory: ())
    let blocks = try seed(db, ["First words.", "* * *", "Second words."])
    let svc = makeService(
        db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

    try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

    let firstRows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
    let secondRows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk2")

    #expect(firstRows.isEmpty == false)
    #expect(secondRows.isEmpty == false)
    #expect(firstRows.map(\.audioEndTime).max()! < secondRows.map(\.audioStartTime).min()!)
    #expect(firstRows.map(\.source).allSatisfy { $0 == "synthesized" })
}
```

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationServiceTests`

Expected: fail because `NarrationService` still calls `materializeChapter(...)`, which writes interpolated rows without synthesis-range source metadata.

- [ ] **Step 4: Capture timing in `NarrationService`**

Inside `renderChapter`, before the planned-block loop, add:

```swift
var speechRangesByBlock: [String: [NarrationSpeechRange]] = [:]
```

Inside each planned block, add:

```swift
var timing = NarrationSynthesisTiming(blockID: plannedBlock.blockID, blockStart: cursor)
```

When appending each accepted speech chunk, replace:

```swift
try await stream.append(chunk)
blockDuration += chunk.duration
```

with:

```swift
try await stream.append(chunk)
timing.appendSpeech(text: subText, duration: chunk.duration)
blockDuration += chunk.duration
```

After a successful speech block, before advancing to the next planned block, persist the ranges:

```swift
if timing.speechRanges.isEmpty == false {
    speechRangesByBlock[plannedBlock.blockID] = timing.speechRanges
}
```

When appending planned silence, keep the global cursor behavior from Task 2. Do not add planned silence to `timing`; silence belongs between blocks, not inside a speakable block's word timing.

- [ ] **Step 5: Add a materializer entry point for synthesis ranges**

Add a new method to `WordTimingMaterializer`:

```swift
static func materializeSynthesizedChapter(
    audiobookID: String,
    speechRangesByBlock: [String: [NarrationSpeechRange]],
    writer: DatabaseWriter
) throws
```

Implement it with this structure:

```swift
static func materializeSynthesizedChapter(
    audiobookID: String,
    speechRangesByBlock: [String: [NarrationSpeechRange]],
    writer: DatabaseWriter
) throws {
    let blockIDs = Array(speechRangesByBlock.keys)
    guard !blockIDs.isEmpty else { return }
    let dao = WordTimingDAO(db: writer)
    try dao.deleteAll(forAudiobook: audiobookID, blockIDs: blockIDs)

    var records: [WordTimingRecord] = []
    for (blockID, ranges) in speechRangesByBlock {
        for (rangeIndex, range) in ranges.enumerated() {
            let words = WordTokenizer.words(in: range.text)
            guard words.isEmpty == false else { continue }
            for interpolated in WordTimingInterpolator.interpolate(
                text: range.text,
                blockStart: range.start,
                blockEnd: range.end)
            {
                records.append(
                    WordTimingRecord(
                        audiobookID: audiobookID,
                        epubBlockID: blockID,
                        wordIndex: rangeIndex * 10_000 + interpolated.index,
                        word: interpolated.word,
                        audioStartTime: interpolated.start,
                        audioEndTime: interpolated.end,
                        confidence: 0.7,
                        source: "synthesized"))
            }
        }
    }
    try dao.insert(records)
}
```

Use the existing shared `WordTokenizer.words(in:)` from `Shared/WordTokenizer.swift`; do not duplicate tokenization logic in this task.

- [ ] **Step 6: Switch narration rendering to the synthesis-specific materializer**

In `NarrationService.renderChapter`, replace:

```swift
try WordTimingMaterializer.materializeChapter(
    audiobookID: audiobookID, blockIDs: speakableBlockIDs, writer: db)
```

with:

```swift
if speechRangesByBlock.isEmpty {
    try WordTimingMaterializer.materializeChapter(
        audiobookID: audiobookID, blockIDs: speakableBlockIDs, writer: db)
} else {
    try WordTimingMaterializer.materializeSynthesizedChapter(
        audiobookID: audiobookID,
        speechRangesByBlock: speechRangesByBlock,
        writer: db)
}
```

- [ ] **Step 7: Run timing tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationSynthesisTimingTests
make test-only FILTER=EchoTests/WordTimingMaterializerTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: word timing for generated narration no longer stretches through pauses, and per-word read-along remains monotonic.

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Services/Narration/NarrationSynthesisTiming.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/WordTimingMaterializer.swift EchoTests/NarrationSynthesisTimingTests.swift EchoTests/WordTimingMaterializerTests.swift EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): materialize word timing from synthesis ranges"
```

---

## Task 7: Follow-Up C — Pronunciation Preflight

**Files:**
- Create: `EchoCore/Services/Narration/NarrationPronunciationPreflight.swift`
- Test: `EchoTests/NarrationPronunciationPreflightTests.swift`
- Modify: `EchoCore/Services/Narration/KokoroG2P.swift`

**Interfaces:**
- Consumes: normalized block text, `PronunciationOverrides`, `KokoroG2P`.
- Produces: `[NarrationPronunciationCandidate]` for per-book review; no cloud upload and no automatic shared dictionary edits.

- [ ] **Step 1: Add candidate scanner tests**

Create `EchoTests/NarrationPronunciationPreflightTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationPronunciationPreflightTests {
    @Test func flagsAcronymsAndProperNounsNotAlreadyOverridden() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Xcode talks to NASA and Fakkeldy."],
            overrides: PronunciationOverrides(entries: ["Fakkeldy": "fɑkəldi"]),
            phonemes: { word in word == "Xcode" ? "" : "ok" })

        #expect(candidates.map(\.word).contains("Xcode"))
        #expect(candidates.map(\.word).contains("NASA"))
        #expect(!candidates.map(\.word).contains("Fakkeldy"))
    }

    @Test func collapsesRepeatedCandidates() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Kubernetes Kubernetes Kubernetes"],
            overrides: PronunciationOverrides(entries: [:]),
            phonemes: { _ in "" })

        #expect(candidates.count == 1)
        #expect(candidates[0].occurrenceCount == 3)
    }
}
```

- [ ] **Step 2: Create preflight model and scanner**

Create `EchoCore/Services/Narration/NarrationPronunciationPreflight.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationPronunciationCandidate: Equatable, Sendable {
    enum Reason: String, Sendable {
        case emptyPhonemes
        case acronym
        case properNoun
    }

    let word: String
    let reasons: Set<Reason>
    let occurrenceCount: Int
}

enum NarrationPronunciationPreflight {
    static func scan(
        texts: [String],
        overrides: PronunciationOverrides,
        phonemes: (String) -> String
    ) -> [NarrationPronunciationCandidate] {
        var buckets: [String: (display: String, reasons: Set<NarrationPronunciationCandidate.Reason>, count: Int)] = [:]
        let overridden = Set(overrides.entries.keys.map { $0.lowercased() })

        for text in texts {
            let normalized = TextNormalizer.normalize(text)
            for raw in normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
                let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
                guard word.count > 1 else { continue }
                let key = word.lowercased()
                guard !overridden.contains(key) else { continue }

                var reasons: Set<NarrationPronunciationCandidate.Reason> = []
                if phonemes(word).isEmpty { reasons.insert(.emptyPhonemes) }
                if word.allSatisfy(\.isUppercase), word.count >= 2 { reasons.insert(.acronym) }
                if word.first?.isUppercase == true, !word.allSatisfy(\.isUppercase) {
                    reasons.insert(.properNoun)
                }
                guard !reasons.isEmpty else { continue }

                var bucket = buckets[key] ?? (word, [], 0)
                bucket.reasons.formUnion(reasons)
                bucket.count += 1
                buckets[key] = bucket
            }
        }

        return buckets.values
            .map { NarrationPronunciationCandidate(word: $0.display, reasons: $0.reasons, occurrenceCount: $0.count) }
            .sorted { lhs, rhs in
                if lhs.occurrenceCount != rhs.occurrenceCount { return lhs.occurrenceCount > rhs.occurrenceCount }
                return lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
            }
    }
}
```

- [ ] **Step 3: Add real-G2P entry point and JSON report model**

Add the real-G2P call site as a pure helper in `NarrationPronunciationPreflight`:

```swift
static func scan(
    blocks: [EPubBlockRecord],
    overrides: PronunciationOverrides,
    g2p: KokoroG2P = KokoroG2P()
) -> [NarrationPronunciationCandidate] {
    scan(
        texts: blocks.compactMap(\.text),
        overrides: overrides,
        phonemes: g2p.phonemes(for:))
}
```

Do not automatically write candidates into `PronunciationOverrideStore`. The first shipping shape is a report/list for review.

- [ ] **Step 4: Add failing JSON encoding test**

Append to `EchoTests/NarrationPronunciationPreflightTests.swift`:

```swift
@Test func candidatesEncodeAsStableLocalReportJSON() throws {
    let candidates = [
        NarrationPronunciationCandidate(
            word: "Xcode",
            reasons: [.emptyPhonemes, .properNoun],
            occurrenceCount: 4)
    ]

    let data = try NarrationPronunciationPreflight.encodeReport(candidates)
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains(#""word" : "Xcode""#))
    #expect(json.contains(#""occurrenceCount" : 4"#))
    #expect(json.contains("emptyPhonemes"))
    #expect(json.contains("properNoun"))
}
```

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationPronunciationPreflightTests`

Expected: fail because `encodeReport(_:)` does not exist yet.

- [ ] **Step 5: Add local-only JSON report encoding**

Make `NarrationPronunciationCandidate` conform to `Codable` and add:

```swift
static func encodeReport(_ candidates: [NarrationPronunciationCandidate]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(candidates)
}
```

This task stops at the pure report encoder. CLI file writing is out of scope here because it needs command-line UX, destination selection, and `.gitignore` policy.

- [ ] **Step 6: Run preflight tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationPronunciationPreflightTests
make test-only FILTER=EchoTests/PronunciationOverridesTests
```

Expected: preflight and override tests pass.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Narration/NarrationPronunciationPreflight.swift EchoTests/NarrationPronunciationPreflightTests.swift
git commit -m "feat(narration): scan pronunciation candidates before render"
```

---

## Task 8: Verification, CLI Smoke, and Docs

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the completed tasks above.
- Produces: verified local build/test evidence and a short architecture note describing the render-plan pipeline.

- [ ] **Step 1: Run focused test stack**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationRenderPlanTests
make test-only FILTER=EchoTests/NarrationChunkQualityTests
make test-only FILTER=EchoTests/NarrationServiceTests
make test-only FILTER=EchoTests/WordTimingMaterializerTests
make test-only FILTER=EchoTests/NarrationTextChunkerTests
make test-only FILTER=EchoTests/NarrationPronunciationPreflightTests
```

Expected: every listed suite passes.

- [ ] **Step 2: Build shared app and CLI surfaces**

Run:

```bash
make build-tests
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Expected: all builds succeed. If simulator tests fail with device-state chatter, recover with `xcrun simctl shutdown all`, boot the configured simulator, and rerun only the failed suite.

- [ ] **Step 3: Local generated-audio smoke**

Use a public-domain or local-only EPUB. Generate a short chapter with `echo-cli narrate` or the existing headless render path. Inspect:

```bash
file /path/to/generated.m4a
ffprobe -hide_banner -show_format /path/to/generated.m4a
```

Expected: audio file is valid, duration includes planned pauses, and no private text/media is copied into the repo or PR body.

- [ ] **Step 4: Update architecture/changelog**

In `ARCHITECTURE.md`, update the On-Device Narration section to mention:

```markdown
Render-time narration now flows through a pure `NarrationRenderPlan`: text normalization and pronunciation overrides produce speech segments, decorative separators become planned silence, and synthesized block anchors span speech only. Word timing uses explicit synthesized end times so read-along does not stretch highlighted words through inserted pauses.
```

In `CHANGELOG.md`, add one concise bullet under Unreleased/current section:

```markdown
- **Narration render quality:** generated EPUB narration now plans speech and pauses explicitly before synthesis, retries low-quality speech chunks once, and keeps word timing out of inserted silence. Follow-up work adds phoneme-budget chunking and pronunciation preflight.
```

- [ ] **Step 5: Final branch hygiene**

If implementation is meant to persist, create/switch to a named branch before committing from a detached worktree:

```bash
git switch -c codex/narration-render-quality
```

Then push and open a ready PR to `nightly`:

```bash
git push -u origin codex/narration-render-quality
gh pr create --base nightly --head codex/narration-render-quality --title "Improve render-time narration quality" --body-file /tmp/narration-render-quality-pr.md
```

After opening the PR, watch hosted CI and inspect failing logs before making claims about pass/fail state.

---

## Dependency Order

```text
Task 1 Render plan
  -> Task 2 Service wiring and planned pauses
      -> Task 3 Acoustic quality retry
      -> Task 4 Word timing silence guard
          -> Task 8 verification/docs for first shipping slice

Follow-ups after first slice:
Task 5 Phoneme-aware chunking
  -> rerun Task 8 focused verification
Task 6 Synthesis-time word timing
  -> rerun Task 8 focused verification
Task 7 Pronunciation preflight
  -> rerun Task 8 focused verification
```

## Self-Review Notes

- Spec coverage: first slice covers render-plan scaffolding, intentional pauses, acoustic retry behavior, and a timing guard for inserted silence.
- Follow-up coverage: Tasks 5, 6, and 7 explicitly cover smarter chunking, synthesis-time timing, and pronunciation preflight.
- Type consistency: `NarrationRenderPlanner.make(...)` produces `NarrationRenderPlan.blocks`; each block exposes `blockID`, `speechSegments`, `trailingSilence`, and `isSpeakable`.
- Privacy: the plan does not persist book text in repo docs. The only suggested generated report is local-only and ignored if created near a repo checkout.
