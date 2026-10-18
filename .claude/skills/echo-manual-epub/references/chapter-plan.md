# Chapter plan, content sources, and the writer prompt

Everything the chapter-writer agents need that is specific to Echo. Read this in
full before fanning out the writers.

## Content sources (the fact-pack truth — read these fresh each rebuild)

The manual must reflect the app **as it is now**, so re-read these every rebuild
rather than trusting the last version's prose:

- `docs/guides/user-manual.md` — the canonical feature reference (the *how*). The
  spine of the manual; almost every chapter maps to one or more of its sections.
- `docs/guides/getting-the-most-out-of-echo.md` — the *why* (the learning science
  behind each feature). Source the one-breath "why this helps" notes from here.
- `ROADMAP.md` Part A (the six wedges, §A.1 narration, §A.2 Echo Pro) — what is
  shipped vs in-progress vs later. The authority on feature **status**.
- `docs/assets/*.png` (now_playing_mockup, read_tab_mockup, insights_mockup) —
  real reference for what a few screenshots should look like.

When a chapter touches the database, sync, or narration internals, you may skim
`ARCHITECTURE.md` for accuracy, but keep the prose user-facing.

## Status discipline (this is what keeps the manual honest)

The manual is written **as the current version** (e.g. v1.0): shipped features in
the present tense. But it is narrated, and emoji status tags can't be heard — so
every not-yet-shipped feature must be **spoken aloud** as either:
- "coming in version one-point-oh" (the `🚧` / in-active-development items), or
- "on the roadmap" / "on the roadmap for after launch" (the `🔭` post-1.0 items).

Pull each feature's status from the manual's status tags and ROADMAP Part A, and
put the right phrase in that chapter's fact pack so the writer says it. A listener
should never come away thinking an unshipped feature is available today. Convert
version numbers to spoken form ("version one-point-oh", not the digits).

## Throughlines (2–4 ideas that recur; weave where they fit, never force all in)

1. **On-device and private by default** — no servers, no accounts, no tracking;
   speech recognition (alignment) and narration both run on the user's own device.
2. **Built for the margins** — curb-cut design: made for interrupted lives and
   neurodivergent brains; the accommodation for the people who struggle most turns
   out better for everyone.
3. **Capture cheap, decide later** — a one-tap mark, bookmark, or memo now beats a
   perfect note that breaks your flow; sort it when switching costs nothing.
4. **Your data is yours, forever** — open formats, full export, open source under
   the GPL; even this manual is proof you can read your own words back out.

## Default chapter outline (16 chapters; adjust as the app changes)

Part One (chs 1–5) is the basics — after it a new user can use Echo. Parts Two–Four
are the nitty-gritty. Each chapter pairs one feature area with its real, named
components and the one-breath "why."

| # | Title | Grounded in (user-manual.md §) | Key status flags |
|---|-------|--------------------------------|------------------|
| 0 | Welcome to Echo | intro, three tabs, philosophy, "how to use this narrated manual" | — |
| 1 | Loading Your First Book | §1 formats, Load Folder, Audiobookshelf | onboarding 🚧; ABS Mac UI later |
| 2 | Organizing Your Library | §2 one-folder-per-book, Keep Downloaded | — |
| 3 | Playing a Book | §3 tabs, transport, speed, boost | Mark/Card Inbox 🚧 |
| 4 | Never Losing Your Place | §5 Smart Rewind, §7 Sleep Timer | — |
| 5 | Loops and Bookmarks | §6 loops, §8 bookmarks/memos/photos | place chips 🚧 |
| 6 | Reading Along | §11 reader, §13 PDF | reader speed controls 🚧 |
| 7 | Lining Up Words and Audio | §12 alignment (WhisperKit) | % aligned 🚧; **on-device-vs-cloud tradeoff** |
| 8 | Letting Echo Read to You | §1 markdown + ROADMAP §A.1 narration | streaming start 🔭; multi-voice 🔭; **render-then-play tradeoff** |
| 9 | Flashcards and Spaced Repetition | §9 study system, FSRS | Card Inbox/decks/.apkg 🚧; Chapter Study Mode 🔭 |
| 10 | Capturing Without Breaking Flow | §9 Card Inbox, §10 Brain Dump | **both 🚧 — flag clearly** |
| 11 | Seeing Yourself Learn | §14 Insights | Insights 🚧; Places map 🔭 |
| 12 | Your Data, Your Way | §16 exports, m4b | bundle/deck export 🚧; mp3/.apkg export 🔭 |
| 13 | Wrist, Car, and Lock Screen | §18 Watch, §19 widgets, §20 CarPlay | Mark/Dictate on watch 🚧; richer CarPlay 🔭 |
| 14 | Echo for Mac, Sync, and Context Memory | §21 Mac, §22 sync, §15 Context Memory | Mac study layer 🚧; study sync 🚧; Context Memory 🚧; **location tradeoff** |
| 15 | Privacy, Echo Pro, and What's Next | §25 privacy, §23 Pro, §26 FAQ + roadmap | paywall UX 🚧; roadmap items 🔭 |

