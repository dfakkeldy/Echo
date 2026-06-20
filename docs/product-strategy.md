# Echo Product Strategy: V1 Scope & Aha! Moment

This document outlines the product scope boundaries for **Echo 1.0** and defines the core user experience milestones that validate the app's value proposition.

---

## 1. Defining the "Aha!" Moment

The "Aha!" moment for an Echo user occurs during the transition from passive listening to active, integrated learning:

> **The Moment:** A user is listening to an audiobook while walking or commuting, hears a critical concept, and taps the Apple Watch or phone once to mark it. Later, when they open the app to study, they see that marked passage already transcribed and aligned inside their EPUB/PDF reader. With one tap, they convert that mark into a spaced-repetition flashcard (featuring the narrator's voice snippet) and successfully review it on their watch during their next commute.

### Key Retrieval Cues:
*   **Tactile Capture:** Marking a timestamp hands-free via watchOS complications or simple headphones media triggers.
*   **Unified Medium:** Visualizing the audio timeline mapped directly onto book text.
*   **The Spacing Effect:** Seamlessly graduating captured notes into daily study review without leaving the listening flow.

---

## 2. Echo 1.0 Feature Scope

**Launch is gate-driven (ship-when-green), not calendar-dated.** The fixed **August 1, 2026** target was retired on 2026-06-19 when 1.0 was re-scoped to hold for a deep, defensible study moat (see [`superpowers/specs/2026-06-19-roadmap-rebuild-design.md`](superpowers/specs/2026-06-19-roadmap-rebuild-design.md) and `../ROADMAP.md`). The boundary between in-scope and post-1.0 is now organized as **six competitive wedges**:

### In-Scope for 1.0 (the six wedges — deeper than the original WS0–WS8 cut)
*   **Listening Capture Layer:** Durably recording playback events and durations on-device to accumulate statistics.
*   **On-Device Auto-Alignment:** Snapping chapter offsets, detecting drift, and applying TokenDTW word-level alignment entirely on-device (WhisperKit/CoreML).
*   **Synced EPUB/PDF Reader:** Highlight-scrolling EPUB passages, PDF companion alignment with scrubber joystick, and page screenshot bookmarks.
*   **Intermittent Attention Aids:** Proportional 3-tier Smart Rewind (seconds, minutes, hours) and chapter/bookmark looping.
*   **Memory Bookmarks:** Inline voice memo playbacks and photo bookmarks that switch player artwork.
*   **Anki Core & SRS:** **FSRS** *and* SM-2 scheduling, **Chapter Study Mode** (each chapter an Anki-style card — listen, grade Again/Good, one interleaved FSRS queue, per-book + global new-per-day limits), card editor, card inbox, deck/tag management, and genuine `.apkg` deck import **+ export** with history.
*   **Brain Dump & Notes:** Watch dictation notes inbox for leaky working memory.
*   **Export:** Per-book Markdown study bundles (notes, bookmarks, cards, audio clips, photos) for Obsidian, Logseq, and Notion.
*   **iCloud Study Sync:** Core playback position, flashcards, decks, and bookmarks synced across iOS, watchOS, and macOS.
*   **Deep Analytics / Insights:** On-device retention curves, coverage heatmaps, streaks, speed trends, grade distributions, and a 30-day review forecast *(pulled into 1.0)*.
*   **On-Device Narration (Kokoro):** Align *or* synthesize — narrate text-only EPUBs on-device when there's no audiobook; chaptered `.m4b` export.
*   **Full Audiobookshelf:** Connect a self-hosted ABS server, browse, background download-to-local (alignment/flashcards then fire unchanged), optional progress sync *(pulled into 1.0)*.
*   **Full macOS Parity:** The complete study layer (flashcard creation, FSRS/Chapter-Study review, Card Inbox, deep Insights) on Mac — a **full peer**, not a "functional core" — plus the batch transcribe/align/narrate pipeline.

### Out-of-Scope (Post-1.0 Roadmap)
*   **AnkiConnect:** Syncing directly to local Anki desktop servers.
*   **On-device AI Drafting:** Prompting local LLMs to write flashcard *question* cards from chapter content (distinct from Chapter Study Mode, which generates no Q&A).
*   **CarPlay Capture:** Adding dedicated dictate/mark buttons to the CarPlay dashboard.
*   **Photo-of-a-page → audio jump · multi-voice narration · Audiobookshelf streaming** (see `../ROADMAP.md`).
*   **Focus Soundscapes:** Generating background noise masks to block external distractions during study.

> **Moved into 1.0 (2026-06-19):** FSRS scheduling and Advanced Mac Parity were *out-of-scope* in the original cut; the deep-moat re-scope pulled both **into** 1.0 (see In-Scope above).
