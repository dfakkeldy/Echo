# Echo User Manual

The complete reference for **Echo: Audiobook Study Player** on iPhone, iPad, Apple Watch, Mac, CarPlay, and widgets.

New to Echo? Read [Getting the Most Out of Echo](getting-the-most-out-of-echo.md) first — it explains *why* these features help you learn. This manual explains *how* everything works.

> **Status tags:** 🚧 **Coming in 1.0** = in active development right now. 🔭 **Roadmap** = planned after 1.0. Everything unmarked ships in the current beta.

---

## Contents

1. [Getting Started](#1-getting-started)
2. [Organizing Your Library](#2-organizing-your-library)
3. [The Three Tabs](#3-the-three-tabs)
4. [Playback](#4-playback)
5. [Smart Rewind](#5-smart-rewind)
6. [Loop Modes](#6-loop-modes)
7. [Sleep Timer](#7-sleep-timer)
8. [Bookmarks](#8-bookmarks)
9. [The Study System](#9-the-study-system-flashcards--review)
10. [Brain Dump & Book Notes](#10-brain-dump--book-notes--coming-in-10)
11. [The Reader: EPUB](#11-the-reader-epub)
12. [Audio–Text Alignment](#12-audiotext-alignment)
13. [PDF Companions](#13-pdf-companion-documents)
14. [Insights](#14-insights--coming-in-10)
15. [Context Memory](#15-context-memory-location--coming-in-10)
16. [Exports & Your Data](#16-exports--your-data)
17. [Playlist & Timeline](#17-the-playlist--timeline)
18. [Apple Watch](#18-apple-watch)
19. [Widgets & Control Center](#19-widgets--control-center)
20. [CarPlay](#20-carplay)
21. [Echo for Mac](#21-echo-for-mac)
22. [Sync & iCloud](#22-sync--icloud)
23. [Settings Reference](#23-settings-reference)
24. [Transcription Tools](#24-transcription-tools-power-users)
25. [Privacy](#25-privacy)
26. [Troubleshooting & FAQ](#26-troubleshooting--faq)

---

## 1. Getting Started

### What Echo plays

Echo is a player for **DRM-free** audiobooks — files you own and can see in the Files app:

- **MP3 / M4A** — including folders of one-file-per-chapter rips
- **M4B** — with full embedded chapter parsing, including books split across multiple M4B files (chapters are aggregated automatically)
- **FLAC, AAC, AIFF, OGG, OPUS, WMA** — on Mac
- **EPUB** — as a synced companion text (see The Reader)
- **PDF** — as a synced companion document (see PDF Companions)

Echo does not bypass DRM and cannot play protected Audible/Apple Books titles. Tools like Libation or OpenAudible can export books you own to open formats — see the FAQ for details and a note on legality.

### Loading your first book

1. Put the audiobook in a folder — one folder per book is the happy path (see [Organizing Your Library](#2-organizing-your-library)). iCloud Drive, "On My iPhone," third-party file providers: all work.
2. In Echo, choose **Load Folder** and select the book's folder.
3. Echo scans the folder, builds the chapter list, finds the cover art (embedded art, or a `cover.*` image in the folder), and picks up any EPUB or PDF sitting alongside the audio for automatic import.
4. Press play.

Echo remembers everything per book: position, speed, loop mode, and settings overrides. Reopen the app days later and it resumes exactly where you left off — with Smart Rewind backing up just enough to restore your context.

First launch walks you through this — including a step on setting up your library folder. 🚧 Coming in 1.0

> 📸 *Screenshot coming soon — loading a book folder and the Now Playing screen that follows.*

### Cover art

Echo looks for artwork in this order: image embedded in the audio file → an image file in the book folder (prefers `cover.*`) → the Echo app icon as fallback. Artwork drives the player background, the watch complication thumbnail, and the dynamic accent color.

---

## 2. Organizing Your Library

Echo reads your files in place — there's no import-everything step and no hidden copy of your library. That means a little folder discipline up front pays off every single day.

### The golden rule: one folder per book

```
iCloud Drive/
└── Audiobooks/
    ├── Thinking, Fast and Slow/
    │   ├── Thinking Fast and Slow.m4b
    │   ├── Thinking Fast and Slow.epub   ← auto-imported
    │   └── cover.jpg                     ← optional if art is embedded
    ├── Project Hail Mary/
    │   ├── 01 - Chapter 1.mp3
    │   ├── 02 - Chapter 2.mp3
    │   ├── …
    │   └── cover.png
    └── Archive/
        └── (finished books)
```

- **One parent folder** ("Audiobooks") holds everything. One place to look, one place to back up, one place to point Echo at.
- **One folder per book**, named by the book title — human-readable ("Project Hail Mary", not "PHM_64kbps_final2").
- **Companion text goes in the same folder.** Drop the `.epub` or `.pdf` next to the audio and Echo's auto-import scanner picks it up. One EPUB per book folder.
- **An `Archive/` subfolder** keeps finished books out of your active view without deleting anything. Export your study notes first (see Exports).

### File naming that sorts correctly

- **Zero-pad track numbers:** `01, 02 … 10, 11` — not `1, 2 … 10`. Plain alphabetical sorting puts "10" before "2"; zero-padding fixes it everywhere, forever.
- **Rename *before* the first load, not after.** Echo tracks progress per file; renaming files mid-book can orphan your position in them.
- **Prefer M4B when you have the choice.** A single M4B carries embedded chapter markers and cover art in one tidy file. Books split across several M4Bs are fine — Echo aggregates the chapters automatically. Folders of MP3s work well; their "chapters" are the files, named by you.
- **Libation-style fine-grained chapters are handled.** Files named like "Chapter 11. A" / "Chapter 11. B" are automatically grouped into logical chapters with sections.

### iCloud Drive: the rules of the road

> **The single most important setting:** long-press your **Audiobooks** folder in the Files app and choose **Keep Downloaded**. Without it, iOS silently *evicts* audio files to reclaim space — the file is "there" with a little cloud icon, but the bytes are gone until re-downloaded. That's the #1 cause of "my book stopped playing mid-commute."

- **Check the cloud icons before you leave Wi-Fi.** A cloud-with-arrow icon next to a file means it's not on the device.
- **iCloud Drive is the cross-device choice:** the same folder is reachable from iPhone, iPad, and Mac. "On My iPhone" is the fully-offline choice — always local, never evicted, but invisible to other devices.
- **On the Mac,** "Optimize Mac Storage" does the same eviction trick — right-click the folder in Finder and choose **Keep Downloaded** there too.
- **Third-party providers** (Dropbox, Drive, NAS apps) work through the Files app, but many don't background-download as smoothly — for daily listening, iCloud Drive or on-device storage is less fussy.
- **Don't move or rename the book's folder casually.** Echo holds a secure reference to the folder you picked; moving it may require re-selecting the folder (your bookmarks and cards survive — they live in Echo's database, not the folder).

### What lives where

| Data | Where it lives |
|---|---|
| Audio, EPUB, PDF files | Your folder, wherever you put it. Echo reads in place and never modifies your files. |
| Bookmarks, flashcards, notes, alignment, progress | Echo's local database on the device (synced via your personal iCloud — see Sync). |
| Playlist order edits | Echo's database *plus* a small portable manifest file in the book's folder. |
| Voice memos & bookmark photos | Echo's app storage on the device. |

---

## 3. The Three Tabs

| Tab | What it's for |
|---|---|
| **Now Playing** | The player: artwork, scrubber, transport controls, speed, sleep timer, bookmarks, quick capture. |
| **Read** | The synced EPUB/PDF reader: read along, search, align, highlight, bookmark from text. |
| **Timeline** | Your study feed: chapters, bookmarks, flashcards, notes, and aligned text in one scrollable history, plus the review queue and dashboard modules. |

A mini-player bar stays visible on the Timeline tab so transport controls are never more than one tap away.

---

## 4. Playback

### Transport controls

Five configurable transport buttons. Defaults: skip back, previous chapter, play/pause, next chapter, skip forward.

- **Skip durations** configurable 5–60 s, independently forward/backward, synced to the watch.
- **Long-press secondary actions:** each button can carry a second action on long-press. Configure under *Settings → Player Controls*.
- **Sections:** fine-grained chapter files are grouped into logical chapters; Next/Previous Section jumps sub-sections; the scrubber shows tick marks and snaps with a haptic tap.
- **Mark for a flashcard** 🚧 Coming in 1.0 — a one-tap Mark action drops the passage into your Card Inbox without pausing playback.

### Speed control — pitch-corrected

0.5× to 2×+ with true pitch correction. Global default in Settings; each book remembers its own speed; all displayed times adjust to the current speed.

### Volume boost

Up to +9 dB of clean gain (configurable), independent of system volume.

### Audio behavior

- Playback pauses automatically when headphones disconnect.
- Calls, alarms, and Siri interruptions pause and resume correctly (no auto-resume if *you* paused first).
- Audio is configured as spoken-word audio system-wide.

---

## 5. Smart Rewind

Every time you press play after a pause, Echo rewinds first — proportionally to how long you were gone (seconds → a few seconds; minutes → more; hours–days → the most). All three tiers configurable under *Settings → Smart Rewind*. This is Echo's signature feature: it makes interruption free.

---

## 6. Loop Modes

- **Loop chapter** — repeat the current chapter until you turn it off. *The feature Echo was built for.*
- **Loop playlist** — repeat the whole book.
- **Loop between bookmarks** — repeat the passage between consecutive bookmarks.
- **Off** — straight through.

Loop mode is remembered per book; available on the watch and as a long-press action.

---

## 7. Sleep Timer

Countdown (with fade-out) or stop at chapter end. Echo notes the pause time so tomorrow's Smart Rewind re-covers what you drifted through. Controllable from phone and watch.

---

## 8. Bookmarks

### Creating bookmarks

- **Phone:** bookmark button in the player (or a transport long-press).
- **Reader:** long-press any paragraph → **Save Bookmark**.
- **Watch:** one (configurable) button; quick-bookmark timeout confirms or auto-saves.
- **Siri:** dictate a bookmark hands-free.
- **PDF:** long-press a page → bookmark with a page screenshot.

### What a bookmark can hold

| Element | Details |
|---|---|
| Title & note | Editable text; titles default to "Bookmark N". |
| Voice memo | Recorded in the moment; volume-normalized. |
| Photo | From library or camera; drives dynamic artwork. |
| Place 🚧 | With Context Memory enabled, an approximate place name, shown as a chip. |
| PDF view state | Exact page, zoom, scroll restore. |
| Enabled/disabled | Disabled bookmarks stay visible but won't trigger inline playback. |

### Voice memos that play inline

With *Inline Voice Memos* enabled, playback reaching a bookmark with a memo ducks the narration and plays **your** voice, then resumes. Toggle globally or per book.

### Photo bookmarks & dynamic artwork

As playback passes a photo bookmark, the player artwork switches to your photo (phone, watch, lock screen) and back. The science is in [the learning guide](getting-the-most-out-of-echo.md).

> **Safety first:** never take photos while driving. Pick from your library later — or let Context Memory capture the place automatically, hands-free (🚧 Coming in 1.0).

### Managing bookmarks

- Grouped per book; sortable; editable (rename, retime, re-record, swap photo).
- **Loop between bookmarks** uses them as fences.
- **Export to Markdown** — timestamps, notes, deep links (see Exports).
- Any bookmark promotes to a **flashcard** in one tap.

---

## 9. The Study System (Flashcards & Review)

A complete spaced-repetition system — think Anki, built into your audiobook player, with audio on the cards.

### Creating cards

- **From the reader:** long-press a passage → **Create Flashcard**.
- **From a bookmark:** any bookmark becomes a card.
- **From a mark** 🚧 — via the Card Inbox, below.
- **From a note** 🚧 — promote a Brain Dump entry.
- **From scratch:** in the Timeline tab.
- **Import a deck:** Anki-style JSON today; real .apkg with 1.0.

Cards carry a front, a back, and optionally: an **audio snippet**, a **photo**, a **deck and tags** (🚧), and a **trigger timing** (or manual-review-only).

### The Card Inbox — mark now, card later 🚧 Coming in 1.0

1. **Mark:** one tap on the transport bar (or a watch button) captures the passage just heard — context either side, transcript snippet when aligned. Playback never stops.
2. **Inbox:** marks collect grouped by book, with a badge on the dashboard and Timeline toolbar.
3. **Convert:** tap a mark → pre-filled card editor (adjust clip, write the front as a question, pick a deck) — or swipe to dismiss.

When the Card Inbox arrives, inline flashcard popups retire — capture stops competing with listening.

> 📸 *Screenshot coming soon — the Card Inbox with marked passages and the pre-filled card editor.*

### Inline recall during playback

Cards with a trigger timing surface as you listen — a micro-review in context. *Manual only* cards never interrupt. (With 1.0, new cards default to manual-only and the popup mechanism is retired.)

### Editing cards 🚧 Coming in 1.0

Full editor on every card: front/back, audio snippet range ("use current position"), deck, tags, enabled toggle, delete-with-confirmation. Reachable from the Timeline, review sessions, and the deck browser.

### Decks & tags 🚧 Coming in 1.0

- **Deck list:** card count + due count per deck; "Unfiled" holds deckless cards.
- **Deck detail:** searchable cards, per-deck mini-stats, rename, delete (cascade or orphan).
- **Review by deck:** run a session over one deck — exam-week mode.
- **Tags:** space-separated, Anki convention.

### Importing real Anki decks (.apkg) 🚧 Coming in 1.0

Pick a `.apkg` from the deck list's import button — **scheduling history included** (mature cards stay mature).

- First field → front; remaining fields → back (HTML cleaned); tags kept; suspended cards arrive disabled; media copied in; review state maps conservatively.
- **Cloze cards** flatten to plain Q&A in v1 (counted in the import summary).
- **Newest Anki format:** Echo will ask you to re-export with *"Support older Anki versions"* checked.
- Imported decks aren't tied to an audiobook and review like any other cards.

### Daily Review

- **SM-2 scheduling** (Anki's family): grades **Again / Hard / Good / Easy** drive each card's next appearance.
- Cards with audio play their snippet.
- Due / reviewed-today / total show on the Timeline review module; the full picture lives in Insights 🚧.
- Optional **daily local notification** (generated on-device; Echo has no servers).

### Review on Apple Watch

Full hands-free review sessions: hear the card, think, tap a grade.

> **🔭 Roadmap — Chapter Study Mode:** chapters as flashcards with a due-chapter listening queue. Until then: loop the chapter, grade yourself honestly at its end, card what you couldn't explain.

---

## 10. Brain Dump & Book Notes 🚧 Coming in 1.0

Bookmarks pin thoughts to a *moment*; flashcards pin them to a *question*. Book Notes are everything else — thoughts about the book as a whole, plus the "buy stamps" intrusions that would otherwise cost you a chapter.

### Capturing

- **Phone:** Note button in the Now Playing overflow — text field, or hold to record a voice memo. Playback continues.
- **Watch:** a *Dictate Note* action — speak, done; lands on the current book.
- Notes are **untethered** (book-level, not timestamped), though capture position is recorded as silent context.

### The Notes inbox

- Per-book **Book Notes** view: newest first, text + voice entries, inline memo playback, swipe to delete.
- **Promote** any note → *bookmark* (at capture position) or → *flashcard* (pre-filled editor).
- Entry points: note icon with count on the Timeline toolbar; a dashboard module when anything's waiting.
- Notes appear in the Timeline feed and join the study-notes export.

> 📸 *Screenshot coming soon — Book Notes inbox with a voice memo entry and promote actions.*

---

## 11. The Reader: EPUB

Drop the `.epub` in the book's folder (auto-import) or use **Import Document**. Imports are copy-only and validated; paragraphs, headings, images, inline formatting, block quotes, and links are preserved.

- Clean feed of cards: chapter headers, paragraphs, images.
- **Follow the narration:** active paragraph highlighted, auto-scroll with playback; scroll away to browse, tap to return live.
- **Tap to seek** any paragraph; tap images for full-screen.
- **Search** full text; results jump text *and* audio.
- **Table of contents** + sticky position header (Part → Chapter → Section).
- **Highlights:** long-press → Change Color.
- **Typography:** size, spacing, card tint; **Lexend** and **OpenDyslexic** built in.
- **Reader speed controls** 🚧 Coming in 1.0 — adjust playback speed without leaving the Read tab.

The bottom toolbar switches to reader-optimized controls while the Read tab is active.

---

## 12. Audio–Text Alignment

### Auto-Align (recommended)

**Auto-Align Chapters** uses on-device speech recognition (WhisperKit on the Neural Engine — *no audio ever leaves your device*):

| Tier | What it does |
|---|---|
| 0 — Title match | Chapter titles → instant coarse anchors. |
| 1 — Chapter snap | Transcribes a clip at each boundary, fuzzy-matches, anchors every chapter start/end. |
| 2 — Drift detection | Spot-checks inside chapters for drift. |
| 3 — Drift repair | Bisects flagged regions; word-level anchors via token DTW. |

Between anchors, positions interpolate weighted by paragraph word counts. On completion, Echo celebrates your **% aligned** 🚧 Coming in 1.0.

**Continuous Alignment** (optional) refines in the background while you listen.

### Manual anchors

- Long-press a paragraph → **Align to Now** (or **Align to 5s Ago**).
- Heading cards: **Align to Chapter Start/End**.
- Locked anchors show a green badge; **Erase Anchor** removes one; **Reset Alignment** starts fresh.

---

## 13. PDF Companion Documents

Import like an EPUB — the Import button routes automatically.

- Continuous scroll and zoom.
- **Page-level alignment:** long-press a page → Manual Alignment sheet with play/pause, ±5 s skips, and the **scrubber joystick** (small pulls = precise, big pulls = fast, live audio preview).
- **Page bookmarks:** screenshot thumbnail + exact page/zoom/scroll restore.

---

## 14. Insights 🚧 Coming in 1.0

Computed entirely on your device from your own history. Open from the dashboard modules or the Timeline toolbar.

| Section | Contents |
|---|---|
| Overview | Range picker (D/W/M/Y/all), total listening time, streak, daily average. |
| Listening | Time per bucket, speed trend, per-book share, time-of-day histogram, session lengths. |
| Per-book | Chapter-coverage heatmap — "Chapter 7 — 86% covered, listened 3×". |
| Study | Reviews/day, retention curve vs 90% target, grade distribution, 30-day due forecast. |
| Planner | Planned-versus-actual session pairs. |
| Places | If Context Memory is on: where you listen most (map view 🔭 Roadmap). |

The dashboard gets live teaser modules (listened-today, streak, upcoming reviews). The Mac gets a Stats pane (Overview/Listening/Study).

> 📸 *Screenshot coming soon — Insights overview with streak, listening chart, and chapter-coverage heatmap.*

---

## 15. Context Memory (Location) 🚧 Coming in 1.0

Off by default; opt in via **Settings → Privacy & Location → Context Memory**.

- **Approximate places only:** reduced-accuracy location, neighborhood level — never your doorstep.
- **Three capture points:** session start, bookmark creation, chapter start. Powers bookmark place chips, "Chapter 3 started at Oak Street" in per-book Insights, and the Places list.
- **Never blocking:** capture is fire-and-forget with a timeout — bookmarks save instantly even in airplane mode, just without a place.
- **Deletable in one tap:** *Delete Location History* erases every captured place permanently.
- **Sync policy:** bookmark places travel with bookmarks via your personal iCloud while enabled; **session location history never leaves the device.**

---

## 16. Exports & Your Data

Your data is yours, in formats you can read, forever. The database schema is open source.

| Export | What you get |
|---|---|
| **Bookmarks → Markdown** (today) | Timestamps, notes, deep links that reopen Echo at the exact second. |
| **Study Notes bundle** 🚧 | Per book: one Markdown file (bookmarks, Book Notes, flashcards, chapter headings, places) + `assets/` (voice memos, photos). Obsidian/Logseq/Notion-ready. Per book or bulk in Settings. |
| **Deck → JSON** 🚧 | `.echodeck.json` with every field incl. scheduling; re-imports losslessly — backup + migration. |
| **Anki .apkg import** 🚧 | Inbound — see The Study System. (.apkg *export* 🔭 Roadmap.) |

---

## 17. The Playlist & Timeline

### Playlist

- Chapters in playback order with duration and progress; logical chapters expand into sections.
- **Drag to reorder**; **tap to dim** a chapter to skip it (skipped by playback and loops).
- Hierarchical titles render nested structure with indentation.
- Edits persist per book; a portable manifest file keeps ordering across devices.

### Timeline

Your study history as a feed: chapters, bookmarks (photos/memo indicators), flashcards, notes, aligned excerpts. Dashboard modules (due cards, streak, listened today, inbox badges) live here. **Freeze** while browsing; sync-and-resume when ready.

---

## 18. Apple Watch

### The remote

- **Up to 25 buttons:** five pages × five slots, all user-assignable: play/pause, skips (5–60 s), chapters, sections, loop, speed, sleep timer, bookmark, Pomodoro — or empty (empty pages hide).
- **Mark passage** 🚧 — one tap into the Card Inbox.
- **Dictate note** 🚧 — speak a Brain Dump note; playback never pauses.
- **Design it from the phone:** drag-and-drop in *Settings → Watch App*; syncs instantly.
- **Digital Crown:** volume or scrubbing (with deadzone).
- **Big targets:** hit them in gloves, rain, mid-stride.

### On-wrist features

Now-playing screen with full-screen artwork (incl. photo-bookmark switching), voice-memo bookmarks, hands-free flashcard review, Pomodoro with persistent alarm, sleep timer/speed/loop control, and a complication with book thumbnail + progress ring.

### Reliability

Durable application-context sync; stale commands never replay; the watch requests authoritative position on wake and converges.

> 📸 *Screenshot coming soon — the watch remote grid and a hands-free review session.*

---

## 19. Widgets & Control Center

- Lock/Home Screen widget: thumbnail + progress ring.
- Play/pause from the widget.
- Control Center toggle-playback control.

---

## 20. CarPlay

Browse list + transport commands (play, pause, skip). Intentionally minimal for now; richer templates and capture buttons are on the roadmap. No CarPlay? The watch remote and aux cable are the designed path.

---

## 21. Echo for Mac

- **Three-pane layout:** bookmarks sidebar, player pane, document pane.
- Broadest format support (FLAC/OGG/OPUS).
- **EPUB alignment** with streaming on-device transcription.
- **Transcript pane** with live highlighting, search, and word clouds.
- Bookmarks share the iOS format via the app-group store.
- **Insights pane** 🚧 Coming in 1.0 — listening and study charts.
- **Review pane** 🚧 Coming in 1.0 — clear due cards at the desk; menu-bar + keyboard-shortcut basics.

Mac 1.0 is the *functional core* — play, read, review, see your stats. Full reader/alignment parity continues after 1.0.

---

## 22. Sync & iCloud

Echo has no servers and no accounts — sync rides on *your* iCloud.

- **Today:** audio files sync wherever you keep them; alignment anchors sync so a book aligned once stays aligned.
- **Study sync** 🚧 Coming in 1.0 — flashcards, decks, bookmarks, playback position across iPhone, Mac, and Watch (personal iCloud, private database).
- **Sensible conflicts:** scheduling follows your most recent review; content follows your most recent edit.
- **What never syncs:** session location history, and anything you haven't opted into.
- Voice memos, brain-dump notes, and planned sessions stay device-local in 1.0; their sync is on the roadmap.

---

## 23. Settings Reference

| Group | Settings |
|---|---|
| Playback | Default speed · per-book speed memory · volume boost gain · seek durations (5–60 s) |
| Smart Rewind | Three tiers with per-tier rewind amounts |
| Bookmarks | Inline voice memo playback (global + per book) · quick-bookmark timeout |
| Study | Daily review notification · inline flashcard triggers · deck defaults 🚧 |
| Privacy & Location 🚧 | Context Memory toggle (off by default) · Delete Location History |
| Reader | Font (incl. Lexend, OpenDyslexic) · text size · line spacing · card tint · per-card colors |
| Appearance | Accent color or Artwork mode · dark mode · app icon · player layout · button sizes |
| Player Controls | Five tap + five long-press actions |
| Watch App | Layout designer (5×5) · Crown mode · artwork layout · haptics · date overlay · title scroll speed |
| Per-book overrides | Any global setting, pinned per book |
| Data | Study-notes bulk export 🚧 · deck export 🚧 |
| Help | The full in-app help library |
| Language | English and Dutch |

---

## 24. Transcription Tools (Power Users)

A companion command-line tool (`Tools/transcription_generator.py`) for archival transcripts on your Mac. EPUB/PDF alignment runs entirely in-app now (on-device WhisperKit); the earlier Swift transcription/alignment CLI has been retired.

- **Python CLI** (faster-whisper): transcribe a single file with `--audio_path` or a folder with `--dir` (existing `.transcript.json` files are skipped). Tune with `--model_size`, `--language`, `--device`, and `--force`.
- Output is a `.transcript.json` sidecar of timestamped segments plus word-frequency data (rendered as word clouds on Mac).

Optional — the iOS app's built-in alignment needs none of this. Set up with `pip install -r Tools/requirements.txt` and `brew install ffmpeg`.

---

## 25. Privacy

- **No accounts. No analytics. No tracking. No ads. No servers.**
- Books, bookmarks, photos, voice memos, notes, flashcards, and listening history stay on your devices (and your personal iCloud, where you enable sync).
- Speech recognition runs **entirely on-device**.
- Location (Context Memory 🚧) is **opt-in, approximate, deletable** — and session location history never leaves the device.
- Open source (MIT): [github.com/dfakkeldy/Echo](https://github.com/dfakkeldy/Echo).

---

## 26. Troubleshooting & FAQ

### Library & playback

**My book won't play / chapters are missing.**
Nine times out of ten this is iCloud eviction: the files show a cloud icon and aren't on the device. Long-press the folder in Files → **Keep Downloaded** (see Organizing Your Library). For multi-file books, confirm name-sorting — or drag-reorder in the playlist.

**How should I organize my audiobook and EPUB files?**
One parent "Audiobooks" folder; one folder per book; EPUB/PDF in the same folder as the audio; zero-padded track numbers. iCloud Drive for cross-device, "On My iPhone" for always-local. Full guide: [Organizing Your Library](#2-organizing-your-library).

**Can Echo play my Audible or Apple Books audiobooks?**
Not while they're DRM-locked — Echo plays open formats only and does not bypass DRM. If you want to listen to audiobooks **you've purchased** in Echo, tools exist that export your own library to open formats: [Libation](https://getlibation.com) (free, open source, for Audible libraries) and [OpenAudible](https://openaudible.org) (paid) are the well-known ones. Libation's M4B exports work beautifully with Echo — chapters, art, and all. One honest caveat: the legality of removing DRM from media you own varies by country, even for personal use — check the rules where you live. Echo has no affiliation with these tools, and the best long-term fix is buying DRM-free where possible (Libro.fm and Downpour offer DRM-free titles; LibriVox is free and public-domain).

**Does Echo work fully offline?**
Yes — playback, reading, alignment, flashcards, notes, insights: everything. The only network use is your own iCloud file syncing (and, if you enable Context Memory, Apple's place-name lookup).

**Will a huge library or a 60-hour book slow Echo down?**
No. Echo reads books in place and keeps its database indexed. The one heavy operation is the *first* auto-alignment of a very long book — plug in for that one.

### Reader & alignment

**The reader text doesn't match the narration.**
Different editions drift. Run **Auto-Align Chapters**; for stubborn spots, long-press the paragraph you're *hearing* → **Align to Now**. Two or three manual anchors usually tame a messy book.

**Auto-alignment is slow or makes my phone warm.**
First run downloads and warms the on-device model, and transcription is real Neural Engine work. Plug in for the first full-book alignment; afterward, repairs are quick.

### Study & data

**Can I import my Anki decks?**
JSON decks import today. Real `.apkg` files — scheduling included — arrive with 1.0 🚧. Newest-format decks: re-export from Anki with *"Support older Anki versions"* checked. Cloze cards flatten to plain Q&A in v1.

**Can I get my flashcards and notes back out?**
Yes — that's policy. Bookmarks → Markdown today; with 1.0, decks → portable JSON (lossless re-import) and books → full study-notes bundles for Obsidian/Logseq/Notion 🚧. The schema is open source; your data is never hostage.

**Inline flashcards interrupt me too much.**
Set those cards to *manual only*, or disable inline triggers in Settings → Study. In 1.0 the Card Inbox replaces mid-playback popups entirely 🚧.

**What's the difference between a bookmark, a note, and a flashcard?**
**Bookmark** = a *moment* (timestamp; optional memo/photo/place). **Note** 🚧 = an *untethered thought* (the brain-dump). **Flashcard** = a *question* you want to keep answering. Notes and bookmarks both promote into flashcards — capture cheap first, decide later.

**Will my flashcards and bookmarks sync between devices?**
Anchors sync today; full study sync (cards, decks, bookmarks, position) ships in 1.0 via your personal iCloud 🚧.

### Watch, privacy & the project

**The watch shows a stale book/position.**
Raise the watch and give it a beat — it requests authoritative state from the phone on wake. Both devices on, same Wi-Fi/Bluetooth, helps.

**Voice memos are quiet/loud.**
Memos are volume-normalized on save; old ones can be re-recorded from the bookmark editor.

**Is the location feature tracking me?**
Only if you turn it on — and even then: approximate places, a few capture moments, stored on-device, deletable in one tap, session history never synced. Echo has no servers to send it to.

**Does Echo use AI? Does anything leave my device?**
On-device machine learning (WhisperKit) for alignment — no cloud APIs, no uploads. No chatbots, no generative features today; if AI-assisted card drafting arrives post-1.0, it runs on-device under the same rules 🔭.

**What's coming after 1.0?**
Chapter Study Mode, on-device AI card drafting, focus soundscapes, gentle hyperfocus/transition reminders, a Context Memory map view, FSRS as an alternative scheduler, .apkg export, richer CarPlay, full Mac reader parity. The [ROADMAP](../../ROADMAP.md) is public.

**Where are my files? Can I get my data out?**
Audio stays where you put it (read in place, never modified). Echo's data lives in a local SQL database with an open schema; everything exports (see Exports). Deleting the app deletes Echo's database — your audio folder is untouched.

---

*Echo is open source under the MIT license. Found a bug, or want a feature? [Open an issue](https://github.com/dfakkeldy/Echo/issues) — the developer reads every one.*
