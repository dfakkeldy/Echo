# Kokoro Synthesis-Time Word Timing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Kokoro-narrated books exact per-word "karaoke" timing captured from the model's own duration predictor at synthesis time, replacing linear interpolation, with safe fallback.

**Architecture:** Bundle a 28 MB ONNX "duration head" (the encoder + duration-predictor subgraph extracted offline from the existing Kokoro model). At synthesis, run it alongside the waveform model with identical inputs to get per-phoneme-token frame durations; split the token stream on the space token (id 16) to recover per-word spans; normalize to the true sample count; accumulate across chunks; write `word_timing` rows with `source:"synthesis"`. This mirrors the existing interpolated→DTW `refine` flow: interpolation runs first as the baseline, synthesis overrides it per block, and any mismatch leaves the interpolated rows in place.

**Tech Stack:** Swift 6 (strict concurrency), ONNX Runtime (`OnnxRuntimeBindings`), GRDB, Swift Testing, MisakiSwift G2P. Offline extraction in Python 3 + `onnx`.

## Global Constraints

- Deployment floor: iOS 18.0 / macOS 15.0 / watchOS 11.0. Narration (`OnnxKokoroEngine`) compiles only under `#if os(iOS) || os(macOS)`; this feature lives entirely inside that boundary. No watchOS work.
- Swift 6 language mode is on (nightly #195): every new type crossing an isolation boundary must be `Sendable`; new engine code stays on the `OnnxKokoroEngine` actor.
- No DB schema change and no migration. `WordTimingRecord` already has `source` and `confidence`; add the string value `"synthesis"` (confidence `0.9`). Do not edit any `Schema_Vxx` file.
- Scope is Kokoro-narrated books only. Do not touch the imported-audiobook WhisperKit + `TokenDTW` path.
- The waveform model `model_fp16.onnx` stays byte-identical to its pinned download (`onnx-community/Kokoro-82M-v1.0-ONNX`, revision `1939ad2a8e416c0acfeecc08a694d14ef25f2231`, 163_234_740 B). Do not modify or re-host it.
- Duration-head output tensor name: `/encoder/predictor/ReduceSum_output_0`. Space token id: `16`. Boundary (BOS/EOS) token id: `0` (`KokoroPhonemeVocab.boundaryTokenId`). Sample rate: `24_000`.
- Feature is strictly additive: any failure (head model absent, run error, token/word-count mismatch) falls back to existing interpolation. Never regress below current behavior.
- Build/test: `make build-tests` once after code changes, then `make test-only FILTER=EchoTests/<Suite>`. Never run two xcodebuilds concurrently or enable parallel testing (16 GB machine).
- Commits follow Conventional Commits.

---

### Task 1: Add `ChunkWordTiming` and `TTSChunk.wordTimings`

**Files:**
- Modify: `EchoCore/Services/Narration/TTSEngine.swift:14-30`
- Test: `EchoTests/TTSChunkWordTimingTests.swift` (create)

**Interfaces:**
- Produces: `struct ChunkWordTiming: Sendable, Equatable { let wordIndex: Int; let start: TimeInterval; let end: TimeInterval }` and a new stored property `let wordTimings: [ChunkWordTiming]?` on `TTSChunk` (defaults to `nil` in the synthesized memberwise initializer, so existing `TTSChunk(samples:sampleRate:duration:)` call sites keep compiling).

- [ ] **Step 1: Write the failing test**

Create `EchoTests/TTSChunkWordTimingTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct TTSChunkWordTimingTests {
    @Test func chunkDefaultsToNilWordTimings() {
        let chunk = TTSChunk(samples: [0, 0], sampleRate: 24_000, duration: 0.1)
        #expect(chunk.wordTimings == nil)
    }

    @Test func silenceHasNilWordTimings() {
        let chunk = TTSChunk.silence(seconds: 0.5, sampleRate: 24_000)
        #expect(chunk.wordTimings == nil)
    }

    @Test func carriesWordTimingsWhenProvided() {
        let timings = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.2)]
        let chunk = TTSChunk(
            samples: [0], sampleRate: 24_000, duration: 0.2, wordTimings: timings)
        #expect(chunk.wordTimings == timings)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: FAIL — compile error: `ChunkWordTiming` not in scope and `TTSChunk` has no `wordTimings` argument.

- [ ] **Step 3: Add the type and field**

In `EchoCore/Services/Narration/TTSEngine.swift`, add above `TTSChunk` (after the `VoiceID` struct):

```swift
/// One rendered word within a synthesized chunk, timed relative to the chunk's
/// own start. Produced by the Kokoro duration head; `nil` on any engine that
/// can't emit timings (mock) or any failure (so the caller falls back to
/// interpolation). `Sendable` to cross the actor→main boundary inside `TTSChunk`.
nonisolated struct ChunkWordTiming: Sendable, Equatable {
    let wordIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}
```

In `TTSChunk`, add the stored property after `duration` (line 17):

```swift
    /// Per-word timing for this chunk (chunk-relative seconds), or `nil` when the
    /// engine can't produce it. Defaulted in the memberwise init so existing
    /// `TTSChunk(samples:sampleRate:duration:)` call sites are unaffected.
    let wordTimings: [ChunkWordTiming]? = nil
```

> Note: leave `TTSChunk.silence(...)` unchanged — it calls `TTSChunk(samples:sampleRate:duration:)`, which now takes `wordTimings` defaulted to `nil`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/TTSChunkWordTimingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/TTSEngine.swift EchoTests/TTSChunkWordTimingTests.swift
git commit -m "feat(narration): add ChunkWordTiming and TTSChunk.wordTimings field"
```

---

### Task 2: `KokoroWordTimer` — per-token frames → per-word timings

**Files:**
- Create: `EchoCore/Services/Narration/KokoroWordTimer.swift`
- Test: `EchoTests/KokoroWordTimerTests.swift`

**Interfaces:**
- Consumes: `ChunkWordTiming` (Task 1).
- Produces: `enum KokoroWordTimer { static func wordTimings(ids: [Int32], perTokenFrames: [Float], wordCount: Int, sampleCount: Int, sampleRate: Double) -> [ChunkWordTiming]? }`. Returns `nil` on any mismatch (frames count ≠ ids count, group count ≠ `wordCount`, non-positive totals). When non-nil, returns exactly `wordCount` entries with `wordIndex` `0..<wordCount`, monotonic non-overlapping, whose times sum to `sampleCount / sampleRate`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/KokoroWordTimerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct KokoroWordTimerTests {
    // ids: [BOS, 'a','a', space, 'b','b', EOS]; frames sum = 13; 1.0 s of audio.
    private let ids: [Int32] = [0, 43, 43, 16, 44, 44, 0]
    private let frames: [Float] = [1, 2, 2, 1, 3, 3, 1]

    @Test func mapsTwoWordsNormalizedToAudioLength() throws {
        let out = try #require(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: frames, wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000))
        #expect(out.count == 2)
        #expect(out[0].wordIndex == 0 && out[1].wordIndex == 1)
        // word 0 = tokens 1..2 → frames [1..5) of 13; word 1 = tokens 4..5 → [6..12)
        #expect(abs(out[0].start - 1.0 / 13.0) < 1e-6)
        #expect(abs(out[0].end - 5.0 / 13.0) < 1e-6)
        #expect(abs(out[1].start - 6.0 / 13.0) < 1e-6)
        #expect(abs(out[1].end - 12.0 / 13.0) < 1e-6)
        // monotonic, non-overlapping, within bounds
        #expect(out[1].start >= out[0].end)
        #expect(out[1].end <= 1.0 + 1e-9)
    }

    @Test func returnsNilWhenWordCountMismatch() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: frames, wordCount: 3,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenFramesCountMismatch() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: [1, 2, 3], wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenAllBoundary() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: [0, 0], perTokenFrames: [1, 1], wordCount: 1,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenNoFrames() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: [Float](repeating: 0, count: 7), wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: FAIL — `KokoroWordTimer` not in scope.

- [ ] **Step 3: Implement `KokoroWordTimer`**

Create `EchoCore/Services/Narration/KokoroWordTimer.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns the Kokoro duration head's per-token frame counts into per-word audio
/// spans. Words are runs of phoneme tokens between the space token (id 16) and
/// the BOS/EOS boundary token (id 0). Frame counts are normalized so the spans
/// sum to the real audio length (`sampleCount / sampleRate`), which absorbs the
/// duration predictor's rounding and any speed scaling.
///
/// Pure and deterministic — unit-tested without the model. Returns `nil` on any
/// inconsistency so the caller falls back to interpolation rather than emitting
/// wrong timings.
enum KokoroWordTimer {
    private static let spaceTokenId: Int32 = 16
    private static let boundaryTokenId: Int32 = KokoroPhonemeVocab.boundaryTokenId  // 0

    static func wordTimings(
        ids: [Int32], perTokenFrames: [Float], wordCount: Int,
        sampleCount: Int, sampleRate: Double
    ) -> [ChunkWordTiming]? {
        guard
            ids.count == perTokenFrames.count, !ids.isEmpty,
            wordCount > 0, sampleCount > 0, sampleRate > 0
        else { return nil }

        let totalFrames = perTokenFrames.reduce(0, +)
        guard totalFrames > 0 else { return nil }
        let secondsPerFrame = (Double(sampleCount) / sampleRate) / Double(totalFrames)

        var groups: [(start: Double, end: Double)] = []
        var cumulative: Double = 0
        var wordStart: Double?
        var wordEnd: Double = 0

        func closeWord() {
            if let s = wordStart {
                groups.append((s, wordEnd))
                wordStart = nil
            }
        }

        for (i, id) in ids.enumerated() {
            let f = Double(perTokenFrames[i])
            let tStart = cumulative * secondsPerFrame
            let tEnd = (cumulative + f) * secondsPerFrame
            cumulative += f
            if id == boundaryTokenId || id == spaceTokenId {
                closeWord()  // boundary/space ends a word; its own span is inter-word gap
                continue
            }
            if wordStart == nil { wordStart = tStart }
            wordEnd = tEnd
        }
        closeWord()

        guard groups.count == wordCount else { return nil }
        return groups.enumerated().map {
            ChunkWordTiming(wordIndex: $0.offset, start: $0.element.start, end: $0.element.end)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/KokoroWordTimerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/KokoroWordTimer.swift EchoTests/KokoroWordTimerTests.swift
git commit -m "feat(narration): add KokoroWordTimer token-frames-to-word-spans mapper"
```

---

### Task 3: `NarrationWordTimingAssembler` — chunk timings → block timings

**Files:**
- Create: `EchoCore/Services/Narration/NarrationWordTimingAssembler.swift`
- Test: `EchoTests/NarrationWordTimingAssemblerTests.swift`

**Interfaces:**
- Consumes: `ChunkWordTiming` (Task 1).
- Produces: `enum NarrationWordTimingAssembler { static func assemble(_ chunks: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)]) -> [ChunkWordTiming]? }`. Concatenates per-chunk word timings into block-level, file-relative timings: rebases `wordIndex` by the running word count and offsets `start`/`end` by `startInFile`. Returns `nil` if **any** chunk's `timings` is `nil` (whole block falls back) or the result is empty.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NarrationWordTimingAssemblerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationWordTimingAssemblerTests {
    @Test func concatenatesRebasingIndexAndOffsettingTime() throws {
        let chunkA = [
            ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.3),
            ChunkWordTiming(wordIndex: 1, start: 0.3, end: 0.6),
        ]
        let chunkB = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.4)]
        let out = try #require(
            NarrationWordTimingAssembler.assemble([
                (chunkA, 0.0),
                (chunkB, 0.6),  // second chunk starts 0.6 s into the file
            ]))
        #expect(out.map(\.wordIndex) == [0, 1, 2])
        #expect(abs(out[2].start - 0.6) < 1e-9 && abs(out[2].end - 1.0) < 1e-9)
    }

    @Test func returnsNilIfAnyChunkMissing() {
        let chunkA = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.3)]
        #expect(
            NarrationWordTimingAssembler.assemble([(chunkA, 0.0), (nil, 0.3)]) == nil)
    }

    @Test func returnsNilWhenEmpty() {
        #expect(NarrationWordTimingAssembler.assemble([]) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: FAIL — `NarrationWordTimingAssembler` not in scope.

- [ ] **Step 3: Implement the assembler**

Create `EchoCore/Services/Narration/NarrationWordTimingAssembler.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Concatenates per-chunk word timings into one block's file-relative word
/// timings. A block is synthesized as one or more chunks; this rebases each
/// chunk's 0-based `wordIndex` by the running word count and shifts its times by
/// the chunk's start offset in the chapter audio file.
///
/// All-or-nothing per block: if any chunk lacks timings (the duration head
/// failed or a sub-chunk was skipped), the whole block returns `nil` so the
/// caller keeps that block's interpolated rows. Pure and unit-testable.
enum NarrationWordTimingAssembler {
    static func assemble(
        _ chunks: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)]
    ) -> [ChunkWordTiming]? {
        var out: [ChunkWordTiming] = []
        var wordBase = 0
        for chunk in chunks {
            guard let timings = chunk.timings else { return nil }
            for t in timings {
                out.append(
                    ChunkWordTiming(
                        wordIndex: wordBase + t.wordIndex,
                        start: t.start + chunk.startInFile,
                        end: t.end + chunk.startInFile))
            }
            wordBase += timings.count
        }
        return out.isEmpty ? nil : out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationWordTimingAssemblerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationWordTimingAssembler.swift EchoTests/NarrationWordTimingAssemblerTests.swift
git commit -m "feat(narration): add NarrationWordTimingAssembler for block-level word timings"
```

---

### Task 4: `WordTimingMaterializer.refineWithSynthesis` — override interpolated rows

**Files:**
- Modify: `EchoCore/Services/WordTimingMaterializer.swift` (add a static method after `refine`, ~line 165)
- Test: `EchoTests/WordTimingSynthesisRefineTests.swift`

**Interfaces:**
- Consumes: `ChunkWordTiming` (Task 1); `WordTimingDAO` (existing) methods `words(forAudiobook:blockID:) -> [WordTimingRecord]` and `update([WordTimingRecord])`.
- Produces: `static func refineWithSynthesis(audiobookID: String, synthesisByBlock: [String: [ChunkWordTiming]], writer: DatabaseWriter) -> Int` (returns the number of blocks actually overridden). For each block: fetch its rows; only if `rows.count == timings.count` (count match — the safety guard against normalization/G2P word drift) override each row positionally with `source:"synthesis"`, `confidence:0.9`. Count mismatch leaves the block's interpolated rows untouched.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/WordTimingSynthesisRefineTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct WordTimingSynthesisRefineTests {
    private func seedInterpolated(_ db: DatabaseService) throws {
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 0, word: "one",
                audioStartTime: 0.0, audioEndTime: 0.5, confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 1, word: "two",
                audioStartTime: 0.5, audioEndTime: 1.0, confidence: 0.5, source: "interpolated"),
        ])
    }

    @Test func overridesWhenCountMatches() throws {
        let db = try DatabaseService(inMemory: ())
        try seedInterpolated(db)
        let overridden = WordTimingMaterializer.refineWithSynthesis(
            audiobookID: "bk",
            synthesisByBlock: [
                "b0": [
                    ChunkWordTiming(wordIndex: 0, start: 0.1, end: 0.4),
                    ChunkWordTiming(wordIndex: 1, start: 0.4, end: 0.9),
                ]
            ],
            writer: db.writer)
        #expect(overridden == 1)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(rows.allSatisfy { $0.source == "synthesis" && $0.confidence == 0.9 })
        #expect(abs(rows[0].audioStartTime - 0.1) < 1e-6)
        #expect(abs(rows[1].audioEndTime - 0.9) < 1e-6)
    }

    @Test func keepsInterpolatedWhenCountMismatch() throws {
        let db = try DatabaseService(inMemory: ())
        try seedInterpolated(db)
        let overridden = WordTimingMaterializer.refineWithSynthesis(
            audiobookID: "bk",
            synthesisByBlock: [
                "b0": [ChunkWordTiming(wordIndex: 0, start: 0.1, end: 0.4)]  // 1 vs 2 rows
            ],
            writer: db.writer)
        #expect(overridden == 0)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(rows.allSatisfy { $0.source == "interpolated" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: FAIL — `refineWithSynthesis` not found.

- [ ] **Step 3: Implement `refineWithSynthesis`**

In `EchoCore/Services/WordTimingMaterializer.swift`, add after `refine(...)` (after line 165, inside the enum):

```swift
    /// Confidence stamped on a word whose time came from the synthesis-time
    /// duration head (above interpolation 0.5; on par with / above DTW 0.85).
    private static let synthesisConfidence: Double = 0.9

    /// Overrides already-materialized interpolated word times with synthesis-time
    /// timings, per block, when the per-block word counts match. A count mismatch
    /// (text normalization / G2P changed the word tokenization) leaves that
    /// block's interpolated rows untouched — the safety guard for the
    /// phoneme-group↔source-word mapping. Returns the number of blocks overridden.
    ///
    /// Mirrors `refine(...)`: additive, retimes matched rows only, never adds or
    /// deletes rows. Call AFTER `materializeChapter` has written the interpolated
    /// baseline for these blocks.
    @discardableResult
    static func refineWithSynthesis(
        audiobookID: String,
        synthesisByBlock: [String: [ChunkWordTiming]],
        writer: DatabaseWriter
    ) -> Int {
        guard !synthesisByBlock.isEmpty else { return 0 }
        let dao = WordTimingDAO(db: writer)
        var updates: [WordTimingRecord] = []
        var blocksOverridden = 0
        for (blockID, timings) in synthesisByBlock {
            guard let rows = try? dao.words(forAudiobook: audiobookID, blockID: blockID),
                rows.count == timings.count, !rows.isEmpty
            else { continue }
            let rowsByIndex = rows.sorted { $0.wordIndex < $1.wordIndex }
            let timingsByIndex = timings.sorted { $0.wordIndex < $1.wordIndex }
            for (row, t) in zip(rowsByIndex, timingsByIndex) {
                var updated = row
                updated.audioStartTime = t.start
                updated.audioEndTime = t.end
                updated.confidence = synthesisConfidence
                updated.source = "synthesis"
                updates.append(updated)
            }
            blocksOverridden += 1
        }
        try? dao.update(updates)
        return blocksOverridden
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/WordTimingSynthesisRefineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/WordTimingMaterializer.swift EchoTests/WordTimingSynthesisRefineTests.swift
git commit -m "feat(narration): add WordTimingMaterializer.refineWithSynthesis override path"
```

---

### Task 5: Extract, bundle, and ship the duration-head model

**Files:**
- Create: `Tools/extract_kokoro_duration_head.py`
- Create (generated artifact): `EchoCore/Services/Narration/kokoro_dur_head.onnx` (~28 MB)
- Modify: `Echo.xcodeproj/project.pbxproj` (4 insertions, mirroring `_kokoro_vocab.json`)
- Optional: `.gitattributes` (LFS for `*.onnx` if the repo adopts LFS)

**Interfaces:**
- Produces: a bundled resource `kokoro_dur_head.onnx` resolvable via `NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx")`. Its single output is `/encoder/predictor/ReduceSum_output_0` with shape `[1, n_tokens]`; inputs are `input_ids`, `style`, `speed` (same as the waveform model).

- [ ] **Step 1: Write the extraction script**

Create `Tools/extract_kokoro_duration_head.py`:

```python
#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract the Kokoro duration-predictor subgraph as a standalone ONNX model.

Source: onnx-community/Kokoro-82M-v1.0-ONNX, file onnx/model_fp16.onnx,
revision 1939ad2a8e416c0acfeecc08a694d14ef25f2231 (163_234_740 bytes).
The full model exposes only `waveform`; the per-phoneme duration it computes
internally (`/encoder/predictor/ReduceSum_output_0`, shape [1, n_tokens]) is the
StyleTTS2 "duration as sum of 50 bins" tensor. We surface it as the sole output
of an extracted subgraph so Echo can read per-token frame durations at synthesis.

Usage:
  python3 Tools/extract_kokoro_duration_head.py \
    --source "$HOME/Library/Application Support/Narration/Models/kokoro-onnx-v6/model_fp16.onnx" \
    --out EchoCore/Services/Narration/kokoro_dur_head.onnx
"""
import argparse
import os
import sys

import onnx

EXPECTED_SOURCE_BYTES = 163_234_740
DURATION_TENSOR = "/encoder/predictor/ReduceSum_output_0"
INPUTS = ["input_ids", "style", "speed"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="path to model_fp16.onnx")
    ap.add_argument("--out", required=True, help="output .onnx path")
    args = ap.parse_args()

    size = os.path.getsize(args.source)
    if size != EXPECTED_SOURCE_BYTES:
        print(
            f"refusing: source is {size} bytes, expected {EXPECTED_SOURCE_BYTES} "
            "(wrong/corrupt model)",
            file=sys.stderr,
        )
        return 1

    onnx.utils.extract_model(args.source, args.out, INPUTS, [DURATION_TENSOR])

    # Verify the extracted model's output signature.
    m = onnx.load(args.out)
    outs = [o.name for o in m.graph.output]
    if outs != [DURATION_TENSOR]:
        print(f"unexpected outputs: {outs}", file=sys.stderr)
        return 1
    print(
        f"OK: wrote {args.out} ({os.path.getsize(args.out)} bytes), output {outs[0]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Generate the artifact and verify its signature**

Run (uses the model already cached on disk by a prior narration run; `/usr/bin/python3` has `onnx` installed):

```bash
/usr/bin/python3 Tools/extract_kokoro_duration_head.py \
  --source "$HOME/Library/Application Support/Narration/Models/kokoro-onnx-v6/model_fp16.onnx" \
  --out EchoCore/Services/Narration/kokoro_dur_head.onnx
/usr/bin/python3 -c "import onnx; m=onnx.load('EchoCore/Services/Narration/kokoro_dur_head.onnx'); print([o.name for o in m.graph.output], [[d.dim_param or d.dim_value for d in o.type.tensor_type.shape.dim] for o in m.graph.output])"
```

Expected: `OK: wrote EchoCore/Services/Narration/kokoro_dur_head.onnx (~28200000 bytes), output /encoder/predictor/ReduceSum_output_0` then `['/encoder/predictor/ReduceSum_output_0'] [[1, 'unk__...']]` (rank-2, batch 1).

> If the cached source model is absent, first run narration once in the app/sim (or download `model_fp16.onnx` from the pinned URL in `OnnxKokoroEngine`) so the source exists, then re-run.

- [ ] **Step 3: Add the resource to the Xcode project**

Edit `Echo.xcodeproj/project.pbxproj`, mirroring the four `_kokoro_vocab.json` entries. First generate two unique 24-hex IDs and confirm they're absent:

```bash
grep -c "B17D0C0FE17AC0DE0F0FE001\|B17D0C0FE17AC0DE0F0FE002" Echo.xcodeproj/project.pbxproj
```
Expected: `0` (if not 0, pick different IDs).

Insert, next to each corresponding `_kokoro_vocab.json` line:

1. In the `PBXBuildFile` section (next to the line `... _kokoro_vocab.json in Copy Narration Resources ... = {isa = PBXBuildFile; fileRef = 739F167A96954DC602A63519 ...};`):
```
		B17D0C0FE17AC0DE0F0FE001 /* kokoro_dur_head.onnx in Copy Narration Resources */ = {isa = PBXBuildFile; fileRef = B17D0C0FE17AC0DE0F0FE002 /* kokoro_dur_head.onnx */; };
```

2. In the `PBXFileReference` section (next to the `739F167A96954DC602A63519 /* _kokoro_vocab.json */ = {isa = PBXFileReference; ... path = EchoCore/Services/Narration/_kokoro_vocab.json; sourceTree = SOURCE_ROOT; };` line):
```
		B17D0C0FE17AC0DE0F0FE002 /* kokoro_dur_head.onnx */ = {isa = PBXFileReference; includeInIndex = 1; name = kokoro_dur_head.onnx; path = EchoCore/Services/Narration/kokoro_dur_head.onnx; sourceTree = SOURCE_ROOT; };
```

3. In the "Copy Narration Resources" build-phase `files = (...)` list (next to the `7D78649F9DA726D16DBDA244 /* _kokoro_vocab.json in Copy Narration Resources */,` entry):
```
				B17D0C0FE17AC0DE0F0FE001 /* kokoro_dur_head.onnx in Copy Narration Resources */,
```

4. In the group `children = (...)` list that contains `739F167A96954DC602A63519 /* _kokoro_vocab.json */,`:
```
				B17D0C0FE17AC0DE0F0FE002 /* kokoro_dur_head.onnx */,
```

> Alternative if you have the Xcode GUI: drag `kokoro_dur_head.onnx` into the Narration group, untick "Copy items if needed", and ensure target membership puts it in the **Copy Narration Resources** phase (not Compile Sources). Skip the manual UUID edits.

- [ ] **Step 4: Verify the project parses and the resource is wired**

Run:
```bash
plutil -lint Echo.xcodeproj/project.pbxproj
grep -c "kokoro_dur_head.onnx" Echo.xcodeproj/project.pbxproj
```
Expected: `OK` from plutil, and count `4`.

- [ ] **Step 5: (If repo uses git-lfs) track the binary**

Run:
```bash
git lfs version >/dev/null 2>&1 && echo "lfs available" || echo "no lfs"
```
If LFS is available and the repo already uses it (`.gitattributes` present), add:
```bash
git lfs track "EchoCore/Services/Narration/*.onnx"
git add .gitattributes
```
Otherwise commit the 28 MB file directly (acceptable; it is the repo's first large binary).

- [ ] **Step 6: Commit**

```bash
git add Tools/extract_kokoro_duration_head.py EchoCore/Services/Narration/kokoro_dur_head.onnx Echo.xcodeproj/project.pbxproj
git add .gitattributes 2>/dev/null || true
git commit -m "build(narration): bundle Kokoro duration-head ONNX + extraction script"
```

---

### Task 6: Run the duration head in `OnnxKokoroEngine` and fill `wordTimings`

**Files:**
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift`
- Test: `EchoTests/OnnxKokoroEngineWordTimingTests.swift` (gated integration test)

**Interfaces:**
- Consumes: `KokoroWordTimer.wordTimings(...)` (Task 2); bundled `kokoro_dur_head.onnx` (Task 5); existing `frontEnd.encode`, `Self.tensorData`, `NSData.toFloatArray`.
- Produces: `synthesize(_:voice:)` now returns a `TTSChunk` whose `wordTimings` is non-`nil` when the head loaded and the per-chunk mapping succeeded; `nil` otherwise. New private actor method `tokenDurations(forText:voice:) -> (ids: [Int32], frames: [Float])?` and stored `durationSession: ORTSession?`.

- [ ] **Step 1: Add the duration-session state and output-name constant**

In `OnnxKokoroEngine` (after `private var session: ORTSession?`, line 32):

```swift
        /// Optional second session: the extracted duration head (encoder +
        /// duration predictor). Loaded best-effort from the app bundle in
        /// `prepare()`; when nil, synthesis emits no word timings and callers fall
        /// back to interpolation. Same inputs as the waveform model.
        private var durationSession: ORTSession?
```

Near the model-location constants (after line 97):

```swift
        /// Bundled duration-head resource name and its sole output tensor.
        private nonisolated static let durationHeadResource = "kokoro_dur_head"
        private nonisolated static let durationOutputName = "/encoder/predictor/ReduceSum_output_0"
```

- [ ] **Step 2: Load the head in `prepare()` (best-effort) and store it**

In the `prepare(progress:)` init `Task`, replace the `self.store(env: env, session: session)` line (~line 156) with a head-loading block + extended store:

```swift
                // Best-effort: load the bundled duration head so synthesis can emit
                // exact word timings. Its absence or a load error is non-fatal — it
                // only disables timing (callers fall back to interpolation).
                var durationSession: ORTSession?
                if let headURL = NarrationResources.url(
                    forResource: Self.durationHeadResource, withExtension: "onnx")
                {
                    do {
                        let headOptions = try ORTSessionOptions()
                        try headOptions.setGraphOptimizationLevel(.all)
                        try headOptions.setIntraOpNumThreads(intraOpThreads)
                        durationSession = try ORTSession(
                            env: env, modelPath: headURL.path, sessionOptions: headOptions)
                    } catch {
                        logger.warning(
                            "Duration head load failed (word timing disabled): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    logger.warning("Duration head resource not bundled (word timing disabled).")
                }
                self.store(env: env, session: session, durationSession: durationSession)
```

Update `store(...)` (line 277):

```swift
        private func store(env: ORTEnv, session: ORTSession, durationSession: ORTSession?) {
            self.env = env
            self.session = session
            self.durationSession = durationSession
        }
```

- [ ] **Step 3: Add `tokenDurations(forText:voice:)`**

Add this method to `OnnxKokoroEngine` (e.g. after `runModel`, before `// MARK: - Private`):

```swift
        /// Runs the duration head for `text` to get per-token frame durations,
        /// returning the BOS/EOS-wrapped token ids alongside them (so callers can
        /// map tokens→words). `nil` when the head isn't loaded or anything fails —
        /// always a soft failure, never throwing into the synthesis path. `speed`
        /// is fixed at 1.0: it only globally scales durations, which the per-word
        /// normalization to the real sample count absorbs.
        private func tokenDurations(forText text: String, voice: VoiceID)
            -> (ids: [Int32], frames: [Float])?
        {
            guard let durationSession else { return nil }
            do {
                let (ids32, refS) = try frontEnd.encode(text: text, voice: voice)
                guard ids32.contains(where: { $0 != KokoroPhonemeVocab.boundaryTokenId }) else {
                    return nil
                }
                let ids64 = ids32.map { Int64($0) }
                let inputIds = try ORTValue(
                    tensorData: Self.tensorData(ids64), elementType: .int64,
                    shape: [NSNumber(value: 1), NSNumber(value: ids64.count)])
                let styleValue = try ORTValue(
                    tensorData: Self.tensorData(refS), elementType: .float,
                    shape: [NSNumber(value: 1), NSNumber(value: refS.count)])
                let speedValue = try ORTValue(
                    tensorData: Self.tensorData([Float(1.0)]), elementType: .float,
                    shape: [NSNumber(value: 1)])
                let outputs = try durationSession.run(
                    withInputs: ["input_ids": inputIds, "style": styleValue, "speed": speedValue],
                    outputNames: [Self.durationOutputName], runOptions: nil)
                guard let durValue = outputs[Self.durationOutputName] else { return nil }
                let frames = try durValue.tensorData().toFloatArray()
                guard frames.count == ids32.count else { return nil }
                return (ids32, frames)
            } catch {
                logger.warning(
                    "Duration head run failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
```

- [ ] **Step 4: Fill `wordTimings` in `synthesize`**

In `synthesize(_:voice:)`, replace the final two lines (the `let audioS` / `return TTSChunk(...)` at lines 200–201) with:

```swift
            let audioS = Double(samples.count) / 24_000

            // Word timings from the duration head (computed on the original text;
            // robust to the silence guard's internal speed nudges / splits via the
            // normalization in KokoroWordTimer). Soft-fails to nil → interpolation.
            var wordTimings: [ChunkWordTiming]?
            if let (ids, frames) = tokenDurations(forText: text, voice: voice) {
                let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
                wordTimings = KokoroWordTimer.wordTimings(
                    ids: ids, perTokenFrames: frames, wordCount: wordCount,
                    sampleCount: samples.count, sampleRate: 24_000)
            }
            return TTSChunk(
                samples: samples, sampleRate: 24_000, duration: audioS, wordTimings: wordTimings)
```

- [ ] **Step 5: Write the gated integration test**

Create `EchoTests/OnnxKokoroEngineWordTimingTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Real dual-session synthesis is heavy (downloads the 163 MB waveform model).
    /// Gated behind ECHO_RUN_KOKORO_TIMING_IT so the default suite stays fast; run
    /// on device/sim with the env var set, or rely on manual smoke verification.
    struct OnnxKokoroEngineWordTimingTests {
        @Test func synthesizeEmitsMonotonicWordTimings() async throws {
            try #require(
                ProcessInfo.processInfo.environment["ECHO_RUN_KOKORO_TIMING_IT"] == "1",
                "set ECHO_RUN_KOKORO_TIMING_IT=1 to run the heavy Kokoro timing IT")
            let engine = OnnxKokoroEngine()
            try await engine.prepare()
            let chunk = try await engine.synthesize("Hello there world.", voice: VoiceID("af_heart"))
            let timings = try #require(chunk.wordTimings, "expected synthesis word timings")
            #expect(timings.count == 3)
            for i in 1..<timings.count {
                #expect(timings[i].start >= timings[i - 1].end - 1e-3)
            }
            #expect(timings.last!.end <= chunk.duration + 1e-3)
        }
    }
#endif
```

- [ ] **Step 6: Verify build + pure suites still pass; run the IT manually if able**

Run: `make build-tests && make test-only FILTER=EchoTests/OnnxKokoroEngineWordTimingTests`
Expected: PASS (the test early-returns via `#require` unless `ECHO_RUN_KOKORO_TIMING_IT=1`). On a device/sim with the model, set the env var to exercise the real path.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Narration/OnnxKokoroEngine.swift EchoTests/OnnxKokoroEngineWordTimingTests.swift
git commit -m "feat(narration): run Kokoro duration head and emit per-word chunk timings"
```

---

### Task 7: Wire `NarrationService` to persist synthesis timings

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Test: `EchoTests/NarrationServiceSynthesisTimingTests.swift`

**Interfaces:**
- Consumes: `TTSChunk.wordTimings` (Task 1); `NarrationWordTimingAssembler.assemble` (Task 3); `WordTimingMaterializer.refineWithSynthesis` (Task 4).
- Produces: `RenderedNarrationFile` gains `let synthesisWordTimingsByBlock: [String: [ChunkWordTiming]]`; `persistRenderedNarration` calls `refineWithSynthesis` after `materializeChapter`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NarrationServiceSynthesisTimingTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationServiceSynthesisTimingTests {
    /// Engine that emits one ChunkWordTiming per whitespace word when `emit` is on.
    private final class WordTimedEngine: TTSEngine {
        let emit: Bool
        init(emit: Bool) { self.emit = emit }
        func prepare() async throws {}
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let dur = Double(max(words, 1)) * 0.2
            let samples = [Float](repeating: 0.05, count: Int(dur * 24_000))
            let timings: [ChunkWordTiming]? =
                emit
                ? (0..<words).map {
                    ChunkWordTiming(
                        wordIndex: $0, start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.2)
                } : nil
            return TTSChunk(
                samples: samples, sampleRate: 24_000,
                duration: Double(samples.count) / 24_000, wordTimings: timings)
        }
    }

    private func block(_ id: String, _ text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "b1", spineHref: "c.xhtml", spineIndex: 0, blockIndex: 0,
            sequenceIndex: 0, blockKind: "paragraph", text: text, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: 0, isHidden: false,
            hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    private func seed(_ db: DatabaseService, _ blocks: [EPubBlockRecord]) throws {
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-26T00:00:00Z')"
            )
        }
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
    }

    private func render(_ db: DatabaseService, emit: Bool) async throws {
        let svc = NarrationService(
            db: db.writer, audiobookID: "b1", tts: WordTimedEngine(emit: emit),
            audioWriter: MockAudioWriter(), cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState())
        try await svc.renderChapter(
            chapterIndex: 0, blocks: [block("blk0", "one two")], voice: VoiceID("af_heart"))
    }

    @Test func writesSynthesisRowsWhenEngineEmitsTimings() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, [block("blk0", "one two")])
        try await render(db, emit: true)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == "synthesis" })
    }

    @Test func keepsInterpolatedWhenEngineEmitsNoTimings() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, [block("blk0", "one two")])
        try await render(db, emit: false)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == "interpolated" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests`
Expected: FAIL — `RenderedNarrationFile` has no `synthesisWordTimingsByBlock`; synthesis rows not written.

- [ ] **Step 3: Add the field to `RenderedNarrationFile`**

In `NarrationService.swift`, add to the `RenderedNarrationFile` struct (after `spokenBlockIDs`, line 90):

```swift
        /// Per-block file-relative word timings captured at synthesis (empty when
        /// the engine emitted none). Applied over the interpolated baseline.
        let synthesisWordTimingsByBlock: [String: [ChunkWordTiming]]
```

- [ ] **Step 4: Collect and assemble timings in `renderNarrationFile`**

In `renderNarrationFile`, declare an accumulator next to `var anchors` (line 349):

```swift
        var synthesisWordTimingsByBlock: [String: [ChunkWordTiming]] = [:]
```

Replace the inner sub-chunk loop (lines 371–388) with one that captures each chunk's timing + file offset:

```swift
            var blockDuration: TimeInterval = 0
            var blockChunkTimings: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)] = []
            for subText in NarrationTextChunker.split(text) {
                try Task.checkCancellation()
                do {
                    let chunkStartInFile = cursor + blockDuration
                    let chunk = try await tts.synthesize(subText, voice: voice)
                    try await stream.append(chunk)
                    blockChunkTimings.append((chunk.wordTimings, chunkStartInFile))
                    blockDuration += chunk.duration
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isLengthCapError(error) {
                    logger.error(
                        "Skipping over-long sub-chunk in block \(block.id): \(error.localizedDescription)"
                    )
                    continue
                }
            }
            if let assembled = NarrationWordTimingAssembler.assemble(blockChunkTimings) {
                synthesisWordTimingsByBlock[block.id] = assembled
            }
```

In the `return RenderedNarrationFile(...)` (line 421), add the argument:

```swift
            spokenBlockIDs: spoken.map(\.id),
            synthesisWordTimingsByBlock: synthesisWordTimingsByBlock)
```

- [ ] **Step 5: Apply the override in `persistRenderedNarration`**

In `persistRenderedNarration`, immediately after the `WordTimingMaterializer.materializeChapter(...)` call (line 280–281), add:

```swift
                let overridden = WordTimingMaterializer.refineWithSynthesis(
                    audiobookID: audiobookID,
                    synthesisByBlock: rendered.synthesisWordTimingsByBlock,
                    writer: db)
                if !rendered.synthesisWordTimingsByBlock.isEmpty {
                    logger.notice(
                        "Synthesis word timing: \(overridden, privacy: .public)/\(rendered.synthesisWordTimingsByBlock.count, privacy: .public) blocks overrode interpolation (rest fell back)."
                    )
                }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationServiceSynthesisTimingTests`
Expected: PASS (2 tests). Then run the existing suite to confirm no regression:
Run: `make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift EchoTests/NarrationServiceSynthesisTimingTests.swift
git commit -m "feat(narration): persist synthesis-time word timings, fall back to interpolation"
```

---

### Task 8: Documentation sync

**Files:**
- Modify: `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update ARCHITECTURE.md**

In the narration / alignment section, add a paragraph (place it near the existing narration pipeline description):

```markdown
**Synthesis-time word timing (Kokoro):** For Echo-narrated books, per-word
read-along timing is captured at synthesis instead of being interpolated. A
28 MB ONNX "duration head" — the encoder + duration-predictor subgraph extracted
offline from `model_fp16.onnx` (see `Tools/extract_kokoro_duration_head.py`) and
bundled as `kokoro_dur_head.onnx` — runs alongside the waveform model in
`OnnxKokoroEngine` with identical inputs. `KokoroWordTimer` splits the phoneme
token stream on the space token (id 16), sums per-token frame durations per word,
and normalizes to the true sample count. `NarrationService` accumulates these
across chunks and `WordTimingMaterializer.refineWithSynthesis` overrides the
interpolated `word_timing` rows (`source:"synthesis"`, confidence 0.9). Any
failure (head absent, run error, word-count mismatch) leaves the interpolated
baseline in place. Imported audiobooks are unaffected — they keep the
WhisperKit + `TokenDTW` path.
```

- [ ] **Step 2: Update README.md**

Where read-along / narration features are listed, add one line:

```markdown
- On-device narrated books get exact word-by-word read-along highlighting, timed from the speech synthesizer itself (no transcription pass).
```

- [ ] **Step 3: Update CHANGELOG.md**

Under the current unreleased/nightly section:

```markdown
### Added
- Exact per-word read-along timing for Kokoro-narrated books, captured at synthesis from the model's duration predictor (replaces interpolation; falls back to it on any mismatch).
```

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md README.md CHANGELOG.md
git commit -m "docs: document synthesis-time word timing for narrated books"
```

---

## Self-Review

**Spec coverage:**
- Duration head extraction + bundle (spec §6, App. A) → Task 5. ✓
- Run head, per-token durations (spec §5, §6) → Task 6. ✓
- Token→word via space id 16, normalize to sample count (spec §3, §7) → Task 2. ✓
- Chunk-offset + block word-index accumulation (spec §7) → Tasks 3, 7. ✓
- `source:"synthesis"` conf 0.9, no schema change (spec §6, §7) → Tasks 1, 4. ✓
- Graceful degradation to interpolation on every failure (spec §8) → Tasks 4 (count guard), 6 (soft-fail), 7 (assembler nil). ✓
- Mismatch logging (spec §10) → Task 7 Step 5. ✓
- Pure unit tests + gated integration + golden monotonic checks (spec §9) → Tasks 2, 3, 4 (unit), 6 (gated IT, monotonic), 7 (service). ✓
- Reproducible extraction script (spec §6) → Task 5 Step 1. ✓
- Doc sync (spec §11) → Task 8. ✓
- Scope = narrated only; imported path untouched (spec §4) → no task edits WhisperKit/TokenDTW. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `ChunkWordTiming(wordIndex:start:end:)` used identically across Tasks 1–7. `KokoroWordTimer.wordTimings(ids:perTokenFrames:wordCount:sampleCount:sampleRate:)`, `NarrationWordTimingAssembler.assemble(_:)`, `WordTimingMaterializer.refineWithSynthesis(audiobookID:synthesisByBlock:writer:)`, and `RenderedNarrationFile.synthesisWordTimingsByBlock` are referenced consistently. `durationOutputName` / `durationHeadResource` defined in Task 6 and used there. ✓
