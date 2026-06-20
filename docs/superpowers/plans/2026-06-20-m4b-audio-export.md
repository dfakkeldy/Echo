# Cross-Platform m4b Audiobook Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export any Echo book as a chaptered `.m4b` — narrated EPUB *or* repackaged imported m4b/mp3 — on both iOS and macOS, through one shared, source-agnostic exporter.

**Architecture:** Refactor the shipped iOS-only `NarrationExportService.exportM4B` into a cross-platform `AudioExportService` split along two seams: an `ExportSource` (where the ordered audio comes from) and the m4b writer (compose → `AVAssetExportSession` → `ChapterMarkerWriter`). `NarrationCacheSource` feeds it the per-chapter narration cache files; `ImportedBookSource` feeds it the original on-disk track files. A resolver auto-picks the source per book. A future `.mp3` writer is a documented hole; mp3 is out of scope.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVMutableComposition`, `AVAssetExportSession`, `AVURLAsset`), GRDB, the `swift-audio-marker` package (`AudioMarker` product), Swift Testing.

**Design spec:** [docs/superpowers/specs/2026-06-20-m4b-audio-export-design.md](../specs/2026-06-20-m4b-audio-export-design.md)

## Global Constraints

- **License header:** every new `.swift` file starts at line 1 with `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows the whole file on edit and can push the header below an `import` — after each edit, confirm the SPDX line is still line 1.
- **Build/test (16 GB machine):** `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` for edit→test loops. **Never** enable parallel testing, uncapped `-jobs`, or two concurrent `xcodebuild` invocations. UI tests are excluded from the scheme.
- **New files auto-compile:** `EchoCore/`, `Shared/`, and `Echo macOS/` are PBXFileSystemSynchronizedRootGroups — new `.swift` files in them are included in their targets automatically. **No pbxproj edits for new source files.** The one exception is Task 3 (linking the `AudioMarker` package product to the macOS target).
- **Cross-platform purity:** files under `EchoCore/Services/Export/` must NOT import `UIKit`/`AppKit` (they compile into the macOS target). Use `AVFoundation` + `Foundation` + `GRDB` only; carry images as `Data`.
- **DB seam:** services take a `GRDB.DatabaseWriter`; tests use `DatabaseService(inMemory: ())` and pass `.writer`. DAOs in use: `TrackDAO(db:).tracks(for:)`, `ChapterDAO(db:).chapters(for:)`, `AudiobookDAO(db:).get(_:)`.
- **Commits:** Conventional Commits. End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Reviewers after shared changes:** run the `cross-platform-parity-reviewer` after Phase 1, and the `schema-migration-reviewer` only if a DB migration is added (none planned).
- **Out of scope:** mp3 output, LAME, quality/bitrate UI, batch export, series/language tags. The m4b writer uses `AVAssetExportPresetAppleM4A` (AAC).

---

## Phase 1 — Generalize the exporter (iOS behavior-preserving)

### Task 1: Source seam + ported pure ordering

**Files:**
- Create: `EchoCore/Services/Export/ExportSource.swift`
- Create: `EchoCore/Services/Export/NarrationCacheSource.swift`
- Modify: `EchoTests/NarrationExportOrderingTests.swift` (repoint to the new pure function)

**Interfaces:**
- Produces: `struct ExportItem { let title: String; let url: URL; let timeRange: CMTimeRange? }`; `protocol ExportSource { func items() async throws -> [ExportItem] }`; `NarrationCacheSource(audiobookID:cacheDirectory:databaseWriter:)` with static `orderedItems(files:titlesByChapterIndex:) -> [ExportItem]`.

- [ ] **Step 1: Repoint the existing ordering test to the new pure function**

Replace the three `NarrationExportService.orderedChapters(...)` call sites and the `.fileURL` accessor in `EchoTests/NarrationExportOrderingTests.swift` with `NarrationCacheSource.orderedItems(...)` and `.url`. The full updated file:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

/// Covers the chapter ordering + titling step of the audiobook exporter
/// — specifically the >=10 chapter alignment bug, where a lexicographic file sort
/// (ch0, ch1, ch10, ch11, ch2…) silently attached titles to the wrong chapters
/// when titles were looked up by enumerated file position.
@Suite struct NarrationExportOrderingTests {

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    private func lexicographicFiles(count: Int) -> [URL] {
        (0..<count)
            .map { "book_id-ch\($0)-af_heart-v4.m4a" }
            .sorted()
            .map(file)
    }

    @Test func ordersFilesByNumericChapterIndexNotLexicographically() {
        let files = lexicographicFiles(count: 12)
        let items = NarrationCacheSource.orderedItems(files: files, titlesByChapterIndex: [:])
        let recovered = items.map {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent)
        }
        #expect(recovered == Array(0..<12))
    }

    @Test func attachesTitlesByChapterIndexAcrossDoubleDigitBoundary() {
        let titles = Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, "Title \($0)") })
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 12), titlesByChapterIndex: titles)
        for item in items {
            let index = NarrationFileNaming.chapterIndex(fromFileName: item.url.lastPathComponent)
            #expect(item.title == "Title \(index!)")
        }
        let ch10 = items.first {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent) == 10
        }
        #expect(ch10?.title == "Title 10")
    }

    @Test func fallsBackToPositionalLabelWhenTitleMissing() {
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 3), titlesByChapterIndex: [:])
        #expect(items.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    @Test func ignoresGapsAndExtraTitleKeys() {
        let files = [file("book_id-ch5-af_heart-v4.m4a"), file("book_id-ch0-af_heart-v4.m4a")]
        let items = NarrationCacheSource.orderedItems(
            files: files, titlesByChapterIndex: [0: "Prologue", 5: "Finale", 99: "Stray"])
        #expect(items.map(\.title) == ["Prologue", "Finale"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (types don't exist yet)**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationExportOrderingTests`
Expected: BUILD/COMPILE FAIL — `cannot find 'NarrationCacheSource' in scope` / `value of type 'ExportItem' has no member`.

- [ ] **Step 3: Create the seam types**

`EchoCore/Services/Export/ExportSource.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// One chapter's worth of source audio plus the title to stamp on its marker.
/// `timeRange == nil` means "use the whole file" (narration cache files and
/// multi-file imported books); a non-nil range slices one source file
/// (a single-file m4b carved into its embedded chapters).
struct ExportItem: Equatable {
    let title: String
    let url: URL
    let timeRange: CMTimeRange?
}

/// Where an export's ordered audio comes from. Narrated books read per-chapter
/// cache files; imported books read the original on-disk track files. Both
/// resolve to the same `[ExportItem]` the service concatenates + chapterises.
protocol ExportSource {
    func items() async throws -> [ExportItem]
}
```

- [ ] **Step 4: Create `NarrationCacheSource` with the ported pure ordering**

