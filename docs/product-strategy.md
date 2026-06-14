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

To launch a polished, highly stable product by **August 1, 2026**, the boundary between in-scope features and post-1.0 roadmap items is strictly defined:

### In-Scope for 1.0 (WS0 - WS8)
*   **Listening Capture Layer:** Durably recording playback events and durations on-device to accumulate statistics.
*   **On-Device Auto-Alignment:** Snapping chapter offsets, detecting drift, and applying TokenDTW word-level alignment entirely on-device (WhisperKit/CoreML).
*   **Synced EPUB/PDF Reader:** Highlight-scrolling EPUB passages, PDF companion alignment with scrubber joystick, and page screenshot bookmarks.
*   **Intermittent Attention Aids:** Proportional 3-tier Smart Rewind (seconds, minutes, hours) and chapter/bookmark looping.
*   **Memory Bookmarks:** Inline voice memo playbacks and photo bookmarks that switch player artwork.
*   **Anki Core & SRS:** SM-2 spaced repetition scheduling, card editor, card inbox, deck/tag management, and genuine `.apkg` deck import with history.
*   **Brain Dump & Notes:** Watch dictation notes inbox for leaky working memory.
*   **Export:** Per-book Markdown study bundles (notes, bookmarks, cards, audio clips, photos) for Obsidian, Logseq, and Notion.
*   **iCloud Study Sync:** Core playback position, flashcards, decks, and bookmarks synced across iOS, watchOS, and macOS.

### Out-of-Scope (Post-1.0 Roadmap)
*   **FSRS Scheduling:** Integrating the Free Spaced Repetition Scheduler.
*   **AnkiConnect:** Syncing directly to local Anki desktop servers.
*   **On-device AI Drafting:** Prompting local LLMs to write flashcard questions from aligned text.
*   **CarPlay Capture:** Adding dedicated dictate/mark buttons to the CarPlay dashboard.
*   **Advanced Mac Parity:** Brining the full aligned reader experience from iOS to macOS (currently Mac is a functional core player only).
*   **Focus Soundscapes:** Generating background noise masks to block external distractions during study.
