# Echo User Manual

The reference for Echo on iPhone, iPad, Apple Watch, and Mac.

**Reviewed against `nightly`, October 24, 2026.** This guide describes the current source. TestFlight tracks can contain older builds; check your build's What to Test notes. Planned work is labelled explicitly. Start with [the learning guide](getting-the-most-out-of-echo.md) for the thinking behind the study tools.

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
10. [Notes and Watch Inbox](#10-notes-and-watch-inbox)
11. [The Reader: EPUB](#11-the-reader-epub)
12. [Audio–Text Alignment](#12-audiotext-alignment)
13. [PDF Companion Documents](#13-pdf-companion-documents)
14. [Insights](#14-insights)
15. [Context Memory](#15-context-memory-location)
16. [Exports & Your Data](#16-exports--your-data)
17. [Playlist & Study Library](#17-playlist--study-library)
18. [Apple Watch](#18-apple-watch)
19. [Widgets & System Controls](#19-widgets--system-controls)
20. [Echo for Mac](#20-echo-for-mac)
21. [Sync & iCloud](#21-sync--icloud)
22. [Settings Reference](#22-settings-reference)
23. [Command-Line Tools](#23-command-line-tools)
24. [Privacy](#24-privacy)
25. [Troubleshooting](#25-troubleshooting)
26. [On-Device Narration](#26-on-device-narration)
27. [Articles & Anthologies](#27-articles--anthologies)

## 1. Getting Started

### What Echo plays

Echo plays **DRM-free files** you own: MP3, M4A, and M4B, including folders of tracks and multi-file M4B books. The Mac also handles additional audio formats through its import/conversion path. Echo cannot play protected Audible or Apple Books downloads.

You can add an **EPUB or PDF** as companion reading material, or narrate a text-only **EPUB, PDF, Markdown (`.md`, `.markdown`), or plain-text (`.txt`)** document on-device. A scanned PDF needs usable text or a matching read-along file for narration; importing an image-only scan does not supply OCR.

### Loading your first book

1. Put the audio files in one folder per book. Add a companion EPUB/PDF and a cover image if you have them.
2. Choose **Load Folder** and select that book's folder, or use the document import action for a standalone document.
3. Let Echo scan the folder and import the companion text.
4. Press Play. Echo saves a resume position and per-book playback settings.

On iPhone/iPad, the Library's Books shelf shows books you have **started listening to**, with related editions grouped under one cover. An unplayed import or companion document stays stored without creating another shelf cover. The Mac sidebar shows the full imported catalog.

### From an Audiobookshelf server

On iPhone/iPad, open **Settings → Library & Accounts → Connections**. On Mac, use the Audiobookshelf connection controls in Settings. Add your server, browse or filter its library, and download a book. Imports show downloading, extraction, validation, and adding progress; open the book after it reports Added. Failed imports can be retried.

Both platforms support multiple saved servers and exchange progress for server-linked books. Echo downloads books for local playback; **Audiobookshelf streaming is planned**. Do not switch apps expecting progress to transfer until the server has received it.

### Cover art

Echo uses embedded audio artwork, a cover image in the folder, or its app icon as a fallback. Artwork also informs the player theme and Watch thumbnail.

## 2. Organizing Your Library

### One folder per book

```text
Audiobooks/
├── A book title/
│   ├── A book title.m4b
│   ├── A book title.epub
│   └── cover.jpg
└── Another book/
    ├── 01 - Introduction.mp3
    ├── 02 - Chapter one.mp3
    └── companion.pdf
```

Keep companion documents beside the audio. Zero-pad track numbers so `02` sorts before `10`. Rename and organize files before first loading them; moving them later may require selecting the folder again.

### iCloud Drive and local storage

In Files or Finder, use **Keep Downloaded** before offline listening. A cloud icon can mean the file is visible but its audio bytes are not local. “On My iPhone” storage stays local to that device. Third-party file providers work through the system picker; download behavior depends on the provider.

Echo reads folder-backed audio in place. Document imports, generated narration, extracted images, and Audiobookshelf downloads also use managed local storage. The local database holds progress, cards, notes, and alignment records. Sharing the source folder through iCloud Drive does **not** sync that database.

Use Library actions to relocate missing files or remove stale entries. Keep backups of source files and export study material before removing a book.

## 3. The Three Tabs

The iPhone/iPad app has **Now Playing**, **Read & Study**, and **Library**. The reader and bottom dock keep playback, speed, bookmarks, notes, and Mark Passage close to the text. Study dashboards and Stats provide review queues, decks, and listening history.

Mac uses a Library/table-of-contents sidebar, reader/player workspace, and a resizable Notes pane. Watch is an iPhone companion rather than an independent audiobook library.

## 4. Playback

Play/pause, skip, chapter and section navigation, speed, and volume controls operate on the current book. Book settings can override defaults. Configure the phone controls at **Settings → Controls → Phone Player Settings**; controls can have different tap and long-press actions.

**Settings → Now Playing → Playback Defaults** contains default speed, skip behavior, and Smart Rewind. Speed uses pitch correction; displayed remaining times account for playback speed. Volume boost can help quiet recordings, but the output still depends on your headphones and system volume.

The optional **Experimental Player Layout** lives under Now Playing settings. It offers movable playback controls; the reader retains its own dock. Focus soundscapes and visualizers are optional listening tools, not a prerequisite for study.

## 5. Smart Rewind

After a pause, Echo can back up before resuming. Tune the pause thresholds and rewind amounts at **Settings → Now Playing → Playback Defaults → Smart Rewind**. A short interruption and an overnight break can use different amounts. Per-book overrides let you adapt a dense textbook without changing every book.

## 6. Loop Modes

Loop the playlist, a chapter, or a passage between bookmarks. Chapter looping repeats the current chapter; bookmark looping needs usable start and end boundaries. If the loop action is unavailable, check that a book and the required boundaries are loaded.

Use ordinary chapter looping for repeated listening. Study Plans separately schedule chapter assignments; they do not require keeping the player in a loop.

## 7. Sleep Timer

Choose a duration or an end-of-chapter stop from the player controls. Timer options include a fade. The Watch also exposes sleep-timer controls. Smart Rewind can restore context at the next listening session.

## 8. Bookmarks

Save a timestamp from playback, the reader, Watch, or supported Siri actions. Add a text note, photo, or voice memo where the platform offers it. Photo bookmarks can replace player artwork around their timestamp. Voice memos can play inline when **Play Bookmarks Inline** is enabled.

Use the bookmark editor to change a note or recording. A plain bookmark is a saved moment; Mark Passage is a separate capture for making a study card later. Local bookmarks are not automatically a cross-device iCloud study library.

## 9. The Study System (Flashcards & Review)

### Capture, then make a card

Tap **Mark Passage** on the phone or Watch without stopping the book. Open **Card Inbox** later, choose a mark, edit the question/answer and audio context, and save a card or dismiss the mark. You can also create cards from reader passages and bookmarks.

Cards can carry text, audio snippets, images, deck assignment, and tags. The deck browser shows card and due counts; its editor supports changes to existing cards. Review all due work or focus on a deck. Grade your recall with **Again / Hard / Good / Easy**; FSRS schedules the next review.

### Import and export

**Settings → Study & Notes → Import Deck** accepts Echo-compatible JSON or a folder containing a `.echo-deck.json` manifest and media. It does **not** directly accept Anki `.apkg` archives. An `.apkg` importer exists in the backend, but the current phone picker does not expose it; a direct archive-import workflow remains unfinished.

Mac has an **Anki export** surface for `.apkg` and an optional AnkiConnect route to a running local Anki installation. Those export actions are separate from the phone's JSON importer.

### Study Plans and generated cards

For EPUB-backed books, open **Book Settings → Study Plan**. Choose chapters, a release cadence, and optional image cards. Due reviews precede new assignments; after grading, FSRS controls the next due date. The global new-chapter cap is in **Settings → Study & Notes**. Some deeper hands-free chapter-review interactions remain unfinished.

AI card generation starts on iPhone/iPad under **Settings → Study & Notes → AI Card Generation**. Options include Apple on-device generation on supported hardware, a deterministic fallback, or an external service you configure. External generation sends source text to that service. Review generated cards before accepting them; an API key is not needed for ordinary manual cards.

## 10. Notes and Watch Inbox

Use **Add Note** in the reader/player tools to save text against the current book and position. Mac's Notes pane supports creating, editing, and deleting per-book notes. Voice memo bookmarks provide a separate audio capture path.

**Watch Inbox** captures a general thought through native dictation, including when no book is open. Set it up on iPhone at **Settings → Controls → Watch App Settings → Watch Inbox** with your HTTPS webhook URL and bare bearer key. Add Inbox to an existing Watch layout if needed.

Finish dictation with Done or the supported double-tap gesture. Echo queues the capture and returns to listening. An open book adds title and position context. A success haptic means the Watch saved it; the phone retains delivery work until the webhook accepts it. Setup shows queued captures and last acceptance. Endpoint acceptance does not establish that a recipient read or acted on the message.

Watch Inbox is separate from local book notes. The older proposed unified “Brain Dump” inbox with note-to-card promotion is not a description of the current UI.

## 11. The Reader: EPUB

Import a standalone EPUB or place it beside the audiobook. The reader preserves paragraphs, headings, images, links, inline formatting, and code blocks.

- Follow the highlighted paragraph and word while audio plays; scroll away to browse and return to live reading.
- Tap aligned text to seek. Search phrases and use the table of contents to navigate.
- Long-press passages for alignment, highlights, notes, or study actions.
- Adjust type size, spacing, and reader appearance. **Lexend** and **OpenDyslexic** are bundled choices.
- Use the inline speed presets and bottom dock without leaving Read & Study.

**Visual Listening** brings figures and code onto the player stage with read-along text in its own scrolling area. A figure stays until the next figure, or chapter end; consecutive figures share available time in reading order. Timing depends on the book's alignment.

## 12. Audio–Text Alignment

### Auto-Align

Run **Auto-Align Chapters** for an audiobook with companion text. The pipeline starts with chapter-title matching, then uses on-device speech recognition and text matching to create or refine anchors. Drift checks and repairs improve timing between chapter boundaries. Model assets may need an initial download; inference runs locally.

Continuous alignment can refine timing during playback. A new automatic run replaces its previous automatic anchors; manual anchors remain a separate source. Alignment quality depends on matching editions and the recording.

### Manual anchors

Long-press a paragraph and choose **Align to Now** or **Align to 5s Ago**. Heading actions can align a chapter start/end. Erase an individual anchor or reset alignment when needed. Save a useful manual correction before running further checks.

An audio-only book can also be transcribed on-device for a searchable read-along without a companion ebook. Transcription can mishear names; it is not the original published text.

## 13. PDF Companion Documents

PDFs can accompany audio or supply text for on-device narration. On iPhone/iPad, use page view or reflow text; page view supports scrolling, zoom, word following, and vocabulary actions where text mapping is available. Mac also has a PDF page reader with read-along. An image-only scan does not gain text automatically.

For manual page alignment, long-press a page and use the alignment sheet's playback controls and scrubber joystick. Page bookmarks retain page/zoom/scroll context.

A publisher can place **`Title.readalong.json` beside `Title.pdf`** before import. When valid, it supplies the narration order and exact printed word boxes, avoiding spoken running headers and page numbers. The importer validates the format, page count, optional PDF hash, words, and rectangles. Reimport after changing either source. Without a matching file, Echo uses ordinary PDF text extraction and search-based highlighting.

On Mac, **Batch → Narrate Documents…** accepts PDF as well as EPUB and text files. The [authoring contract](../pdf-readalong-authoring.md) documents the sidecar format.

## 14. Insights

On iPhone/iPad, open Stats and per-book statistics for listening totals, active days, speed trends, time-of-day patterns, chapter coverage, and study history. Review charts include grade distribution, retention history, and a due forecast when enough data exists. The values come from local listening/review records; an empty history produces little to chart.

The current Mac has Daily Review and study tools, but does not reproduce every phone Insights chart. Avoid treating missing local history or a platform difference as evidence that data synced.

## 15. Context Memory (Location)

Opt in on iPhone at **Settings → Advanced & Privacy → Advanced → Context Memory**. Echo can attach approximate place context to new bookmarks. Automatic session/chapter place capture remains planned. Capturing a bookmark does not wait for location.

Use **Delete Context Memory** in the same settings to remove captured places. Session location history stays on-device. Full private-iCloud bookmark/study sync and a Places map are planned; do not assume location chips travel to another installation.

## 16. Exports & Your Data

| Export | Current behavior |
|---|---|
| Chaptered `.m4b` | Export imported or generated narration with metadata, cover, and chapter markers from the phone's player menu or Mac File menu. MP3 export is planned. |
| Bookmark Markdown | Export timestamped notes and links back into Echo. |
| Study notes | Export study material using the current book or bulk export surfaces. Check the selected export's media options. |
| Auto-export Markdown (Echo Pro on iPhone/iPad) | One updated Markdown file per book in a selected folder. Text includes notes, bookmarks, and flashcards; photos, voice memos, card media, and location data stay in Echo. |
| Anki export (Mac) | `.apkg` file or optional AnkiConnect handoff. |

Enable **Auto-Export Study Notes** at **Settings → Study & Notes**, then choose an export folder. Echo manages an `Echo Study Notes` subfolder. A disconnected folder can require selecting it again. An export is a copy for use in another tool, not live two-way study sync.

## 17. Playlist & Study Library

The playlist shows tracks, chapters, and sections. Change order or disable tracks that should not play. Narrated books show a chapter outline; excluding a chapter prevents narration without deleting already rendered audio.

The Study Library provides decks, Card Inbox, review queues, and study plans. Opening a companion document does not by itself start a listening session or place the book on the phone's listened-books shelf.

## 18. Apple Watch

Watch controls playback on the paired iPhone. Customize up to **five pages of five actions** at **Settings → Controls → Watch App Settings**. Available actions include playback, skips, chapters, sections, loop, speed, sleep timer, bookmark, Mark Passage, Inbox, and Pomodoro. Empty pages hide.

Choose volume or scrubbing for the Digital Crown. Watch also supports voice-memo bookmarks and study review. The Watch exchanges state and queued actions with the phone; it does not replace the phone with standalone file playback. Keep the phone app and Watch app on compatible builds.

## 19. Widgets & System Controls

The current **Echo Widget target is watchOS-only**. It provides circular watch-face and rectangular Smart Stack/complication families with artwork and progress. Availability and color treatment depend on the watch face and WidgetKit rendering mode.

iPhone Lock Screen playback comes from system Now Playing integration. The source contains an iOS Control Widget implementation behind a platform gate, but the current extension target does not ship an iPhone Home/Lock Screen widget or Control Center extension. Do not look for those in the iPhone widget gallery.

## 20. Echo for Mac

Mac includes a local Library, chapter navigation, player, reader, resizable Notes pane, Card Inbox, Daily Review, and Anki export. Audiobookshelf browse/download/progress sync and multiple saved servers are available. The document batch queue imports, transcribes, aligns, or narrates supported documents and can export chaptered M4B files.

Open **Batch → Narrate Documents…** (⌘⌥N) for EPUB/PDF/Markdown/text narration; use Settings (⌘,) for preferences. Mac applies its persisted font/theme choices. Not every phone study chart, AI-generation entry point, or location feature has Mac parity.

The current Mac does not expose Echo Pro purchase/restore UI or enforce the phone's narration/flashcard caps.

## 21. Sync & iCloud

These are different mechanisms:

- **Source files:** iCloud Drive or another file provider can carry books between devices. Download files before going offline.
- **Audiobookshelf:** connected books exchange listening progress with their selected server on iPhone/iPad and Mac.
- **Article Inbox:** article captures and anthology drafts have a private CloudKit sync path. This is separate from the ordinary study database.
- **Community alignment lookup:** import may request matching anchors from Apple's public CloudKit database. There may be no match; local alignment is available. Public alignment uploads are unavailable in Echo 1.0.
- **Watch:** WatchConnectivity carries companion state/actions and capture delivery through the paired phone.
- **Planned:** automatic private-iCloud sync of all flashcards, decks, bookmarks, and playback state across independent Echo installations.

A shared Apple ID or a book appearing in iCloud Drive does not prove study-state transfer. Use exports when you need a portable copy of notes or cards.

## 22. Settings Reference

Phone settings are grouped by intent:

| Group | Main controls |
|---|---|
| Now Playing | Playback Defaults, Smart Rewind, speed/skip behavior, experimental player |
| Appearance | Color scheme, icon, accent, font, Reader Defaults |
| Controls | Phone Player Settings, Watch App Settings, Watch Inbox |
| Library & Accounts | Connections, Echo Pro |
| Study & Notes | AI Card Generation, Import Deck, global new-chapter cap, study-note exports |
| Advanced & Privacy | Advanced, pronunciation/alignment options, Context Memory, diagnostics |
| Support & About | Feedback & Support, Help, privacy, version/commit |

On iPhone/iPad, Echo Pro is a **one-time unlock**. Core import, playback, and reading are free; free narration covers one chapter per book and flashcards are capped at 20. The current Mac behavior differs as described above. Prices and purchase availability come from StoreKit.

## 23. Command-Line Tools

The active **`echo-cli`** can narrate documents, export audiobooks, build study decks, inspect/verify sidecars, and run narration QA. Contributors should build it with **`make echo-cli`**, which applies required Release compiler settings. Run `echo-cli --help` and each command's help for the current arguments. On this project's shared Mac, run Apple builds/tests through the configured build-slot wrapper.

`Tools/transcription_generator.py` is an optional Python transcript tool using faster-whisper. Set up its dependencies from `Tools/requirements.txt`; it is separate from the app's built-in WhisperKit alignment. See [the architecture reference](../../ARCHITECTURE.md#tools--pipeline) and [renderer guide](versioned-echo-renderer.md) for developer workflows.

## 24. Privacy

Local playback, narration inference, and alignment process files on-device without an Echo account. Initial model downloads, Audiobookshelf, community alignment lookup, optional external AI, Article Inbox sync, and a configured Watch Inbox webhook use network services with different data handling.

External AI sends selected book text to your configured provider. Watch Inbox sends dictated text and available book context to your endpoint. These are optional connections; local inference does not imply every feature is offline.

Read [the privacy policy](../privacy.html) for permissions, optional transfers, and deletion controls. Echo is [open source under GPL-3.0](https://github.com/dfakkeldy/Echo).

## 25. Troubleshooting

**My book is missing from the phone shelf.** Start playback. The phone shelf uses listening history; unplayed imports stay stored. Check missing-file filters and select a moved folder again.

**A file is visible but will not play offline.** Check that the bytes are downloaded in Files/Finder. Use Keep Downloaded and finish Audiobookshelf imports before leaving the network.

**Text does not follow the right audio.** Check the edition, run Auto-Align, and add a manual anchor. Reimport older PDFs for page mapping or a newly added read-along sidecar.

**A PDF has no text to narrate.** An image-only scan needs a text-bearing source or an authored read-along file. Echo's ordinary PDF import is not OCR.

**Names sound wrong.** Use the pronunciation tools; EPUB authors can supply supported IPA/PLS metadata. Reimport after changing authored metadata. Kokoro and optional Phonon do not support identical pronunciation/timing features.

**My Watch capture is queued.** Open Watch Inbox setup on iPhone, check the destination and queued state, and use its recovery controls. Keep the bare key private. A saved haptic is different from webhook acceptance.

**Cards or bookmarks are absent on another device.** Shared source files do not carry the study database. Check the sync mechanisms above rather than resetting local data.

**How do I report a bug?** Use Settings → Support & About → Feedback & Support, TestFlight feedback, or [GitHub Issues](https://github.com/dfakkeldy/Echo/issues). Include build, platform, reproduction steps, and the observed result. Keep book content, credentials, and personal captures out of public reports.

## 26. On-Device Narration

Import a text-only document and use **Narrate**. The first selection can download model assets; later inference runs locally. Kokoro offers English voices and pronunciation controls. You can set chapter voice overrides, exclude chapters, and export the resulting audio as chaptered M4B.

**Phonon 31M** is an optional English engine on supported arm64 iPhone/iPad and Apple Silicon Mac builds. Its first use downloads and compiles a separate model bundle. It supplies paragraph alignment, rather than Kokoro's exact word timing and IPA/audit features. See [Phonon narration](../phonon-narration.md) for supported hardware, voices, and CLI behavior.

For authored EPUB pronunciation, see [the IPA/PLS guide](../epub-pronunciation-authoring.md). Changing a voice or pronunciation can require regenerating affected audio. Keep original source documents and separate outputs when comparing engines.

## 27. Articles & Anthologies

The Library's article tools collect article captures and let you assemble an ordered anthology for narration. Review captured text, clean it up, choose its order and chapter voices, and generate a book for the existing reader/player pipeline.

Article/anthology private-iCloud sync is separate from study-state sync. Source websites and any configured services have their own network behavior. Keep an original source link so you can revisit or correct a capture.