`EchoCore/Services/Export/NarrationCacheSource.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// `ExportSource` for a narrated book: the per-chapter `.m4a` files the narration
/// pipeline cached. Ordering + titling is ported verbatim from the former
/// `NarrationExportService.orderedChapters`, including the >=10-chapter numeric
/// sort fix (a lexicographic name sort interleaves ch1, ch10, ch11, ch2…).
struct NarrationCacheSource: ExportSource {
    let audiobookID: String
    let cacheDirectory: URL
    let databaseWriter: DatabaseWriter?

    func items() async throws -> [ExportItem] {
        let fm = FileManager.default
        let prefix = NarrationFileNaming.chapterPrefix(audiobookID: audiobookID)
        let files = ((try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }

        var titlesByChapterIndex: [Int: String] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
            for track in tracks where track.narrationVoice != nil {
                titlesByChapterIndex[track.sortOrder] = track.title
            }
        }
        return Self.orderedItems(files: files, titlesByChapterIndex: titlesByChapterIndex)
    }

    /// Pure ordering+titling, unit-tested without generating audio. Files are
    /// re-sorted by the numeric chapter index embedded in each name (`-ch{N}-`);
    /// titles are looked up by that recovered index (== the narration track's
    /// `sortOrder`), never by file position, which diverges from chapter 10 on.
    /// A file whose index can't be recovered sorts last and gets a 1-based label.
    static func orderedItems(files: [URL], titlesByChapterIndex: [Int: String]) -> [ExportItem] {
        let sorted = files.sorted { lhs, rhs in
            let l = NarrationFileNaming.chapterIndex(fromFileName: lhs.lastPathComponent)
            let r = NarrationFileNaming.chapterIndex(fromFileName: rhs.lastPathComponent)
            switch (l, r) {
            case (let l?, let r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
        return sorted.enumerated().map { position, fileURL in
            let chapterIndex = NarrationFileNaming.chapterIndex(fromFileName: fileURL.lastPathComponent)
            let title = chapterIndex.flatMap { titlesByChapterIndex[$0] } ?? "Chapter \(position + 1)"
            return ExportItem(title: title, url: fileURL, timeRange: nil)
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationExportOrderingTests`
Expected: PASS (4 tests). `NarrationExportService.orderedChapters` is now unused but still present — removed in Task 2.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Export/ExportSource.swift EchoCore/Services/Export/NarrationCacheSource.swift EchoTests/NarrationExportOrderingTests.swift
git commit -m "$(printf 'refactor(export): extract ExportSource seam + NarrationCacheSource\n\nPorts the pure chapter ordering/titling out of NarrationExportService into\na reusable ExportSource. No behavior change.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 2: `AudioExportService` + delegate the iOS path

**Files:**
- Create: `EchoCore/Services/Export/AudioExportService.swift`
- Modify: `EchoCore/Services/Narration/NarrationExportService.swift` (becomes a thin shim; delete `orderedChapters`/`PlannedChapter`)

**Interfaces:**
- Consumes: `ExportItem`, `ExportSource`, `NarrationCacheSource` (Task 1), `ChapterAtom`/`ChapterMarkerWriter` (existing, `AudioMarkerStub.swift`).
- Produces: `actor AudioExportService` with `func exportM4B(items: [ExportItem], outputURL: URL, metadata: ExportMetadata? = nil) async throws`. (`ExportMetadata` defined in Task 9; until then the param is unused — declare it as `metadata: ExportMetadata? = nil` only AFTER Task 9. **For Task 2, omit the `metadata` parameter entirely** and add it in Task 9.)

- [ ] **Step 1: Write a failing structural test for the service surface**

Add `EchoTests/AudioExportServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct AudioExportServiceTests {
    /// Empty input is a clear error, not an empty file.
    @Test func throwsOnNoChapters() async {
        let service = AudioExportService()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        await #expect(throws: AudioExportService.ExportError.self) {
            try await service.exportM4B(items: [], outputURL: out)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make build-tests`
Expected: COMPILE FAIL — `cannot find 'AudioExportService' in scope`.

- [ ] **Step 3: Create `AudioExportService` (generalized compose loop)**

`EchoCore/Services/Export/AudioExportService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Cross-platform, source-agnostic audiobook exporter. Concatenates an ordered
/// list of `ExportItem`s into a gapless `.m4b`, transcodes once via
/// `AVAssetExportSession` (AAC), and stamps real Nero (`chpl`) + QuickTime
/// (`chap`) chapter atoms via `ChapterMarkerWriter`. Generalised from the
/// iOS-only `NarrationExportService` so narrated and imported books share a spine.
actor AudioExportService {
    enum ExportError: Error {
        case noChapters
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
    }

    func exportM4B(items: [ExportItem], outputURL: URL) async throws {
        guard !items.isEmpty else { throw ExportError.noChapters }

        // Imported originals live behind security-scoped bookmarks; the files must
        // stay accessible through the *entire* export (AVAssetExportSession reads
        // them after this loop), so scope every distinct source URL up front and
        // release only when the whole function exits. For narration cache files
        // (app-owned) startAccessing returns false → harmless no-op.
        let urls = Set(items.map(\.url))
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.compositionFailed }

        var currentPosition = CMTime.zero
        var chapters: [ChapterAtom] = []

        for item in items {
            let asset = AVURLAsset(url: item.url)
            let fullDuration = try await asset.load(.duration)
            let range = item.timeRange ?? CMTimeRange(start: .zero, duration: fullDuration)

            chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: item.title))

            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            try audioTrack.insertTimeRange(range, of: assetTrack, at: currentPosition)
            currentPosition = CMTimeAdd(currentPosition, range.duration)
        }

        let tempM4A = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ExportError.exportSessionFailed }
        session.outputURL = tempM4A
        session.outputFileType = .m4a

        await session.export()
        guard session.status == .completed else { throw ExportError.exportSessionFailed }

        let writer = ChapterMarkerWriter()
        do {
            try await writer.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }
    }
}
```

- [ ] **Step 4: Run the structural test to verify it passes**

Run: `make build-tests` then `make test-only FILTER=EchoTests/AudioExportServiceTests`
Expected: PASS (1 test).

- [ ] **Step 5: Rewrite `NarrationExportService.exportM4B` as a shim over the new service**

