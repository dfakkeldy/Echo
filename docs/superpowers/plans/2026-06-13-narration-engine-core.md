# Narration Engine Core + Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and fully unit-test the on-device narration *engine core* — the schema, seams, state, text normalization, and the chapter-render orchestration that writes tracks + `.synthesized` alignment anchors — entirely against a mock TTS engine, so the real Kokoro integration drops into a verified contract.

**Architecture:** MVVM + a `@MainActor` service (`NarrationService`) that drives an injected `TTSEngine` protocol (mocked here, Kokoro later) and an injected `AudioFileWriting` protocol, writing one `TrackRecord` per chapter and one `.synthesized` `AlignmentAnchorRecord` per text block into the existing GRDB store. Mirrors the existing `AutoAlignmentService` + `AutoAlignmentState` sibling.

**Tech Stack:** Swift 6, SwiftUI, GRDB, Swift Testing (`import Testing`), Xcode `make` targets.

---

## Plan sequence (this document = Plan 1 of 5)

This plan covers the fully-specifiable, mock-backed core. Each later plan is its own document and starts with a short codebase-dig where noted:

- **Plan 1 (this doc):** Schema + engine core + seams + `NarrationService.renderChapter`, all TDD against mocks. *No audible output yet.*
- **Plan 2:** Standalone audio-less EPUB import (create an `AudiobookRecord` with `epub_block`s and zero tracks; reading/study works). *Needs a dig for EPUB test fixtures.*
- **Plan 3:** Real `KokoroTTSEngine` (CoreML/ANE) + `MisakiPhonemizer` + one-time model download + the **iPhone 12 Pro benchmark spike**. *Exploratory — starts with a spike, not pure TDD.*
- **Plan 4:** UI — the read-first "Listen" nudge in `NowPlayingTab`, `VoicePickerSheet`, `NarrationStatusView`, `BookDetailViewModel` wiring, render-ahead scheduling.
- **Plan 5 (Phase 2):** Export — per-chapter files (cheap) and `.m4b` (AVFoundation + the Apache `swift-audio-marker` atom writer).

Spec: [docs/superpowers/specs/2026-06-13-epub-ai-narration-design.md](../specs/2026-06-13-epub-ai-narration-design.md).

---

## Conventions (read once)

- **Adding files to the build:** new source files go under `EchoCore/Services/Narration/`; new tests under `EchoTests/` (flat, house style) and mocks under `EchoTests/Mocks/`. After creating any new file, ensure it is a member of the `Echo` target (source) or `EchoTests` target (tests). If `Echo.xcodeproj` uses Xcode-16 synchronized folder groups they are picked up automatically; otherwise add the file reference in Xcode before building.
- **Test loop:** after adding/renaming files run `make build-tests` once, then iterate with `make test-only FILTER=EchoTests/<SuiteName>`. Never enable parallel testing (16 GB machine).
- **Red state in Swift TDD:** because Swift won't compile a reference to a not-yet-defined symbol, the "failing test" step often manifests as a **compile error** (`cannot find 'X' in scope`). That is the legitimate red state — proceed to implement, then go green.
- **Commit style:** Conventional Commits, one commit per task.

---

## File structure

**Create:**
- `Shared/Database/Migrations/Schema_V17.swift` — adds `track.narration_voice`.
- `EchoCore/Services/Narration/TTSEngine.swift` — `TTSEngine` protocol, `TTSChunk`, `VoiceID`.
- `EchoCore/Services/Narration/VoiceCatalog.swift` — the curated voices + default.
- `EchoCore/Services/Narration/AudioFileWriting.swift` — `AudioFileWriting` protocol.
- `EchoCore/Services/Narration/NarrationState.swift` — `@Observable` progress (mirrors `AutoAlignmentState`).
- `EchoCore/Services/Narration/TextNormalizer.swift` — pure text→speakable normalization.
- `EchoCore/Services/Narration/NarrationService.swift` — `renderChapter` orchestration.
- `EchoTests/Mocks/MockTTSEngine.swift`, `EchoTests/Mocks/MockAudioWriter.swift`.
- `EchoTests/AlignmentAnchorSourceTests.swift`, `EchoTests/SchemaV17Tests.swift`, `EchoTests/VoiceCatalogTests.swift`, `EchoTests/NarrationStateTests.swift`, `EchoTests/TextNormalizerTests.swift`, `EchoTests/NarrationServiceTests.swift`.

