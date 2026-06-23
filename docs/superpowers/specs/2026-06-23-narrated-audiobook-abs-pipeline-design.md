# Narrated-audiobook → Audiobookshelf pipeline — holistic fix

**Date:** 2026-06-23
**Status:** design (awaiting review)
**Goal:** every Echo-narrated `.m4b` is self-describing (correct tags, cover, real heading chapter titles, version stamp); Audiobookshelf shows ONE item per book (ebook + audiobook), no duplicates; pulling a book from ABS into Echo lights up read-along.

## Background

Narration pipeline: EPUB → MisakiSwift G2P → Kokoro-82M via ONNX Runtime → per-chapter `.m4a` → `AudioExportService.exportM4B` → chaptered `.m4b` + `.alignment.json` read-along sidecar. A native macOS CLI `echo-cli narrate` (`HeadlessNarrationRunner`) runs it off-simulator. Delivery scripts in `~/Developer/echo-overnight/` place finished m4bs into a Syncthing-mirrored Audiobookshelf library.

## What is already fixed (this session)

The root cause of "m4b metadata is dropped" (Finding #1) was the `swift-audio-marker` package writing the iTunes `ilst` tags **without** the `mdir` metadata handler — so ffprobe/AVFoundation/iTunes/Audiobookshelf ignored *every* tag and the cover (`covr` lives inside `ilst`). It also wrote a chapter text track AVFoundation couldn't read. Both are fixed at the source in a fork (`dfakkeldy/swift-audio-marker`), verified with ffprobe + exiftool + AtomicParsley + AVFoundation; Echo is pinned to it and `ChapterMarkerWriter` writes title/album/artist/albumArtist/genre. Upstream PR: atelier-socle/swift-audio-marker#2.

This holistic fix builds on that.

## Decisions (locked)

- **ABS shape:** ONE Title-Case folder per book holding EPUB + m4b + sidecar = a single ABS item (ebook + audiobook), so read-along works. Title from the EPUB `dc:title`.
- **Cleanup:** fully automatic, idempotent, library-wide migration — consolidate each book into its canonical Title-Case folder, delete lowercase/orphan folders, delete stale ABS items, rescan. Log everything.
- **Version stamp:** embed date + render version in the m4b `comment` (`©cmt`): `"Echo narration — 2026-06-23 · ONNX rv6"`.
- **Approach A (fix at the source):** repair the EchoCore export so every m4b (app + CLI) is self-describing; do not bolt metadata on at the delivery layer.
- **Branch:** ONE integration branch off `origin/nightly` folding in `claude/echo-cli-narrate` (#145) + the export/fork fix (`66ea984`) + all new work → ONE PR to `nightly`.
- **Render watcher:** stop → rebuild CLI with fixes → restart, so new renders are born correct (`--resume` + `.done` markers make the stop safe). Already-rendered m4bs get retagged.
- **ffprobe test:** runs when ffprobe is on PATH, skipped otherwise (CI's iOS sim has none); the structural `mdir`/`ftab`/`elst` byte asserts remain the always-on guard.

## Scope — work items

### Phase A — EchoCore export (Swift; benefits the shipping export feature, not just ABS)

- **A1 Real chapter titles.** `HeadlessNarrationRunner` already groups blocks by `chapterIndex`; derive each chapter's title from its first heading block (reuse the existing narration-outline/heading logic) and pass it as the `ExportItem.title` — keyed by chapter index, not enumerated position. Replaces `"Chapter \(pos+1)"` (`HeadlessNarrationRunner.swift:234`).
- **A2 Cover resolution (headless).** Diagnose why `block.imagePath` resolves nil in the headless import (likely the headless `EPUBImportService` / `EPUBAssetStorage` doesn't materialize the image to a path). Make the front-matter cover resolve to JPEG/PNG bytes. The fork now embeds it once non-nil.
- **A3 Version-stamp comment.** Add `comment: String?` to `ExportMetadata`; map it to `info.metadata.comment` (`©cmt`, supported by the package) in `ChapterMarkerWriter`; set `"Echo narration — <yyyy-MM-dd> · ONNX rv\(NarrationFileNaming.renderVersion)"` in the headless runner and the app's narrated-book export path.
- **A4 Don't clobber imported tags (review MEDIUM-4).** `ChapterMarkerWriter` pre-reads the file; default `album=title` and `genre="Audiobook"` only when the field is **absent**, so re-exporting an imported m4b keeps its real album/series/genre. Add the `!isEmpty` guard to title/album (mirror author). Log when cover embedding fails.
- **A5 Independent-reader test.** A test that shells to `ffprobe` when present and asserts title/artist/comment + an attached cover + real chapter titles survive; skipped when absent. Strengthen the AVFoundation test to assert per-chapter `commonKeyTitle` and time ranges (not just `groups.count`).

### Phase A-fork — `swift-audio-marker` robustness (from adversarial review) → tag 0.1.3

- **Chapter `mdat` before audio `mdat` + 64-bit guard (review HIGH-1).** Place the small chapter sample `mdat` ahead of the audio `mdat` (always < 4 GB) and throw if any chapter chunk offset would exceed `UInt32.max`; the audio track already has a `co64` path.
- **Version-1 `elst`/`tkhd` for long books (review HIGH-2).** Emit 64-bit `elst` segment-duration and `tkhd` duration when `movieDuration > UInt32.max`, mirroring the existing mvhd-v1 branch, so the edit list spans the whole media for >27 h books.
- **Clamp the text-sample length prefix** to a UTF-8 boundary (review LOW) so a pathological >64 KB heading can't trap.
- Re-verify with the harness (ffprobe + AVFoundation) on a real multi-hour book's audio; bump tag to **0.1.3**; update upstream PR #2.

### Phase A-pin — supply chain (review LOW)

Pin Echo's SPM dependency to the fork by **immutable revision SHA** (`kind = revision`), not a movable tag — `Package.resolved` is gitignored so a tag is the only anchor and could be force-moved.

### Phase B — retag already-rendered m4bs (CLI; no re-render)

New `echo-cli retag --m4b <file> --epub <file> [--out <file>]` subcommand: read the existing m4b's chapter **times** (via the package/AVFoundation), re-derive the ordered heading titles from the EPUB (same logic as A1), and re-write the m4b through the fixed `ChapterMarkerWriter` with real titles + tags + cover + version comment — audio untouched. A batch wrapper retags everything in `m4b-out/`.

### Phase C — delivery rework (`~/Developer/echo-overnight/` scripts; off git)

Rework `deliver-to-abs.sh` / `deliver-watcher.sh`: place **EPUB + m4b + sidecar** together in one Title-Case folder (`$author/$title/` with `$title.epub` + `$title.m4b` + `$title.alignment.json`) — the EPUB is the missing piece that currently makes a second item. Keep the existing Syncthing-wait + delete-item + rescan. Use the `audiobookshelf-setup` skill conventions (delete-item then rescan, never a plain rescan). Source EPUB from `expanded/<stem>` (or the original `~/Developer/explainer-audiobooks/books/<stem>/<stem>.epub`).

### Phase D — one-time automatic migration (script; off git)

Idempotent, library-wide: for each Echo book, ensure the canonical Title-Case folder holds EPUB + m4b + sidecar; move EPUBs out of the lowercase folders; delete the now-empty lowercase + orphan audio-only folders; delete the stale ABS items (`abs_admin delete-ids`); rescan once at the end. Logs exactly what it did; safe to re-run. Operates on the Syncthing mirror (`/Volumes/Fledging-WD-2TB/Books`) + ABS.

### Phase E — ABS-import read-along (Swift)

After an ABS-pulled book's EPUB blocks import (the `PlayerModel+Audiobookshelf` → `loadFolder` path), run `DocumentImportFinalizer.finalize(audiobookID:databaseService:)` so the `<base>.alignment.json` sidecar (which travels in the ABS download zip as a libraryFile) ingests, resolving anchors to local block IDs → read-along lights up. Wire it where the no-audio EPUB import completion is already awaited (`PlayerModel+Narration.swift` has the precedent), guarded so it only fires for ABS-pulled books carrying a sidecar.

## Operational sequence

1. Create integration branch off `origin/nightly`; merge `claude/echo-cli-narrate` + carry `66ea984`.
2. Implement Phase A (+ fork 0.1.3, re-pin), Phase B, Phase E. Build + test (`make build-tests`, export suites; `swift test` on the fork).
3. Build `echo-cli` from the integration branch. **Stop** the render watcher (`pkill -f intake-watcher.sh` + `pkill -f "Debug/echo-cli narrate"`), point it at the new binary, **restart** (resumes via `.done` markers).
4. Phase B: retag the already-rendered m4bs in `m4b-out/`.
5. Phase C + D: rework delivery, run the one-time migration (consolidate dupes), resume the delivery watcher.
6. Doc-sync (CHANGELOG/ARCHITECTURE); open the PR to `nightly`.

## Deferred (spawned as follow-ups, not blocking)

- HEIC/WebP folder-cover transcode for the app-side `folderCoverData` (review MEDIUM-3).
- Imported-m4b-with-non-`mdir`-`covr` read-side fallback (review MEDIUM-5).
- Parent-scoped atom-tree test assertions / meta-box order test (review LOW).

## Success criteria

- `ffprobe -show_format` on a produced/re-stamped m4b shows correct title, artist, comment (date + rv), and an attached cover; chapters survive with real heading titles.
- ABS shows ONE item per book (ebook + audiobook), no duplicates; `everything-but-the-code` is the clean (non-silent) version.
- Pulling a book from ABS into Echo lights up read-along (anchors ingested from the sidecar).
- Docs synced; PR targets `nightly`.