Replace the body of `exportM4B` and delete `orderedChapters` + `PlannedChapter` (now in `NarrationCacheSource`). Keep `exportChapterFiles` (other callers may use it). New `NarrationExportService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// Thin compatibility shim over `AudioExportService` + `NarrationCacheSource`,
/// kept so the existing iOS call site (`ExportProgressView`) stays unchanged
/// until it migrates to the unified resolver (Task 8). New code should use
/// `AudioExportService` + an `ExportSource` directly.
actor NarrationExportService {
    enum ExportError: Error {
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
        case missingAudiobook
    }

    /// Collects the per-chapter `.m4a` cache files for a book (fast/free path).
    func exportChapterFiles(for bookID: String, cacheDirectory: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let prefix = NarrationFileNaming.chapterPrefix(audiobookID: bookID)
        let allFiles = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        return allFiles
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Concatenates the cached chapters into a single chaptered `.m4b`. Delegates
    /// to `AudioExportService` via `NarrationCacheSource`.
    func exportM4B(
        for bookID: String,
        bookTitle: String,
        cacheDirectory: URL,
        outputURL: URL,
        databaseWriter: DatabaseWriter? = nil
    ) async throws {
        let source = NarrationCacheSource(
            audiobookID: bookID, cacheDirectory: cacheDirectory, databaseWriter: databaseWriter)
        let items = try await source.items()
        guard !items.isEmpty else { throw ExportError.missingAudiobook }
        do {
            try await AudioExportService().exportM4B(items: items, outputURL: outputURL)
        } catch {
            throw ExportError.exportSessionFailed
        }
    }
}
```

- [ ] **Step 6: Verify nothing else referenced the removed symbols**

Run: `grep -rn "orderedChapters\|PlannedChapter" EchoCore EchoTests "Echo macOS" Shared`
Expected: no matches (Task 1 already moved the test).

- [ ] **Step 7: Build + run the full export-related suites green**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationExportOrderingTests` and `make test-only FILTER=EchoTests/ChapterMarkerWriterTests` and `make test-only FILTER=EchoTests/AudioExportServiceTests`
Expected: all PASS. iOS export behavior is unchanged (same composition + chapter-atom path).

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Services/Export/AudioExportService.swift EchoCore/Services/Narration/NarrationExportService.swift EchoTests/AudioExportServiceTests.swift
git commit -m "$(printf 'refactor(export): add AudioExportService spine; NarrationExportService delegates\n\nGeneralised compose -> export -> chapterise loop now takes [ExportItem] with\noptional per-item time ranges. iOS narrated->m4b behavior preserved.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

- [ ] **Step 9: Run the cross-platform parity reviewer** on the Phase 1 diff (shared `EchoCore` change). Address any flagged macOS gap before Phase 2.

---

## Phase 2 — macOS narrated → m4b

### Task 3: Make chapter-writing cross-platform (link `AudioMarker` to macOS)

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj` (link package product to the macOS target)
- Modify: `EchoCore/Services/Narration/AudioMarkerStub.swift` (broaden the platform guard)
- Modify: `EchoTests/ChapterMarkerWriterTests.swift` (run on macOS too)

- [ ] **Step 1: Link the `AudioMarker` product to the `Echo macOS` target**

Preferred (reliable): in Xcode, select the **Echo macOS** target → **General** → **Frameworks, Libraries, and Embedded Content** → **+** → choose **AudioMarker** (from the already-resolved `swift-audio-marker` package) → Add.

Headless fallback (`Echo.xcodeproj/project.pbxproj`), mirroring the iOS entries (`CC00000000008AUMK0000000` product dependency, `CC00000000009AUMK0000000` build file):
1. Add a new `PBXBuildFile` in the build-file section: `CC0000000016AUMK0000016 /* AudioMarker in Frameworks (macOS) */ = {isa = PBXBuildFile; productRef = CC0000000017AUMK0000017 /* AudioMarker */; };`
2. Add a new `XCSwiftPackageProductDependency`: `CC0000000017AUMK0000017 /* AudioMarker */ = { isa = XCSwiftPackageProductDependency; package = CC00000000007AUMK0000000 /* XCRemoteSwiftPackageReference "swift-audio-marker" */; productName = AudioMarker; };`
3. Add `CC0000000017AUMK0000017 /* AudioMarker */,` to the **Echo macOS** target's `packageProductDependencies = ( … );` list (target at pbxproj line ~479, its `packageProductDependencies` opens at ~480).
4. Add `CC0000000016AUMK0000016 /* AudioMarker in Frameworks (macOS) */,` to the **Echo macOS** target's `PBXFrameworksBuildPhase` `files = ( … );`.

- [ ] **Step 2: Broaden the platform guard in `AudioMarkerStub.swift`**

Change every `#if os(iOS)` / `#else` in `EchoCore/Services/Narration/AudioMarkerStub.swift` to gate on the module's availability instead of the platform, so macOS (now linked) takes the real path. Full file:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if canImport(AudioMarker)
    import AudioMarker
#endif

/// One chapter boundary for the exported m4b.
struct ChapterAtom {
    let startTime: Double
    let title: String
}

#if canImport(AudioMarker)
    // `swift-audio-marker` exports an empty `public struct AudioMarker` that
    // shadows its own module name, and a `Chapter` that collides with Echo's
    // `Models/Chapter.swift`. Reach the package types through `ChapterList`
    // (unambiguous — only the package defines it) and its `Element`.
    private typealias PackageChapterList = ChapterList
    private typealias PackageChapter = ChapterList.Element
#endif

/// Writes real Nero (`chpl`) + QuickTime (`chap`) chapter atoms via the
/// `swift-audio-marker` package.
struct ChapterMarkerWriter {
    enum WriteError: Error { case unavailableOnPlatform }

    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        #if canImport(AudioMarker)
            let engine = AudioMarkerEngine()
            let list = PackageChapterList(
                chapters.map { atom in
                    PackageChapter(start: .seconds(atom.startTime), title: atom.title)
                })
            try engine.writeChapters(list, to: outputURL)
        #else
            throw WriteError.unavailableOnPlatform
        #endif
    }
}
```

- [ ] **Step 3: Broaden the chapter-marker test to macOS**

In `EchoTests/ChapterMarkerWriterTests.swift`, change the file-top `#if os(iOS)` to `#if os(iOS) || os(macOS)` (and its closing `#endif`). The test deliberately does not `import AudioMarker` and drives writing through `@testable import Echo`, so it works once the product is linked into whichever app target the test host uses. Keep the existing oracle (atoms present + still playable).

- [ ] **Step 4: Build + test on macOS**

Run: `make build-tests` (iOS host) then `make test-only FILTER=EchoTests/ChapterMarkerWriterTests`
Then a macOS compile check: `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build` (single invocation, no parallel).
Expected: iOS suite PASS; macOS target compiles with `AudioMarker` linked (no `unavailableOnPlatform` path).

- [ ] **Step 5: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj EchoCore/Services/Narration/AudioMarkerStub.swift EchoTests/ChapterMarkerWriterTests.swift
git commit -m "$(printf 'feat(export): enable chapter-marker writing on macOS\n\nLink the AudioMarker product into the Echo macOS target and gate\nChapterMarkerWriter on canImport(AudioMarker) instead of os(iOS).\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 4: macOS export entry point (NSSavePanel)