**Modify:**
- `Shared/Database/AlignmentAnchorRecord.swift` — add `.synthesized` to `Source`.
- `Shared/Database/DatabaseService.swift:84-103` — register the V17 migration.

---

## Task 1: Add `.synthesized` anchor source

**Files:**
- Modify: `Shared/Database/AlignmentAnchorRecord.swift:44-51`
- Test: `EchoTests/AlignmentAnchorSourceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/AlignmentAnchorSourceTests.swift
import Testing
@testable import Echo

@Suite struct AlignmentAnchorSourceTests {
    @Test func synthesizedHasStableRawValue() {
        #expect(AlignmentAnchorRecord.Source.synthesized.rawValue == "synthesized")
    }

    @Test func synthesizedRoundTripsFromRawValue() {
        #expect(AlignmentAnchorRecord.Source(rawValue: "synthesized") == .synthesized)
    }
}
```

- [ ] **Step 2: Build the test target to verify it fails**

Run: `make build-tests`
Expected: FAIL to compile — `type 'AlignmentAnchorRecord.Source' has no member 'synthesized'`.

- [ ] **Step 3: Add the case**

In `Shared/Database/AlignmentAnchorRecord.swift`, add the final case to the `Source` enum:

```swift
    enum Source: String {
        case moveToNow = "moveToNow"
        case searchResult = "searchResult"
        case chapterBoundary = "chapterBoundary"
        case imported = "imported"
        case autoAlignment = "autoAlignment"
        case continuousBackground = "continuousBackground"
        case synthesized = "synthesized"   // TTS-generated narration anchors
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/AlignmentAnchorSourceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/AlignmentAnchorRecord.swift EchoTests/AlignmentAnchorSourceTests.swift
git commit -m "feat(alignment): add .synthesized anchor source for TTS narration"
```

---

## Task 2: Schema V17 — `track.narration_voice` column

**Why:** to record which voice rendered each chapter, enabling forward-only voice changes (spec §3.5). A non-null `narration_voice` also marks a track as synthesized. `source` needs no migration (free-text column).

**Files:**
- Create: `Shared/Database/Migrations/Schema_V17.swift`
- Modify: `Shared/Database/DatabaseService.swift:84-103`
- Test: `EchoTests/SchemaV17Tests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/SchemaV17Tests.swift
import Testing
import GRDB
@testable import Echo

@MainActor
@Suite struct SchemaV17Tests {
    @Test func v17AddsNarrationVoiceColumnToTrack() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(track)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("narration_voice"))
    }

    @Test func v17NarrationVoiceIsNullable() throws {
        let db = try DatabaseService(inMemory: ())
        // Inserting a track without narration_voice must succeed.
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('b1', 'Book', 0, '2026-06-13T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO track (id, audiobook_id, title, duration, file_path, is_enabled, sort_order)
                VALUES ('t1', 'b1', 'Ch 1', 0, '/tmp/x.m4a', 1, 0)
                """)
        }
        let v = try db.read { db in
            try String.fetchOne(db, sql: "SELECT narration_voice FROM track WHERE id = 't1'")
        }
        #expect(v == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV17Tests`
Expected: FAIL — `v17AddsNarrationVoiceColumnToTrack` fails (`narration_voice` absent).

- [ ] **Step 3: Create the migration and register it**

Create `Shared/Database/Migrations/Schema_V17.swift`:

```swift
import GRDB

enum Schema_V17 {
    nonisolated static func migrate(_ db: Database) throws {
        // Narration: record which TTS voice rendered each track (chapter).
        // Non-null marks a synthesized track; enables forward-only voice changes.
        try db.alter(table: "track") { t in
            t.add(column: "narration_voice", .text)
        }
    }
}
```

