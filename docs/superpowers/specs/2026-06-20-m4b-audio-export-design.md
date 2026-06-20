# Audiobook Export (.m4b) — Cross-Platform, Source-Agnostic

**Date:** 2026-06-20
**Status:** Design approved (brainstorm) — pending spec review → plan
**Branch context:** `claude/suspicious-mclean-5a6df9`. Builds directly on the shipped iOS narration→m4b exporter (`NarrationExportService`, commit `d8d24b1`, 2026-06-17).

## Problem

The user wants **m4b and mp3 export on both iOS and macOS, either from a narrated EPUB or by repackaging an already-imported m4b/mp3 book** — a 2 (source) × 2 (format) × 2 (platform) matrix.

Recon (4-reader parallel sweep, this session) reconciled a contradiction in the project notes: **exactly one cell already ships.** `NarrationExportService.exportM4B()` ([NarrationExportService.swift:77](../../../EchoCore/Services/Narration/NarrationExportService.swift)) concatenates a narrated book's per-chapter ALAC cache files into a gapless `AVMutableComposition`, transcodes once via `AVAssetExportSession` (`AVAssetExportPresetAppleM4A`), stamps real Nero (`chpl`) + QuickTime (`chap`) chapter atoms via the `swift-audio-marker` package ([AudioMarkerStub.swift:30](../../../EchoCore/Services/Narration/AudioMarkerStub.swift)), and surfaces the file through the iOS share sheet ([ExportProgressView.swift:34](../../../EchoCore/Views/ExportProgressView.swift)). It is walled behind `#if os(iOS)`.

So the true starting state is:

| Source → | Format | iOS | macOS |
|---|---|---|---|
| **Narrated EPUB** | m4b | ✅ ships | ❌ build |
| **Narrated EPUB** | mp3 | ⏸ deferred | ⏸ deferred |
| **Repackage imported m4b/mp3** | m4b | ❌ build | ❌ build |
| **Repackage imported m4b/mp3** | mp3 | ⏸ deferred | ⏸ deferred |

