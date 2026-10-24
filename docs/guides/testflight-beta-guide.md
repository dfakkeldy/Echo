# The Echo Beta Tester Guide

Use Echo with a book you actually want to hear. This guide covers access, supported devices, useful feedback, and current source limitations.

**Reviewed October 24, 2026 against Nightly source.** A feature in the repository may be newer than the TestFlight build you receive. Your build's **What to Test** notes are the guide to that build.

## 1. Getting access

Request an invitation at [testflight@kinnokilabs.com](mailto:testflight@kinnokilabs.com?subject=Echo%20beta%20access), or through [GitHub Issues](https://github.com/dfakkeldy/Echo/issues). Mention the platforms you use; do not post your email address or private book files in a public issue.

Nightly is the integration track; Weekly is the promoted beta track. TestFlight access, build processing, and external eligibility are separate from a PR merging. An invitation does not promise a particular source revision is available yet.

## 2. Requirements

- **iPhone/iPad:** iOS/iPadOS 18 or newer.
- **Apple Watch:** watchOS 11 or newer, paired with an iPhone running Echo. Watch is a companion remote, not an independent file player.
- **Mac:** macOS 15 or newer. Optional Phonon narration has a separate arm64/Apple Silicon requirement.
- **A book:** DRM-free audio, a supported text document to narrate, or a connected Audiobookshelf server.

Alignment and narration may download models on first use. Longer books need local storage and processing time. Download your audio before offline listening. A scanned PDF needs usable text or an authored read-along file; ordinary PDF import does not add OCR.

## 3. Install and update

Install Apple's **TestFlight**, open your invitation on the target device, and accept/install Echo. For Watch, check the iPhone's Watch app if the companion does not install automatically. Update the phone and Watch together.

Read **What to Test** before updating. TestFlight builds expire after 90 days; keep source files and exported study material backed up. Do not remove an older installation just to resolve a symptom without preserving its local data first.

Core import, playback, and reading are free. On iPhone/iPad, free narration covers one chapter per book and flashcards are capped at 20; **Echo Pro is a one-time unlock**. TestFlight purchases use Apple's sandbox. The current Mac has no purchase/restore UI and does not apply those phone caps.

## 4. Feedback that helps

TestFlight screenshot feedback attaches device/build information. For a reproducible issue, [GitHub Issues](https://github.com/dfakkeldy/Echo/issues) or **Settings → Support & About → Feedback & Support** provides a trackable route.

Include:

- Platform, OS, and Echo build/commit where available.
- What you did, what you expected, and what happened.
- For reading/alignment: source format, edition, narrator, chapter, approximate timestamp, and whether Auto-Align or manual anchors were used.
- For narration: voice/engine, document format, and whether it is a first render or cached audio.
- For Watch Inbox: whether it is queued or accepted. Keep endpoint credentials and dictated text private.

Report the outcome you observed. A Watch haptic proves local saving, an import's Added state proves a completed local import, and a webhook acceptance proves endpoint acceptance; none establishes what a downstream person did.

## 5. Areas to explore

These are optional ways to focus feedback. You do not need to complete a test checklist to use the beta.

### Everyday listening

Try interruptions, Smart Rewind, a chapter loop, and a sleep timer with your normal book. Include the audio route if playback or resume fails. On iPhone/iPad, a book enters the Books shelf after listening starts; an unplayed import or companion document stays stored without adding a cover. Mac shows the imported catalog.

### Reading and Visual Listening

Try a matching EPUB or text-bearing PDF, Auto-Align, search, tap-to-seek, and a manual correction. The PDF reader has page/reflow support on iPhone/iPad and page read-along on Mac. A valid `.readalong.json` beside a PDF supplies authored narration order and exact word boxes. Reimport to pick up a newly supplied sidecar.

Figures stay on the Visual Listening stage until the next figure or chapter end. Read-along text scrolls separately. If either behaves incorrectly, include the chapter and seek position.

### Capture and study

Mark a passage on phone or Watch and open Card Inbox later. Make or edit a card, assign a deck, review it, and check local Stats. Study Plans can schedule EPUB chapter assignments. The broader hands-free chapter-study workflow is still partial.

The phone's deck importer takes Echo JSON or a deck folder. Anki archive import has a backend but no current phone picker entry; do not expect an `.apkg` archive to appear in that picker. Mac offers Anki export/AnkiConnect.

### Watch Inbox

Configure **Settings → Controls → Watch App Settings → Watch Inbox** on iPhone, then use the Watch's Inbox action. A book is optional. Check the queued count and last acceptance in setup if delivery does not finish. Native dictation is separate from local book notes.

### Narration and exports

Narrate an EPUB, PDF, Markdown, or text file. On Mac use **Batch → Narrate Documents…** (⌘⌥N), including a folder of supported EPUB/PDF documents. Kokoro and optional Phonon have different pronunciation and timing features. Export chaptered `.m4b` audio or study notes if useful to your workflow.

### Audiobookshelf

Connect through the phone's **Settings → Library & Accounts → Connections** or Mac's Audiobookshelf settings. Browse/sort/filter, download, then open the verified local import. A failed import should remain named and retryable. Playback is download-based, not streaming. Check server receipt before assuming progress reached another client.

### AI cards and accessibility

AI card generation starts on iPhone/iPad at **Settings → Study & Notes → AI Card Generation**. Available routes include on-device generation on supported hardware, a deterministic fallback, or a configured external provider. External generation sends book text to that service; Auto may use it once configured. Mac preferences do not imply a Mac generation entry point.

Choose Lexend or OpenDyslexic, adjust type size/spacing, and use VoiceOver or Reduce Motion if those fit your normal use. Tell us about a control you cannot reach, identify, or read.

## 6. Current limitations

- **Study-state sync remains incomplete.** iCloud Drive carries source files; Article Inbox has its own private sync; import can look up community alignment markers. These do not sync all ordinary cards, decks, bookmarks, or playback across installations.
- **Audiobookshelf** requires completed local downloads. Streaming and fully resumable background transfers remain deferred; Mac multi-file progress differs from the phone's book-time axis.
- **Platform parity varies.** Mac has Daily Review and Card Inbox, but not every phone Insights chart, location feature, or AI-generation action. The Echo Widget target ships on Watch; iPhone playback controls use system Now Playing.
- **Models and editions matter.** First-use downloads/processing take time. Different ebook/audio editions can need manual alignment. Phonon offers paragraph alignment rather than Kokoro's word timing and IPA/audit support.
- **Full private-iCloud study sync, a unified Brain Dump inbox, and the direct phone Anki archive import workflow remain unfinished.** The [manual](user-manual.md) describes usable alternatives.

A new failure is still worth reporting even if it falls in one of these areas. Avoid resetting local data to diagnose it.

## 7. Privacy during the beta

Core book import, local playback, reading, and voice synthesis run on-device without an Echo account. You can connect Echo to your own Audiobookshelf server to browse and play your library. External AI features send text to the provider you configure. When network access is permitted, importing a book may look up matching public alignment markers, with local fallback for an ordinary lookup failure. Model downloads and files you choose in iCloud also use network services. This 1.0 release does not expose public-alignment uploads. These connections are optional; they are not needed for local playback and reading.

A configured Watch Inbox sends captured text and available book context to your endpoint. Article captures and anthology drafts have a private CloudKit sync path. These optional connections are separate from local inference.

Apple's TestFlight shares crash reports and feedback you choose to send with the developer, including device/OS/build information. That is TestFlight's mechanism. Read [the privacy policy](../privacy.html) for Echo's optional services and deletion controls.