In `Shared/Database/DatabaseService.swift`, add the registration immediately after the V16 line (around line 102):

```swift
        migrator.registerMigration("v16_fsrs_cloze_transcript") { db in try Schema_V16.migrate(db) }
        migrator.registerMigration("v17_track_narration_voice") { db in try Schema_V17.migrate(db) }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV17Tests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/Migrations/Schema_V17.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV17Tests.swift
git commit -m "feat(db): V17 add track.narration_voice for synthesized narration"
```

---

## Task 3: TTS seam types — `TTSEngine`, `TTSChunk`, `VoiceID`

**Files:**
- Create: `EchoCore/Services/Narration/TTSEngine.swift`
- Test: covered by Task 5/7 (these are plain types; no behavior to test alone).

- [ ] **Step 1: Create the seam types**

```swift
// EchoCore/Services/Narration/TTSEngine.swift
import Foundation

/// Identifier for a narration voice (e.g. a Kokoro voicepack key).
struct VoiceID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A rendered span of speech audio for one block of text.
/// Samples are mono Float PCM at `sampleRate`. `Sendable` so it can cross
/// the actor→main boundary safely (no non-Sendable AVAudioPCMBuffer).
struct TTSChunk: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
}

/// The swappable narration engine boundary. Mocked in tests; Kokoro in Plan 3.
protocol TTSEngine: Sendable {
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `make build-tests`
Expected: PASS (compiles; no tests yet).

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Services/Narration/TTSEngine.swift
git commit -m "feat(narration): add TTSEngine seam (TTSEngine, TTSChunk, VoiceID)"
```

---

## Task 4: Voice catalog (curated 4 + default)

**Files:**
- Create: `EchoCore/Services/Narration/VoiceCatalog.swift`
- Test: `EchoTests/VoiceCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/VoiceCatalogTests.swift
import Testing
@testable import Echo

@Suite struct VoiceCatalogTests {
    @Test func hasFourCuratedVoices() {
        #expect(VoiceCatalog.all.count == 4)
    }

    @Test func defaultIsWarmUSFemaleAva() {
        #expect(VoiceCatalog.default.id == VoiceID("af_warm"))
        #expect(VoiceCatalog.default.displayName == "Ava")
    }

    @Test func allVoicesAreUnique() {
        let ids = VoiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupByIDReturnsMatch() {
        #expect(VoiceCatalog.voice(for: VoiceID("af_warm"))?.displayName == "Ava")
        #expect(VoiceCatalog.voice(for: VoiceID("nope")) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests`
Expected: FAIL to compile — `cannot find 'VoiceCatalog' in scope`.

- [ ] **Step 3: Implement**

```swift
// EchoCore/Services/Narration/VoiceCatalog.swift
import Foundation

struct NarrationVoice: Identifiable, Hashable, Sendable {
    let id: VoiceID
    let displayName: String
    let descriptor: String   // e.g. "US · warm"
    let sampleClipName: String  // bundled preview clip (added in Plan 4)
}

enum VoiceCatalog {
    /// Curated set (spec §3.2). Kokoro voicepack keys as raw IDs.
    static let all: [NarrationVoice] = [
        NarrationVoice(id: VoiceID("af_warm"),  displayName: "Ava",     descriptor: "US · warm",   sampleClipName: "voice_ava"),
        NarrationVoice(id: VoiceID("am_steady"), displayName: "Michael", descriptor: "US · steady", sampleClipName: "voice_michael"),
        NarrationVoice(id: VoiceID("bf_bright"), displayName: "Emma",    descriptor: "UK · bright", sampleClipName: "voice_emma"),
        NarrationVoice(id: VoiceID("bm_deep"),   displayName: "George",  descriptor: "UK · deep",   sampleClipName: "voice_george"),
    ]

    static let `default`: NarrationVoice = all[0]

    static func voice(for id: VoiceID) -> NarrationVoice? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/VoiceCatalogTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/VoiceCatalog.swift EchoTests/VoiceCatalogTests.swift
git commit -m "feat(narration): curated voice catalog with Ava (US, warm) default"
```