Genuine tradeoffs to name **once, cleanly** (not a reflex every chapter): ch7
(on-device transcription vs uploading to a server), ch8 (render-then-play vs an
instant streaming start), ch14 (approximate/opt-in location vs precise always-on).

Real names the listener should come away able to search for: the Now Playing / Read
/ Timeline tabs, Load Folder, Keep Downloaded, Smart Rewind, Auto-Align Chapters,
WhisperKit, on-device narration / Kokoro / the default voice Ava, render-then-play,
the Card Inbox, Brain Dump, FSRS, Daily Review, Insights, the chaptered .m4b export,
Audiobookshelf, Echo Pro, Lexend and OpenDyslexic, the GPL license.

## The voice & rules block (give to EVERY writer agent verbatim)

THIS WILL BE NARRATED ALOUD by Echo, inside the app. Write 100% for the EAR.

NEVER READ CODE OR SYMBOLS ALOUD (absolute): no code, snippets, or syntax; don't
spell out camelCase or snake_case identifiers, operators, braces, arrows, or empty
parentheses. For any name that would narrate badly, say it in plain words and
explain the idea.

DO NAME THE REAL THINGS so the listener learns the vocabulary: name actual
features, screens, and files by their real, spoken-friendly names the way a
podcaster would ("the Now Playing screen", "a file called cover-dot-jpg", "the
Files app"), each glossed in one breath the first time. A plain dotted filename
spoken naturally is fine (an m4b file); never spell out programmer-style names.

EMPHASIS: say something matters once, plainly, then move on. Most paragraphs make
no claim about their own importance. Never use "tattoo this", "burn this in", "the
one rule if you remember nothing else", "the single most important", "the whole
point / show / game", "it changes everything", or anything in that family.

NUMBERS & FORM: say numbers and units like a narrator ("about forty megabytes",
"version one-point-oh", "up to nine decibels"). Define each piece of jargon in one
short breath. Flowing prose only — no bullet lists, no tables, and no headings
inside the chapter except the single title line.

VOICE: second person ("you"), patient, encouraging, a little wry — a smart friend
explaining over coffee, not a motivational speaker. Short, varied sentences.

SHAPE of each chapter: open with a hook (a small scene, a question, or a problem —
NOT "In this chapter we will"). Teach the concept plainly. Ground it in the real,
named component. Where the design genuinely gave up one thing for another, name
that tradeoff once and cleanly, then move on — only where the cost is real. Close
with two to four spoken sentences pointing ahead to what the listener can now do —
no heading, and without announcing it ("to sum up", "the takeaway").

MANUAL-SPECIFIC: address a real new user; be concrete and useful, not marketing.
Flag unreleased features aloud (see status discipline). Write NO image markup and
never say "see the image below" — figures are injected separately and the listener
may be hands-free, so the prose must stand alone (you may say where a thing appears
on screen).

## The writer-prompt template (one agent per chapter, in parallel batches of ~6)

For each chapter build a prompt = the voice & rules block above + throughlines +
the full title list (for continuity) + this chapter's beats and fact pack. The
fact pack is the accuracy backbone: 6–7 beats of ~450–600 words each, plus the
real names + status flags pulled from the content sources. Tell each agent:

> LENGTH: at least 2,700 words; aim 3,000–3,300. Earn it with vivid concrete
> explanation — never pad.
> OUTPUT: write plain spoken prose beginning with EXACTLY one heading line
> "## Chapter N — Title"; save with the Write tool to
> `<build>/chapters/chNN.md` (zero-padded); return a one-line status + word count.
> Final reminder: this is SPOKEN ALOUD by Echo. If a sentence would sound like
> reading code or symbols, rewrite it as natural English. No code, ever.

Use the Agent tool (one subagent per chapter), `model: sonnet` is a good
cost/quality fit for this bounded prose-writing. Dispatch in batches of about six.
Do NOT have writers place images — that is the injector's job.
