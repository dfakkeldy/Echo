# macOS Unification Plan (CODE_AUDIT.md §5.1 / §10.4)

**Decision:** Option A — full macOS unification. Make `PlaybackController` / `BookmarkStore` / the DTW alignment pipeline compile for macOS so `MacPlayerModel` becomes a thin AppKit shell over the shared core, and Mac becomes a true peer (cross-device alignment + bookmarks).

This is the audit's single largest refactor, so it is **sequenced into 5 sub-phases**, each its own PR. A1–A3 fix the *currently-broken* alignment handoff (moderate risk, more isolated). A4–A5 are the large, higher-risk playback/bookmark unification.

## Why it's broken today (verified)
- **Block-ID divergence:** `MacEPUBParser` emits `epub-mac-s<spine>-b<count>`; iOS emits `epub-<audiobookID>-s<i>-b<blockIdx>`. They can never match, so **every Mac-produced alignment anchor references a nonexistent iOS block and is silently dropped** at timeline recalc.
- **Stale algorithm:** `MacGlobalAlignmentService` uses a pre-DTW uniform-`duration/word` + Jaccard window matcher that iOS replaced with real word-timestamps + gated DTW (`TokenDTW` + `AnchorSelector`).
- **No DB write:** Mac alignment writes a `.alignment.json` sidecar (consumed later on *iOS* import), never the DB — so the macOS reader's auto-scroll never lights up from Mac-run alignment.
- **Siloed playback/bookmarks:** `MacPlayerModel` wraps `AVPlayer` directly and stores `MacBookmark` in `mac.bookmarks.v1` UserDefaults, disjoint from the shared `Bookmark` / `BookmarkStore` / DB — so Mac bookmarks are invisible to iOS/watch.

---

## Phase A1 — Unify EPUB block IDs + parsing  *(fixes the handoff foundation)*
- Share the spine-walking driver, not just the leaf XML delegates. Extract a single `parseEPUBBlocks(...) -> [TextBlockDescriptor]` (stable IDs via the iOS `epub-<audiobookID>-s\(i)-b\(blockIdx)` formula) into `Shared/`, consumed by both `EPUBImportService` (iOS) and the Mac path.
- Delete `MacEPUBParser`'s parallel extraction (it ignores `linear="no"`, headings, images, and chapter indices — guaranteeing different block sets even if the ID format were unified).
- **Outcome:** Mac-produced block IDs match the iOS DB → anchors can resolve.
- **Risk:** medium — the two parsers must emit identical block sets; the shared XML delegates already exist (`Shared/EPUBXMLParsing.swift`), only the driver differs.

## Phase A2 — Share the DTW alignment pipeline
- Extract the iOS DTW core (token build → `TokenDTW.alignWithBisection` → `AnchorSelector.select`) into a shared service both `AutoAlignmentService` (iOS) and the Mac aligner call. Mac keeps its own `AudioExtractor` front-end.
- Delete `MacGlobalAlignmentService`'s Jaccard aligner.
- **Outcome:** Mac alignment uses the superior word-timestamp + DTW algorithm.
- **Risk:** medium — the DTW core lives in `EchoCore` (iOS target); it must compile for macOS. `TokenDTW`/`AnchorSelector` are pure value types (should port cleanly); WhisperKit is cross-platform; only the audio-window reading needs a macOS path.

## Phase A3 — Write anchors to the DB + recalc timeline on macOS
- Have the Mac aligner upsert anchors via `AlignmentAnchorDAO` and call `AlignmentService.recalculateTimeline()` (the same path `EPUBAutoImportScanner` uses on iOS), instead of only the JSON sidecar.
- Move the shared `AlignmentAnchorExport` wire-format struct into `Shared/` (it's currently defined twice — §9.8).
- **Outcome:** the macOS reader auto-scroll lights up from Mac-run alignment; cross-device sharing works.
- **Risk:** low–medium.

> **A1–A3 deliver the headline value: macOS alignment actually works.** They can proceed before A4–A5.

## Phase A4 — Unify playback (`PlaybackController` for macOS)  *(large)*
- Make `PlaybackController` / `AudioEngine` compile for macOS. The bulk is platform-agnostic AVFoundation; the iOS-only bits (`AVAudioSession`, `MPNowPlayingInfoCenter` background modes) need `#if os(iOS)` guards or a macOS audio-session shim.
- `MacPlayerModel` becomes a thin AppKit shell delegating to the shared `PlaybackController` + `PlaybackState`, instead of its own `AVPlayer` wrapper. Bring chapter parsing (`ChapterService`), smart-rewind, sleep timer, and now-playing into the Mac path "for free."
- **Risk:** **large** — `AudioEngine`'s session/now-playing handling is iOS-shaped; `PlaybackState`'s 9-writer coordinator graph must work on macOS.

## Phase A5 — Unify bookmarks (shared `Bookmark` + `BookmarkStore`)
- Make `BookmarkStore` compile for macOS; replace `MacBookmark` with the shared `Bookmark` struct + DB storage.
- **One-time migration** of existing `mac.bookmarks.v1` UserDefaults data into the DB (mirror the iOS `MigrationService` idempotent pattern — see §5.10).
- **Outcome:** Mac bookmarks round-trip with iOS/watch via the shared DB.
- **Risk:** medium — data migration for existing Mac users.

---

## ⚠️ Sequencing & timing (important)
A4–A5 rewrite the shared **playback/bookmark/audio core** — exactly the services the **active narration / Kokoro-TTS work** (branches `feat/epub-ai-narration-01-schema`, `feat/kokoro-tts-spike`) also touches. Running them in parallel courts merge conflicts and destabilizes the core narration is built on.

**Recommended order:**
1. **A1–A3 now-ish** (alignment handoff fix) — more isolated (EPUB parsing + alignment pipeline + anchor DB writes), high user value, moderate risk.
2. **A4–A5 after the narration/TTS feature stabilizes and merges** — coordinate so the playback/bookmark rewrite doesn't collide with in-flight TTS playback work.

Each sub-phase = one branch off `main` + one PR, build-verified on **both** the `Echo` and `Echo macOS` schemes (§5.1 lives in macOS-only code the iOS scheme doesn't compile).