---

## Task 5: `AudioFileWriting` seam + `NarrationState`

**Files:**
- Create: `EchoCore/Services/Narration/AudioFileWriting.swift`, `EchoCore/Services/Narration/NarrationState.swift`
- Test: `EchoTests/NarrationStateTests.swift`

- [ ] **Step 1: Write the failing test (state)**

```swift
// EchoTests/NarrationStateTests.swift
import Testing
@testable import Echo

@MainActor
@Suite struct NarrationStateTests {
    @Test func startsIdleAndNotRunning() {
        let s = NarrationState()
        #expect(s.phase == .idle)
        #expect(s.isRunning == false)
    }

    @Test func preparingChapterIsRunning() {
        let s = NarrationState()
        s.update(phase: .preparingChapter, progress: 0.1, statusMessage: "Preparing chapter…")
        #expect(s.isRunning == true)
        #expect(s.progress == 0.1)
    }

    @Test func failSetsFailedAndMessage() {
        let s = NarrationState()
        s.fail("boom")
        #expect(s.phase == .failed)
        #expect(s.errorMessage == "boom")
        #expect(s.isRunning == false)
    }

    @Test func resetReturnsToIdle() {
        let s = NarrationState()
        s.update(phase: .renderingAhead, progress: 0.5, statusMessage: "x")
        s.reset()
        #expect(s.phase == .idle)
        #expect(s.progress == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests`
Expected: FAIL to compile — `cannot find 'NarrationState' in scope`.

- [ ] **Step 3: Implement both files**

```swift
// EchoCore/Services/Narration/AudioFileWriting.swift
import Foundation

/// Writes rendered PCM chunks to a single on-disk audio file (AAC).
/// Mocked in tests; the AVFoundation implementation arrives in Plan 3.
protocol AudioFileWriting: Sendable {
    /// Concatenate `chunks` into one file at `url`. Returns total duration written.
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval
}
```

```swift
// EchoCore/Services/Narration/NarrationState.swift
import Foundation
import Observation

/// Observable progress for narration rendering. Mirrors AutoAlignmentState.
@MainActor @Observable
final class NarrationState {
    enum Phase: String, Sendable {
        case idle
        case preparingChapter   // cold start / seek: rendering the current chapter
        case renderingAhead     // playing, rendering the next chapter in background
        case completed
        case failed
    }

    var phase: Phase = .idle
    var progress: Double = 0.0
    var statusMessage: String = ""
    var currentChapterIndex: Int = 0
    var totalChapters: Int = 0
    var renderedChapterCount: Int = 0
    var errorMessage: String?
    var debugLog: [String] = []

    var isRunning: Bool {
        switch phase {
        case .idle, .completed, .failed: return false
        case .preparingChapter, .renderingAhead: return true
        }
    }

    func log(_ message: String) { debugLog.append(message) }

    func update(phase: Phase, progress: Double, statusMessage: String) {
        self.phase = phase
        self.progress = progress
        self.statusMessage = statusMessage
    }

    func fail(_ message: String) {
        phase = .failed
        errorMessage = message
    }

    func complete() {
        phase = .completed
        progress = 1.0
    }

    func reset() {
        phase = .idle
        progress = 0
        statusMessage = ""
        currentChapterIndex = 0
        renderedChapterCount = 0
        errorMessage = nil
        debugLog.removeAll()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationStateTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/AudioFileWriting.swift EchoCore/Services/Narration/NarrationState.swift EchoTests/NarrationStateTests.swift
git commit -m "feat(narration): AudioFileWriting seam + observable NarrationState"
```

---

## Task 6: `TextNormalizer` (pure)

**Why:** highest-ROI correctness work (spec §5). Pure function, table-driven tests, no model.

