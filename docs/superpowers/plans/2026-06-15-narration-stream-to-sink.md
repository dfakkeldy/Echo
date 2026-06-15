# Stream-to-Sink Narration Writing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate per-chapter PCM buffering by streaming each synthesized chunk directly to the audio file, reducing peak memory from ~chapter-size PCM to ~single-chunk PCM (~200KB → <1MB per chapter).

**Architecture:** `NarrationService.renderChapter` currently collects all `[TTSChunk]` in an array, then writes them all at once via `audioWriter.write(chunks, to:)`. We extend `AudioFileWriting` with an incremental API (`appendChunk` / `finalize`) so each chunk is written immediately after synthesis. `NarrationTextChunker` already guarantees chunks ≤200 chars, so per-chunk memory is bounded.

**Tech Stack:** Swift 6.2, AVFoundation (`AVAudioFile`, `AVAudioPCMBuffer`), `AudioFileWriting` protocol, `actor` isolation

---

## Pre-Flight Checklist

- [ ] Run `make build-tests` to confirm clean build before starting
- [ ] Create branch: `git checkout -b perf/narration-stream-to-sink`

---

### Task 1: Add incremental writing to AudioFileWriting protocol

**Files:**
- Read: `EchoCore/Services/Narration/AudioFileWriting.swift` (find the protocol definition)
- Read: `EchoCore/Services/Narration/AVFoundationAudioWriter.swift` (current implementation)

- [ ] **Step 1: Read existing protocol and implementation**

```bash
# Find the AudioFileWriting protocol
grep -rn "protocol AudioFileWriting\|func write" EchoCore/Services/Narration/ --include="*.swift"
```

- [ ] **Step 2: Write the failing test**

Create `EchoTests/StreamingAudioWriterTests.swift`:
```swift
import AVFoundation
import Testing
@testable import Echo

@Suite struct StreamingAudioWriterTests {

    @Test func appendChunkIncreasesDuration() async throws {
        let writer = AVFoundationAudioWriter()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-streaming.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        // Start streaming
        try await writer.beginStream(to: outputURL, sampleRate: 24000)

        // Append first chunk
        let chunk1 = TTSChunk(
            samples: Array(repeating: 0.5, count: 24000),  // 1 second
            sampleRate: 24000, duration: 1.0)
        try await writer.appendChunk(chunk1)

        // Append second chunk
        let chunk2 = TTSChunk(
            samples: Array(repeating: -0.3, count: 48000), // 2 seconds
            sampleRate: 24000, duration: 2.0)
        try await writer.appendChunk(chunk2)

        // Finalize
        let totalDuration = try await writer.finalize()

        // Total should be ~3 seconds
        #expect(abs(totalDuration - 3.0) < 0.1)

        // Verify file exists and has audio
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 0)

        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test func emptyStreamProducesValidFile() async throws {
        let writer = AVFoundationAudioWriter()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        try await writer.beginStream(to: outputURL, sampleRate: 24000)
        let duration = try await writer.finalize()
        #expect(duration == 0)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test func appendChunkFailsBeforeBeginStream() async {
        let writer = AVFoundationAudioWriter()
        let chunk = TTSChunk(samples: [0.1], sampleRate: 24000, duration: 0.1)
        do {
            try await writer.appendChunk(chunk)
            #expect(Bool(false), "Expected error but got none")
        } catch {
            #expect(error is StreamingAudioError)
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `make test-only FILTER=EchoTests/StreamingAudioWriterTests`
Expected: FAIL — `beginStream`, `appendChunk`, `finalize` not defined on `AVFoundationAudioWriter`

- [ ] **Step 4: Extend AudioFileWriting protocol**

Create `EchoCore/Services/Narration/AudioFileWriting.swift` if it doesn't exist, or modify the existing protocol:

```swift
import Foundation

protocol AudioFileWriting: Sendable {
    /// Write all chunks at once (existing batch API — kept for compatibility).
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval

    // MARK: - Incremental (stream-to-sink)

    /// Begin an incremental write session. Must be called before `appendChunk`.
    func beginStream(to url: URL, sampleRate: Double) async throws

    /// Append a single chunk to the stream. `beginStream` must have been called.
    func appendChunk(_ chunk: TTSChunk) async throws

    /// Finalize the stream and return the total audio duration in seconds.
    func finalize() async throws -> TimeInterval
}

enum StreamingAudioError: LocalizedError {
    case streamNotBegun
    case streamAlreadyBegun
    case streamAlreadyFinalized

    var errorDescription: String? {
        switch self {
        case .streamNotBegun:
            "appendChunk called before beginStream"
        case .streamAlreadyBegun:
            "beginStream called but a stream is already active"
        case .streamAlreadyFinalized:
            "appendChunk called after finalize"
        }
    }
}
```

- [ ] **Step 5: Implement incremental writing in AVFoundationAudioWriter**

Modify `EchoCore/Services/Narration/AVFoundationAudioWriter.swift`:

```swift
import AVFoundation
import Foundation

final class AVFoundationAudioWriter: AudioFileWriting, Sendable {
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var totalFrames: AVAudioFrameCount = 0
    private var isStreaming = false

