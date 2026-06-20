# Echo Marketing Plan

> Working document: what goes where, who we're talking to, and how the story gets told.
> Companion docs: [README.md](README.md) · [ROADMAP.md](ROADMAP.md) · website in [docs/](docs/)

---

## 1. Positioning

**One-liner (universal hook):** Echo is the audiobook player that helps you *remember* what you heard.

**Lead (study system — and you get alignment + narration in the box):** Echo turns the audiobooks you already own into a **spaced-repetition study system**. It **aligns your audiobook to your ebook** so you can read along on-device, **narrates ebooks that have no audiobook** (on-device neural TTS), and turns what you hear into flashcards — with the narrator's own voice attached — that you review on your phone or your wrist. Reading along is the *on-ramp*; remembering what you heard is the *point*.

**Longer:** Every other audiobook app is built for passive listening — play, pause, fall asleep. Echo is built for learning: chapter looping, smart rewind, voice and photo bookmarks, a synced EPUB/PDF reader, on-device alignment of real narration, on-device narration of text-only ebooks, and a built-in spaced-repetition study system — all designed around interrupted attention and backed by memory science.

### Reader vs. Study System (the 2026 competitive split — read this before writing copy)

The category got crowded in 2026. A wave of apps now **sync a real audiobook to your ebook on-device** — Voxlight (pre-launch), AudioBookSync, Continuum, TriBooks, Storyteller — and the megaplatforms shipped it too (Audible "Read & Listen", Spotify "Page Match", Kindle Immersion). **Audiobook↔text sync is now table stakes, not Echo's moat.** (Full teardown: [docs/competitor-analysis.md](docs/competitor-analysis.md) §6–8.)

So the line that matters is the **category split**:

> **Those apps are sync _readers_. Echo is a study _system_** — the only one that turns the read-along into spaced-repetition study (flashcards with the narrator's voice, reviewed on your watch), *and* the only one that still works when you own the ebook but **not** an audiobook (it narrates it for you).

The sharp competitor contrast, in one line: **"Other apps sync an audiobook and an ebook you already own. Echo studies them — and if there's no audiobook, it narrates the ebook for you."**

What this means for every surface:
- **Lead with the study system** (the uncontested moat) and the **neurodivergent-first / founder story** (the part a paywalled, closed-source, anonymous-dev reader structurally *cannot* tell).
- **Keep alignment + narration visible** as what's in the box — but as the *on-ramp* ("how the text gets in front of you"), never as the headline "no one else can do this" claim (false, and the alignment lead breaks the week Voxlight launches).
- **Never** write "only app that syncs real narration" / "no competitor aligns on-device." It's now false. Prefer *"today, no one else does all of this at once."*

### The audience question ("is it too focused on the neurodivergent?")

The answer is the **curb-cut effect**: curb cuts were designed for wheelchairs, but they help everyone pushing a stroller, pulling luggage, or riding a bike. Echo was designed for an AuDHD brain with an interrupted workday — and that design produces a better tool for *every* listener whose attention is interrupted, which is to say, every listener.

So the positioning is layered, not narrowed:

| Layer | Audience | Message |
|---|---|---|
| Core story | Neurodivergent learners (ADHD, AuDHD, dyslexia) | "Finally, an app that works the way your brain works." |
| Broad benefit | Students, professionals, lifelong learners | "Stop forgetting your audiobooks. Turn listening into knowledge." |
| Situational | Commuters, drivers, parents, tradespeople | "Built by a mail carrier who's in and out of the car 30 times a day. It survives interruption." |
| Niche-technical | DRM-free / Libation / LibriVox / Anki users | "Whispersync for the books you already own — on-device, with study built in. Anki, but audio-first." |

**Rule of thumb:** lead every surface with the *universal benefit* (remember what you hear), support it with the *neurodivergent-first origin* (credibility + differentiation), and close with the *technical depth* (alignment, SRS, watch) for the people who evaluate features.

### Holding the line against the "sync" crowd (2026)

A wave of indie apps now does on-device audiobook↔ebook **sync** — Voxlight, AudioBookSync, SyncBooks (see `docs/competitor-analysis.md` §7.11). They share Echo's privacy/on-device pitch and even similar landing pages, so **never lead with "sync your own files, on-device, private."** That's table stakes now — it camouflages Echo into the crowd.

Lead with the two tiers above them, which none of them reach:

1. **Word-level read-along** (true karaoke), not chapter-level snapping. The sync cohort matches *chapters*; Echo follows every *word*.
2. **Spaced-repetition study** — flashcards with auto-attached audio snippets, across iPhone/Watch/Mac. **No competitor has a study layer at all.**

Messaging rule: **sync is the bridge, study is the destination.** The defensible superlative is **"the only audiobook *study* player"** — *never* "the only app that aligns audio to text," which is no longer true (a reviewer will catch it; see `competitor-analysis.md` §6). The website carries this as the "Read-along is where most apps stop" depth-ladder section on `index.html`.

### How much of Dan's story to include

All of it — it is the single most differentiating asset Echo has. A 47-year-old mail carrier with no formal CS background, facing a layoff, who built a four-platform Apple app in two months because no app on the internet would loop a chapter — that is a story tech press, Reddit, and Apple editorial all respond to. People root for it, and it *proves* the app's thesis: it was built inside the exact interruption-heavy life it serves.

Where it appears, scaled to the surface:
- **Website:** full story section + link to the devlog ("watch it being built, week by week").
- **App Store description:** 3–4 sentence condensed origin story (already in place).
- **Press/Reddit pitches:** the story IS the pitch; the app is the proof.
- **Devlog:** the story in commit form — radical transparency, great for Hacker News.

---

## 2. What goes where

### Two web surfaces

Echo has two sites with distinct jobs:

- **kinnokilabs.com** (+ kinnokilabs.ca) — the *company* site and canonical product pages. App Store `marketing_url` → `/apps/echo`; `support_url` → `/echo-help` (real FAQs + email contact). Echo docs live at `/echo-learn`, `/echo-manual`, `/echo-devlog`, `/echo-beta`. Built with Swift Publish; `make publish` in `~/Developer/KinNoKiLabsSite` regenerates, commits, and pushes — Cloudflare Pages deploys on push.
- **dfakkeldy.github.io/Echo** — the *project* site for the open-source audience (GitHub Pages from `main:/docs`). Same content suite, OpenDyslexic-branded design. Linked from the README; the natural landing for Show HN / r/iOSProgramming traffic.

Content changes should land on both; kinnokilabs.com is the one App Store users see.

### Website content — the *why*

The website carries everything that needs room to breathe:

- **Home (`index.html`)** — hero promise, the story, feature grid organized by benefit, the science teaser, platform lineup, open-source + privacy trust signals, CTA (beta access).
- **Learn (`learn.html`)** — "Getting the Most Out of Echo": every feature explained alongside the memory science that makes it work. This doubles as shareable evergreen content — it earns links and Reddit posts on its own ("why taking a photo helps you remember an audiobook").
- **Manual (`manual.html`)** — the complete user manual. Reference depth; also a sales tool for feature-evaluators.
- **Devlog (`devlog.html`)** — weekly build summaries from the actual commit history. Build-in-public artifact and press kit in one.
- **Beta (`beta.html`)** — the TestFlight funnel: how to join, how to send useful feedback, six structured test plans, known limitations, beta privacy. Every "join the beta" CTA on the site lands here; when the public TestFlight link exists, it goes at the top of this page (one URL to update).
- **Privacy (`privacy.html`)** — short, absolute, plain language. Privacy is a feature.

### App Store listing — the *what*, in 10 seconds

- **Name (30 chars):** `Echo: Audiobook Study Player`
- **Subtitle (30 chars):** `For Every Mind`
- **Promotional text (170 chars):** rotating hook; updates without review. Lead with the newest benefit.
- **Description:** benefit-first bullets, condensed origin story, accessibility section. *Only shipped features* — App Review Guideline 2.3.1 requires metadata accuracy, so vision-stage features stay on the website until they ship.
- **Keywords (100 chars):** prioritize phrases users actually search: `audiobook, study, ADHD, anki, flashcards, epub, dyslexia, loop, bookmark, m4b, drm-free, speed`.
- **Screenshots:** demonstrate the study workflow in ≤10 seconds of scanning: ① player with photo bookmark, ② synced reader following the narration, ③ flashcard review, ④ watch remote, ⑤ "all on-device" privacy frame. Caption every screenshot with a benefit, not a feature name.
- **What's New:** every release, written like the devlog — humans read these.

### Channels beyond the website/App Store

| Channel | Play | Notes |
|---|---|---|
| **TestFlight public link** | Beta funnel from all channels | All CTAs route through `beta.html` (tester guide + test plans); beta copy is version-controlled in `fastlane/testflight/` and ships with `fastlane beta`; beta testers become launch-day reviewers |
| **Show HN / Hacker News** | "Show HN: I deliver mail; I built an audiobook player that helps you remember books" | Open source + story + on-device ML = HN catnip. Link repo, not landing page |
| **Reddit** | Value-first posts, never ads | r/audiobooks (DRM-free workflow), r/ADHD + r/AuDHD (the science guide, asked-for-advice tone), r/Anki ("audio-first SRS"), r/iOSProgramming + r/SwiftUI (devlog/how-it's-built), r/libation + r/audible (mp3/m4b workflow) |
| **Apple editorial pitch** | App Store "Behind the App" / accessibility stories | Apple actively features accessibility-first indie apps; pitch via App Store Connect promotional request around launch + Global Accessibility Awareness Day (May) |
| **Tech press** | MacStories, 9to5Mac, Daring Fireball, The Verge "Installer" | Pitch the human story + 60-second demo video; MacStories loves indie + accessibility + open source |
| **YouTube/Shorts** | 30–60s demos: photo bookmark → artwork switch; auto-align an EPUB; watch-only workflow | Screen recordings are cheap to make and demo features words can't |
| **Anki/SRS community** | Blog post: "What Anki gets right, and what audio changes" | Position as *complement*, not replacement — deck import exists |
| **Open-source community** | GitHub README as landing page, good-first-issues, GPL-3.0 license | Stars are social proof; contributors are evangelists |
| **Podcasts** | Indie dev shows (Under the Radar audience), ADHD podcasts | The origin story carries a 30-minute conversation easily |

### Launch sequence

1. **Now → beta:** publish website + devlog, TestFlight public link, soft posts in r/audiobooks + r/libation. Collect testimonials.
2. **App Store launch:** press pitches out 2 weeks prior, Show HN on launch day, Reddit value-posts staggered over launch week, Apple editorial request filed.
3. **Post-launch:** devlog continues weekly (retention + SEO), science-guide excerpts as standalone posts, App Store promotional text rotated with each release.

---

## 3. Messaging bank

Approved phrases — keep voice consistent everywhere:

- "Turn listening into learning."
- "The audiobook player that helps you remember."
- "Built for interrupted attention." / "It survives interruption."
- "Anki for your ears." (community surfaces only — assumes Anki familiarity)
- "Your brain already remembers *where* you were. Echo uses that."
- "Designed for AuDHD brains. Better for every brain." (the curb-cut line)
- "For Every Mind." (official subtitle)
- **NEW — "Other apps sync your audiobook and ebook. Echo helps you study them."** (the reader-vs-system line — the primary 2026 differentiator)
- **NEW — "No audiobook? Echo narrates the ebook on-device — then you can study that too."** (the align-*or*-synthesise span; the sharp anti-Voxlight line — they need you to own *both*)
- **NEW — "Verifiably private — not just promised. The code is open."** (privacy-as-*auditability*; pair GPL with the no-cloud line)
- **REWORDED — "No cloud. No tracking. Your books, your data, your device."** — keep, but it's now baseline trust, *not* a differentiator (Voxlight/AudioBookSync market the same verbatim). Only sharpen the privacy *contrast* against ad-supported (Fox Reader) and cloud-AI (Speechify/Voiser) apps.

Words to avoid: "revolutionary", "AI-powered" (it's on-device ML — say *that*, it's more credible), "hack your brain", any medical claims ("treats ADHD" — never). **And now: any absolutist alignment claim** — "only app that syncs real narration", "no competitor aligns on-device", "only app that designs for neurodivergent users" — all are now *factually false or contestable* (AudioBookSync ships on-device ASR; Continuum ships OpenDyslexic; Audible/Spotify/Kindle ship sync at scale). Prefer **"today, no one else does all of this at once."** Don't headline **"narration that doesn't melt your phone"** — Fox Reader ships the same Kokoro model and streams it instantly even on an A14, so it invites a latency comparison Echo currently loses (scope that line to Voice Dream's *old* engines only).

---

## 4. Measurement

Keep it lightweight and privacy-consistent (no analytics in-app, ever):

- GitHub stars / traffic graphs (free, built-in)
- TestFlight tester count + crash-free rate
- App Store Connect impressions → product page views → downloads funnel
- App Store keyword rankings (check manually monthly)
- Devlog/manual page views via GitHub Pages traffic insights

---

## 5. Honesty ledger (internal)

The website and manual describe the complete product vision in present tense (per docs policy). Features documented ahead of shipping are tracked here so App Store metadata never overclaims:

| Feature | Docs | Shipped? |
|---|---|---|
| Photo bookmarks + artwork switching | Manual, Learn, site | ✅ Shipped (`bookmarkImageFileName`, `BookmarkArtworkCoordinator`) |
| SM-2 flashcards, daily review, watch review, deck import | Everywhere | ✅ Shipped |
| 3-tier auto-alignment (WhisperKit/TokenDTW) | Everywhere | ✅ Shipped |
| PDF companion + manual alignment joystick | Everywhere | ✅ Shipped |
| **Chapter Study Mode** (chapter-as-Anki-card, study playlist) | Manual, Learn, site | 🔶 Vision (post-1.0) — site copy tagged "🔭 Roadmap" |
| iCloud study-state sync (cards/decks/bookmarks/position) | Manual, Learn, site | 🔶 Partial (anchors only) — WS8; site copy tagged "🚧 Coming in 1.0" |
| **Insights / Stats screen** (listening time, streaks, coverage, retention) | Site, Learn, Manual | 🔶 WS3–4 — tagged "🚧 Coming in 1.0" |
| **Context Memory** (opt-in location on bookmarks/sessions/chapters) | Site, Learn, Manual, Privacy | 🔶 WS5 — tagged "🚧 Coming in 1.0" |
| **Card Inbox / mark-later** (+ card editor, decks & tags) | Site, Learn, Manual | 🔶 WS6 — tagged "🚧 Coming in 1.0" |
| **Brain Dump / Book Notes** (untethered notes, watch dictation) | Site, Learn, Manual | 🔶 WS6b — tagged "🚧 Coming in 1.0" |
| **.apkg import, JSON deck export, study-notes Markdown bundle** | Site, Learn, Manual | 🔶 WS7 — tagged "🚧 Coming in 1.0" |

When a 🔶 item ships: move it into App Store description + What's New, announce in devlog, delete the row (and remove the site's 🚧 tag).

### Competitive-honesty gaps (added 2026-06-19 — claims that would over-state Echo)

Distinct from the vision-vs-shipped ledger above: these are places where current/likely copy would *overclaim against competitors*. Reviewers can falsify them in one screenshot, so keep marketing inside these bounds.

| Gap | The honest bound | Why it matters |
|---|---|---|
| **TTS read-along is block-level, not word-level** | Don't claim "word-level read-along" for the *narrated* (Kokoro) path — it writes one anchor per text block. Word-level karaoke is the *real-narration* path only. | A reviewer comparing the two paths will catch it; undermines the alignment credibility Echo *does* deserve for EPUB. |
| **On-device narration A14 gate — ✅ resolved (merged from main)** | Narration now runs on **every device at the iOS 18 floor, including A14 (iPhone 12 Pro)**, via the ONNX engine (`OnnxKokoroEngine`, off the ANE) — you *can* now market on-device narration breadth, including older phones. | Was a gap; the A14 ONNX pivot **de-gated** it (ROADMAP §A.1, verified ≈0.7 s load / RTF ≈0.5 on a 12 Pro). |
| **PDF alignment is manual scrubber-only** | "On-device alignment" = EPUB auto-pipeline (WhisperKit/TokenDTW). PDF is *manual* page-pinning. Frame PDF as a "read-only companion," not auto-aligned. | README's "True ePub & PDF Alignment" implies auto-alignment covers PDF; it doesn't. |
| **"Take your decks with you" is partial** | The narrator-audio snippet — Echo's most distinctive card asset — does **not** survive `.apkg` export (no Anki schema slot). Don't imply full round-trip portability. | Also: portability *lowers* switching costs — pitch it as no-lock-in trust, never as retention. |
| **Don't market "we ship, Voxlight doesn't"** | Voxlight is pre-launch today, but that's a perishable fact on a date Echo doesn't control. | Naming an unlaunched rival only advertises it; the claim self-destructs on its launch day. |

**Site tag convention (added 2026-06-10):** all unshipped features on the website/manual carry a visible "🚧 Coming in 1.0" or "🔭 Roadmap" pill — the site may describe the full vision in present tense *because* the tags disclose status. The Libation/OpenAudible links live in the website FAQ only — never in App Store metadata or in-app help (App Review 2.3.1 posture).