**Files:**
- Create: `EchoCore/Services/Narration/TextNormalizer.swift`
- Test: `EchoTests/TextNormalizerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// EchoTests/TextNormalizerTests.swift
import Testing
@testable import Echo

@Suite struct TextNormalizerTests {
    @Test(arguments: [
        ("Dr. Smith arrived.",        "Doctor Smith arrived."),
        ("St. Mary on St. James St.",  "Saint Mary on Saint James Street."),  // contextual handled below
        ("It cost 1,200 dollars.",     "It cost 1200 dollars."),
        ("See e.g. chapter 3.",        "See for example chapter 3."),
        ("A pause — then silence.",    "A pause, then silence."),
        ("Chapter IV begins.",         "Chapter 4 begins."),
    ])
    func normalizes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test func stripsThousandsSeparatorInNumbers() {
        #expect(TextNormalizer.normalize("12,345,678") == "12345678")
    }

    @Test func leavesPlainProseUnchanged() {
        #expect(TextNormalizer.normalize("The quick brown fox.") == "The quick brown fox.")
    }
}
```

> Note: "St." is genuinely ambiguous (Saint vs Street). For v1 use a simple rule: "St." before a capitalized word → "Saint", "St." after a word/at clause end → "Street". The `St. Mary on St. James St.` case encodes that. If the rule proves brittle on real books, revisit in Plan 3's normalization-hardening pass — do not over-engineer here.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make build-tests`
Expected: FAIL to compile — `cannot find 'TextNormalizer' in scope`.

- [ ] **Step 3: Implement**

```swift
// EchoCore/Services/Narration/TextNormalizer.swift
import Foundation

/// Converts written prose into a speakable form before phonemization.
/// Pure and deterministic — the unit with the highest naturalness ROI.
enum TextNormalizer {
    static func normalize(_ input: String) -> String {
        var s = input
        s = expandAbbreviations(s)
        s = stripThousandsSeparators(s)
        s = normalizeRomanNumeralChapters(s)
        s = normalizeDashes(s)
        return s
    }

    private static func expandAbbreviations(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "e.g.", with: "for example")
        out = out.replacingOccurrences(of: "Dr.", with: "Doctor")
        // "St." → Saint before a capitalized word, else Street.
        out = replaceStreetVsSaint(out)
        return out
    }

    private static func replaceStreetVsSaint(_ s: String) -> String {
        // "St." followed by whitespace + uppercase letter → "Saint"; otherwise "Street".
        let saint = try! NSRegularExpression(pattern: "St\\.(?=\\s+[A-Z])")
        let street = try! NSRegularExpression(pattern: "St\\.")
        let r1 = NSRange(s.startIndex..., in: s)
        var out = saint.stringByReplacingMatches(in: s, range: r1, withTemplate: "Saint")
        let r2 = NSRange(out.startIndex..., in: out)
        out = street.stringByReplacingMatches(in: out, range: r2, withTemplate: "Street")
        return out
    }

    private static func stripThousandsSeparators(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: "(?<=\\d),(?=\\d{3}\\b)")
        let r = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: r, withTemplate: "")
    }

    private static func normalizeRomanNumeralChapters(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: "\\bChapter ([IVXLC]+)\\b")
        let r = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, range: r).reversed()
        var out = s
        for m in matches {
            guard let whole = Range(m.range, in: out),
                  let num = Range(m.range(at: 1), in: out),
                  let value = romanToInt(String(out[num])) else { continue }
            out.replaceSubrange(whole, with: "Chapter \(value)")
        }
        return out
    }

    private static func normalizeDashes(_ s: String) -> String {
        // Em dash used as a pause → comma.
        s.replacingOccurrences(of: " — ", with: ", ")
    }

    private static func romanToInt(_ roman: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        var total = 0, prev = 0
        for ch in roman.reversed() {
            guard let v = values[ch] else { return nil }
            total += v < prev ? -v : v
            prev = v
        }
        return total > 0 ? total : nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build-tests && make test-only FILTER=EchoTests/TextNormalizerTests`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/TextNormalizer.swift EchoTests/TextNormalizerTests.swift