**mp3 is deferred** (see Non-Goals): Apple frameworks cannot *encode* mp3 (decode-only, a licensing legacy), so real mp3 requires vendoring LAME (LGPL — license-compatible with Echo's GPL-3.0). The user chose to ship the m4b matrix first and treat mp3 as a separate later project.

This spec covers the **three remaining m4b cells**: narrated→macOS, and repackage-imported→both platforms.

## Goals

- A single, **source-agnostic, cross-platform** `AudioExportService` that produces a chaptered `.m4b` from **either** a narrated book (per-chapter cache files) **or** an imported book (original on-disk files).
- One **unified "Export Audiobook (.m4b)…" action** on iOS and macOS, available from the player More menu and the library item context menu, that **auto-detects** the source per book.
- Embedded book **metadata** in the output: title, author (if known), and cover art (if recoverable), with a **"prompt only if missing"** confirm step.
- macOS delivery via `NSSavePanel`; iOS delivery via `ShareLink` (existing).
- Behavior-preserving refactor: the shipped iOS narrated→m4b path keeps working, with green tests before any new cell is added.

## Non-Goals

- **mp3 output of any kind** (single-file or per-chapter) and the LAME dependency. Deferred to a future project. The writer seam is designed so it drops in later without touching sources.
- **Quality/bitrate UI.** Output uses the existing `AVAssetExportPresetAppleM4A` (AAC); no user-facing codec/bitrate controls.
- **Batch/bulk export** of multiple books at once. One book per invocation.
- **m4b→m4b "passthrough" (stream-copy) optimization.** The single-m4b→m4b case re-encodes through the same spine (re-chapter + re-tag); avoiding the transcode is an optional future optimization, not in scope.
- **Series / language tags, per-chapter artwork, chapter editing.** Only book-level title/author/cover are embedded.

## Decisions locked (brainstorm)

| Decision | Choice |
|---|---|
| Scope this round | **Full matrix, m4b only** (mp3 deferred) |
| mp3 chapter strategy (banked for later) | **Per-chapter mp3 files** (folder/zip), not single-file ID3 `CHAP` |
| mp3 encoder (banked for later) | **Vendor LAME** when mp3 returns; deferred now |
| Export UX | **One-tap; prompt only if author or cover art is missing** |
| Export action | **Single auto-detecting "Export…"** replaces the iOS narration-only button |
| single-m4b→m4b | **Re-chapter + re-tag** through the same spine (not skipped, not passthrough) |
| Architecture | **Source seam + Writer seam** (`AudioExportService`), concrete-type + injection (DatabaseService pattern) |
| Output codec | **AAC** via `AVAssetExportPresetAppleM4A`; no quality UI |

## Verified facts (this session)

- `swift-audio-marker` declares `[.iOS(.v17), .macOS(.v14), .visionOS(.v1), .macCatalyst(.v17)]` — **macOS is supported.** The `#else throw unavailableOnPlatform` in `ChapterMarkerWriter` is a wiring gap (product linked only into the iOS app target's Frameworks phase, `CC08EC562F9522F600206D2F`), not a capability limit.
- AVFoundation/AudioToolbox **cannot encode mp3** (`kAudioFormatMPEGLayer3` is decode-only). Confirms mp3 needs LAME.
- Imported books are referenced **by URL, not copied** ([TrackRecord.filePath](../../../Shared/Database/TrackRecord.swift) = original `URL.absoluteString`); export reads originals under security-scoped access.
- Source kind is **implicit**: narrated tracks have `narrationVoice != nil` + `source='synthesized'` alignment anchors; imported tracks have `narrationVoice == nil`. Auto-detection keys off this.

---

## Architecture — two seams

```
AudioExportService (actor, EchoCore, cross-platform)
   │
   ├── ExportSource  ──►  [ExportChapter]
   │     • NarrationCacheSource   (per-chapter cache .m4a, whole-file segments)
   │     • ImportedBookSource     (DB chapters + original URLs, timeRange or whole-file segments)
   │
   ├── compose → AVMutableComposition (gapless)
   ├── export  → temp .m4b via AVAssetExportSession (AVAssetExportPresetAppleM4A)
   ├── tag     → ExportMetadata (title / author / cover) via AVAssetExportSession.metadata
   └── AudioExportWriter (.m4b)
         • ChapterMarkerWriter (swift-audio-marker, now cross-platform)
         • [.mp3PerChapter — named hole, NOT built]
   ▼
returns temp output URL
   ▼
Platform delivery (thin, in views): iOS ShareLink / macOS NSSavePanel
```

- **`ExportChapter`** = `(title: String, segments: [(url: URL, timeRange: CMTimeRange?)])`. `timeRange == nil` ⇒ whole file. This single shape expresses both "one cache file per chapter" (narrated) and "N time ranges into one m4b" or "N whole mp3 files" (imported).
- The two user axes map onto the two seams: **narrated vs repackaged = source**; **m4b vs (future) mp3 = writer**. Each new cell is a new strategy, not a new pipeline.

## Components

| Component | Location | Role |
|---|---|---|
| `AudioExportService` (actor) | `EchoCore/Services/Export/` (new) | Orchestrates compose→export→tag→chapterize→return temp URL. Generalized from `NarrationExportService`. |
| `ExportSource` (protocol) | `EchoCore/Services/Export/` | Yields `[ExportChapter]`. |
| `NarrationCacheSource` | `EchoCore/Services/Export/` | Existing glob/order/title-from-`TrackRecord` logic, lifted from `NarrationExportService`. |
| `ImportedBookSource` | `EchoCore/Services/Export/` | `ChapterRecord` + original track URLs → chapters; security-scoped access on originals. |
| `AudioExportWriter` (protocol) + `M4BWriter` | `EchoCore/Services/Export/` | `.m4b` = AVAssetExportSession + metadata + `ChapterMarkerWriter`. `.mp3PerChapter` is a documented hole. |
| `ExportMetadata` | `EchoCore/Services/Export/` | `{ title, author?, coverArt? }`; drives prompt-if-missing + tag embedding. |
| `ChapterMarkerWriter` | `EchoCore/Services/Narration/AudioMarkerStub.swift` (existing) | Un-gate to cross-platform (`#if canImport(AudioMarker)`), keep the `ChapterList`/`Element` type-collision workaround on macOS too. |
| `ExportProgressView` | `EchoCore/Views/` (existing) | Generalize; drop the `#if os(iOS)` wall; reuse observable-progress pattern. |
| macOS export entry + `NSSavePanel` | `Echo macOS/Views/` (new) | Mirror `MacAnkiExportView.exportToFile()` save pattern. |

The old `NarrationExportService` becomes a thin shim over `AudioExportService` + `NarrationCacheSource` (or is deleted once call sites migrate).

## Data flow, per cell

- **Narrated → m4b (iOS existing / macOS new):** `NarrationCacheSource` → compose cache files → export → tag → atoms → deliver. macOS needs only: package linked to target, writer un-gated, `NSSavePanel` delivery, More-menu action.
- **Repackage imported → m4b (both new):** `ImportedBookSource` → compose (timeRanges for a single multi-chapter m4b; whole-file segments for a multi-file mp3/m4a folder) → export (re-encodes to AAC) → tag → atoms → deliver. **single-m4b→m4b** is the degenerate case: one source file, re-chaptered with Echo's current chapters + freshly embedded cover/author.

## Entry points & metadata flow

- **Unified action "Export Audiobook (.m4b)…"** in the player More menu + library item context menu, both platforms. Auto-detects: any track with `narrationVoice != nil` ⇒ `NarrationCacheSource`; else `ImportedBookSource`. The current iOS narration-only export button folds into this action.
- **Metadata resolution:** build `ExportMetadata` from the book. Cover for narrated books comes from the EPUB cover image (extract from EPUB asset storage); for imported, from `ArtworkCache` embedded/folder extraction ([ArtworkCache.swift:14](../../../EchoCore/Services/ArtworkCache.swift)). If `author == nil` **or** `coverArt == nil`, present a small pre-filled confirm sheet; otherwise export immediately.

## Progress & errors

- Reuse the observable-progress pattern (`AutoAlignmentState` / `ExportProgressView`). `AVAssetExportSession` progress is coarse (poll `progress` during export); acceptable.
- Extend `ExportError` (currently `compositionFailed`, `exportSessionFailed`, `chapterAtomWriteFailed`, `missingAudiobook`) with `sourceUnavailable` and `securityScopeDenied` for the imported path.
- Temp-dir hygiene: generate under `FileManager.temporaryDirectory/UUID`, `defer` cleanup on success or error.

## Testing

- `AudioExportService` against `DatabaseService(inMemory:)` with tiny fixture audio files: assert **chapter count**, **ordered titles**, **monotonic non-overlapping start times**, and **total duration ≈ Σ segment durations** for both `NarrationCacheSource` and `ImportedBookSource`.
- `ImportedBookSource`: cover multi-file (N whole-file segments) and single-file-multi-chapter (N timeRanges) shapes.
- `ChapterMarkerWriter`: existing `ChapterMarkerWriterTests` + a macOS-side case (atoms written, file re-loads with correct `AVAsset` chapter groups).
- Metadata: assert embedded `title`/`artist`/`artwork` survive the post-export chapter-atom rewrite.
- Run via `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. No parallel testing / no concurrent xcodebuild (16 GB machine).

## Phasing (build order — each phase ends shippable)

1. **Refactor (no behavior change):** extract `AudioExportService` + `NarrationCacheSource` from `NarrationExportService`; iOS narrated→m4b identical; existing tests green.
2. **macOS narrated→m4b:** link `AudioMarker` to the macOS target, un-gate `ChapterMarkerWriter`, add `NSSavePanel` delivery + the unified More-menu action on macOS.
3. **`ImportedBookSource` + unified auto-detecting action** on both platforms (repackage imported → m4b).
4. **Metadata embedding** (title/author/cover) + the prompt-if-missing sheet.

mp3 reappears later as one new `AudioExportWriter` (`.mp3PerChapter`) + LAME, with no change to the sources or the service spine.

## Risks / checks before coding

- **macOS deployment target ≥ 14** (required by `swift-audio-marker`). Verify in build settings; near-certain given the app's modern SwiftUI baseline, but confirm in Phase 2.
- **`AudioMarker` type-collision workaround** (`ChapterList`/`Element` typealiases) must compile on macOS, not just iOS — broaden the guard from `#if os(iOS)` to `#if canImport(AudioMarker)`.
- **Schema reviewer:** no new migration expected (export reads existing tables). If a `cover_image_path` column is added to link narrated EPUB covers, route through the schema-migration-reviewer and a new `Schema_Vxx`.
- **Cross-platform parity reviewer:** the refactor touches shared `EchoCore` services consumed by iOS + macOS; run the parity reviewer after Phase 1.
- **Security scope on imported originals:** wrap reads in `startAccessingSecurityScopedResource()` / `defer stop`, mirroring `PlayerModel+Bookmarks`.

## Documentation to update (per CLAUDE.md doc-sync)

- `ARCHITECTURE.md` — new `Services/Export/` module + the two seams.
- `README.md` / `CHANGELOG.md` — "Export your audiobook as a chaptered .m4b (narrated or imported), iOS + macOS."
- `ROADMAP.md` — mark m4b export shipped cross-platform; note mp3 as deferred/LAME-gated.
