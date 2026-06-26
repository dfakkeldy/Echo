# Building Echo — The Devlog

Echo went from "I wonder if I could make an iOS app" to a four-platform audiobook study system — with on-device AI narration — in about nine weeks. This is the week-by-week story, reconstructed from the actual git history — **956 commits** between April 19 and June 19, 2026, written by a mail carrier with no prior Swift experience, in the hours around a full-time delivery route.

It's all open source. You can audit every claim below: [github.com/dfakkeldy/Echo](https://github.com/dfakkeldy/Echo).

---

## Now — June 2026 · *The road to 1.0* (in progress)

Most of the 1.0 program has now landed, build by build: the **listening capture layer** and the **Insights screen** (real listening time, streaks, chapter coverage, retention curves), opt-in **Context Memory** (place-tagged bookmarks and sessions), the full **Anki workflow** (decks, a card editor, the mark-later Card Inbox, Markdown and JSON export), and — the headline of the last two weeks — **on-device AI narration** that reads a text-only EPUB aloud in a neural voice, entirely offline. Echo also went **GPL-3.0**. What's left for 1.0: **Brain Dump notes** with watch dictation, deeper **Markdown second-brain export**, **Audiobookshelf sync**, and **iCloud study sync** — planned the same way everything else here was built: in public.

---

## Week 1 — April 19 · *The two-hour app* (10 commits)

It started with a problem, not a plan. No audiobook app on the internet would loop a single chapter, survive thirty interruptions a shift, and play at 1.25× without chipmunk-voicing the narrator. One Sunday of vibe-coding later: a working player that loaded a folder from iCloud, looped chapters, and played speed-corrected audio. By the end of the day it had background-persistence so it would still be ready to play after a long pause — the first brick of what became Smart Rewind.

Then the repo went quiet for ten days. (Day job. Also: using the thing every day on the route, finding out what was missing.)

---

## Week 2 — April 27 – May 3 · *The watch appears* (20 commits)

