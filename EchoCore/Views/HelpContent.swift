import Foundation

struct HelpSection: Identifiable {
    let id: String
    let title: String
    let body: String
}

enum HelpContent {
    static let sections: [HelpSection] = [
        HelpSection(
            id: "loading",
            title: "Loading Books",
            body: """
            Tap the folder icon in the top-left corner to open the file picker. You can select a single audio file or an entire folder.

            Supported formats: MP3, M4A, and M4B.

            When you select a folder, all supported audio files inside are added to your playlist in alphabetical order. Chapter markers embedded in M4B and M4A files are automatically detected and used for chapter navigation.

            Artwork is discovered automatically — the app looks for embedded cover art, then for an image file named "cover" (any image format) in the same folder. If nothing is found, the app icon is used as a fallback.

            If a .transcript.json file with the same name as your audio file is in the same folder, it is loaded automatically and available as a scrolling transcript overlay.

            Your last opened book is restored automatically when you relaunch the app.

            **Keeping files available offline:** Files stored in iCloud Drive or other cloud services may be automatically removed from your device to free up space. To ensure your audiobooks are always available:

            • In the Files app, long-press the folder containing your audiobooks and select "Keep Downloaded." This pins the files to your device so they never get evicted.
            • For the most reliable experience, store your audiobooks in an "On My iPhone" / "On My iPad" folder rather than iCloud Drive. These folders are always local and never subject to cloud eviction.

            If you open Echo and your book doesn't resume, check that your files are still downloaded in the Files app.
            """
        ),
        HelpSection(
            id: "playback",
            title: "Playback Controls",
            body: """
            The transport bar has five buttons:

            • Previous — Jump to the previous chapter or track.
            • Skip Back 30s — Rewind 30 seconds (respects chapter boundaries).
            • Play / Pause — Start or pause playback.
            • Skip Forward 30s — Jump ahead 30 seconds.
            • Next — Jump to the next chapter or track.

            Each button can be configured with a Tap Action (primary) and a Long Press Action (secondary). Customize both in Settings > Phone Controls. Long-press a button for 0.5 seconds to trigger its secondary action with haptic feedback.

            Playback also works from the Lock Screen and Control Center. Use the system Now Playing controls to pause, play, or skip without opening the app.
            """
        ),
        HelpSection(
            id: "speed",
            title: "Playback Speed",
            body: """
            Tap the speed button in the bottom toolbar to cycle through playback speeds: 1.0×, 1.25×, 1.5×, 2.0×, and 3.0×.

            Your chosen speed is saved per book. When you come back to a book, it resumes at the speed you last used for it.

            The default speed for new books is 1.25×, but you can change this in Settings > Playback > Default Speed. This setting is overridden if you manually select a different speed for a specific book.
            """
        ),
        HelpSection(
            id: "volume-boost",
            title: "Volume Boost",
            body: """
            The volume boost toggle applies a +9 dB gain to the audio. This is useful for quiet recordings or listening in noisy environments.

            Tap the speaker icon in the bottom toolbar to toggle it on or off. When active, the icon shows filled sound waves.
            """
        ),
        HelpSection(
            id: "loop",
            title: "Loop Modes",
            body: """
            The loop button cycles through three modes:

            • Off — The playlist plays straight through from start to finish.
            • Chapter — The current chapter repeats. When it ends, it starts again from the beginning of the same chapter.
            • Bookmark — Loops between consecutive bookmarks. Playback jumps back to the previous bookmark when it reaches the next one. This mode is hidden when no bookmarks exist.

            Tap the infinity (∞) icon in the bottom toolbar to cycle modes. A filled icon means a loop mode is active.
            """
        ),
        HelpSection(
            id: "bookmarks",
            title: "Bookmarks",
            body: """
            Bookmarks let you save and annotate specific moments in your audiobook.

            Creating a bookmark: Tap the bookmark icon in the bottom toolbar while playing. This captures the current timestamp and opens the bookmark editor.

            Editing a bookmark: You can give it a title, adjust the timestamp with +/- 1 second buttons, add a text note, attach a photo from your library (picture bookmark), or record a voice memo.

            Picture bookmarks: When playback passes a bookmark with an attached image, that image temporarily replaces the album artwork on the player screen.

            Voice memos: Record audio notes attached to bookmarks. When "Play Bookmarks Inline" is enabled in Settings, voice memos play automatically as the audiobook reaches each bookmark's timestamp. During voice memo playback, the main player dims and a "Playing Voice Memo" badge appears.

            Bookmarks are stored as a portable .json file alongside your audiobook files. You can export bookmarks to Markdown — the exported file includes clickable links that open the audiobook at the exact timestamp.

            Manage bookmarks from the Playlist screen: reorder, edit, toggle on/off, or delete them.
            """
        ),
        HelpSection(
            id: "flashcards",
            title: "Flashcards & Daily Review",
            body: """
            Echo includes a built-in spaced repetition system (SRS) — Anki-style flashcards scheduled with the SM-2 algorithm, so each card comes back right before you'd forget it.

            Creating cards: Long-press a paragraph in the Reader and choose "Create Flashcard" (the text seeds the card), promote any bookmark to a card, or create one from scratch in the Timeline tab. Every card has a front (write it as a question) and a back (the answer), and can carry an audio snippet from the book.

            Trigger timing: Each card can surface at the beginning or end of its audio moment during playback — a quick quiz in context — or be set to manual-only so it never interrupts listening.

            Daily Review: Cards due today appear in the review queue. Grade each one Again, Hard, Good, or Easy — your grade determines when it returns (tomorrow if you missed it, weeks out if it was easy). Cards with audio play their snippet during review.

            Review on Apple Watch: Full hands-free review sessions run on the watch — hear the card, think your answer, tap a grade.

            Stats & reminders: The Timeline tab shows due count, reviewed-today, and total cards. Enable the daily review notification in Settings to get a local reminder when cards are due.

            Deck import: Anki-style JSON decks can be imported with validation, so existing decks come along.
            """
        ),
        HelpSection(
            id: "sleep-timer",
            title: "Sleep Timer",
            body: """
            The sleep timer stops playback after a set duration. Tap the moon icon in the bottom toolbar to choose a preset:

            • 15 minutes
            • 30 minutes
            • 45 minutes
            • 1 hour
            • End of Chapter — Stops when the current chapter finishes.

            When a timer is active, the remaining time appears next to the moon icon as a compact countdown. To cancel, open the menu again and tap "Off".
            """
        ),
        HelpSection(
            id: "smart-rewind",
            title: "Smart Rewind",
            body: """
            Smart Rewind automatically rewinds a few seconds when you resume playback after a pause. This helps you pick up where you left off without losing context.

            You can configure three tiers based on pause duration:

            • Short pauses (seconds) — A small rewind for brief interruptions.
            • Medium pauses (minutes) — A larger rewind when you've been away longer.
            • Long pauses (hours) — The largest rewind, or optionally jump to the start of the current chapter.

            Configure Smart Rewind in Settings > Smart Rewind. The feature is off by default. All automatic rewind amounts and the manual skip backward button respect chapter boundaries — you will never rewind past the start of the current chapter.
            """
        ),
        HelpSection(
            id: "epub-reader",
            title: "EPUB Reader & Search",
            body: """
            If you add an EPUB file alongside your audiobook (in the same folder, with the same name), the Reader tab becomes available. This turns your audiobook into a fully searchable, browsable book.

            **Automatic alignment:** When you first open an EPUB, the app automatically aligns each chapter to the corresponding audio chapter. Paragraphs are spaced proportionally within each chapter based on their word count — longer paragraphs get wider time ranges for more accurate estimates.

            **Auto-Align Chapters:** Long-press any card and choose "Auto-Align Chapters" to run the full 3-tier alignment pipeline using on-device speech recognition (WhisperKit + CoreML):

            • Tier 1 — Chapter Snap: The app transcribes short audio clips at each chapter boundary and fuzzy-matches the recognized text against your EPUB to anchor chapter start/end positions.
            • Tier 2 — Drift Detection: Each chapter's interpolated block positions are compared against the boundaries to flag chapters that have drifted out of alignment.
            • Tier 3 — Drift Repair: For misaligned chapters, TokenDTW (Dynamic Time Warping) aligns transcribed audio tokens against EPUB tokens at word-level precision and inserts correction anchors at the best-matching positions.

            A live log shows every match attempt so you can see exactly what's happening. Best run when you have a few minutes — it processes each chapter sequentially.

            **Manual alignment:** Long-press any paragraph card and choose "Align to Now" to lock that paragraph to the current playback position. This makes the alignment exact. The more paragraphs you lock, the more precise the alignment becomes. You can also use "Align to Chapter Start/End" on heading cards to match them to specific chapter boundaries. Locked-anchor cards show a green badge with the anchored timestamp.

            **Anchor management:** Long-press a locked-anchor card and choose "Erase Anchor" to remove a single anchor, or "Reset Alignment" to clear all anchors for the current book. Both automatically recalculate surrounding timestamps based on remaining anchors.

            **Search:** Pull down or tap the header to reveal the search bar. Type any phrase to instantly filter the entire book to matching paragraphs. Matching words are highlighted in yellow.

            **Table of Contents:** Tap the list icon in the reader header to browse the book's full table of contents. Tap any entry to jump to that section.

            **Auto-scroll:** The reader can follow playback automatically. When auto-scroll is on, the current paragraph highlights with a blue bar and the view scrolls to keep it centered. Scroll manually to pause auto-follow; tap the scroll-to-active button (↓) in the header to re-enable it.

            **Reader toolbar:** When the Reader tab is active, the bottom toolbar switches to reader-optimized controls: skip back, play/pause, skip forward (with your configured seek durations), timeline, and bookmark. This keeps essential playback controls at your fingertips while reading.

            **Card colors:** Long-press any card and choose "Change Color" to highlight it. Use this to color-code important passages, mark sections to revisit, or organize your study notes.

            **Bookmarks from text:** Long-press a paragraph and choose "Save Bookmark" to create a timestamped bookmark linked to that text. The bookmark's note is pre-filled with the first 200 characters of the paragraph.

            **Copy text:** Long-press and choose "Copy Text" to copy the paragraph to your clipboard.

            **Inline formatting & markers:** The reader preserves bold, italic, and underline formatting from the EPUB. Images, hyperlinks, blockquotes, and horizontal rules are detected and displayed in the reading feed.

            **Reader settings:** Tap the font size icon in the header to adjust font size, line spacing, and the default card background tint.
            """
        ),
        HelpSection(
            id: "pdf",
            title: "PDF Companion Documents",
            body: """
            PDFs work as companion documents too — slides, scanned textbooks, sheet music. The import button accepts both EPUB and PDF and routes automatically; the Reader tab shows the PDF with continuous scrolling and zoom.

            **Page alignment:** Long-press a page and choose "Align" to open the Manual Alignment sheet: play/pause, ±5 second skips, and a scrubber joystick — pull a little for slow, precise scrubbing, further for fast travel, with live audio preview while you drag. Confirm to lock the page to that audio position.

            **Page bookmarks:** Long-press a page and choose "Save Bookmark." Echo stores a screenshot thumbnail plus your exact page, zoom, and scroll position — tapping the bookmark later restores the view precisely.
            """
        ),
        HelpSection(
            id: "playlist",
            title: "Playlist",
            body: """
            The Playlist shows all chapters, tracks, and bookmarks in a unified chronological list. Use the filter chips at the top to show or hide chapters/tracks and bookmarks.

            Tap a chapter or track to jump to its position. Tap the eye button (or swipe left) to toggle an item on/off — disabled items appear dimmed and are skipped during playback. Tap "Reorder" (or "Edit" in standalone mode) to enter reorder mode with drag handles. Tap "Reset" to restore the original order and re-enable all items.

            Bookmarks appear inline at their timestamps. Tap a bookmark to jump to it. Swipe left to enable/disable, swipe right to edit or delete.
            """
        ),
        HelpSection(
            id: "watch",
            title: "Watch App",
            body: """
            The Apple Watch app works as a remote control for the iPhone player. Key features:

            • Up to five customizable Player Pages — Each page holds up to 5 action slots that you can configure from the iPhone Settings > Watch App screen. Swipe between pages to configure them. Empty pages are hidden on the watch.
            • Digital Crown — Configurable to control volume or scrub through the current track.
            • Quick Bookmarks — Hold the bookmark button to auto-create a bookmark after a configurable countdown (1–15 seconds). Great for hands-free bookmarking.
            • Progress Display — Choose between a circular progress ring and a linear progress bar. Each can show either chapter progress or total book progress.
            • Artwork — Two layouts: Full Face (immersive artwork) and Classic (small artwork with background). Backgrounds can be blurred artwork or solid black.
            • Word Cloud — A watch page showing the most frequent words from the current chapter.
            • Pomodoro Timer — A focus timer assignable to any button slot. Pick hours/minutes/seconds with the multi-wheel picker, watch the progress ring, and get a persistent alarm when time is up.
            • Flashcard Review — Run your Daily Review hands-free from the wrist (see Flashcards & Daily Review).
            • Fullscreen Artwork — Tap the album art on the player screen to view the cover fullscreen. An optional date overlay can show the day and date on the player.
            • Haptic feedback on button taps can be toggled in Settings.

            Configure all watch options from the iPhone app under Settings > Watch App.
            """
        ),
        HelpSection(
            id: "carplay",
            title: "CarPlay",
            body: """
            Echo appears in CarPlay with a browse list and transport controls — play, pause, and skip from the car's screen. Playback also responds to your car's steering-wheel and head-unit controls via the system Now Playing integration.

            CarPlay support is intentionally minimal for now; richer browsing is planned. No CarPlay in your car? Echo is designed so the Apple Watch remote covers the same job — the phone can stay in your pocket or on the aux cable.
            """
        ),
        HelpSection(
            id: "appearance",
            title: "Appearance & Settings",
            body: """
            Access Settings by tapping the gear icon in the top-right corner of the player.

            • Appearance — Toggle between dark and light mode. Choose from three fonts: Lexend (default, designed for readability), OpenDyslexic (optimized for readers with dyslexia), and the system font.

            • EPUB Reader — Add an EPUB file alongside your audiobook to unlock the searchable Reader tab with word-level alignment, Table of Contents, and card-based browsing.

            • Play Bookmarks Inline — When enabled, voice memos attached to bookmarks play automatically when the audiobook reaches that timestamp.
            """
        )
    ]
}
