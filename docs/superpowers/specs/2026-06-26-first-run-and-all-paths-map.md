# Echo First-Run & All-Paths Test Map

*Working reference, 2026-06-26. Grounded by code exploration on branch `claude/ecstatic-borg-a7e8df`. This is the current-state map + desired-behavior vision used to design the first-run experience and to drive testing. It is NOT yet an approved design spec — open decisions are in §G.*

> Status legend: **WORKS** (shipped, verified) · **PARTIAL** (infra exists, gap remains) · **MISSING** (not implemented) · **DESIRED** (vision-side only).
> Where enumeration passes disagreed with verified code facts, the verified facts win and are noted inline.

---

## Decisions resolved (2026-06-26)

- **ABS demo (G2):** one-tap **"Connect to demo"** — pre-filled, read-only, rate-limited, public-domain-only guest server. NOT a self-hosted load-bearing server.
- **Auto-play (G4):** add an **"Auto-play on open" Setting, default OFF.** The default first-run experience stays load-don't-play, with a prominent Play affordance + the dismissible help offers. When the user turns it ON, audio-first opens (1 M4B / MP3 folder / multi-M4B) start playing; text-only opens never auto-play (they offer narration).
- **MP3 ordering (G1):** honor embedded **track-number/disc metadata**, fall back to natural filename sort; **show the resulting order** so the user can verify/reorder.
- **EchoDeckBuilder (G3):** it's a **real, separate macOS app** at `~/Developer/EchoDeckBuilder` (SwiftUI, SPM executable, MVP complete on branch `codex/echo-deck-builder-mvp`; 34 tests passing). Takes an **EPUB** in, exports **"Echo Deck JSON vNext"** (`.echo-deck.json`) with portable `s<i>-b<j>` anchors. See revised §G3/§F16 for integration shape + the two gaps (transcript-input, iOS-only).
- **Manual artifact + behavior:** bundle **`~/Developer/echo-manual-build/welcome-to-echo/dist/Welcome-to-Echo.epub`** (16 ch, 44k words, 28 placeholder images; text-only today) — NOT the explainer-audiobooks series. The landing page's **"Play / Read the welcome manual"** opens this bundled EPUB; **chapter 1 narration is pre-rendered + bundled** (plays instantly), and **once playback starts the remaining chapters narrate on-device** progressively. Prereqs: pre-render ch.1 audio + word alignment via `echo-cli`/overnight harness, and re-verify the manual against shipped features (dated 2026-06-22, can go stale).
- **Web landing page:** `dfakkeldy.github.io/Echo` stays the **external marketing front door** ("Join the Beta") with the desktop reference manual at `/manual.html`. The **in-app manual is self-contained** (opens the bundled EPUB, not the web page) — no runtime dependency on the site. Keep web manual.html in sync via `doc-sync`.
- **Companion docs (A5):** audio + **one** EPUB/PDF → auto-load it; **multiple** → load the **name-matching** one; none matching → offer to import. PDF now auto-imports (today only EPUB does, via `EPUBAutoImportScanner`, "first found").
- **ABS demo server:** point at the community demo **`audiobooks.dev`** (`demo`/`demo`, listed in ABS's official README) with a graceful-offline fallback; no self-hosted server for 1.0.
- **On-device narration reliability:** owner-confirmed **REQUIRED** — a gating dependency for the bundled manual (silence-guard + fresh-process batching ≤~5 ch + per-chapter error UI/resume).

---

## A. Getting content in (ingest paths)

The invariant behind every audio path: **one folder (or single file's parent folder) = exactly ONE book.** `state.folderURL` (normalized to a directory) is the audiobook ID, so opening `/path/book.m4b` and opening `/path/` produce the same book and share progress/EPUB blocks/timeline (`PlayerLoadingCoordinator.swift:86-91`, `:95-109`).

| # | Path | Trigger | Accepts | Current behavior | No-copy reality | Status |
|---|------|---------|---------|------------------|-----------------|--------|
| A1 | **Open folder** | Folder icon in top header → `FolderPicker` (`asCopy: false`) → `loadFolder(url)` | `.mp3 .m4a .m4b`; `.epub .pdf .md .txt` | All top-level audio → one playlist (alphabetic `localizedStandardCompare`, `PlaylistManager.swift:67`); first EPUB auto-imported; PDF detected not imported; first image / `cover.*` set as artwork | **NO COPY** — security-scoped bookmark; deleting original breaks playback | WORKS |
| A2 | **Pick single audio file** | Same picker, single file | `.mp3 .m4a .m4b` | Parent dir becomes `folderURL`; single-track playlist (`PlayerLoadingCoordinator.swift:248`); EPUB auto-scanned in parent | NO COPY | WORKS |
| A3 | **Pick single document** | Folder icon or "+EPUB" button | `.epub` / `.pdf` | Audio-less book; reader-only; narration possible | NO COPY (EPUB/PDF blocks copied into DB) | WORKS |
| A4 | **Folder of multiple audio files** | Open folder w/ 2+ audio | `.mp3 .m4a .m4b` | All tracks, one book; M4Bs aggregated w/ cumulative offsets (`M4BParser.swift:18-59`) | NO COPY | WORKS |
| A5 | **Mixed folder (audio+EPUB+PDF+cover+junk)** | Open folder | mixed | Audio → tracks; first EPUB auto-imported (`EPUBAutoImportScanner.swift:53-67`); PDF NOT auto-imported; cover auto-detected (`ArtworkCache.swift:87-119`); junk ignored | NO COPY | WORKS (PDF gap) |
| A6 | **Nested subfolders / multi-disc** | Open folder w/ `Disc 1/`, `Disc 2/` | audio in subfolders | **NOT SUPPORTED** — `contentsOfDirectory` non-recursive (`PlaylistManager.swift:55`); only top-level files load; multi-disc must be flat siblings | NO COPY | PARTIAL (silent — nested ignored) |
| A7 | **Audiobookshelf browse & download** | Settings → Audiobookshelf → connect → browse → download | ABS item (`.m4b`+`.epub` zip) | `ABSImportService.prepareLocalFolder()` unzips into managed ABS cache, pre-stamps `AudiobookRecord`, then `loadFolder()` as A1 | **COPIES** into app-managed ABS cache dir; re-downloadable | WORKS (PR #102, Schema V23) |
| A8 | **ABS progress sync** | Automatic after ABS load | progress metadata | `ABSProgressSync` pushes position/chapters; reads ABS progress on first load (`PlayerModel+Audiobookshelf.swift`) | — | WORKS |
| A9 | **Anki deck import** | Settings → Flashcards / Import Deck | `.json` / `.apkg` | `DeckImportService` / `ApkgImportService` parse → flashcard+deck tables | Cards parsed into DB; original discarded | WORKS |
| A10 | **Markdown / text as study book** | Open `.md .markdown .txt` | text | Audio-less study doc via shared `import(parse:)` (PR #109) | NO COPY | WORKS (owner device-verify open) |
| A11 | **Open-in-Echo (iOS share sheet)** | Files → Share → Open in Echo | audio/EPUB/PDF | `UIDocumentPickerViewController` passes `file://`; same as A1/A2 | NO COPY | WORKS (conditional) |
| A12 | **AirDrop** | AirDrop into Echo | audio/EPUB/PDF/json | Lands in app Documents sandbox; opened via picker | **COPIES into sandbox** (differs from no-copy norm) | UNVERIFIED behavior |
| A13 | **iCloud Drive / On My iPhone** | Files → cloud folder | folder/audio | Same as A1; bookmark persists; iCloud may evict unless "Keep Downloaded" (`HelpContent.swift:28-33`) | NO COPY (evictable) | WORKS |
| A14 | **Drag-drop (macOS)** | Drag folder/file onto window | — | **NO `.onDrop` support found in code** | — | MISSING (per ingest pass) |
| A15 | **Bundled manual seed** | First launch | bundled ch.1 audio + EPUB | — | — | MISSING (vision) |
| A16 | **Transcript sidecar auto-discover** | `*.transcript.json` in folder | JSON transcript | Referenced in `HelpContent` but no verified auto-load wiring for bare M4B | — | UNVERIFIED / PARTIAL |

> Note on A16/sidecars: the ingest pass *claimed* auto-load; no verified fact confirms it. Treat as unverified (see §H).

---

## B. What's in the folder (content-combination matrix)

| Scenario | #books | What plays | Contents view shows | Nudges/offers (current) | Current behavior | Desired behavior |
|----------|--------|-----------|---------------------|--------------------------|------------------|------------------|
| **1 M4B only** | 1 | 1 track; does NOT auto-play | M4B embedded chapters in **picker** (`ChapterService.swift:14-60`; ≥2 → all, else 1 synthetic). No dedicated sidebar; TOC view is EPUB-only | none | Loads, waits for Play | Auto-play immediately; dismissible help: Load EPUB / Load PDF / Open Manual / Transcribe |
| **Single M4B file picked** | 1 | same as above (parent dir = book) | same | none | same as 1-M4B-folder | identical to 1-M4B-folder case |
| **Folder of MP3s** | 1 | N tracks, alphabetic; does NOT auto-play | Each MP3's embedded chapters, else 1 chapter/file (`PlayerLoadingCoordinator.swift:313-317`) | none | Loads | Auto-play; clarify order; same help cards |
| **2+ M4Bs (multi-disc)** | 1 (aggregated) | N tracks; does NOT auto-play | All chapters across all M4Bs w/ cumulative offsets (`M4BParser.swift:34-56`) — seamless | none | Loads, all chapters in picker | Auto-play; "multi-disc: N files, M chapters" |
| **M4B + EPUB + cover** | 1 | 1 track; no auto-play | M4B chapters in picker + Read tab shows EPUB TOC (auto-imported). TOC view does NOT show M4B chapters (`MacTOCTreeView.swift:27-34`) | none (narration nudge gated on `tracks.isEmpty`) | EPUB auto-imported, blocks shown | Auto-play; nudges; offer alignment |
| **M4B + PDF only** | 1 | 1 track; no auto-play | Read tab → PDF viewer (`RootTabView.swift:79-80`); M4B chapters NOT in Read tab | none | PDF loads | Add Transcribe button in `ReaderEmptyState`/`BookSettingsView` |
| **M4B + EPUB + PDF** | 1 | 1 track | EPUB precedence (`RootTabView.swift:77-78`); PDF ignored | none | EPUB shown, PDF invisible | Allow switch to PDF; transcribe still offered |
| **EPUB only (no audio)** | 1 (narration book) | No tracks; controls grayed | EPUB TOC; single synthetic chapter | **Narration nudge** "Echo can narrate it on-device" + voice picker (`NowPlayingTab.swift:46-88`, `NarrationNudgePolicy.swift`) | Narrate-this-book nudge; on-device TTS (ch.0 fg, rest bg) | Dismissible nudge; post-narration transcribe offer |
| **PDF only (no audio)** | 1 | No tracks | PDF viewer; no chapters | Narration nudge (same policy) | same as EPUB-only | post-narration transcribe → searchable |
| **.md/.txt only** | 1 | No tracks | Markdown/text; no chapters | Narration nudge | Narrate-this-book nudge | same |
| **Audio + cover + junk** | 1 | Audio tracks | Audio chapters; cover auto-found | (audio path) none | Cover found, junk ignored | same |
| **Audio + junk (no cover)** | 1 | Audio tracks | Audio chapters; app-icon fallback | none | works | same |
| **Nested subfolders** | 1 (flattened) | Top-level audio only | Top-level chapters only | none | Nested ignored silently | Recursive scan OR explicit "flat folder required" message |
| **Empty folder** | 0 | none; controls grayed | `ReaderEmptyState` | Narration nudge fires (tracks empty) | Empty state | Prominent onboarding + pick-folder CTA + no-copy reassurance |
| **Unsupported-only (.wav/.flac/.aiff)** | 0 | none | none | Narration nudge fires | Empty state, formats not obvious | "Unsupported format — Echo plays MP3/M4A/M4B" |

> Verified correction: the narration nudge keys on `tracks.isEmpty` regardless of *why* — so it WILL fire on a genuinely empty/unsupported folder (offering to narrate nothing). Arguably a bug; needs a guard (§F14).

> Companion auto-load (resolved): a single EPUB/PDF beside the audio auto-loads; with **multiple** companions, the **name-matching** file loads (the M4B's filename is the disambiguator); none matching → the import nudge. PDF now auto-imports too. New test rows: M4B + 2 EPUBs (one name-matching) → matching loads; M4B + 2 EPUBs (no match) → nudge, none auto-loaded; M4B + 1 PDF → PDF auto-loads.

---

## C. What you can do with a book (per-book action paths)

**Loading / library** — Open folder; open single file; pick from ABS (`PlayerModel.addFromAudiobookshelf()`); resume last (`restoreLastSelectionIfPossible()`); load different book (`loadFolder(_:autoplay:)`); reset playlist (`resetPlaylist()`).

**Core playback** — Play/Pause (`togglePlayPause()`); skip ±30 w/ bookmark-snap & smart-rewind; custom skip; seek (`seek(toSeconds:)`/`seek(toFraction:)`); joystick scrub (watch/gamepad).

**Speed / mode** — `setSpeed()` 0.75–2.0 per-book; speed presets; volume boost ±6dB; loop mode off/track/chapter.

**Chapter / track nav** — next/prev chapter; next/prev track; `seekToChapter(at:)`; EPUB section nav; chapter picker (disabled <2 chapters); toggle track/chapter enabled; reorder.

**Sleep timer / utilities** — minutes or end-of-chapter (`SleepTimerManager`); cancel/toggle; remaining countdown; `stop()`.

**Bookmarks & capture** — add instant; draft+append (voice memo + photo + note); edit/delete; list; jump-to-bookmark; mark passage (range [now-15s, now+5s]).

**Voice memos / media** — record per-bookmark; CarPlay voice memo; stop/preview; attach image.

**Flashcards & study** — create from reader long-press; from bookmark (Card Inbox); inline during playback; grade (FSRS-4.5, PR #97); daily review; watch hands-free review; Anki `.apkg` import/export; deck list/detail; enable/disable; assign deck; tag; audio-snippet cards.

**Reading & text study** — auto-import EPUB; manual import EPUB/PDF; synced highlight + auto-scroll; **word-tap-to-seek** (if alignment present); auto-align DTW (`AutoAlignmentService`); manual align (`ManualAlignmentSheet`); chapter outline; EPUB search (`.searchable`, client-side); TOC tree (macOS); font/line-spacing/theme; reader notes + voice memo.

**Transcription** — `StandaloneTranscriptionService.start()` (on-device WhisperKit, ch.0 fg + rest bg) — **infra only, no UI entry point** (PARTIAL); search standalone transcript (client-side, no FTS5); fallback display in Read tab when no EPUB/PDF (`RootTabView.swift:81-88`); continuous auto-alignment toggle.

**Narration (TTS)** — `startNarrationPlayback(voice:)`; voice picker (~20 ONNX voices); render-ahead (ch.1 immediate, rest queued); exclude chapter ("Not in Audio"); pronunciation overrides; render progress; silence-guard retry (`NarrationSilenceGuard`, PR #144).

**Export & sharing** — narrated/imported `.m4b` export (`Export/`, swift-audio-marker, PR #100); study-notes export; Anki export; share deck to CloudKit; iOS share sheet; synthesis-time word timing for narrated books (PR #197, not merged).

**Playlist / library mgmt** — view playlist; edit mode; enable/disable/reorder; ABS browse.

**CarPlay / Watch** — CarPlay playback + voice memo + library browse (4 tabs); watch playback control, flashcard review, bookmark, `syncToWatch()`, complications.

**Per-book settings** — speed/volume/font/bookmark-inline overrides; location capture (opt-in); seek durations; metadata editing for export.

**Insights** — listening stats; study progress; per-chapter word clouds; session report CSV.

**Deep links / automation** — `handleDeepLink()` (`echoaudio://`): play@time, focus, chapter, settings; programmatic tab switch.

**Advanced** — macOS batch processing; `echo-cli narrate` (PR #145); playlist manifest `.m3u8`.

---

## D. The first-run surface (landing, nudges, manual, no-copy, file-onboarding, permissions)

**Current reality (verified):**
- `OnboardingView.swift` **exists but is never presented** (not wired into `EchoCoreApp.swift`). macOS has **no onboarding at all** (`Echo_macOSApp.swift`).
- No landing/welcome page. App opens to Now Playing → "No track selected"; bottom dock controls gated off when `folderURL == nil` (`UnifiedBottomDock`, line 28).
- **No bundled manual**, no library seeding, no listen-first hybrid.
- **No smart content-aware first run** — no auto-play, no per-content help offers.
- Only nudge that exists: **narration nudge** (text-only book, no audio). It is *not* dismissible — hides only when narration starts or tracks appear.
- **Notification permission**: requested at app init *before view tree renders* (`ReviewNotificationService.swift:51-59`, `EchoCoreApp.swift:71`) → daily 9 AM review reminder when due cards exist. (WORKS, though pre-context prompt is a UX smell.)
- **No-copy reassurance**: only in `HelpContent.swift:28-33`, not on any first-run surface.
- **ABS**: fully functional but reachable only via Settings → Audiobookshelf; not surfaced at first run.

**Top header** (`UnifiedTopHeader`): folder icon (primary), settings, help; stats/+EPUB/export disabled until a book loads.

**Desired first-run (vision):**
- Landing page: (a) encourage opening bundled **Manual** (listen-first: ch.1 pre-rendered plays instantly, rest narrated on-device in bg, seeded on first launch); (b) prominent **OPEN FOLDER** CTA; (c) **no-copy reassurance** ("Echo references files in place — don't delete originals"); (d) how to get files onto device; (e) ABS for advanced users.
- Content-aware open: 1 M4B alone → **starts playing immediately**, then non-blocking dismissible help offers (Load EPUB / Load PDF / Open Manual / Transcribe). Single M4B file ≡ 1-M4B folder.
- Folder of MP3s → one book, track order (decision §G1).
- Permission prompts desired but absent: ABS self-signed cert trust (in Settings today); mic permission (system-handled on first voice memo).

---

## E. Edge / returning-user / platform-entry paths

**Returning user:**
- Restore last book (`restoreLastSelectionIfPossible()`) — WORKS, but **stale/deleted-file resolution returns nil SILENTLY** (`Persistence.swift:238-240`) — no error UI. CRITICAL gap.
- macOS permission/scope lost (device unmounted) → **SILENT FAIL**.
- Multi-session progress persistence — WORKS.

**Edge content:** single M4B (no auto-play); MP3 folder (multi-track OK); multi-M4B (aggregates seamlessly); nested subfolders (unsupported, silent); mixed folder (non-audio ignored); empty folder; corrupted M4B (loads, scrubber "--:--"); very large folder (loads all, may be slow); rapid folder switches (possible race).

**Narration edges:** EPUB-no-audio narrates on-device (WORKS); backgrounded interruption cancels render (recovery unclear); **OOM/model failure calls `.fail()` but NO user-facing error UI** (`NarrationState.swift:41-42`) — gap; silent-chunk recovery via `NarrationSilenceGuard` (WORKS); fully offline (WORKS).

**ABS edges:** auth flow WORKS; server-unreachable / token-expired caught but **network-vs-unauthorized distinction weak in UI**; download progress UI needs validation.

**Platform entry:** iOS/iPad 2-tab (onboarding exists but unshown; iPad needs landscape polish); **macOS 3-pane (NO onboarding — CRITICAL)**; watchOS carousel (syncs from iPhone; needs first-run guidance); CarPlay 4-tab (wired; needs driving-safety audit — no modals while driving).

---

## F. Net-new behaviors this requires (build list / delta from today)

1. **First-run landing page** (new view) — folder CTA, manual offer, ABS link, no-copy copy. (~3–5 days)
2. **Wire `OnboardingView`** into `EchoCoreApp` *and* add a macOS equivalent. (~2–3 days)
3. **Bundle + seed the Manual** on first launch — bundle `Welcome-to-Echo.epub` (from `~/Developer/echo-manual-build/welcome-to-echo/dist/`) into Echo's resources + DB-seed the audiobook/track records so it appears as the first library item. Prereq: **pre-render ch.1 audio + word alignment** (echo-cli/overnight) and bundle those alongside. (~2–3 days)
4. **Listen-first hybrid narration** for the manual — ch.1 plays from the bundled pre-rendered audio instantly; **once playback starts, the remaining 15 chapters narrate on-device** progressively (render-ahead). Current narration renders all chapters on-device with no pre-bundled head. (~3 days)
5. **"Auto-play on open" Setting (default OFF)** — add the toggle; when ON, `loadFolder()` calls `play()` for audio-first opens (1-M4B / MP3 / multi-M4B), never for text-only. Default OFF preserves today's load-don't-play. Independently: make the Play affordance prominent on a freshly loaded book regardless of the setting. (~1 day)
6. **Dismissible help-offer nudge system** (Load EPUB / Load PDF / Manual / Transcribe) — extend beyond narration nudge; non-blocking; must not gate transport. (~5–7 days)
7. **Nudge dismissal persistence** — new `nudge_dismissal` table (per-book, per-type). (~1 day) → DB migration → triggers doc-sync.
8. **Wire Transcription UI** — button in `ReaderEmptyState`/`BookSettingsView` (only when `!hasEPUB && !hasPDF`) → instantiate `StandaloneTranscriptionService` → progress UI (adapt `AutoAlignmentProgressView`) → on completion show `StandaloneTranscriptView`. (~2 days)
9. **Optional FTS5 index** on `standalone_transcript.text` (currently client-side filter). (~0.5 day) → schema migration → doc-sync.
10. **M4B chapters in Contents/TOC view when no EPUB** — `MacTOCTreeView` is EPUB-only; fall back to `state.chapters`. (~1 day, UI only)
11. **PDF auto-import** (or explicit "Load PDF" nudge) — EPUB auto-imports, PDF does not. (~1 day)
12. **Nested-folder support OR explicit messaging** — recursive scan vs documented flat requirement. (decision; ~M)
13. **Error UIs for silent failures** — stale/deleted file on restore; macOS scope-lost; narration OOM/model-fail; ABS network-vs-auth distinction. (~2–3 days)
14. **Unsupported-format + empty-folder messaging** (and suppress narration nudge on empty/unsupported folders). (~1 day)
15. **No-copy reassurance on landing** (move/duplicate from `HelpContent`). (~0.5 day)
16. **EchoDeckBuilder integration ("EPUB/transcript → AI → flashcards").** EDB is a *separate, working macOS app* (`~/Developer/EchoDeckBuilder`, SwiftUI/SPM, MVP complete). Today it takes an **EPUB** (not a transcript), extracts spine/block sections, and exports **"Echo Deck JSON vNext"** (`.echo-deck.json`) with portable `s<i>-b<j>` anchors (same convention as Echo's `DocumentImportFinalizer`). MVP card generation is a deterministic fixture; on-device Foundation Models generation lives on other EDB branches. Hand-off is **file-based, one-way** (export deck → import into Echo); no URL scheme/App Intent yet.
    - **Echo-side work (the concrete integration):** implement the **vNext importer** — add `sourceAnchor` to `FlashcardDeckImport.ImportedCard`; resolve via a new `EPUBSourceAnchorResolver` to local `epub_block.id`; wire into both `DeckImportService` and `ApkgImportService`; add an **"Open in EchoDeckBuilder"** hand-off for the current EPUB (macOS). (~3–5 days)
    - **Gap 1 — input mismatch (DEFERRED):** "transcribe bare audio → cards" needs EDB to accept a **transcript** input (it only takes EPUB today). Per §G3, deferred post-1.0; for 1.0 the bare-audio "Transcribe" action only makes audio searchable and exposes a forward-hook to flashcards.
    - **Gap 2 — platform (RESOLVED):** EDB is **macOS-only**. On iOS, "Make flashcards" = **export this EPUB for EchoDeckBuilder on Mac**; generation happens on the Mac and the deck syncs/imports back. No iOS-native generator in 1.0.

---

## G. Open decisions

1. **MP3 folder ordering.** ✅ RESOLVED — honor embedded track-number/disc metadata, fall back to natural filename sort, and surface the order so the user can verify/reorder.
2. **Public demo ABS server.** ✅ RESOLVED — one-tap "Connect to demo" (read-only, rate-limited, public-domain-only guest), not a self-hosted load-bearing server.
3. **EchoDeckBuilder — RESOLVED: "EPUB round-trip first."** 1.0 ships the path EDB already supports: **"Open in EchoDeckBuilder"** for an EPUB book (macOS) + Echo's **vNext importer** (sourceAnchor → epub_block via a new `EPUBSourceAnchorResolver`, in `DeckImportService` + `ApkgImportService`) so decks flow back. Bare-audio **"Transcribe → flashcards" is a forward-hook only** (transcribe = searchable now; cards once EDB learns transcript input). On iOS, **"Make flashcards" = "export this EPUB for EchoDeckBuilder on Mac."** Deferred post-1.0: EDB transcript-input mode; an on-device in-Echo generator; AI-engine choice (Foundation Models vs cloud) for EDB's real generator.
4. **Auto-play on open.** ✅ RESOLVED — add an "Auto-play on open" Setting, **default OFF**; when ON, applies to audio-first opens only (never text-only). Default stays load-don't-play with a prominent Play affordance.
5. **Nested-folder / multi-disc** — recursive scan vs enforce flat layout + message. (Affects A6.)
6. **Nudge persistence policy** — narration = no dismissal; manual = session-only; EPUB/PDF/transcribe/AI = persisted per-book with settings re-enable. Confirm.
7. **PDF auto-import** vs manual + nudge (A5).
8. **Notification permission timing** — currently pre-context at launch; consider deferring to first card creation.
9. **AirDrop copy semantics** (A12) — copies into sandbox vs the no-copy norm; confirm and message accordingly.
10. **FTS5 for standalone transcripts** — ship now or accept client-side filter for small transcripts.

---

## H. Coverage gaps & unverified assumptions (completeness-critic)

**Contradictions resolved toward verified facts:**
- *"Contents/Chapters shows all M4B chapters"* — chapters ARE fully parsed and appear in the **ChapterPickerSheet** (single + multi-M4B), but the **TOC/Contents tree view (`MacTOCTreeView`) is EPUB-only**. The vision item is **satisfied in the picker, NOT in the TOC view** → build item F10.
- *Empty/unsupported folder narration nudge* — fires per policy (`tracks.isEmpty`) but is **arguably a bug** → guard F14.
- *Transcript sidecar auto-load (A16)* — asserted by ingest pass, **unconfirmed**. Unverified.
- *Drag-drop on macOS (A14)* — no `.onDrop` found; not independently re-verified. Likely MISSING.

**Implied-but-missing paths (no pass covered):**
- **Deleting a book / removing from library** — no path for forgetting a book, clearing a stale entry, or removing an ABS download.
- **Re-running alignment / clearing anchors from the UI** — service clears prior auto-anchors per run, but the *user-facing trigger* + progress surface weren't tied to a first-run path.
- **Switching EPUB→PDF when both present** — desired in §B but no current toggle; only EPUB precedence verified.
- **iCloud/CloudKit sync of bookmarks/flashcards across devices** — share-to-CloudKit exists for decks; full cross-device restore on a fresh install not mapped.
- **Nudge state / overrides when the underlying folder moves** — security-scoped bookmark re-grant flow not mapped.

**"Desired" behaviors whose current state is unknown/unverified:** AirDrop copy-into-sandbox (A12); transcript sidecar (A16); macOS drag-drop (A14); mic-permission flow on first voice memo; ABS self-signed cert trust prompt; watchOS/CarPlay first-run guidance.

**Verified-but-risky (carry into test plan):**
- Stale/deleted-file restore returns nil **silently** (`Persistence.swift:238-240`) — CRITICAL, needs error UI + test.
- Narration OOM/model-fail calls `.fail()` with **no UI** — needs error surface + test.
- No-recursion folder scan — multi-disc users silently lose nested files; needs message + test.
- `StandaloneTranscriptionService` exists but is **instantiated nowhere** — wiring is the whole feature; no integration test of the full flow exists.

**Doc-sync reminder:** F3, F4, F7, F8, F9, F11, F16 add features / change the schema (new `nudge_dismissal` table, optional `standalone_transcript` FTS5) — per the project's Documentation & Workflow Sync rule, `ARCHITECTURE.md`, `README.md`, and `CHANGELOG.md`/`ROADMAP.md` will need updating, and the `doc-sync` skill should run before any PR lands these.