The project got a name (BookLoop — it wouldn't survive), and got serious: a playlist editor with a virtual chapter queue, disabled-chapter skipping, persistent progress and per-book speed memory. Then the line that changed the app's shape: *"feat: Add Apple Watch app with Connectivity, Haptics, and Glassmorphism UI."* One day later the watch had widgets and App Intents; by week's end the complication showed the current book's thumbnail with live progress. The phone could finally stay plugged into the aux cable, in the user's pocket, all shift.

---

## Week 3 — May 4 – 10 · *Bookmarks learn to talk* (48 commits)

The week of the signature features. **Smart Rewind** grew its three tiers — seconds, minutes, hours — so every interruption length got a proportional rewind. **Voice memo bookmarks** landed, including the detail that still surprises people: memos *play back inline* when the narration reaches them. Then bookmarks reached the watch, learned to **loop between bookmarks**, and got volume normalization.

Also this week: an Appearance menu with **OpenDyslexic and Lexend** fonts (the accessibility thread starts here, not as an afterthought), a sleep timer, the MIT relicense — and the first macOS app. Honesty corner: this is also the week of commits literally titled *"broke some stuff"*, *"broken"*, and *"stuck on computing dependencies"* ×2, as three Xcode targets were forcibly consolidated into one project. It got fixed. The git history keeps the scars.

---

## Week 4 — May 11 – 17 · *The study player thesis* (92 commits)

The week Echo decided what it was. **Whisper transcription** arrived via a Mac generator and Python/Swift CLIs — audiobooks became *text* you could search and sync-scroll on the phone. **Picture bookmarks** landed, with the player artwork dynamically switching to your photo as playback passes it (the context-dependent-memory feature, before we knew to call it that). Siri-dictated bookmarks, Markdown export, and deep links rounded out capture.

Under the hood, the foundation work began in earnest: the AVPlayer backend was replaced with **AVAudioEngine** (volume boost, pitch-true speed), the 2,900-line PlayerModel "god class" started its decomposition into focused services, settings were centralized, fastlane + App Store metadata appeared, and the app got **Dutch localization**, in-app **help files**, and a full accessibility pass (labels, Dynamic Type). Five planning docs for an Anki-style SRS were committed — next week they'd become real.

---

## Week 5 — May 18 – 24 · *The big bang* (132 commits)

The busiest week of the project's opening stretch, and it reads like a different app shipped every day:

- **A real database.** GRDB/SQLite foundation with migrations, DAOs, and tests — bookmarks and everything after now had a durable home.
- **The Anki system.** SM-2 daily review, inline flashcard recall during playback, audio snippet cards, JSON deck import, and hands-free **flashcard review on the watch**.
- **The EPUB alignment pipeline** — a Swift CLI that unpacks an EPUB, parses the spine, and fuzzy-aligns transcribed audio to text with Levenshtein matching. The hardest problem in the app, started properly, with tests.
- **V1 EPUB timeline core** — `epub_block` and `alignment_anchor` tables, an import service, manual anchors with interpolation: the seed of the Read tab.
- Plus: tab navigation, multi-file **M4B support**, a CarPlay prototype now deferred for entitlement approval, a portable playlist manifest, a Twitter-style unified timeline feed — and this very **GitHub Pages site** with the privacy policy.

---

## Week 6 — May 25 – 31 · *Stabilize, audit, rebrand* (81 commits)

A maturity week. A systematic roadmap appeared and got executed: concurrency safety (`@MainActor`, Sendable), crash elimination, silent-failure remediation, database integrity, accessibility polish — then a comprehensive code audit that surfaced **55 findings**, all resolved within days. The SRS gained review stats and daily notifications.

Two headliners: the **EPUB Reader Feed** shipped — the dedicated Read tab with card-based rendering, full-text search with highlighting, per-passage colors, TOC, and auto-scroll that follows the narration. And **WhisperKit auto-alignment** arrived: on-device speech recognition snapping chapter boundaries, detecting drift, and repairing it automatically. The "align an entire audiobook to its EPUB with one tap" dream became a feature.

And at week's end: *"chore: Rebrand Orbit Audiobooks to **Echo**"* — new name, alternate app icons, and the "For Every Mind" positioning, with the infinity-symbol icon in silver and gold as a nod to the AuDHD community the app was built from.

---

## Week 7 — June 1 – 7 · *Word-level precision + PDF* (18 commits)

Fewer commits, bigger ones. **TokenDTW** replaced the earlier silence-mapping approach: word-level dynamic-time-warping alignment for drift repair, later optimized from ~125 MB peak memory to ~25 MB with a sliding two-row algorithm. The EPUB parser was unified across platforms and learned to preserve inline formatting (bold, italics, links, images) in the database. Tier 0 title matching made coarse alignment instant.

The reader grew up too: **PDF companion documents** shipped — page-level alignment, a manual-alignment sheet with a spring-loaded **scrubber joystick**, and page-screenshot bookmarks. The Now Playing screen was redesigned around full-bleed artwork, and accent colors started deriving from the cover art itself.

---

## Week 8 — June 8 – 14 · *Polish, then the study system lands* (210 commits)

The week opened on polish with a safety net: a **watch connectivity overhaul** (durable application-context sync; stale transport commands can no longer replay and phantom-pause you), pause-on-headphone-disconnect, a **Pomodoro timer** on the watch with a persistent alarm, a fullscreen cover-art viewer, and a configurable date overlay. The engineering flourish: the **accent contrast safety pipeline** — artwork-derived theme colors now pass WCAG/CIELAB legibility gates, with a three-stage rescue ladder (nudge the hue → re-pick a safe hue → fall back to brand tint) so no album cover can ever make the UI unreadable. Plus a zip-slip path-traversal security fix in EPUB extraction.

Then, mid-week, the study system the "road to 1.0" had promised actually shipped. The **Insights screen** arrived — a Swift Charts dashboard over a new stats aggregation layer (listening time, streaks, chapter coverage, retention trends), built pure-functions-first with its own tests. **Context Memory** landed as opt-in location capture wired into bookmarks. The **Anki workflow** filled out: deck support, a card editor, the mark-later **Card Inbox**, and Markdown study-notes plus JSON deck export. A battery-drain audit pulled the always-on CADisplayLink, halved timer ticks, and made the FFT visualizer reuse its setup. And quietly, the first bricks of the next big thing went in: a **TTSEngine** seam, a curated voice catalog, synthesized alignment anchors, and a Kokoro CoreML inference spike — the foundation for on-device narration.

---

## Week 9 — June 15 – 19 · *The voice arrives* (345 commits)

The single biggest week in the project's history, and it had one headline: **on-device AI narration**. Point Echo at a text-only EPUB and it reads the book aloud in a neural voice — the **Kokoro** TTS model running entirely on device, no account, no cloud, no audio leaving the phone. The architecture is *render-then-play*: each chapter is synthesized to a lossless cache and then played back, so there are none of the streaming hitches that plague live-TTS readers, and the result survives backgrounding and scrubbing like any other audiobook. The reader gained **word-by-word karaoke highlighting** driven by the synthesizer's own word timings, and a **pronunciation dictionary** so you can teach it names and jargon with your own IPA.

Getting there meant a hard week of audio engineering: killing an encoder whine, fixing a Kokoro/BNNS crash by chunking the input, gating to A15+ where the older Neural Engine traps, and — by week's end — swapping in a **fixed-shape Kokoro pipeline** with lexicon-only grapheme-to-phoneme conversion that dropped a heavy MLX dependency so the whole thing builds and unit-tests cleanly. The UI now shows one-time model download and compile progress so the first render doesn't look frozen.

Around the headline, a lot else shipped. The **macOS app** got a BookPlayer-style redesign — a chapter-navigation bar, volume boost, a real Settings scene, a playback-options popover — plus an **overnight batch queue** that can align *or* narrate a whole folder of EPUBs while you sleep, then export real **M4B files with chapter markers**. iOS got an **Echo Pro** entitlement model with a free-tier gate and paywall, per-tab **NavigationStacks** with deep links and restored state, and an Audiobookshelf data-layer foundation. The website grew a **glossary** with accessible inline popovers. And the licensing changed for good: Echo is now **GPL-3.0**, with SPDX headers across every source file.

---

## The shape of the thing

Nine working weeks. Four platforms (iOS, watchOS, macOS, widgets). A SQL database, an on-device ML alignment pipeline, an on-device neural text-to-speech narrator, a spaced-repetition system, and an EPUB/PDF reader — built nights-and-weekends around a mail route, by someone whose previous programming experience was "some Python scripts for GIS and a Visual Basic call logger in high school."

The point of publishing this log isn't bragging rights. It's the same as open-sourcing the code: you should be able to see exactly what you're trusting with your books and your attention — and maybe, if you've been wondering whether you could build *your* app, this page is the nudge.

*The devlog updates roughly weekly, generated from the real commit history.*