git commit -m "feat(narration): pure TextNormalizer for speakable prose"
```

---

## Task 7: `NarrationService.renderChapter` (the core)

**What it does:** given a chapter's text blocks + a voice, synthesize each block via the injected `TTSEngine`, write one AAC file via the injected `AudioFileWriting`, insert one `TrackRecord` (with `narration_voice`, `sortOrder = chapterIndex`, `duration = Σ block durations`) and one `.synthesized` `AlignmentAnchorRecord` per text block (monotonic `audioTime`). Blocks with empty/nil text are skipped (no anchor), mirroring how alignment leaves un-narrated blocks for interpolation.

**Files:**
- Create: `EchoCore/Services/Narration/NarrationService.swift`, `EchoTests/Mocks/MockTTSEngine.swift`, `EchoTests/Mocks/MockAudioWriter.swift`
- Test: `EchoTests/NarrationServiceTests.swift`

- [ ] **Step 1: Write the two mocks**

```swift
// EchoTests/Mocks/MockTTSEngine.swift
import Foundation
@testable import Echo

/// Deterministic TTS double: duration = characterCount × secondsPerChar.
final class MockTTSEngine: TTSEngine, @unchecked Sendable {
    let secondsPerChar: Double
    private(set) var calls: [(text: String, voice: VoiceID)] = []
    var throwOnText: String?

    init(secondsPerChar: Double = 0.1) { self.secondsPerChar = secondsPerChar }

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        calls.append((text, voice))
        if let bad = throwOnText, text == bad { throw NarrationError.synthesisFailed }
        let duration = Double(text.count) * secondsPerChar
        return TTSChunk(samples: [Float](repeating: 0, count: max(1, text.count)),
                        sampleRate: 24_000, duration: duration)
    }
}
```

```swift
// EchoTests/Mocks/MockAudioWriter.swift
import Foundation
@testable import Echo

/// Records the file it was asked to write and returns Σ chunk durations.
final class MockAudioWriter: AudioFileWriting, @unchecked Sendable {
    private(set) var writtenURLs: [URL] = []
    private(set) var chunkCounts: [Int] = []

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        writtenURLs.append(url)
        chunkCounts.append(chunks.count)
        return chunks.reduce(0) { $0 + $1.duration }
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// EchoTests/NarrationServiceTests.swift
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
@Suite struct NarrationServiceTests {

    private func blocks(_ audiobookID: String, _ texts: [String?]) -> [EPubBlockRecord] {
        texts.enumerated().map { i, t in
            EPubBlockRecord(
                id: "blk\(i)", audiobookID: audiobookID, spineHref: "c.xhtml",
                spineIndex: 0, blockIndex: i, sequenceIndex: i,
                blockKind: "paragraph", text: t, htmlContent: nil, cardColor: nil,
                chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
                isHidden: false, hiddenReason: nil, isFrontMatter: false,
                wordCount: nil, markers: nil, textFormats: nil,
                createdAt: nil, modifiedAt: nil)
        }
    }

    private func makeService(_ db: DatabaseService, tts: TTSEngine, writer: AudioFileWriting)
        -> NarrationService {
        NarrationService(db: db.writer, audiobookID: "b1",
                         tts: tts, audioWriter: writer,
                         cacheDirectory: FileManager.default.temporaryDirectory,
                         state: NarrationState())
    }

