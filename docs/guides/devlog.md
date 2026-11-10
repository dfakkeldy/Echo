# Building Echo — The Devlog

Echo started as a simple chapter-looping audiobook player in April 2026. Dan directs AI coding agents to build and maintain it, testing the results in daily listening. This log combines a dated commit digest with the original account of the first nine weeks.

The source is public: [github.com/dfakkeldy/Echo](https://github.com/dfakkeldy/Echo). “Shipped” in the generated digest means merged source, not App Store publication or a verified TestFlight upload.

---

<!-- AUTO-DEVLOG:START -->
## Automated update - Oct 24-Nov 10, 2026

*Generated from 21 commits merged in this date range.*

### Shipped
- Re-render only the edited blocks of a narrated book (#683) ([d4e182d](https://github.com/dfakkeldy/Echo/commit/d4e182d))

### Fixed
- 1.0.1 — keep Siri and Watch positions fresh during playback (#670) (#672) ([bf69ae8](https://github.com/dfakkeldy/Echo/commit/bf69ae8))
- Download an iCloud read-along file, and recover a PDF imported before it arrived ([bcb06db](https://github.com/dfakkeldy/Echo/commit/bcb06db))

### Build, docs, and housekeeping
- Merge gate caller on main, where pull_request_target starts (#675) ([e429822](https://github.com/dfakkeldy/Echo/commit/e429822))
- Merge gate, a required check that holds stop-list PRs for Dan (#674) ([0caf7ae](https://github.com/dfakkeldy/Echo/commit/0caf7ae))
- Set nightly marketing version to 1.1 ([de27f43](https://github.com/dfakkeldy/Echo/commit/de27f43))
- Add the verified 1.0.x patch route ([3b59d10](https://github.com/dfakkeldy/Echo/commit/3b59d10))
- Reframe v1.1 tracks around the shipped App Store 1.0 ([2dab29c](https://github.com/dfakkeldy/Echo/commit/2dab29c))
- Cite PR #664 instead of a branch-local commit ([242cfba](https://github.com/dfakkeldy/Echo/commit/242cfba))
- Bound published, not delivered, Watch position freshness ([3984a73](https://github.com/dfakkeldy/Echo/commit/3984a73))
- Fix shifted ROADMAP range ([bd476e8](https://github.com/dfakkeldy/Echo/commit/bd476e8))
- ...and 9 more housekeeping items.

<!-- AUTO-DEVLOG:END -->

## November 10, 2026 — reader and playback updates

Nightly now uses a continuous reader (#669), a simpler play button (#668), consistent chapter labels (#666), clearer player/Watch timer labels (#667), and refreshed iPhone screens (#673). Siri and Watch published positions stay fresh during playback (#670); delivery still depends on the receiving surface. These are source changes, not release receipts. The generated digest above groups conventional commit subjects and counts source commits, including back-merges.

## October 24, 2026 — source snapshot

Since the summer, the source has gained Audiobookshelf on Mac, PDF batch narration, article/anthology workflows, authored EPUB pronunciation, optional Phonon narration, and Watch Inbox dictation with queued-delivery recovery. The latest PDF read-along files carry narration order and exact word boxes; Visual Listening keeps figures visible while the full read-along text scrolls separately.

The [manual](user-manual.md) describes today's reachable workflows and platform differences. Full private-iCloud study-state sync, parts of hands-free Chapter Study, and some Mac parity remain incomplete. Merged code, hosted CI, a distributed build, and observed device behavior are separate milestones.

## The opening nine weeks — historical account

The entries below describe the original April–June build period. Their dates, counts, and development snapshots are retained as history; use the current manual for availability.

---

## Week 1 — April 19 · *The two-hour app* (10 commits)

It started with a problem, not a plan. No audiobook app on the internet would loop a single chapter, survive constant interruptions, and play at 1.25× without chipmunk-voicing the narrator. After one Sunday spent directing an AI coding agent: a working player that loaded a folder from iCloud, looped chapters, and played speed-corrected audio. By the end of the day it had background-persistence so it would still be ready to play after a long pause — the first brick of what became Smart Rewind.

Then the repo went quiet for ten days while daily use showed what was missing.

---

## Week 2 — April 27 – May 3 · *The watch appears* (20 commits)

The project got a name (BookLoop — it wouldn't survive), and got serious: a playlist editor with a virtual chapter queue, disabled-chapter skipping, persistent progress and per-book speed memory. Then the line that changed the app's shape: *"feat: Add Apple Watch app with Connectivity, Haptics, and Glassmorphism UI."* One day later the watch had widgets and App Intents; by week's end the complication showed the current book's thumbnail with live progress. The phone could finally stay plugged into the aux cable, in the user's pocket, all day.

---

## Week 3 — May 4 – 10 · *Bookmarks learn to talk* (48 commits)

The week of the signature features. **Smart Rewind** grew its three tiers — seconds, minutes, hours — so every interruption length got a proportional rewind. **Voice memo bookmarks** landed, including the detail that still surprises people: memos *play back inline* when the narration reaches them. Then bookmarks reached the watch, learned to **loop between bookmarks**, and got volume normalization.

Also this week: an Appearance menu with **OpenDyslexic and Lexend** fonts (the accessibility thread starts here, not as an afterthought), a sleep timer, the MIT relicense — and the first macOS app. Honesty corner: this was also the week the build broke more than once, as three Xcode targets were consolidated into one project. It got fixed. The git history keeps the scars.

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

And at week's end: *"chore: Rebrand Orbit Audiobooks to **Echo**"* — new name, alternate app icons, and the "For Every Mind" positioning, with the infinity-symbol icon in silver and gold as a nod to the neurodivergent community Echo is built for.

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

Nine working weeks. Three platforms (iPhone and iPad, Apple Watch, Mac) plus widgets. A SQL database, an on-device ML alignment pipeline, an on-device neural text-to-speech narrator, a spaced-repetition system, and an EPUB/PDF reader — built on nights and weekends by Dan, whose background is GIS and estimating work, directing AI coding agents.

The point of publishing this log isn't bragging rights. It's the same as open-sourcing the code: you should be able to see exactly what you're trusting with your books and your attention — and maybe, if you've been wondering whether you could build *your* app, this page is the nudge.

*Last reviewed November 10, 2026. The generated digest covers merged source through this review.*
