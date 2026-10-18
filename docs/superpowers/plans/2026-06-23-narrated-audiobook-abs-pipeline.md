# Narrated-audiobook → Audiobookshelf pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Echo-narrated `.m4b` is self-describing (correct tags, cover, real heading chapter titles, version stamp); Audiobookshelf shows ONE item per book (ebook + audiobook), no duplicates; pulling a book from ABS into Echo lights up read-along.

**Architecture:** Fix at the source — repair the EchoCore export + the forked `swift-audio-marker` writer so every m4b (app + CLI) is correct; add a CLI `retag` path for already-rendered m4bs; rework the off-git delivery to a one-folder-per-book ABS layout + a one-time dedup migration; and run `DocumentImportFinalizer` on the ABS-pulled with-audio load path.

**Tech Stack:** Swift (EchoCore, swift-audio-marker fork, ArgumentParser CLI), zsh delivery scripts, Audiobookshelf API via `abs_admin.py`, ffprobe/exiftool/AtomicParsley for independent verification.

## Global Constraints

- PR targets `nightly`. One integration branch off `origin/nightly` folding `claude/echo-cli-narrate` (#145) + `66ea984` (export/fork fix) + this work.
- Fork: `dfakkeldy/swift-audio-marker`; Echo pins it by **immutable revision SHA** (`Package.resolved` is gitignored). Bump to tag **0.1.3** after the robustness fixes.
- Version-stamp comment string: `"Echo narration — <yyyy-MM-dd> · ONNX rv\(NarrationFileNaming.renderVersion)"` (renderVersion is currently `6`).
- ABS folder layout: `Author/Title/Title.{epub,m4b,alignment.json}`; title/author from EPUB `dc:title`/`dc:creator`; replacing a file = ABS delete-item + rescan (never a plain rescan).
- macOS 16 GB: never run two `xcodebuild` concurrently; `make build-tests` needs `CODE_SIGNING_ALLOWED=NO` (onnxruntime codesign break on Xcode 26.5).
- `make build-tests` then `make test-only FILTER=EchoTests/<Suite>` for Echo; `swift test --filter AudioMarkerTests` in the fork.
- ABS env (from `~/Developer/echo-overnight/deliver-to-abs.sh`): `ABS_URL=http://100.95.69.48:13378`, library `f246f255-a98f-4665-8478-11d8dae37b2e`; helper `~/.claude/skills/audiobookshelf-setup/scripts/abs_admin.py`; SSH `dan@100.95.69.48`; Syncthing mirror `/Volumes/Fledging-WD-2TB/Books`, host `/var/mnt/2TB Internal HDD/Books`.

---

## Phase 0 — Integration branch

### Task 0: Create the integration branch off nightly

**Files:** none (git ops). Worktree: a fresh one for the integration branch.

- [ ] **Step 1:** From the main checkout, create the branch and worktree off the latest nightly:

```bash
cd /Users/dfakkeldy/Developer/Echo
git fetch origin
git worktree add -b feature/narrated-abs-pipeline .claude/worktrees/narrated-abs-pipeline origin/nightly
cd .claude/worktrees/narrated-abs-pipeline
```

- [ ] **Step 2:** Fold in the echo-cli branch (#145) and the export/fork fix:

```bash
git merge --no-ff claude/echo-cli-narrate -m "merge: echo-cli narrate (#145) into integration branch"
git cherry-pick 66ea984        # export/fork fix (AudioMarkerStub/ExportMetadataResolver/tests/pbxproj/docs)
git cherry-pick f062c91        # the design spec
```

- [ ] **Step 3:** Resolve conflicts (CHANGELOG.md is the likely one — keep both the export-fix entry and nightly's entries). Then confirm the tree builds:

```bash
xcodebuild -resolvePackageDependencies -scheme Echo 2>&1 | grep -iE "AudioMarker|error"
```
Expected: `AudioMarker … @ 0.1.2` (or the revision after Task A-pin), no errors.

- [ ] **Step 4:** Copy this plan + spec into the branch if not already carried (they were committed on `dreamy-torvalds`; re-add if missing):

```bash
ls docs/superpowers/specs/2026-06-23-narrated-audiobook-abs-pipeline-design.md docs/superpowers/plans/2026-06-23-narrated-audiobook-abs-pipeline.md
git add -A && git commit -m "chore: integration branch for narrated-abs pipeline" || true
```

---

## Phase A-fork — swift-audio-marker robustness (→ 0.1.3)

Work in `/Users/dfakkeldy/Developer/swift-audio-marker` on branch `fix/itunes-metadata-handler-and-quicktime-chapter-track`. Verify with the harness at `/tmp/am-probe` (probe) + `/tmp/avcheck` (AVFoundation) + ffprobe.

### Task F1: 64-bit-safe chapter chunk offsets (review HIGH-1)

**Files:**
- Modify: `Sources/AudioMarker/MP4/MP4Writer.swift` (the `writeMoovFirst`/`writeMdatFirst` ordering + `adjustMoovForLayout`/`patchChapterTrackStco` offset math)
- Test: `Tests/AudioMarkerTests/MP4Tests/MP4WriterTests.swift`

**Interfaces:**
- Produces: chapter sample `mdat` written BEFORE the audio `mdat`; a thrown `MP4Error` when any chapter chunk offset would exceed `UInt32.max`.

- [ ] **Step 1: Write the failing test** — a synthetic large-offset case. Add to `MP4WriterTests`:

```swift
@Test("Chapter stco offsets stay within 32-bit by ordering chapter mdat first")
func chapterMdatPlacedBeforeAudioMdat() throws {
    let url = try createTestMP4WithMdat()
    defer { try? FileManager.default.removeItem(at: url) }
    var info = AudioFileInfo()
    info.chapters = ChapterList([Chapter(start: .zero, title: "A"), Chapter(start: .seconds(1), title: "B")])
    try writer.write(info, to: url)
    let bytes = try Data(contentsOf: url)
    // The first mdat after ftyp/moov must be the chapter mdat (its text samples carry the titles),
    // i.e. "A"/"B" appear before the (silent) audio mdat payload region.
    let firstMdat = bytes.range(of: Data("mdat".utf8))!.lowerBound
    let titleA = bytes.range(of: Data("A".utf8))!.lowerBound
    #expect(titleA < bytes.count)              // sanity
    #expect(firstMdat < titleA || titleA < firstMdat + 4096)  // chapter samples adjacent to first mdat
    // Round-trips through the package reader unchanged.
    #expect(try reader.read(from: url).chapters.count == 2)
}
```

- [ ] **Step 2: Run to verify it fails / or passes-trivially** — `swift test --filter MP4WriterTests` and confirm the ordering assertion drives the change (if it passes as-is, tighten it to assert chapter-mdat-before-audio-mdat by atom walk).

- [ ] **Step 3: Implement** — in `MP4Writer`, write the chapter `mdat` before the audio `mdat` (both for moov-first and mdat-first layouts), recompute `chapterMdatDataStart` relative to the new position, and guard:

```swift
// in adjustMoovForLayout, before patching:
guard chapterMdatDataStart <= UInt64(UInt32.max) else {
    throw MP4Error.writeFailed("chapter chunk offset exceeds 32-bit; book too large for stco chapter track")
}
```
Place the chapter mdat immediately after ftyp/(moov when moov-first) so its offset is always small.

- [ ] **Step 4: Run tests** — `swift test --filter AudioMarkerTests`. Expected: all pass (chapter round-trip + new ordering test).

- [ ] **Step 5: Harness re-verify** — `cd /tmp/am-probe && swift build && ./.build/debug/probe in.m4a f1.m4b cover.jpg && swift /tmp/avcheck/check.swift /tmp/am-probe/f1.m4b | grep chapterGroups` → 2 groups.

- [ ] **Step 6: Commit** — `git commit -am "fix(mp4): place chapter mdat first + guard 32-bit chapter offsets"`

### Task F2: version-1 elst/tkhd for >27 h books (review HIGH-2)

**Files:**
- Modify: `Sources/AudioMarker/MP4/MP4TextTrackBuilder.swift` (`buildEdts`, `buildTkhd`)
- Test: `Tests/AudioMarkerTests/MP4Tests/MP4WriterTests.swift`

- [ ] **Step 1: Write the failing test:**

```swift
@Test("Edit list spans full movie duration without 32-bit truncation")
func editListNotTruncatedForLongBooks() throws {
    let builder = MP4TextTrackBuilder()
    // movieDuration > UInt32.max in movie timescale
    let big: UInt64 = UInt64(UInt32.max) + 100_000
    let r = builder.buildChapterTrack(chapters: ChapterList([Chapter(start: .zero, title: "A")]),
                                      trackID: 3, movieTimescale: 44100, movieDuration: big)
    // elst segment_duration must equal `big` (v1, 64-bit) not its 32-bit truncation.
    #expect(r.trak.range(of: Data("elst".utf8)) != nil)
    // (assert the 8-byte segment duration equals `big` by locating the elst payload)
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter MP4WriterTests`. Expected FAIL (current elst is v0/32-bit).

- [ ] **Step 3: Implement** — emit version-1 `elst` (8-byte segment_duration + 8-byte media_time) and version-1 `tkhd` (8-byte duration) when `movieDuration > UInt32.max`, mirroring the package's mvhd-v1 branch; keep v0 otherwise.

- [ ] **Step 4: Run tests** — `swift test --filter AudioMarkerTests`. Expected: pass.

- [ ] **Step 5: Commit** — `git commit -am "fix(mp4): 64-bit elst/tkhd for movies beyond 32-bit duration"`

### Task F3: clamp text-sample length prefix (review LOW) + tag 0.1.3

**Files:** Modify `Sources/AudioMarker/MP4/MP4TextTrackBuilder.swift:71` (sample writer).

- [ ] **Step 1:** Clamp the UTF-8 title bytes to ≤ 65535 on a character boundary before writing the `UInt16` length prefix (mirror the `min(urlBytes.count, 255)` href precedent).
- [ ] **Step 2:** `swift test --filter AudioMarkerTests` → pass.
- [ ] **Step 3:** Commit, then tag + push + update upstream PR:

```bash
git commit -am "fix(mp4): clamp chapter text sample length prefix to 16-bit"
git tag -a 0.1.3 -m "0.1.3: 64-bit-safe chapter offsets/elst/tkhd + length clamp" && git push origin HEAD 0.1.3
gh pr comment atelier-socle/swift-audio-marker#2 --body "Pushed 0.1.3 with 64-bit-safe chapter offsets, v1 elst/tkhd, and a text-sample length clamp."
```

---

## Phase A-pin — pin Echo to the fork by revision

### Task P1: revision-SHA pin

**Files:** Modify `Echo.xcodeproj/project.pbxproj` (the `swift-audio-marker` `XCRemoteSwiftPackageReference`).

- [ ] **Step 1:** Get the 0.1.3 commit SHA: `git -C /Users/dfakkeldy/Developer/swift-audio-marker rev-parse 0.1.3`.
- [ ] **Step 2:** Change the requirement from `exactVersion 0.1.2` to:

```
requirement = {
    kind = revision;
    revision = "<the 0.1.3 sha>";
};
```

- [ ] **Step 3:** `xcodebuild -resolvePackageDependencies -scheme Echo` → resolves AudioMarker at the revision.
- [ ] **Step 4: Commit** — `git commit -am "build: pin swift-audio-marker fork by immutable revision (0.1.3)"`

---

## Phase A — EchoCore export

### Task A1: real heading chapter titles in the headless export

**Files:**
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift:233-235`
- Test: `EchoTests/HeadlessNarrationExportTitlesTests.swift` (new — pure mapping test)

**Interfaces:**
- Consumes: `NarrationOutlineBuilder.build(allBlocks:isRendered:) -> [NarrationOutlineChapter]` (`.chapterIndex`, `.title`).
- Produces: export items titled by heading, keyed on `chapterIndex`.

- [ ] **Step 1: Write the failing test** — verify titles come from headings, by chapterIndex:

```swift
@Test func mapsExportTitlesFromHeadingsByChapterIndex() {
    let outline = [
        NarrationOutlineChapter(chapterIndex: 0, displayNumber: 1, title: "Introduction", isExcluded: false, isRendered: true),
        NarrationOutlineChapter(chapterIndex: 2, displayNumber: 2, title: "The Cat Ate It", isExcluded: false, isRendered: true),
    ]
    let titles = HeadlessNarrationRunner.titlesByChapterIndex(outline)
    #expect(titles[0] == "Introduction")
    #expect(titles[2] == "The Cat Ate It")
}
```

- [ ] **Step 2: Run to verify it fails** — `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/HeadlessNarrationExportTitlesTests` → FAIL (`titlesByChapterIndex` undefined).

- [ ] **Step 3: Implement** — add the pure helper and use it:

```swift
// HeadlessNarrationRunner
static func titlesByChapterIndex(_ outline: [NarrationOutlineChapter]) -> [Int: String] {
    Dictionary(uniqueKeysWithValues: outline.map { ($0.chapterIndex, $0.title) })
}
// in export (replacing lines 233-235):
let titles = Self.titlesByChapterIndex(
    NarrationOutlineBuilder.build(allBlocks: blocks, isRendered: { _ in true }))
let items = ordered.map { (chIdx, url) in
    ExportItem(title: titles[chIdx] ?? "Chapter \(chIdx + 1)", url: url, timeRange: nil)
}
```

- [ ] **Step 4: Run tests** — same FILTER → PASS.
- [ ] **Step 5: Commit** — `git commit -am "fix(narration): real heading chapter titles in headless m4b export"`

### Task A2: resolve the EPUB cover from the OPF (headless)

**Files:**
- Create: `EchoCore/Services/Narration/EpubCoverResolver.swift`
- Test: `EchoTests/EpubCoverResolverTests.swift`
- Modify: `HeadlessNarrationRunner.swift` (use it as the primary cover source; keep the image-block scan as fallback)

**Interfaces:**
- Produces: `enum EpubCoverResolver { static func coverData(expandedEPUBDir: URL) -> Data? }` — parses the OPF (`<meta name="cover" content="id">` or a manifest item with `properties="cover-image"`), resolves the referenced image file relative to the OPF, returns JPEG/PNG bytes (nil otherwise).

- [ ] **Step 1: Write the failing test** — build a tiny on-disk EPUB dir with an OPF declaring a cover and assert the bytes come back:

```swift
@Test func resolvesCoverFromOpfMeta() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    let jpeg = Data([0xFF,0xD8,0xFF,0xE0,0,0]); try jpeg.write(to: dir.appendingPathComponent("OEBPS/cover.jpg"))
    let opf = """
    <?xml version="1.0"?><package><metadata><meta name="cover" content="cov"/></metadata>
    <manifest><item id="cov" href="cover.jpg" media-type="image/jpeg"/></manifest></package>
    """
    try opf.write(to: dir.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
    #expect(EpubCoverResolver.coverData(expandedEPUBDir: dir) == jpeg)
}
```

- [ ] **Step 2: Run to verify it fails** — FILTER `EchoTests/EpubCoverResolverTests` → FAIL.
- [ ] **Step 3: Implement** — find the OPF (`*.opf` under the dir), parse the cover id → manifest href → resolve relative to the OPF's directory; restrict to `jpg/jpeg/png`; return `Data(contentsOf:)`. Reuse the existing `EPUBXMLParsing` helpers if they already expose manifest items; otherwise a small regex/XMLParser over the OPF.
- [ ] **Step 4: Run tests** → PASS.
- [ ] **Step 5: Wire into HeadlessNarrationRunner** — `let coverData = EpubCoverResolver.coverData(expandedEPUBDir: config.epubURL) ?? <existing image-block scan>`.
- [ ] **Step 6: Commit** — `git commit -am "fix(narration): resolve m4b cover from EPUB OPF (headless)"`

### Task A3: version-stamp comment field

**Files:**
- Modify: `EchoCore/Services/Export/ExportMetadata.swift` (add `comment`)
- Modify: `EchoCore/Services/Narration/AudioMarkerStub.swift` (map `©cmt`)
- Modify: `HeadlessNarrationRunner.swift` (set the comment), and the app's narrated-export path (`ExportMetadataResolver` / caller) to set it for narrated books
- Test: `EchoTests/ChapterMarkerWriterTests.swift` (byte-assert `©cmt` + the comment string)

**Interfaces:**
- Produces: `ExportMetadata.comment: String?`; `ChapterMarkerWriter` writes it to `info.metadata.comment`.

- [ ] **Step 1: Write the failing test** — extend `roundTripPreservesChaptersAndTitle` or add a case asserting the comment string is present in the output bytes when set.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — add `var comment: String?` (default nil) to `ExportMetadata`; in `ChapterMarkerWriter` after the title/album lines: `if let c = metadata.comment, !c.isEmpty { info.metadata.comment = c }`. In `HeadlessNarrationRunner`, build `let stamp = "Echo narration — \(Self.isoDate()) · ONNX rv\(NarrationFileNaming.renderVersion)"` and pass `comment: stamp`. Add a date helper (`yyyy-MM-dd`, `Locale(identifier: "en_US_POSIX")`, UTC).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(export): embed Echo-narration version stamp in m4b comment"`

### Task A4: don't clobber imported album/genre; guard empty title; log cover failure (review MEDIUM-4 + LOWs)

**Files:** Modify `EchoCore/Services/Narration/AudioMarkerStub.swift`; Test `EchoTests/ChapterMarkerWriterTests.swift`.

- [ ] **Step 1: Write the failing test** — give the source m4b a pre-existing album/genre (write one first via the package, or assert the mapping only sets defaults when absent) and assert they survive while a narrated book (no prior tags) still gets `album=title`, `genre=Audiobook`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — only default when absent:

```swift
if let metadata {
    if !metadata.title.isEmpty {
        info.metadata.title = metadata.title
        if (info.metadata.album ?? "").isEmpty { info.metadata.album = metadata.title }
    }
    if (info.metadata.genre ?? "").isEmpty { info.metadata.genre = "Audiobook" }
    if let author = metadata.author, !author.isEmpty {
        info.metadata.artist = author
        if (info.metadata.albumArtist ?? "").isEmpty { info.metadata.albumArtist = author }
    }
    if let c = metadata.comment, !c.isEmpty { info.metadata.comment = c }
    if let coverArt = metadata.coverArt {
        if let art = try? Artwork(data: coverArt) { info.metadata.artwork = art }
        else { logger.warning("export: cover art could not be decoded; exporting without cover") }
    }
}
```
(Add a `logger` if the type lacks one.)

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -am "fix(export): preserve imported album/genre; guard empty title; log cover failures"`

### Task A5: independent-reader (ffprobe) test + strengthen AVFoundation test

**Files:** Create `EchoTests/M4BFfprobeExportTests.swift`; Modify `EchoTests/AudioExportServiceTests.swift` (the AVFoundation case).

- [ ] **Step 1: Write the ffprobe test** — skip when ffprobe is absent:

```swift
@Test func ffprobeSeesTagsCoverAndChapterTitles() async throws {
    guard let ffprobe = which("ffprobe") else { return }   // skip-if-absent
    // export a 2-chapter m4b with title/author/comment/cover via AudioExportService
    // run: ffprobe -show_format -show_chapters -show_streams -of json <out>
    // #expect format.tags.title == "...", comment contains "ONNX rv", an attached_pic stream exists,
    //        chapter tags.title == ["One","Two"]
}
```
Add a tiny `which(_:)` helper (`/usr/bin/env which` via `Process`).

- [ ] **Step 2: Strengthen the AVFoundation test** — in `titleAndChaptersVisibleToAVFoundation`, assert each group's `commonKeyTitle` equals `["One","Two"]` and the time ranges are 0–1 / 1–2, not just `groups.count == 2`.
- [ ] **Step 3: Run** — `make test-only FILTER=EchoTests/M4BFfprobeExportTests` and `…/AudioExportServiceTests` → PASS (ffprobe test runs locally where ffprobe exists; skipped on CI).
- [ ] **Step 4: Commit** — `git commit -am "test(export): ffprobe independent-reader + assert chapter titles/times via AVFoundation"`

---

## Phase B — retag already-rendered m4bs (no re-render)

### Task B1: M4BRetagger service

**Files:**
- Create: `EchoCore/Services/Export/M4BRetagger.swift`
- Test: `EchoTests/M4BRetaggerTests.swift`

**Interfaces:**
- Produces: `enum M4BRetagger { static func chapterTitles(forExpandedEPUBAt: URL) -> [String]; static func retag(m4b: URL, expandedEPUBDir: URL, out: URL, title: String, author: String?, comment: String) async throws }`
- Consumes: `NarrationOutlineBuilder` (ordered titles), `EpubCoverResolver` (cover), `ChapterMarkerWriter` (write), AVFoundation `loadChapterMetadataGroups` (read existing chapter times).

- [ ] **Step 1: Write the failing test** — `chapterTitles(forExpandedEPUBAt:)` returns the heading titles in chapter order for a fixture EPUB dir (reuse the A2-style fixture with two headings). Assert order.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — `chapterTitles` imports the EPUB blocks (in-memory `DatabaseService`, same as `HeadlessNarrationRunner`) and returns `NarrationOutlineBuilder.build(...).sorted{ $0.displayNumber }.map(\.title)`. `retag` reads the m4b's existing chapter start times via `AVURLAsset.loadChapterMetadataGroups` (now AVFoundation-readable post-fork), zips them with `chapterTitles` (count-tolerant: if counts differ, keep times and pad/truncate titles, logging the mismatch), builds `[ChapterAtom]`, resolves the cover via `EpubCoverResolver`, and calls `ChapterMarkerWriter.writeChapters(_:to:outputURL:metadata:)` with `ExportMetadata(title:author:coverArt:comment:)`. Audio is copied by the writer's in-place modify — never re-encoded.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(export): M4BRetagger — re-stamp tags/cover/heading titles without re-render"`

### Task B2: `echo-cli retag` subcommand

**Files:**
- Create: `Tools/echo-cli/RetagCommand.swift`
- Modify: `Tools/echo-cli/EchoCLI.swift` (`subcommands: [NarrateCommand.self, RetagCommand.self]`)

**Interfaces:**
- Consumes: `M4BRetagger.retag(...)`.

- [ ] **Step 1: Implement** the command (mirror `NarrateCommand`):

```swift
struct RetagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retag",
        abstract: "Re-stamp an existing m4b with real heading titles, tags, cover, version comment (no re-render).")
    @Option var m4b: String
    @Option var epub: String
    @Option var out: String?
    @Option var title: String
    @Option var author: String = "Unknown Author"
    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let stamp = "Echo narration — \(M4BRetagger.isoDateToday()) · ONNX rv\(NarrationFileNaming.renderVersion)"
        let outURL = URL(fileURLWithPath: out ?? m4b)
        try await M4BRetagger.retag(m4b: URL(fileURLWithPath: m4b),
            expandedEPUBDir: URL(fileURLWithPath: epub), out: outURL,
            title: title, author: author, comment: stamp)
        print("retagged \(outURL.lastPathComponent)")
    }
}
```

- [ ] **Step 2:** Register the subcommand in `EchoCLI.swift`.
- [ ] **Step 3: Build the CLI** — `xcodebuild -scheme echo-cli -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` (or the project's documented echo-cli build). Expected: build succeeds; `echo-cli retag --help` lists the options.
- [ ] **Step 4: Commit** — `git commit -am "feat(cli): echo-cli retag subcommand"`

---

## Phase E — ABS-import read-along

### Task E1: finalize after the with-audio EPUB pairing

**Files:** Modify `EchoCore/Services/PlayerLoadingCoordinator.swift` (the with-audio sibling-EPUB import path — `grep -n "EPUBAutoImportScanner.scanAndImportIfNeeded\|importer.import\|pairs" PlayerLoadingCoordinator.swift` to locate the audio-present branch; the audio-less branch at `importDocumentForAudiolessBook` already finalizes).

**Interfaces:** Consumes `DocumentImportFinalizer.finalize(audiobookID:blocks:fileURL:duration:databaseService:) async -> Bool`.

- [ ] **Step 1: Locate** the with-audio EPUB pairing — the path that imports a sibling EPUB when audio tracks exist (distinct from `importDocumentForAudiolessBook`). Confirm it does NOT already call `finalize` (Finding #5). If the with-audio path routes through `EPUBAutoImportScanner.scanAndImportIfNeeded` (which finalizes), then the gap is elsewhere — verify by adding a logging line and pulling a sidecar-carrying book; otherwise proceed.
- [ ] **Step 2: Write the failing test** — a `PlayerLoadingCoordinator`/finalizer integration test: import an EPUB + place a `<base>.alignment.json` sidecar next to the audio file, run the with-audio load path, and assert anchors with `source == .imported`/sidecar exist for local block IDs. (If a full coordinator test is too heavy, test the seam: a helper `finalizePairedDocument(audiobookID:blocks:fileURL:duration:db:)` that the coordinator calls, unit-tested directly.)
- [ ] **Step 3: Run** → FAIL.
- [ ] **Step 4: Implement** — after the with-audio sibling-EPUB `importer.import(...)` returns `blocks`, add:

```swift
_ = await DocumentImportFinalizer.finalize(
    audiobookID: audiobookID, blocks: blocks, fileURL: pairedEPUBURL,
    duration: bookDuration, databaseService: db)
```
`finalize` is a no-op without a `<base>.alignment.json` sidecar, so this is safe for every paired book and lights up read-along for any sidecar-carrying book (ABS-pulled or local).

- [ ] **Step 5: Run** → PASS.
- [ ] **Step 6: Commit** — `git commit -am "fix(abs): run DocumentImportFinalizer on the with-audio EPUB pairing so sidecar read-along works"`

---

## Phase C/D — delivery rework + one-time migration (off-git scripts)

Scripts live in `~/Developer/echo-overnight/` (not in the repo). Each step logs to `logs/`.

### Task C1: rework deliver-to-abs.sh to one Title-Case folder with the EPUB

**Files:** Modify `~/Developer/echo-overnight/deliver-to-abs.sh`.

- [ ] **Step 1:** After resolving `title`/`author` from the OPF (already present), copy the **EPUB** into `$dest` too:

```sh
# locate the source EPUB (expanded dir → repackage, or the original .epub)
srcepub=$(find "$EXP/$stem" -name '*.epub' 2>/dev/null | head -1)
[ -n "$srcepub" ] || srcepub="$HOME/Developer/explainer-audiobooks/books/$stem/$stem.epub"
[ -f "$srcepub" ] && cp "$srcepub" "$dest/$title.epub"
```
Keep the existing m4b + sidecar copy, the Syncthing host-size wait, the delete-stale-item, and the rescan. Update the host-sync wait to also confirm the `.epub` landed.

- [ ] **Step 2: Verify** on one already-rendered book (dry: copy to a scratch `$dest`, `ls` shows `Title.epub`, `Title.m4b`, `Title.alignment.json`). Do NOT run the live ABS delete/scan yet — that's Task D1's job to do library-wide.
- [ ] **Step 3:** Leave `deliver-watcher.sh` PAUSED until D1 completes.

### Task D1: one-time idempotent dedup migration

**Files:** Create `~/Developer/echo-overnight/migrate-abs-consolidate.sh`.

- [ ] **Step 1:** Write the script. For each Echo book (drive off `m4b-out/*.m4b` + a stem→Title map from each book's OPF):
  1. Compute canonical `Author/Title` from the OPF.
  2. Ensure `$SYNC/$Author/$Title/` holds `Title.epub` + `Title.m4b` + `Title.alignment.json` (move the EPUB out of the lowercase folder if that's where it is).
  3. Record the set of OLD folders for this book: the lowercase stem folder(s) (`*/the-bug-is-a-clue`, etc.) and any audio-only Title-Case folder that isn't canonical.
  4. After all books are consolidated: for each OLD folder now empty/superseded, `rm -rf` it on the Syncthing mirror; collect the corresponding stale ABS item ids (search by old title/path) and `abs_admin delete-ids` them.
  5. Wait for Syncthing to settle on the host (reuse the size-poll), then ONE `abs_admin scan`.
  6. Log every move/delete/skip; re-running is a no-op (guard each move/delete on existence).
- [ ] **Step 2: Dry-run mode first** — `migrate-abs-consolidate.sh --dry-run` prints the plan (moves/deletes/ABS-deletes) without touching anything. Review the output against Finding #4's expected dupes (the-bug-is-a-clue, git-happens, tests-first, the-voice-in-the-machine, findable, you-are-the-architect, Echo-From-The-Inside, Why-It-Feels-Right + their Title-Case audio-only twins).
- [ ] **Step 3: Run for real** — `migrate-abs-consolidate.sh`. Confirm via `abs_admin` (or the API) that each book is now ONE item with both ebook + audiobook and no duplicate.

---

## Phase Ops — rebuild CLI, restart watcher, retag, deliver

### Task Ops1: stop → rebuild → restart the render watcher

- [ ] **Step 1:** Stop the watcher + in-flight render: `pkill -f intake-watcher.sh; pkill -f "Debug/echo-cli narrate"`.
- [ ] **Step 2:** Build `echo-cli` from the integration branch (with fork 0.1.3 + Phase A/B). Note the new binary path under the branch's DerivedData.
- [ ] **Step 3:** Point `intake-watcher.sh` at the new binary (update the `echo-cli` path it invokes), restart it. It resumes via `.done`/`.anchors` markers. New renders are born correct (real titles, cover, tags, comment).

### Task Ops2: retag the already-rendered m4bs

- [ ] **Step 1:** For each `m4b-out/<stem>.m4b` already complete (`.done` present), run:

```bash
echo-cli retag --m4b "m4b-out/<stem>.m4b" --epub "expanded/<stem>" \
  --title "<dc:title>" --author "<dc:creator>"
```
(Wrap in a small loop reading title/author from each OPF, as `deliver-to-abs.sh` already does.)

- [ ] **Step 2: Verify** each: `ffprobe -show_format -show_chapters <m4b>` shows title/artist/comment, an attached cover stream, and real heading chapter titles. Spot-check `everything-but-the-code` is the clean (non-silent) version.

### Task Ops3: deliver + migrate + resume watcher

- [ ] **Step 1:** Run Task D1 (migration) to consolidate dupes.
- [ ] **Step 2:** Resume `deliver-watcher.sh` (now reworked, Task C1) so future renders deliver as one-folder items.
- [ ] **Step 3:** Spot-check ABS: pull one book into Echo on device and confirm read-along lights up (Phase E + sidecar).

---

## Phase Docs/PR

### Task Z1: doc-sync + PR

- [ ] **Step 1:** Use the `doc-sync` skill. Update CHANGELOG (a "Fixed" entry covering: readable m4b tags/cover/real-chapter-titles + version stamp; ABS one-folder layout + dedup; ABS-import read-along) and ARCHITECTURE (export writer section: version comment + imported-tag preservation; ABS import → finalize wiring).
- [ ] **Step 2:** `make build-tests CODE_SIGNING_ALLOWED=NO` then run the export + narration + ABS suites green; `swift test --filter AudioMarkerTests` green in the fork.
- [ ] **Step 3:** Open the PR to `nightly`: `gh pr create --base nightly --title "fix: narrated-audiobook → Audiobookshelf pipeline (metadata/cover/chapters, dedup, read-along)" --body <summary + spec link + success-criteria checklist>`.

---

## Self-review

- **Spec coverage:** A1–A5 (export), A-fork F1–F3 (robustness), A-pin (supply chain), B1–B2 (retag), C1/D1 (delivery+migration), E1 (read-along), Ops1–3 (rebuild/retag/deliver), Z1 (docs/PR) — every spec section maps to a task.
- **Deferred** (spawned as chips, not blocking): HEIC cover transcode, imported-non-mdir-covr read fallback, atom-tree test hardening.
- **Type consistency:** `EpubCoverResolver.coverData(expandedEPUBDir:)` reused by A2 + B1; `NarrationOutlineBuilder.build(allBlocks:isRendered:)` reused by A1 + B1; `ExportMetadata.comment` defined in A3, consumed by A4/B1/B2; `M4BRetagger.retag(...)` defined in B1, consumed by B2.