**Files:**
- Create: `Echo macOS/Views/MacAudioExportView.swift`
- Modify: `Echo macOS/Echo_macOSApp.swift` (add a Command menu item)

**Interfaces:**
- Consumes: `AudioExportService`, `NarrationCacheSource` (Phase 1), `MacPlayerModel` (`audiobookID: String?`, `currentTitle: String`, `dbService: DatabaseService?`), `NarrationCache.directory()`.

- [ ] **Step 1: Create the macOS export sheet**

`Echo macOS/Views/MacAudioExportView.swift` (mirrors `MacAnkiExportView`'s `NSSavePanel` flow; resolves the source with `NarrationCacheSource` — Task 8 swaps in the auto-resolver):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import GRDB

/// Exports the loaded book's narration to a chaptered `.m4b` via a save panel.
struct MacAudioExportView: View {
    let audiobookID: String
    let bookTitle: String
    let databaseWriter: DatabaseWriter

    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var savedPath = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Audiobook").font(.title2)
            if isExporting {
                ProgressView("Exporting \(bookTitle).m4b…")
            } else if !savedPath.isEmpty {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(savedPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else if let errorText {
                Label(errorText, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).multilineTextAlignment(.center)
            }
            HStack {
                Button("Export…") { presentSavePanel() }.disabled(isExporting)
                Button("Done") { dismiss() }
            }
        }
        .padding().frame(width: 420, height: 220)
    }

    private func presentSavePanel() {
        errorText = nil
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Audiobook as .m4b")
        panel.allowedContentTypes = [UTType("public.m4a-audio") ?? .audio]
        panel.nameFieldStringValue = "\(ExportFileName.safe(bookTitle)).m4b"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            isExporting = true
            Task {
                do {
                    let source = NarrationCacheSource(
                        audiobookID: audiobookID,
                        cacheDirectory: NarrationCache.directory(),
                        databaseWriter: databaseWriter)
                    let items = try await source.items()
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
                    try await AudioExportService().exportM4B(items: items, outputURL: temp)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: temp, to: dest)
                    try? FileManager.default.removeItem(at: temp)
                    await MainActor.run { savedPath = dest.path; isExporting = false }
                } catch {
                    await MainActor.run { errorText = error.localizedDescription; isExporting = false }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add the shared safe-filename helper (cross-platform)**

Create `EchoCore/Services/Export/ExportFileName.swift` (used by both platforms; replaces the private `ExportProgressView.safeFileName`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Strips path separators and other illegal characters from a book title so the
/// derived file name can't escape the temp/destination directory.
enum ExportFileName {
    static func safe(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Audiobook" : cleaned
    }
}
```

Add a tiny test `EchoTests/ExportFileNameTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ExportFileNameTests {
    @Test func stripsPathSeparators() {
        #expect(ExportFileName.safe("Vol. 1/2") == "Vol. 1-2")
    }
    @Test func fallsBackWhenEmpty() {
        #expect(ExportFileName.safe("   ") == "Audiobook")
    }
}
```

- [ ] **Step 3: Add the macOS menu command**

In `Echo macOS/Echo_macOSApp.swift`, inside the existing `.commands { … }` (near the `CommandMenu("Study")` block at ~line 182), add a File-area command. Use a `@State` sheet flag on the relevant scene view, or present via the existing pattern that drives `MacAnkiExportView` at line 78. Concretely, alongside that Anki menu item add:

```swift
Button("Export Audiobook (.m4b)…") {
    showingAudioExport = true
}
.disabled(player.audiobookID == nil)
```

and present it from the same view that owns `player` (the tri-pane), mirroring how `MacAnkiExportView()` is presented:

```swift
.sheet(isPresented: $showingAudioExport) {
    if let id = player.audiobookID, let db = player.dbService?.writer {
        MacAudioExportView(audiobookID: id, bookTitle: player.currentTitle, databaseWriter: db)
    }
}
```

(Match the file's existing `@State`/binding placement; `player` is the `MacPlayerModel` already in scope for the Playback/Batch menus.)

- [ ] **Step 4: Build macOS + run the filename test**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ExportFileNameTests`
Then: `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build`
Expected: tests PASS; macOS builds.

- [ ] **Step 5: Manual on-device check (owner)** — on macOS, narrate (or open an already-narrated) book, File → Export Audiobook (.m4b)…, save, and confirm the `.m4b` opens in a chapter-aware player (Books.app) with correct chapter names.

- [ ] **Step 6: Commit**

```bash
git add "Echo macOS/Views/MacAudioExportView.swift" "Echo macOS/Echo_macOSApp.swift" EchoCore/Services/Export/ExportFileName.swift EchoTests/ExportFileNameTests.swift
git commit -m "$(printf 'feat(export): macOS narrated audiobook export via NSSavePanel\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Phase 3 — Repackage imported books + unified auto-detect

### Task 5: `ImportedBookSource` (pure mapping + tests)

**Files:**
- Create: `EchoCore/Services/Export/ImportedBookSource.swift`
- Create: `EchoTests/ImportedBookSourceTests.swift`

**Interfaces:**
- Consumes: `TrackRecord`, `ChapterRecord`, `TrackDAO`, `ChapterDAO`, `ExportItem`.
- Produces: `struct ImportedBookSource: ExportSource` with `init(audiobookID:databaseWriter:)`, `enum SourceError { case sourceUnavailable }`, and static `makeItems(tracks:chapters:) -> [ExportItem]`.

- [ ] **Step 1: Write failing tests for the pure mapping**

`EchoTests/ImportedBookSourceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct ImportedBookSourceTests {
    private func track(_ id: String, _ path: String, sort: Int, duration: Double = 60) -> TrackRecord {
        TrackRecord(id: id, audiobookID: "bk", title: "Track \(sort)", duration: duration,
                    filePath: path, isEnabled: true, sortOrder: sort, playlistPosition: nil,
                    narrationVoice: nil)
    }
    private func chapter(_ title: String, _ start: Double, _ end: Double, sort: Int) -> ChapterRecord {
        ChapterRecord(id: nil, audiobookID: "bk", title: title, startSeconds: start,
                      endSeconds: end, isEnabled: true, sortOrder: sort, playlistPosition: nil)
    }

    /// Single source file + N chapters → N items slicing the file by time range.
    @Test func singleFileBecomesTimeRangeSlices() {
        let tracks = [track("t0", "file:///b.m4b", sort: 0, duration: 300)]
        let chapters = [
            chapter("One", 0, 120, sort: 0),
            chapter("Two", 120, 300, sort: 1),
        ]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: chapters)
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items.allSatisfy { $0.url == URL(string: "file:///b.m4b") })
        #expect(items[0].timeRange?.start.seconds == 0)
        #expect(items[1].timeRange?.start.seconds == 120)
        #expect(items[1].timeRange?.duration.seconds == 180)
    }

    /// Multiple files → one whole-file item per track, titled by chapter when counts align.
    @Test func multiFileBecomesWholeFileItems() {
        let tracks = [
            track("t0", "file:///a.mp3", sort: 0),
            track("t1", "file:///b.mp3", sort: 1),
        ]
        let chapters = [
            chapter("Intro", 0, 60, sort: 0),
            chapter("Body", 60, 120, sort: 1),
        ]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: chapters)
        #expect(items.map(\.title) == ["Intro", "Body"])
        #expect(items.map(\.url) == [URL(string: "file:///a.mp3"), URL(string: "file:///b.mp3")])
        #expect(items.allSatisfy { $0.timeRange == nil })
    }

    /// Multiple files but no usable chapters → fall back to track titles.
    @Test func multiFileFallsBackToTrackTitles() {
        let tracks = [track("t0", "file:///a.mp3", sort: 0), track("t1", "file:///b.mp3", sort: 1)]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: [])
        #expect(items.map(\.title) == ["Track 0", "Track 1"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: COMPILE FAIL — `cannot find 'ImportedBookSource'`.

- [ ] **Step 3: Implement `ImportedBookSource`**

`EchoCore/Services/Export/ImportedBookSource.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// `ExportSource` for an already-imported audiobook (m4b or loose mp3/m4a), read
/// from its original on-disk files (referenced, never copied). Two shapes:
///   • one source file with N chapters → N items slicing it by chapter time range;
///   • multiple track files → one whole-file item per file, titled by the
///     positionally-matching chapter (or the track's own title).
/// Multi-file books with sub-file chapters collapse to per-file granularity (a
/// documented v1 limitation — the common case is one chapter per file).
struct ImportedBookSource: ExportSource {
    enum SourceError: Error { case sourceUnavailable }

    let audiobookID: String
    let databaseWriter: DatabaseWriter

    func items() async throws -> [ExportItem] {
        let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
        let chapters = try ChapterDAO(db: databaseWriter).chapters(for: audiobookID)
        let items = Self.makeItems(tracks: tracks, chapters: chapters)
        guard !items.isEmpty else { throw SourceError.sourceUnavailable }
        for item in items where !FileManager.default.fileExists(atPath: item.url.path) {
            throw SourceError.sourceUnavailable
        }
        return items
    }

    /// Pure mapping (no disk/DB) from records to ordered export items.
    static func makeItems(tracks: [TrackRecord], chapters: [ChapterRecord]) -> [ExportItem] {
        let enabledTracks = tracks.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
        let enabledChapters = chapters.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }

        if enabledTracks.count == 1, enabledChapters.count >= 1,
           let url = URL(string: enabledTracks[0].filePath) {
            return enabledChapters.map { ch in
                ExportItem(
                    title: ch.title,
                    url: url,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: ch.startSeconds, preferredTimescale: 600),
                        duration: CMTime(seconds: max(0, ch.endSeconds - ch.startSeconds),
                                         preferredTimescale: 600)))
            }
        }

        return enabledTracks.enumerated().compactMap { index, track in
            guard let url = URL(string: track.filePath) else { return nil }
            let title = enabledChapters.count == enabledTracks.count
                ? enabledChapters[index].title
                : track.title
            return ExportItem(title: title, url: url, timeRange: nil)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ImportedBookSourceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Export/ImportedBookSource.swift EchoTests/ImportedBookSourceTests.swift
git commit -m "$(printf 'feat(export): ImportedBookSource for repackaging imported books\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 6: Source auto-detection resolver

**Files:**
- Create: `EchoCore/Services/Export/ExportSourceResolver.swift`
- Create: `EchoTests/ExportSourceResolverTests.swift`

**Interfaces:**
- Produces: `enum ExportSourceResolver` with `static func isNarrated(audiobookID:databaseWriter:) -> Bool` and `static func resolve(audiobookID:databaseWriter:cacheDirectory:) -> ExportSource`.

- [ ] **Step 1: Write failing tests against an in-memory DB**

`EchoTests/ExportSourceResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct ExportSourceResolverTests {
    private func seedTrack(_ db: DatabaseService, narrationVoice: String?) throws {
        let track = TrackRecord(
            id: "t0", audiobookID: "bk", title: "Chapter 1", duration: 10,
            filePath: "file:///x.m4a", isEnabled: true, sortOrder: 0,
            playlistPosition: nil, narrationVoice: narrationVoice)
        try TrackDAO(db: db.writer).insertAll([track], audiobookID: "bk")
    }

    @Test func detectsNarratedWhenAnyTrackHasVoice() throws {
        let db = try DatabaseService(inMemory: ())
        try seedTrack(db, narrationVoice: "af_heart")
        #expect(ExportSourceResolver.isNarrated(audiobookID: "bk", databaseWriter: db.writer))
        let source = ExportSourceResolver.resolve(
            audiobookID: "bk", databaseWriter: db.writer, cacheDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(source is NarrationCacheSource)
    }

    @Test func detectsImportedWhenNoVoice() throws {
        let db = try DatabaseService(inMemory: ())
        try seedTrack(db, narrationVoice: nil)
        #expect(!ExportSourceResolver.isNarrated(audiobookID: "bk", databaseWriter: db.writer))
        let source = ExportSourceResolver.resolve(
            audiobookID: "bk", databaseWriter: db.writer, cacheDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(source is ImportedBookSource)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: COMPILE FAIL — `cannot find 'ExportSourceResolver'`.

- [ ] **Step 3: Implement the resolver**

`EchoCore/Services/Export/ExportSourceResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Picks the right `ExportSource` for a book by inspecting its tracks: any
/// synthesized track (`narrationVoice != nil`) ⇒ narrated cache; otherwise the
/// imported originals.
enum ExportSourceResolver {
    static func isNarrated(audiobookID: String, databaseWriter: DatabaseWriter) -> Bool {
        let tracks = (try? TrackDAO(db: databaseWriter).tracks(for: audiobookID)) ?? []
        return tracks.contains { $0.narrationVoice != nil }
    }

    static func resolve(
        audiobookID: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL
    ) -> ExportSource {
        if isNarrated(audiobookID: audiobookID, databaseWriter: databaseWriter) {
            return NarrationCacheSource(
                audiobookID: audiobookID, cacheDirectory: cacheDirectory, databaseWriter: databaseWriter)
        }
        return ImportedBookSource(audiobookID: audiobookID, databaseWriter: databaseWriter)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ExportSourceResolverTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Export/ExportSourceResolver.swift EchoTests/ExportSourceResolverTests.swift
git commit -m "$(printf 'feat(export): auto-detect narrated vs imported export source\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 7: Wire the unified "Export…" action on both platforms

**Files:**
- Modify: `EchoCore/Views/ExportProgressView.swift` (iOS — use the resolver; rename the source inputs)
- Modify: `Echo macOS/Views/MacAudioExportView.swift` (macOS — use the resolver)
- Verify: `EchoCore/Views/NowPlayingTab.swift` (iOS export sheet call site still compiles; ensure the action is reachable for imported books too)

- [ ] **Step 1: iOS — drive `ExportProgressView` through the resolver**

Replace the `runExport()` body in `EchoCore/Views/ExportProgressView.swift` so it resolves the source (narrated *or* imported) instead of calling `NarrationExportService` directly. Updated `runExport()` (keep the rest of the file, but delete the now-unused private `safeFileName` and use `ExportFileName.safe`):

```swift
        private func runExport() async {
            let source = ExportSourceResolver.resolve(
                audiobookID: audiobookID,
                databaseWriter: databaseWriter ?? PlayerModel.exportFallbackWriter(),
                cacheDirectory: cacheDirectory)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(ExportFileName.safe(bookTitle))
                .appendingPathExtension("m4b")
            do {
                let items = try await source.items()
                try await AudioExportService().exportM4B(items: items, outputURL: output)
                exportedURL = output
            } catch {
                errorText = error.localizedDescription
            }
            isExporting = false
        }
```

`databaseWriter` is required by the resolver (imported books read the DB). If the existing call site can pass a non-optional writer, change the stored `let databaseWriter: DatabaseWriter?` to non-optional `DatabaseWriter` and update `NowPlayingTab.swift:191` to pass `model.databaseService?.writer` guarded by `if let`. (Simplest: make the property non-optional and guard at the call site.) Remove `PlayerModel.exportFallbackWriter()` if you make it non-optional — that helper is only a stopgap if a nil writer must be tolerated.

- [ ] **Step 2: iOS — ensure the export action is reachable for imported books**

In `EchoCore/Views/NowPlayingTab.swift`, confirm the control that sets `showingExport = true` (the player More menu "Export…" item) is shown whenever a book is loaded, not gated on `hasEPUB`/narration. If it is narration-gated, broaden its condition to `model.folderURL != nil`. The `.sheet(isPresented: $showingExport)` block (line 185) already passes `audiobookID`, `bookTitle`, `cacheDirectory`, and `databaseWriter` — unchanged.

- [ ] **Step 3: macOS — drive `MacAudioExportView` through the resolver**

In `Echo macOS/Views/MacAudioExportView.swift`, replace the `NarrationCacheSource(...)` construction inside `presentSavePanel()`'s `Task` with:

```swift
                    let source = ExportSourceResolver.resolve(
                        audiobookID: audiobookID,
                        databaseWriter: databaseWriter,
                        cacheDirectory: NarrationCache.directory())
                    let items = try await source.items()
```

(The rest of the save/copy flow is unchanged.)

- [ ] **Step 4: Build both platforms**

Run: `make build-tests` (iOS) then `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build`
Expected: both compile. Existing export suites still green: `make test-only FILTER=EchoTests/AudioExportServiceTests`.

- [ ] **Step 5: Manual checks (owner)** — iOS: open an imported m4b, More → Export…, confirm a chaptered `.m4b` shares out. macOS: same via File → Export Audiobook (.m4b)…. Also re-verify a narrated book still exports on both.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/ExportProgressView.swift EchoCore/Views/NowPlayingTab.swift "Echo macOS/Views/MacAudioExportView.swift"
git commit -m "$(printf 'feat(export): unified auto-detecting export action (narrated or imported)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Phase 4 — Metadata embedding + prompt-if-missing

### Task 8: Embed title / author / cover into the output

**Files:**
- Create: `EchoCore/Services/Export/ExportMetadata.swift`
- Create: `EchoCore/Services/Export/ExportMetadataResolver.swift`
- Create: `EchoTests/ExportMetadataTests.swift`
- Modify: `EchoCore/Services/Export/AudioExportService.swift` (accept + embed metadata)

**Interfaces:**
- Produces: `struct ExportMetadata { var title: String; var author: String?; var coverArt: Data? ; func assetMetadataItems() -> [AVMetadataItem] }`; `enum ExportMetadataResolver { static func resolve(audiobookID:fallbackTitle:firstSourceURL:databaseWriter:) async -> ExportMetadata; static func embeddedArtworkData(for:) async -> Data? }`.
- Modifies: `AudioExportService.exportM4B(items:outputURL:metadata:)` — adds a defaulted `metadata: ExportMetadata? = nil`.

- [ ] **Step 1: Write failing tests for metadata item construction**

`EchoTests/ExportMetadataTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct ExportMetadataTests {
    @Test func buildsTitleAndArtistItems() {
        let meta = ExportMetadata(title: "My Book", author: "Jane Doe", coverArt: nil)
        let items = meta.assetMetadataItems()
        #expect(items.contains { $0.identifier == .commonIdentifierTitle && ($0.value as? String) == "My Book" })
        #expect(items.contains { $0.identifier == .commonIdentifierArtist && ($0.value as? String) == "Jane Doe" })
    }

    @Test func omitsEmptyAuthorAndNilCover() {
        let meta = ExportMetadata(title: "T", author: "", coverArt: nil)
        let items = meta.assetMetadataItems()
        #expect(!items.contains { $0.identifier == .commonIdentifierArtist })
        #expect(!items.contains { $0.identifier == .commonIdentifierArtwork })
    }

    @Test func includesArtworkWhenPresent() {
        let meta = ExportMetadata(title: "T", author: nil, coverArt: Data([0xFF, 0xD8, 0xFF]))
        #expect(meta.assetMetadataItems().contains { $0.identifier == .commonIdentifierArtwork })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: COMPILE FAIL — `cannot find 'ExportMetadata'`.

- [ ] **Step 3: Implement `ExportMetadata`**

`EchoCore/Services/Export/ExportMetadata.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Book-level tags embedded in the exported file. Cover art is raw image data
/// (JPEG/PNG bytes) so the type stays cross-platform (no UIImage/NSImage).
struct ExportMetadata: Equatable {
    var title: String
    var author: String?
    var coverArt: Data?

    /// AVFoundation common-key metadata items for the export pass.
    func assetMetadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(Self.item(.commonIdentifierTitle, value: title as NSString))
        if let author, !author.isEmpty {
            items.append(Self.item(.commonIdentifierArtist, value: author as NSString))
        }
        if let coverArt {
            items.append(Self.item(.commonIdentifierArtwork, value: coverArt as NSData))
        }
        return items
    }

    private static func item(_ id: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ExportMetadataTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Implement `ExportMetadataResolver` (cross-platform, no UIKit)**

`EchoCore/Services/Export/ExportMetadataResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// Gathers `ExportMetadata` without any UIKit/AppKit dependency (compiles on
/// iOS + macOS). Title/author come from `AudiobookRecord`; cover art is pulled
/// best-effort from the first source file's embedded artwork (imported books
/// usually carry one; narrated cache files do not → cover stays nil and the
/// prompt step in Task 9 offers to add one).
enum ExportMetadataResolver {
    static func resolve(
        audiobookID: String,
        fallbackTitle: String,
        firstSourceURL: URL?,
        databaseWriter: DatabaseWriter
    ) async -> ExportMetadata {
        let record = try? AudiobookDAO(db: databaseWriter).get(audiobookID)
        let title = (record?.title).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let author = record?.author
        var cover: Data?
        if let firstSourceURL { cover = await embeddedArtworkData(for: firstSourceURL) }
        return ExportMetadata(title: title, author: author, coverArt: cover)
    }

    /// Reads raw artwork `Data` from an asset's common metadata (cross-platform).
    static func embeddedArtworkData(for url: URL) async -> Data? {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
}
```

- [ ] **Step 6: Embed metadata in `AudioExportService`**

In `EchoCore/Services/Export/AudioExportService.swift`, add the defaulted parameter and set the session metadata. Change the signature and the export-session block:

```swift
    func exportM4B(items: [ExportItem], outputURL: URL, metadata: ExportMetadata? = nil) async throws {
```

…and after `session.outputFileType = .m4a` add:

```swift
        if let metadata { session.metadata = metadata.assetMetadataItems() }
```

- [ ] **Step 7: Resolve + pass metadata at both call sites**

iOS `ExportProgressView.runExport()` — before `exportM4B`, resolve metadata and pass it:

```swift
                let items = try await source.items()
                let meta = await ExportMetadataResolver.resolve(
                    audiobookID: audiobookID, fallbackTitle: bookTitle,
                    firstSourceURL: items.first?.url,
                    databaseWriter: databaseWriter ?? PlayerModel.exportFallbackWriter())
                try await AudioExportService().exportM4B(items: items, outputURL: output, metadata: meta)
```

macOS `MacAudioExportView` — inside the `Task`, after `let items = try await source.items()`:

```swift
                    let meta = await ExportMetadataResolver.resolve(
                        audiobookID: audiobookID, fallbackTitle: bookTitle,
                        firstSourceURL: items.first?.url, databaseWriter: databaseWriter)
                    try await AudioExportService().exportM4B(items: items, outputURL: temp, metadata: meta)
```

- [ ] **Step 8: Add an integration test that title/artist survive the chapter-atom rewrite**

Append to `EchoTests/AudioExportServiceTests.swift` (guarded `#if os(iOS) || os(macOS)` since it needs the `AudioMarker`-linked host and real encode). Use Echo's `AVFoundationAudioWriter` to make two tiny ALAC `.m4a` fixtures (same approach as `ChapterMarkerWriterTests.makeSilentM4A`), export with metadata, then reload and assert the title item is present:

```swift
    @Test func embedsTitleMetadataInOutput() async throws {
        let a = try await Self.makeSilentM4A(seconds: 1)
        let b = try await Self.makeSilentM4A(seconds: 1)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let items = [
            ExportItem(title: "One", url: a, timeRange: nil),
            ExportItem(title: "Two", url: b, timeRange: nil),
        ]
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        defer { try? FileManager.default.removeItem(at: out) }
        try await AudioExportService().exportM4B(
            items: items, outputURL: out,
            metadata: ExportMetadata(title: "Round Trip", author: "Tester", coverArt: nil))

        let meta = try await AVURLAsset(url: out).load(.commonMetadata)
        let title = meta.first { $0.commonKey == .commonKeyTitle }
        #expect((try? await title?.load(.stringValue)) == "Round Trip")
    }
```

Copy `makeSilentM4A` from `ChapterMarkerWriterTests` into a shared test helper (e.g. `EchoTests/Helpers/SilentAudioFixture.swift`) if it isn't already reusable, and have both suites call it (DRY).

- [ ] **Step 9: Run the suites**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ExportMetadataTests` and `make test-only FILTER=EchoTests/AudioExportServiceTests`
Expected: PASS. If the title item does not survive the `swift-audio-marker` rewrite, set the metadata via `ChapterMarkerWriter` instead (write atoms first, then a metadata pass) — but the expected path is that export-session metadata persists through the package's in-place atom add.

- [ ] **Step 10: Commit**

```bash
git add EchoCore/Services/Export/ExportMetadata.swift EchoCore/Services/Export/ExportMetadataResolver.swift EchoCore/Services/Export/AudioExportService.swift EchoCore/Views/ExportProgressView.swift "Echo macOS/Views/MacAudioExportView.swift" EchoTests/ExportMetadataTests.swift EchoTests/AudioExportServiceTests.swift EchoTests/Helpers/SilentAudioFixture.swift
git commit -m "$(printf 'feat(export): embed title/author/cover metadata in exported m4b\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 9: "Prompt only if missing" confirm sheet

**Files:**
- Create: `EchoCore/Services/Export/ExportMetadata+Completeness.swift` (pure check)
- Create: `EchoTests/ExportMetadataCompletenessTests.swift`
- Create: `EchoCore/Views/ExportDetailsSheet.swift` (iOS confirm sheet — `#if os(iOS)`)
- Create: `Echo macOS/Views/MacExportDetailsView.swift` (macOS confirm sheet)
- Modify: iOS `ExportProgressView.swift` + macOS `MacAudioExportView.swift` to branch on completeness

**Interfaces:**
- Produces: `extension ExportMetadata { var isComplete: Bool { author?.isEmpty == false && coverArt != nil } }`.

- [ ] **Step 1: Failing test for the completeness rule**

`EchoTests/ExportMetadataCompletenessTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ExportMetadataCompletenessTests {
    @Test func incompleteWhenAuthorMissing() {
        #expect(!ExportMetadata(title: "T", author: nil, coverArt: Data([1])).isComplete)
        #expect(!ExportMetadata(title: "T", author: "", coverArt: Data([1])).isComplete)
    }
    @Test func incompleteWhenCoverMissing() {
        #expect(!ExportMetadata(title: "T", author: "A", coverArt: nil).isComplete)
    }
    @Test func completeWithBoth() {
        #expect(ExportMetadata(title: "T", author: "A", coverArt: Data([1])).isComplete)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: COMPILE FAIL — `value of type 'ExportMetadata' has no member 'isComplete'`.

- [ ] **Step 3: Implement the completeness rule**

`EchoCore/Services/Export/ExportMetadata+Completeness.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ExportMetadata {
    /// "Good enough to export silently": both an author and a cover are present.
    /// When false, the export flow shows a small pre-filled confirm sheet.
    var isComplete: Bool {
        (author?.isEmpty == false) && coverArt != nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make build-tests` then `make test-only FILTER=EchoTests/ExportMetadataCompletenessTests`
Expected: PASS (3 tests).

- [ ] **Step 5: iOS confirm sheet**

`EchoCore/Views/ExportDetailsSheet.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import PhotosUI
    import SwiftUI

    /// Pre-filled "confirm details" step shown only when author or cover is
    /// missing. Returns the (possibly edited) metadata to the caller's `onConfirm`.
    struct ExportDetailsSheet: View {
        @State var metadata: ExportMetadata
        let onConfirm: (ExportMetadata) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var pickerItem: PhotosPickerItem?

        var body: some View {
            NavigationStack {
                Form {
                    Section("Title") {
                        TextField("Title", text: $metadata.title)
                    }
                    Section("Author") {
                        TextField("Author", text: Binding(
                            get: { metadata.author ?? "" },
                            set: { metadata.author = $0 }))
                    }
                    Section("Cover") {
                        if let data = metadata.coverArt, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 120)
                        }
                        PhotosPicker("Choose cover…", selection: $pickerItem, matching: .images)
                    }
                }
                .navigationTitle("Export Details")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export") { onConfirm(metadata); dismiss() }
                    }
                    ToolbarItem(placement: .cancelAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task(id: pickerItem) {
                    if let data = try? await pickerItem?.loadTransferable(type: Data.self) {
                        metadata.coverArt = data
                    }
                }
            }
        }
    }
#endif
```

- [ ] **Step 6: macOS confirm sheet**

`Echo macOS/Views/MacExportDetailsView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Pre-filled confirm step (macOS), shown only when author or cover is missing.
struct MacExportDetailsView: View {
    @State var metadata: ExportMetadata
    let onConfirm: (ExportMetadata) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Details").font(.title2)
            TextField("Title", text: $metadata.title)
            TextField("Author", text: Binding(
                get: { metadata.author ?? "" }, set: { metadata.author = $0 }))
            HStack {
                if let data = metadata.coverArt, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 80)
                }
                Button("Choose cover…") { chooseCover() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") { onConfirm(metadata); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 420)
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            metadata.coverArt = data
        }
    }
}
```

- [ ] **Step 7: Branch on completeness at both call sites**

iOS `ExportProgressView`: add `@State private var pendingMetadata: ExportMetadata?` and a `.sheet(item:)` presenting `ExportDetailsSheet`. In `runExport()`, after resolving `meta`, branch:

```swift
                if meta.isComplete {
                    try await AudioExportService().exportM4B(items: items, outputURL: output, metadata: meta)
                    exportedURL = output
                } else {
                    // Hand off to the confirm sheet; the actual export runs in onConfirm.
                    isExporting = false
                    pendingMetadata = meta
                    return
                }
```

and add the sheet (the `onConfirm` re-enters a small `export(with:)` that runs `AudioExportService` and sets `exportedURL`). Keep `ExportItem`s captured in `@State` so `onConfirm` can reuse them without re-reading the source.

macOS `MacAudioExportView`: identical branch — if `meta.isComplete`, export; else present `MacExportDetailsView(metadata: meta) { confirmed in /* export with confirmed */ }`.

- [ ] **Step 8: Build both platforms + run all export suites**

Run: `make build-tests` then each of `make test-only FILTER=EchoTests/ExportMetadataCompletenessTests`, `.../ExportMetadataTests`, `.../AudioExportServiceTests`, `.../ImportedBookSourceTests`, `.../ExportSourceResolverTests`, `.../NarrationExportOrderingTests`.
Then `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' build`.
Expected: all PASS; both targets build.

- [ ] **Step 9: Manual checks (owner)** — narrated book (no author/cover): export prompts, pre-filled with title, lets you add author + cover, produces a tagged `.m4b`. Imported book with embedded cover + author: exports silently (no prompt).

- [ ] **Step 10: Commit**

```bash
git add EchoCore/Services/Export/ExportMetadata+Completeness.swift EchoTests/ExportMetadataCompletenessTests.swift EchoCore/Views/ExportDetailsSheet.swift "Echo macOS/Views/MacExportDetailsView.swift" EchoCore/Views/ExportProgressView.swift "Echo macOS/Views/MacAudioExportView.swift"
git commit -m "$(printf 'feat(export): prompt for author/cover only when missing\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Final: docs sync + wrap-up

### Task 10: Documentation

**Files:** `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md`, `ROADMAP.md`

- [ ] **Step 1:** Run the `doc-sync` skill. Apply:
  - `ARCHITECTURE.md` — new `EchoCore/Services/Export/` module: `AudioExportService` + the `ExportSource` seam (`NarrationCacheSource`, `ImportedBookSource`, `ExportSourceResolver`) + `ExportMetadata`. Note the m4b writer reuses `ChapterMarkerWriter` (now cross-platform).
  - `README.md` — feature line: "Export any book — narrated or imported — as a chaptered `.m4b`, on iOS and macOS."
  - `CHANGELOG.md` — `### Added` entry.
  - `ROADMAP.md` — mark cross-platform m4b export shipped; note mp3 is deferred (needs LAME; per-chapter-file strategy decided).
- [ ] **Step 2: Commit**

```bash
git add ARCHITECTURE.md README.md CHANGELOG.md ROADMAP.md
git commit -m "$(printf 'docs: cross-platform m4b audiobook export\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Self-review notes (plan author)

- **Spec coverage:** narrated→macOS (Tasks 3–4, 7), imported→both (Tasks 5–7), unified auto-detect action (Task 6–7), prompt-if-missing (Task 9), metadata embedding (Task 8), single-m4b→m4b as time-range slices (Task 5 `singleFileBecomesTimeRangeSlices`). mp3 correctly absent (Non-Goals).
- **Deviation from spec (intentional, simpler):** the spec sketched `ExportChapter(title, segments:[…])`; reading the actual compose loop showed one segment per chapter suffices, so the seam is `ExportItem(title, url, timeRange?)`. The `securityScopeDenied`/`sourceUnavailable` errors moved onto `ImportedBookSource` (where missing files are detectable) rather than the service.
- **Type consistency:** `ExportItem`, `ExportSource.items()`, `AudioExportService.exportM4B(items:outputURL:metadata:)`, `NarrationCacheSource.orderedItems`, `ImportedBookSource.makeItems`, `ExportSourceResolver.resolve`, `ExportMetadata.assetMetadataItems()/isComplete` are used identically across tasks.
- **Risk to watch (Task 8 Step 9):** confirm export-session `metadata` survives the `swift-audio-marker` in-place atom rewrite; fallback noted if not.
