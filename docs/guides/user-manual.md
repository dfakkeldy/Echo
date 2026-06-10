# Echo User Manual

The complete reference for **Echo: Audiobook Study Player** on iPhone, iPad, Apple Watch, Mac, CarPlay, and widgets.

New to Echo? Read [Getting the Most Out of Echo](getting-the-most-out-of-echo.md) first — it explains *why* these features help you learn. This manual explains *how* everything works.

---

## Contents

1. [Getting Started](#1-getting-started)
2. [The Three Tabs](#2-the-three-tabs)
3. [Playback](#3-playback)
4. [Smart Rewind](#4-smart-rewind)
5. [Loop Modes](#5-loop-modes)
6. [Sleep Timer](#6-sleep-timer)
7. [Bookmarks](#7-bookmarks)
8. [The Study System (Flashcards & Review)](#8-the-study-system-flashcards--review)
9. [The Reader: EPUB](#9-the-reader-epub)
10. [Audio–Text Alignment](#10-audiotext-alignment)
11. [PDF Companion Documents](#11-pdf-companion-documents)
12. [The Playlist & Timeline](#12-the-playlist--timeline)
13. [Apple Watch](#13-apple-watch)
14. [Widgets & Control Center](#14-widgets--control-center)
15. [CarPlay](#15-carplay)
16. [Echo for Mac](#16-echo-for-mac)
17. [Settings Reference](#17-settings-reference)
18. [Transcription Tools (Power Users)](#18-transcription-tools-power-users)
19. [Privacy](#19-privacy)
20. [Troubleshooting & FAQ](#20-troubleshooting--faq)

---

## 1. Getting Started

### What Echo plays

Echo is a player for **DRM-free** audiobooks — files you own and can see in the Files app:

- **MP3 / M4A** — including folders of one-file-per-chapter rips
- **M4B** — with full embedded chapter parsing, including books split across multiple M4B files (chapters are aggregated automatically)
- **FLAC, AAC, AIFF, OGG, OPUS, WMA** — on Mac
- **EPUB** — as a synced companion text (see [The Reader](#9-the-reader-epub))
- **PDF** — as a synced companion document (see [PDF Companion Documents](#11-pdf-companion-documents))

Echo does not bypass DRM and cannot play protected Audible/Apple Books titles. Tools like Libation or OpenAudible can export books you own to open formats.

### Loading your first book

1. Put the audiobook in a folder — one folder per book is the happy path. iCloud Drive, "On My iPhone," third-party file providers: all work.
2. In Echo, choose **Load Folder** and select the book's folder.
3. Echo scans the folder, builds the chapter list, finds the cover art (embedded art, or a `cover.*` image in the folder), and picks up any EPUB or PDF sitting alongside the audio for automatic import.
4. Press play.

Echo remembers everything per book: position, speed, loop mode, and settings overrides. Reopen the app days later and it resumes exactly where you left off — with [Smart Rewind](#4-smart-rewind) backing up just enough to restore your context.

> **Offline tip (important for iCloud users):** long-press your audiobook folder in the Files app and choose **Keep Downloaded**. Otherwise iOS may evict the audio files to save space, and your book will need to re-download mid-commute.

### Cover art

Echo looks for artwork in this order: image embedded in the audio file → an image file in the book folder (prefers `cover.*`) → the Echo app icon as fallback. Artwork drives the player background, the watch complication thumbnail, and the dynamic accent color (see [Appearance](#17-settings-reference)).

---

## 2. The Three Tabs

| Tab | What it's for |
|---|---|
| **Now Playing** | The player: artwork, scrubber, transport controls, speed, sleep timer, bookmarks. |
| **Read** | The synced EPUB/PDF reader: read along, search, align, highlight, bookmark from text. |
| **Timeline** | Your study feed: chapters, bookmarks, flashcards, and aligned text in one scrollable history, plus the review queue and stats. |

A mini-player bar stays visible on the Timeline tab so transport controls are never more than one tap away.

---

## 3. Playback

### Transport controls

The Now Playing tab gives you five configurable transport buttons. Defaults: skip back, previous chapter, play/pause, next chapter, skip forward.

- **Skip durations** are configurable from 5–60 seconds, independently for forward and backward, and sync to the watch.
- **Long-press secondary actions:** each of the five buttons can carry a second action on long-press (e.g., long-press skip-forward for next chapter, long-press play for a bookmark). Configure under *Settings → Player Controls*.
- **Sections:** books with fine-grained chapter files (e.g., "Chapter 11. A", "Chapter 11. B") are automatically grouped into logical chapters. Next/Previous Section actions jump between the sub-sections; the scrubber shows a tick mark at each boundary and snaps to them with a haptic tap while dragging.

### Speed control — pitch-corrected

Echo plays from 0.5× to 2×+ with true pitch correction — voices stay natural at any speed (no chipmunks at 1.25×, no slow-motion growl at 0.8×).

- Set a **global default speed** in Settings.
- Each book remembers its **own speed** — your dense textbook can live at 1× while your familiar re-listen runs 1.5×.
- All displayed times (elapsed, remaining, chapter lengths) adjust to your current speed, so "20 minutes left" means real minutes.

### Volume boost

Quiet narrator? Enable **Volume Boost** for up to +9 dB of clean gain (configurable). Works independently of system volume.

### Audio behavior

- Playback pauses automatically when your headphones disconnect or the aux cable is pulled — no broadcasting to the room.
- Calls, alarms, and Siri interruptions pause playback and resume correctly afterward (and Echo won't auto-resume if *you* had paused first).
- Audio is configured as spoken-word audio system-wide, which improves routing and voice processing on every output.

---

## 4. Smart Rewind

Every time you press play after a pause, Echo rewinds first — proportionally to how long you were gone:

| You were away… | Echo rewinds (default) |
|---|---|
| Seconds (a quick interruption) | a few seconds |
| Minutes (delivered some mail, made coffee) | more |
| Hours–days (overnight, the weekend) | the most |

All three tiers are configurable under *Settings → Smart Rewind*. The rewind happens silently and automatically; you just press play and the story makes sense again.

This is Echo's signature feature: it makes interruption free. You never scrub backward hunting for the last sentence you remember.

---

## 5. Loop Modes

Echo's loop button cycles through:

- **Loop chapter** — repeat the current chapter until you turn it off. *The feature Echo was built for:* loop one chapter all day until you know it.
- **Loop playlist** — repeat the whole book/playlist.
- **Loop between bookmarks** — repeat the passage between consecutive bookmarks: drop one bookmark at the start of a key argument, one at the end, and drill exactly that stretch.
- **Off** — straight through.

Loop mode is remembered per book and is available on the watch and as a transport long-press action.

---

## 6. Sleep Timer

Set a countdown (with fade-out) or stop at chapter end. When it fires, Echo pauses — and notes the pause time, so tomorrow's Smart Rewind backs you up over whatever you drifted through. Start, stop, and toggle the sleep timer from the phone or directly from the watch.

---

## 7. Bookmarks

Bookmarks are Echo's capture tool — and they can carry far more than a timestamp.

### Creating bookmarks

- **Phone:** tap the bookmark button in the player (or a configured transport long-press).
- **Reader:** long-press any paragraph → **Save Bookmark** (the bookmark binds to that text *and* its audio moment).
- **Watch:** one (configurable) button on the remote. A quick-bookmark timeout lets you confirm or auto-save.
- **Siri:** dictate a bookmark hands-free — "Hey Siri…" while driving; the note arrives transcribed.
- **PDF:** long-press a page → bookmark with a screenshot of that page attached.

### What a bookmark can hold

| Element | Details |
|---|---|
| **Title & note** | Editable text; titles default to "Bookmark N". |
| **Voice memo** | Record your thought in the moment. Memos are volume-normalized so they match the narration level. |
| **Photo** | Attach from your photo library or camera — see below. |
| **PDF view state** | For PDF bookmarks: exact page, zoom, and scroll position restore on tap. |
| **Enabled/disabled** | Disabled bookmarks stay visible (grayed) but won't trigger inline playback. |

### Voice memos that play inline

With *Inline Voice Memos* enabled, when playback reaches a bookmark that has a memo, Echo ducks the narration and plays **your** voice — past-you annotating the book for present-you — then resumes the narrator. Toggle globally or per book.

### Photo bookmarks & dynamic artwork

Attach a photo to a bookmark and Echo makes it part of the listening experience: as playback passes the bookmark, the **player artwork switches to your photo** (and back to the cover afterward), on the phone, the watch, and the lock screen. Your photos become visual mileposts inside the book.

Why bother? Because your brain involuntarily memorizes *where you were* alongside *what you heard* — and a photo of the place re-triggers the passage. The full story is in [Getting the Most Out of Echo §1](getting-the-most-out-of-echo.md#1-photo-bookmarks--borrow-your-brains-sense-of-place).

> **Safety first:** never take photos while driving. Pick from your library later — a photo taken around that time and place works nearly as well as one taken in the moment.

### Managing bookmarks

- Bookmarks group under their book in the playlist, sortable and editable (rename, retime, re-record, swap photo).
- **Loop between bookmarks** uses them as loop fences (see [Loop Modes](#5-loop-modes)).
- **Export to Markdown:** share or archive a book's bookmarks — timestamps, notes, and deep links that reopen Echo at the exact second.
- Every bookmark can be promoted to a **flashcard** in one tap (see next section).

---

## 8. The Study System (Flashcards & Review)

Echo includes a complete spaced-repetition system (SRS) — think Anki, built into your audiobook player, with audio on the cards. *(New to spaced repetition? The [learning guide](getting-the-most-out-of-echo.md#2-the-study-system--spaced-repetition-explained-from-zero) explains it from zero.)*

### Creating cards

- **From the reader:** long-press a passage → **Create Flashcard**. The passage text seeds the card.
- **From a bookmark:** any bookmark — note, voice memo, photo and all — becomes a card.
- **From scratch:** in the Timeline tab.
- **Import a deck:** Anki-style JSON decks import with validation — bring your existing decks along.

Every card has a **front** (your prompt — write it as a question) and a **back** (the answer), and can carry:
- an **audio snippet** — the actual narrated clip from the book,
- a **photo** — e.g., the one from its source bookmark,
- a **trigger timing** — play this card *before* or *after* its audio moment during listening, or keep it manual-review-only.

### Inline recall during playback

Cards with a trigger timing surface as you listen: reach the moment in the book and Echo quizzes you on the related card — a micro-review in context. Cards set to *manual only* never interrupt playback.

### Daily Review

- Echo schedules every card with the **SM-2 algorithm** (the same scheduling family Anki uses): grade a card and its next appearance is computed from your history — tomorrow if you missed it, weeks out if it was easy.
- The **review queue** shows everything due today. Grade each card **Again / Hard / Good / Easy**.
- Cards with audio play their snippet — review with your ears.
- **Stats:** due count, reviewed-today, and total cards show on the Timeline tab's review module.
- **Notifications:** an optional daily local notification reminds you when cards are due. (Local = generated on your device; Echo has no servers.)

### Review on Apple Watch

The full review session runs hands-free on the watch: hear the card, think your answer, tap a grade. Perfect for the walk between mailboxes.

### Chapter Study Mode

For books you need to *master*, flip the whole book into a study deck:

1. **Set Up for Study** on a book: Echo skips front-matter (intro, copyright, acknowledgments) and creates one card per main chapter — or per section, when the book has section-level structure.
2. Listen to a chapter (loop it as much as you like). At the end, Echo asks for a grade: **Again** or **Easy**.
3. The chapter is now scheduled like any flashcard. When it comes due, it appears in your **study playlist** — open Study Mode and your due chapters *are* your listening queue.

Regular flashcards and chapter cards coexist: chapters teach the material; your hand-made cards pin down the details. And if you ignore the study system entirely, bookmarks are still just bookmarks — Echo never forces the workflow on you.

---

## 9. The Reader: EPUB

Add the EPUB alongside your audiobook and the **Read** tab becomes a full book reader, synchronized to the narration.

### Importing

Drop the `.epub` in the book's folder — Echo's auto-import scanner picks it up — or use **Import Document** in the playlist. Echo parses the book (safely — imports are copy-only and validated), extracts every paragraph, heading, and image, and stores them in its local database. Inline formatting (bold, italics), block quotes, and links are preserved.

### Reading

- The book renders as a clean feed of cards: chapter headers, paragraphs, images.
- **Follow the narration:** the active paragraph is highlighted and the feed auto-scrolls with playback. Scroll away to browse freely; auto-scroll politely disengages and a tap brings you back to the live position.
- **Tap to seek:** tap any paragraph to jump the audio to that exact text. Tap images to view full-screen.
- **Search:** full-text search with highlighted matches; tap a result to jump there — in text *and* in audio.
- **Table of contents:** the chapter picker navigates the book's structure; the sticky header shows your position as Part → Chapter → Section.
- **Highlights:** long-press → **Change Color** to tint passages — build your own color system.
- **Typography:** font size, line spacing, and card background are adjustable; **Lexend** and **OpenDyslexic** (dyslexia-friendly) fonts are built in.

### The reader toolbar

While the Read tab is active, the bottom toolbar switches to reader-optimized controls: skip back / play–pause / skip forward, timeline, and bookmark — so you can drive playback without leaving the text.

---

## 10. Audio–Text Alignment

Alignment is what binds the reader to the narration: every paragraph gets a timestamp. Echo builds this map for you and lets you correct it anywhere.

### Auto-Align (recommended)

Tap **Auto-Align Chapters** and Echo's on-device speech recognition (WhisperKit, running on the Neural Engine — *no audio ever leaves your device*) aligns the book in tiers:

| Tier | What it does |
|---|---|
| **0 — Title match** | Matches chapter titles to audio file/chapter names for instant coarse anchors. |
| **1 — Chapter snap** | Transcribes a short clip at each chapter boundary and fuzzy-matches it to the text, anchoring every chapter start/end. |
| **2 — Drift detection** | Spot-checks inside chapters to find passages drifting out of sync (narrators ad-lib; editions differ). |
| **3 — Drift repair** | Bisects flagged regions and inserts word-level correction anchors using token-based dynamic time warping. |

A progress view shows each tier working, with a debug log if you're curious. Between anchors, Echo interpolates positions weighted by paragraph word counts — long paragraphs get proportionally more time.

**Continuous Alignment** (optional, in Settings) keeps refining in the background while you listen: Echo samples short windows of the audio it's already playing, transcribes them on-device, and drops new anchors as it confirms positions.

### Manual anchors

Reality is messy — narrators skip forewords and editions disagree. Fix any spot in seconds:

- Long-press a paragraph → **Align to Now** (or **Align to 5s Ago**) to lock it to the playhead.
- Heading cards offer **Align to Chapter Start/End** for bulk anchoring.
- Locked anchors show a green badge with their timestamp; interpolated text shows its estimated status.
- **Erase Anchor** removes one; **Reset Alignment** clears the book and starts fresh. Recalculation is instant.

---

## 11. PDF Companion Documents

Working from a PDF (slides, sheet music, a scanned textbook)? Import it like an EPUB — the Import button accepts both and routes automatically.

- The Read tab renders the PDF with continuous scroll and zoom.
- **Page-level alignment:** long-press a page → align it to the current audio. The **Manual Alignment sheet** gives you play/pause, ±5s skips, and a **scrubber joystick** — pull a little for slow precise scrubbing, more for fast travel, with live audio preview while you drag.
- **Page bookmarks:** bookmark a page and Echo stores a screenshot thumbnail plus your exact page, zoom, and scroll position — tapping the bookmark restores the view precisely.

---

## 12. The Playlist & Timeline

### Playlist

- Chapters list in playback order with duration and progress; logical chapters expand to show their sections.
- **Drag to reorder** when filenames sort badly.
- **Tap to dim** a chapter to skip it ("this is the LibriVox disclaimer track") — dimmed chapters are skipped by playback and loops.
- Hierarchical titles render nested structure (Part 1 → Chapter 1 → Section A) with visual indentation.
- Playlist edits persist per book, and a portable manifest file keeps your ordering if you move the folder between devices.

### Timeline

The Timeline tab is your study history as a feed: chapters, bookmarks (with photos and memo indicators), flashcards, and aligned text excerpts, in book order. It's where the review module lives (due cards, stats, streaks) and the fastest place to skim everything you've captured from a book. **Freeze** the timeline while browsing so it stops following playback, then sync-and-resume when ready.

---

## 13. Apple Watch

Echo's watch app is a full remote — designed so you *never* need the phone in your hand (or out of the aux cable).

### The remote

- **Up to 25 buttons**: five pages of five slots, every slot user-assignable: play/pause, skip forward/back (5–60s, configurable), next/previous chapter, next/previous section, loop mode, speed, sleep timer, bookmark, Pomodoro — or empty. Empty pages hide automatically.
- **Design it from the phone:** drag-and-drop the layout in *Settings → Watch App*; it syncs to the wrist instantly.
- **Digital Crown:** assign to volume or scrubbing (with a deadzone so a brushed crown doesn't jump your position).
- **Big targets:** buttons are sized to hit without looking — gloves, rain, walking.

### On-wrist features

- **Now playing screen** with full-screen artwork (or the classic compact layout) — including photo-bookmark artwork switching, and a tap-for-fullscreen cover viewer.
- **Bookmarks with voice memos**, recorded on the wrist, delivered reliably to the phone.
- **Hands-free flashcard review** — full Daily Review sessions on the watch.
- **Pomodoro timer** — hours/minutes/seconds wheels, a fat progress ring, persistent alarm. Lives right in the button grid.
- **Sleep timer** start/stop, speed cycling, loop control.
- **Complication:** current book thumbnail + progress ring on your watch face; tap to open the remote. The optional date overlay puts the day/date on the player screen (handy when the player *is* your watch face all day).

### Reliability

State syncs via durable application context — the watch picks up the truth the moment it wakes, even after a weekend off-wrist, and stale commands are never replayed (no phantom pauses or position jumps). If watch and phone disagree, the watch asks the phone for the authoritative position and converges.

---

## 14. Widgets & Control Center

- **Lock Screen / Home Screen widget:** current book thumbnail with a progress ring.
- **Play/pause from the widget** without opening the app (App Intents).
- **Control Center:** a toggle-playback control.

---

## 15. CarPlay

Echo appears in CarPlay with a browse list and remote transport commands — play, pause, skip — through the car's interface. (CarPlay is intentionally minimal for now; richer templates are on the roadmap.)

No CarPlay in your car (Echo's creator doesn't have it either)? That's what the watch remote and aux cable are for. Echo's whole design assumes the phone stays in your pocket.

---

## 16. Echo for Mac

The Mac companion app:

- **Three-pane layout:** bookmarks sidebar, player with transport + speed controls, document pane.
- Plays the same folders (broadest format support, including FLAC/OGG/OPUS).
- **EPUB alignment** with streaming on-device transcription — point it at a book and watch alignment build in real time.
- **Transcript pane** with live highlighting and search; word-cloud visualization of any book's vocabulary.
- Bookmarks share the same format as iOS and live in the shared app-group store.

---

## 17. Settings Reference

| Group | Settings |
|---|---|
| **Playback** | Default speed · per-book speed memory · volume boost gain · seek forward/back durations (5–60s) |
| **Smart Rewind** | Three tiers (short/medium/long pause) with per-tier rewind amounts |
| **Bookmarks** | Inline voice memo playback (global + per book) · quick-bookmark timeout |
| **Study** | Daily review notification · inline flashcard triggers · Chapter Study Mode setup |
| **Reader** | Font (incl. Lexend, OpenDyslexic) · text size · line spacing · card tint · per-card colors |
| **Appearance** | Theme accent color or **Artwork mode** (accent derived from the cover, automatically adjusted for legibility — never unreadable-yellow-on-white) · dark mode · app icon (multiple designs) · player layout (Default/Compact) · transport button sizes |
| **Player Controls** | Five tap actions + five long-press actions for the transport row |
| **Watch App** | Button layout designer (5 pages × 5 slots) · Digital Crown mode · artwork layout · haptics · date overlay · title scroll speed |
| **Per-book overrides** | Speed, font, volume boost, inline memos — any global setting, pinned per book |
| **Help** | The full in-app help library |
| **Language** | English and Dutch |

---

## 18. Transcription Tools (Power Users)

The Echo repository ships companion CLI tools (`Tools/`) for generating full transcripts of your audiobooks on your Mac:

- **Swift CLI** (WhisperKit): `transcribe` a file or `--dir` for batch folders; `align` an EPUB to produce an enhanced, timestamped transcript.
- **Python CLI** (OpenAI Whisper): same job, GPU-accelerated where available (`--device auto`).
- Output includes timestamped segments and word-frequency data (the Mac app renders these as word clouds).

These are optional — the iOS app's built-in alignment needs none of this — but lovely for archival transcripts of your library.

---

## 19. Privacy

The shortest section, because there's nothing to disclose:

- **No accounts. No analytics. No tracking. No ads. No servers.**
- Your books, bookmarks, photos, voice memos, flashcards, and reading history stay on your devices (and your personal iCloud, if you enable sync).
- Speech recognition for alignment runs **entirely on-device**. Audio never leaves your hardware.
- The app is **open source (MIT)** — you can read every line: [github.com/dfakkeldy/Echo](https://github.com/dfakkeldy/Echo).

---

## 20. Troubleshooting & FAQ

**My book won't play / chapters are missing.**
Check the files exist locally (see the *Keep Downloaded* tip in [Getting Started](#1-getting-started)). For multi-file books, confirm the files sort correctly by name — and remember you can drag-reorder in the playlist.

**The reader text doesn't match the narration.**
Different editions drift. Run **Auto-Align Chapters** first; for stubborn spots, long-press the paragraph you're *hearing* and tap **Align to Now**. Two or three manual anchors usually tame even a messy book.

**Auto-alignment is slow or warm on my phone.**
The first run downloads and warms the on-device speech model, and transcription is real work for the Neural Engine. Plug in for the first full-book alignment of a long book; afterward, incremental repairs are quick.

**The watch shows a stale book/position.**
Raise the watch and give it a beat — it requests authoritative state from the phone on wake. Both devices on, same Wi-Fi/Bluetooth, helps. (The sync layer was specifically hardened against stale-state replays.)

**Voice memos are quiet/loud.**
Memos are volume-normalized on save; very old memos can be re-recorded from the bookmark editor.

**Inline flashcards interrupt me too much.**
Set those cards to *manual only*, or disable inline triggers in Settings → Study. Your reviews then live only in Daily Review.

**Where are my files? Can I get my data out?**
Your audio stays where you put it (Echo reads in place). Echo's own data lives in a local SQL database; bookmarks export to Markdown, and the open-source schema means your data is never hostage.

**Does Echo work fully offline?**
Yes — playback, reading, alignment, flashcards, everything. The only network use is your own iCloud file syncing.

**Can it play my Audible books?**
Not while they're DRM-locked. Echo plays open formats only.

---

*Echo is open source under the MIT license. Found a bug, or want a feature? [Open an issue](https://github.com/dfakkeldy/Echo/issues) — the developer reads every one.*