    @Test func writesOneTrackPerChapterWithVoiceAndDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')")
        }
        let tts = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: tts, writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks("b1", ["abcd", "ef"]),
                                    voice: VoiceID("af_warm"))

        let track = try db.read { db in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(db)
        }
        #expect(track?.sortOrder == 0)
        #expect(track?.narrationVoiceRaw == "af_warm")
        // duration = (4 + 2) chars × 0.1 = 0.6
        #expect(track.map { abs($0.duration - 0.6) < 0.0001 } == true)
    }

    @Test func writesSynthesizedAnchorPerTextBlockInOrder() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')")
        }
        let svc = makeService(db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks("b1", ["abcd", "ef"]),
                                    voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1")
                .order(Column("audio_time")).fetchAll(db)
        }
        #expect(anchors.count == 2)
        #expect(anchors.allSatisfy { $0.source == "synthesized" })
        #expect(anchors[0].epubBlockID == "blk0")
        #expect(abs(anchors[0].audioTime - 0.0) < 0.0001)     // first block at 0
        #expect(abs(anchors[1].audioTime - 0.4) < 0.0001)     // after "abcd" (4×0.1)
    }

    @Test func skipsBlocksWithNoText() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')")
        }
        let tts = MockTTSEngine()
        let svc = makeService(db, tts: tts, writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks("b1", ["hi", nil, ""]),
                                    voice: VoiceID("af_warm"))

        let anchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        #expect(anchorCount == 1)            // only the "hi" block
        #expect(tts.calls.count == 1)         // empty/nil blocks not synthesized
    }

    @Test func cancellationStopsBeforeWritingTrack() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')")
        }
        let svc = makeService(db, tts: MockTTSEngine(), writer: MockAudioWriter())

        let task = Task { try await svc.renderChapter(chapterIndex: 0,
            blocks: blocks("b1", ["abcd", "ef"]), voice: VoiceID("af_warm")) }
        task.cancel()
        _ = try? await task.value

        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 0)              // no partial track persisted on cancel
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL to compile — `cannot find 'NarrationService'`, `NarrationError`, and `track.narrationVoiceRaw` members.

- [ ] **Step 4: Implement `NarrationError`, the `TrackRecord` accessor, and `NarrationService`**

First, extend `TrackRecord` so the new column is decoded. In `Shared/Database/TrackRecord.swift`, add the property to the struct (keep it optional + Codable-mapped):

```swift
    var narrationVoiceRaw: String?   // maps to track.narration_voice; nil = real (non-synthesized) audio
```

Add an explicit `CodingKeys` entry if the file defines one; if it relies on GRDB's automatic snake_case mapping, confirm `databaseColumnEncodingStrategy`/`columnDecodingStrategy` — Echo's records map `audiobookID`→`audiobook_id` automatically, so `narrationVoiceRaw`→`narration_voice` requires either matching that convention or an explicit key. Mirror exactly how `playlistPosition`→`playlist_position` is handled in this same struct.

Then create the service:

```swift
// EchoCore/Services/Narration/NarrationService.swift
import Foundation
import GRDB
import os.log

enum NarrationError: Error, Equatable {
    case synthesisFailed
    case audiobookNotFound
}

/// Renders narration one chapter at a time (spec §3.3, v1.0 render-then-play):
/// synthesize each block → write one AAC file → insert a TrackRecord + one
/// `.synthesized` AlignmentAnchorRecord per text block. Mirrors AutoAlignmentService.
@MainActor @Observable
final class NarrationService {
    private let logger = Logger(category: "Narration")
    private let db: DatabaseWriter
    private let audiobookID: String
    private let tts: TTSEngine
    private let audioWriter: AudioFileWriting
    private let cacheDirectory: URL
    let state: NarrationState

    private let trackDAO: TrackDAO
    private let anchorDAO: AlignmentAnchorDAO

    init(db: DatabaseWriter, audiobookID: String, tts: TTSEngine,
         audioWriter: AudioFileWriting, cacheDirectory: URL, state: NarrationState) {
        self.db = db
        self.audiobookID = audiobookID
        self.tts = tts
        self.audioWriter = audioWriter
        self.cacheDirectory = cacheDirectory
        self.state = state
        self.trackDAO = TrackDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
    }

    /// Render one chapter. Cancellable between blocks; on cancel, nothing is persisted.
    func renderChapter(chapterIndex: Int, blocks: [EPubBlockRecord], voice: VoiceID) async throws {
        state.update(phase: .preparingChapter, progress: 0,
                     statusMessage: "Preparing chapter \(chapterIndex + 1)…")

        let spoken = blocks.filter { ($0.text?.isEmpty == false) }
        var chunks: [TTSChunk] = []
        var anchors: [AlignmentAnchorRecord] = []
        var cursor: TimeInterval = 0
        let now = ISO8601DateFormatter().string(from: Date())

        for (i, block) in spoken.enumerated() {
            try Task.checkCancellation()
            let text = TextNormalizer.normalize(block.text ?? "")
            let chunk = try await tts.synthesize(text, voice: voice)
            anchors.append(AlignmentAnchorRecord(
                id: "syn-\(audiobookID)-\(block.id)",
                audiobookID: audiobookID, epubBlockID: block.id,
                audioTime: cursor, audioEndTime: cursor + chunk.duration,
                anchorKind: "point", source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                note: nil, createdAt: now, modifiedAt: now))
            chunks.append(chunk)
            cursor += chunk.duration
            state.update(phase: .preparingChapter,
                         progress: Double(i + 1) / Double(spoken.count),
                         statusMessage: "Preparing chapter \(chapterIndex + 1)…")
        }

        try Task.checkCancellation()

        let fileURL = cacheDirectory.appendingPathComponent(
            "\(audiobookID)-ch\(chapterIndex)-\(voice.rawValue).m4a")
        let duration = try await audioWriter.write(chunks, to: fileURL)

        try Task.checkCancellation()   // last gate before any DB write

        let track = TrackRecord(
            id: "syn-\(audiobookID)-ch\(chapterIndex)", audiobookID: audiobookID,
            title: "Chapter \(chapterIndex + 1)", duration: duration,
            filePath: fileURL.path, isEnabled: true, sortOrder: chapterIndex,
            playlistPosition: nil, narrationVoiceRaw: voice.rawValue)
        try trackDAO.insertAll([track], audiobookID: audiobookID)
        for anchor in anchors { try anchorDAO.insert(anchor) }

        state.renderedChapterCount += 1
        logger.info("Rendered chapter \(chapterIndex) → \(anchors.count) anchors")
    }
}
```

> Note: `TrackRecord`'s memberwise initializer now takes `narrationVoiceRaw` as its final argument. If the struct uses a custom init elsewhere, add the parameter with a `nil` default to avoid breaking existing call sites.

- [ ] **Step 5: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift Shared/Database/TrackRecord.swift EchoTests/Mocks/MockTTSEngine.swift EchoTests/Mocks/MockAudioWriter.swift EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): NarrationService.renderChapter writes tracks + synthesized anchors"
```

---

## Self-review checklist (done by plan author)

- **Spec coverage (this plan's slice):** `.synthesized` source (§4.1) ✓ T1; narration-voice persistence for forward-only voice change (§3.5) ✓ T2/T7; `TTSEngine`/actor seam (§4.3) ✓ T3; curated voices + default (§3.2) ✓ T4; observable progress mirroring AutoAlignmentState (§4) ✓ T5; text normalization (§5) ✓ T6; render-then-play chapter→track + per-block anchor (§3.3/§4.1) ✓ T7; cancellation (§4.4) ✓ T7. Deferred by design to Plans 2–5: standalone import, real Kokoro/Misaki, model download, benchmark, UI, export.
- **Placeholder scan:** none — every step has runnable code/commands. The one judgement call ("St." rule) is explicitly bounded with a real default.
- **Type consistency:** `VoiceID`, `TTSChunk`, `TTSEngine`, `AudioFileWriting`, `NarrationState.Phase`, `NarrationService.init` signature, and `TrackRecord.narrationVoiceRaw` are used identically across T3–T7. `renderChapter(chapterIndex:blocks:voice:)` matches between test and impl.
- **Open verification for the implementer:** confirm `TrackRecord`'s snake_case mapping mechanism (Task 7 Step 4) by mirroring `playlistPosition`→`playlist_position` exactly; if Echo defines explicit `CodingKeys`, add `narrationVoiceRaw = "narration_voice"` there.