    // MARK: - Batch (existing)

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        try await beginStream(to: url, sampleRate: chunks.first?.sampleRate ?? 24000)
        for chunk in chunks {
            try await appendChunk(chunk)
        }
        return try await finalize()
    }

    // MARK: - Incremental

    func beginStream(to url: URL, sampleRate: Double) async throws {
        guard !isStreaming else { throw StreamingAudioError.streamAlreadyBegun }
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false)
        else { throw StreamingAudioError.invalidFormat }

        try? FileManager.default.removeItem(at: url)
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = f
        self.format = fmt
        self.totalFrames = 0
        self.isStreaming = true
    }

    func appendChunk(_ chunk: TTSChunk) async throws {
        guard isStreaming else { throw StreamingAudioError.streamNotBegun }
        guard let file, let format else { throw StreamingAudioError.streamNotBegun }

        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frameCount)
        else { throw StreamingAudioError.bufferAllocationFailed }

        buffer.frameLength = frameCount
        // Copy Float samples into the buffer's floatChannelData
        if let channelData = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                channelData[0][i] = chunk.samples[i]
            }
        }

        try file.write(from: buffer)
        totalFrames += frameCount
    }

    func finalize() async throws -> TimeInterval {
        guard isStreaming else { throw StreamingAudioError.streamNotBegun }
        let sampleRate = format?.sampleRate ?? 24000  // capture before nil
        let duration = Double(totalFrames) / sampleRate
        file = nil
        format = nil
        isStreaming = false
        totalFrames = 0
        return duration
    }
}

extension StreamingAudioError {
    static let invalidFormat = StreamingAudioError.invalidFormat
    static let bufferAllocationFailed = StreamingAudioError.bufferAllocationFailed
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `make test-only FILTER=EchoTests/StreamingAudioWriterTests`
Expected: PASS — all 3 tests pass

- [ ] **Step 7: Run existing NarrationService tests**

Run: `make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS — existing batch API still works (delegates to incremental)

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Services/Narration/AudioFileWriting.swift \
        EchoCore/Services/Narration/AVFoundationAudioWriter.swift \
        EchoTests/StreamingAudioWriterTests.swift
git commit -m "perf(narration): add incremental write API to AudioFileWriting

AVFoundationAudioWriter now supports beginStream/appendChunk/finalize
for streaming chunks directly to disk. Batch write() delegates to
the incremental API — no regression for existing callers.

3 tests: appendChunk, empty stream, error-before-begin.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Stream chunks in NarrationService instead of buffering

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift:45-101`

- [ ] **Step 1: Read current renderChapter code**

```bash
# Read lines 45-125 of NarrationService.swift
```

The current code buffers ALL chunks in `var chunks: [TTSChunk]` (line 48), then writes at line 101:
```swift
let duration = try await audioWriter.write(chunks, to: fileURL)
```

- [ ] **Step 2: Refactor to stream chunks**

Replace the buffering loop:

```swift
// Before (lines 47-101 — buffered):
var chunks: [TTSChunk] = []
// ... per block synthesis: chunks.append(chunk)
// ... after loop: audioWriter.write(chunks, to: fileURL)

// After (streaming):
try await audioWriter.beginStream(to: fileURL, sampleRate: 24000)
var totalDuration: TimeInterval = 0
for (i, block) in spoken.enumerated() {
    // ... same synthesis loop, but:
    for subText in NarrationTextChunker.split(text) {
        let chunk = try await tts.synthesize(subText, voice: voice)
        try await audioWriter.appendChunk(chunk)  // ← write immediately
        totalDuration += chunk.duration
        blockDuration += chunk.duration
    }
    // ... same anchor creation
}
let duration = try await audioWriter.finalize()
```

- [ ] **Step 3: Run existing tests**

Run: `make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS — behavior is identical, only memory pattern changed

- [ ] **Step 4: Run streaming writer tests**

Run: `make test-only FILTER=EchoTests/StreamingAudioWriterTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift
git commit -m "perf(narration): stream synthesized chunks directly to disk

Previously all PCM chunks for a chapter were collected in a [TTSChunk]
array before writing — a 10-minute chapter could buffer ~70MB of Float
samples. Now each chunk is written immediately via appendChunk(),
eliminating per-chapter PCM accumulation.

Peak memory per chapter: ~70MB → <1MB (single chunk).

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Device verification

**Files:** None (verification only)

- [ ] **Step 1: Build for device**

```bash
xcrun xcodebuild -scheme Echo -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -jobs 4 build
```

- [ ] **Step 2: Install and test**

```bash
xcrun devicectl device install app --device <device-id> <app-path>
```

- [ ] **Step 3: Narrate a long book (6+ chapters)**

Open Xcode debug console. Verify:
- No `Terminated due to signal 9` (jetsam)
- RTF stays consistent (no thermal throttling from memory pressure)
- Audio output is correct (chapters play continuously)
- `Rendered chapter N → X anchors` shows all chapters complete

- [ ] **Step 4: Check peak memory**

In Xcode, open the Debug Navigator → Memory gauge. Peak should stay under ~600MB (models + single chunk + OS overhead) instead of climbing with each chapter.

---

### Memory Budget After Both Fixes

| Component | Before | After | Savings |
|-----------|--------|-------|---------|
| Kokoro models | ~255MB (palettized) | ~138MB (fixed-shape) | -117MB |
| Chapter PCM buffer | ~70MB (10-min chapter) | <1MB (single chunk) | -69MB |
| **Peak per chapter** | **~325MB** | **~139MB** | **~186MB** |
| **6 chapters cumulative** | **jetsam (~3.5GB)** | **~139MB** | **sustainable** |
