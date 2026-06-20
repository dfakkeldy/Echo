# Echo Roadmap Rebuild — Design Spec

**Date:** 2026-06-19
**Status:** Approved design — pending spec review, then ROADMAP.md rewrite + README resync
**Author:** Dan Fakkeldy (with Claude)
**Supersedes:** the WS0–WS10 forward plan in `ROADMAP.md` Part A (Phase 1–9 blueprint preserved as history)

---

## 1. Context & motivation

Echo is **pre-release**, so there are no migration, compatibility, or installed-base constraints — we can restructure freely.

Two inputs drove this rebuild:

1. **Kickstart competitor weakness analysis** — 7 recurring complaint themes mined from reviews across the 13 tracked competitors:
   1. UI/UX confusion (navigation, card organization, poor onboarding, hard-to-reach features)
   2. Audiobook sync & file-management problems (lost progress, file corruption, bad metadata, unsupported formats)
   3. Reliability & performance (lag, crashes, freezing, slow start, losing saved content — especially after updates)
   4. Support & feedback (poor communication, unhelpful responses, cumbersome feedback systems)
   5. Pricing & monetization (hidden fees, subscriptions, intrusive ads, feature paywalls)
   6. Security & privacy (cloud-storage/upload concerns, lack of transparency)
   7. App-specific polish (e.g. Prologue UI glitches, slow performance, poor integration)

2. **The 2026-06-19 moat reassessment** (`docs/competitor-analysis.md` §6) — adversarial audit returned **0 durable / 3 eroding / 14 not-a-moat**. Audiobook↔text sync is now table stakes; the only uncontested moat is the **fused study system** (SRS + align-or-synthesize + watch) plus non-copyable attributes (neurodivergent-first DNA, founder story, GPL/free/verifiable-privacy).

**Structured market data (Kickstart `get_competitor_analysis`, 13 competitors):**
- **High-rated but annoying:** 9/11 rated competitors sit at ≥4.5★ (Speechify 4.7 on 482k ratings; BookPlayer 4.8/17k; Prologue 4.9/5.4k) — yet reviews still surface all 7 complaints.
- **Mostly free:** 11/13 free (avg price $2.31; only Bound $4.99 and AnkiMobile $24.99 are paid).

**Strategic conclusion:** in a field where even 4.5★ apps annoy people, the winning play is to be **the app that doesn't have the annoyances everyone tolerates** (table-stakes quality + trust) **plus** the study moat nobody has. Echo is already structurally positioned to win 6 of the 7 weaknesses (on-device + GPL + no-ads beats #5/#6; folder import + CloudKit beats #2; the moat is the additive #0).

---

## 2. Strategic decisions (locked with the owner)

| Decision | Choice | Rationale |
|---|---|---|
| **Roadmap structure** | **Competitive-wedge pillars** (clean-sheet) | Reorganize around the weakness themes turned into Echo strengths; each wedge states "competitors fail at X → Echo ships Y." Most faithful to "use these weaknesses to rebuild." |
| **1.0 launch gate** | **Hold for a deep, defensible moat + green table-stakes** | The moat is the only durable thing; launching shallow invites "so add flashcards" copying. Accept a later date — *arrive late but clearly differentiated*. |
| **Audiobookshelf** | **Full integration in 1.0** (SYNC wedge) | Owner uses a self-hosted ABS library; foundations are already laid (see §6). Pushes the date further, accepted. |
| **macOS** | **Full peer in 1.0** (study layer + batch pipeline) — *not* a "functional core" | Owner uses the Mac for batch transcribe/align/narrate; the study moat must work there too. Adds scope (the study layer on a second platform); pushes the date further. See §3 "Platform parity". |
| **Launch date** | **Aug 1 2026 target retired → gate-driven** | Ship-when-green, not calendar-driven (follows from the deep-moat gate). |

---

## 3. The six competitive wedges

Each wedge: the weakness it exploits, the competitor evidence, what Echo ships for 1.0, and which existing workstream/code slots underneath.

### Wedge 1 — STUDY MOAT *(the lead; the additive differentiator)*

> **Beats:** nothing — it's the one capability no competitor (sync *or* TTS cohort) has. This is the "deep" the 1.0 gate holds for.

**1.0 scope:**
- **FSRS scheduling** (pulled *into* 1.0, was post-1.0) alongside the existing SM-2.
- **Chapter Study Mode ("Anki mode" — chapter-as-card)** — turns a whole audiobook into a spaced-repetition object; detailed below.
- **Card Inbox / mark-later**, full **card editor**, **decks & tags** (retire mid-playback popups).
- **Narrator-audio-snippet cards** + **watchOS haptic review**, hardened against eviction/relaunch.
- **Align-or-synthesize:** real-narration WhisperKit/TokenDTW alignment *and* on-device Kokoro narration of text-only EPUBs (the sharp anti-Voxlight wedge — rivals require you to own *both* files).
- **`.apkg` round-trip** (import *and* export) + Markdown second-brain export.
- **Deep analytics / full Insights** (pulled *into* 1.0, was 1.x) — retention curves, per-chapter coverage heatmaps, streaks, speed trends, time-of-day patterns, grade distributions, 30-day review forecast — all computed on-device — + **Context Memory** (opt-in, on-device, deletable).

**Chapter Study Mode ("Anki mode") — feature detail.** Turns an entire audiobook into a spaced-repetition object; **the book is a deck.**
- Adding a book in this mode **auto-creates one chapter-card per chapter** (auto-populate — *not* AI Q&A generation; the chapter itself is the card).
- Listening to a chapter *is* studying its card. At the chapter's end the user self-grades **Again / Good**, and **Again is auto-selected if nothing is tapped** (hands-free on a route). **Good** schedules the chapter out via FSRS; **Again** brings it back soon.
- **Review semantics (progressive coarse → fine):** a due chapter-card with *no* granular cards replays the **whole chapter, but skippable** (mark Good / skip the moment it feels familiar). As soon as the user **creates a flashcard inside a chapter**, prompt: *"Retire the chapter card and review with your cards instead?"* — so a chapter distills from a re-listen into quick cards as engagement deepens.
- **One interleaved FSRS queue:** chapter-cards and highlight-flashcards share a single "study today" session, all FSRS-scheduled.
- **New-cards/day, Anki-style:** configurable **per book (deck) *and* globally**. Hitting the limit switches the queue from a new chapter to due reviews / the next deck (book).
- Replaces manual chapter-loop while active (a distinct listening mode).

**Absorbs:** WS0 (capture), WS3–4 (Insights/analytics), WS5 (Context Memory), WS6 (Anki core), WS6b (Brain Dump), WS7 (Import/Export), WS-N (Narration). *Net-new: Chapter Study Mode.*

**Gate criteria:** capture → flashcard → FSRS-scheduled review → watch review works end-to-end; **Chapter Study Mode** runs end-to-end (auto chapter-cards, Again/Good with hands-free Again-default, skippable re-listen, retire-on-card-create, per-deck + global new limits, interleaved FSRS queue); deep-analytics Insights screen populated on-device; `.apkg` round-trips losslessly (known gap: the narrator-audio snippet has no Anki schema slot — document, don't overclaim portability); narration produces word-level read-along for real narration and block-level for synthesized.

### Wedge 2 — ROCK-SOLID *(beats #3 reliability/performance, #7 app-specific glitches)*

> **Beats:** competitors crash, freeze, and lose progress after updates → **Echo never loses your place and never crashes.**

**1.0 scope:**
- **Restore CI test execution** — currently build-only; full simulator test action is blocked by the Apple iOS 26 isolated-deinit simulator runtime bug. Unblock (or pin a working runtime) so the unit/integration suites gate every PR.
- **Crash-free gate:** **≥99.5% crash-free sessions (stretch 99.9%)** with **zero unresolved P0 crash families**, measured via **MetricKit + App Store Connect** — *no third-party SDK*, which keeps the no-tracking promise intact (symbolicate crash families with `xcsym`). The "zero P0 families" clause is the real bar; the percentage needs enough beta session volume to be meaningful.
- **No-lost-progress guarantee** — durable persistence + clean resume after call interruption, app eviction, and relaunch, extended from the watch-persistence rigor to every surface.
- **Performance budget** — fast cold launch, no playback freeze, smooth large-library scrolling.
- **Resolve the A14 narration blocker** — the ONNX pivot (`OnnxKokoroEngine`) or a graceful capability gate. (Spike already builds green; gate is a real-device A14 RTF measurement.)

**Absorbs:** WS2 (CI) + foundation hardening.

**Gate criteria:** CI runs the test suites green on the runner; beta crash-free ≥99.5% sessions (stretch 99.9%) with zero unresolved P0 crash families (via MetricKit / App Store Connect); no-lost-progress verified across interruption/eviction/relaunch on iPhone + Watch + Mac; A14 narration either resolved or cleanly gated with honest messaging.

### Wedge 3 — CLARITY *(beats #1 confusing UI/onboarding, #7 poor integration)*

> **Beats:** competitors are confusing with poor onboarding → **Echo is obvious from first launch.**

**This wedge is a genuine UI overhaul, not polish.** Owner's read: the app needs substantial UI work, and the PR #77 BookPlayer-style redesign was **net-sideways** ("a few steps forward, as many steps back") — it is *a step, not the target state*. So the implementation plan must **open with a UX audit** of the current app (player, reader, library, and the #77 redesign) to name the specific regressions before rebuilding.

**1.0 scope:**
- **UI overhaul** of the core surfaces (player, reader, library), driven by the UX audit — fix the #77 regressions and raise the whole app to a coherent, obvious standard.
- **Onboarding** that teaches the curb-cut workflow in under 60 seconds (import → align → capture → review).
- A **UX-flow audit** (no dead-ends, no dismiss-traps, no buried CTAs; loading/empty/error states everywhere).
- Clean **navigation** + **library organization**; **reader speed controls**, alignment-celebration; iOS/macOS parity.

**Absorbs:** WS9 (Polish) + a net-new UI-overhaul effort, macOS parity items.

**Gate criteria:** UX audit complete with regressions named and fixed; a new user reaches their first aligned read-along and first flashcard without external help; no confusing dead-ends; **owner signs off that the UI is forward progress, not sideways.**

### Wedge 4 — TRUST *(beats #5 ads/paywalls/hidden fees, #6 privacy)*

> **Beats:** competitors hide fees, gate features, and run ad-SDKs → **Echo is free, open, ad-free, and verifiably private.**

**1.0 scope:**
- **No ads, ever.** **Honest Echo Pro** (`FreeTierGate`) modeled on BookPlayer's tip-jar / simple-unlock style — never an aggressive carousel paywall.
- **Verifiable privacy** — on-device, no accounts, no tracking, privacy manifest present — *provable* because the source is GPL-3.0 ("verifiably private, not just promised").
- **No lock-in** — open formats, full data export.

**Absorbs:** the monetization tier (`FreeTierGate`) + the privacy posture. Mostly positioning + paywall UX.

**Gate criteria:** zero ad/analytics SDKs (verified); Pro unlock is non-intrusive and clearly priced; privacy manifest accurate; data export works.

### Wedge 5 — SYNC DONE RIGHT *(beats #2 sync/file-management failures)*

> **Beats:** competitors lose progress, corrupt files, and fumble metadata → **Echo's BYO library + iCloud just works, and your self-hosted shelf comes with it.**

**1.0 scope:**
- **Full CloudKit study-state sync** — position, bookmarks, cards, decks (today it's anchors-only) — with conflict handling and **no lost progress** across iPhone/Watch/Mac.
- Robust multi-format import (M4B/MP3/folders) + correct metadata handling.
- **Full Audiobookshelf integration** (pulled into 1.0): auth (JWT login + refresh-with-rotation), browse libraries/items, **background resumable download-to-local** (land bytes + sibling EPUB into an app-owned folder so the existing import pipeline + alignment + flashcards fire unchanged), and **(optional) two-way progress sync** — a fast-follow within the 1.0 cycle, not a hard gate. *Streaming stays deferred (the audio engine is local-file only).*

**Absorbs:** WS8 (iCloud sync) + WS8b/Phase 9 (Audiobookshelf).

**Gate criteria:** a study-state change on one device appears on the others with no lost progress and sane conflict resolution; an ABS book downloads to local and becomes indistinguishable from a local import (alignment, search, flashcards all work).

### Wedge 6 — SUPPORT *(beats #4 poor support/feedback)*

> **Beats:** competitors give slow, unhelpful support → **Echo is responsive and open.**

**1.0 scope:**
- **In-app feedback** path; responsive GitHub issues; the beta-tester funnel.
- Living docs/manual/glossary as self-serve support.

**Absorbs:** WS10 (Docs & site, ongoing).

**Gate criteria:** in-app feedback reaches the developer; docs cover every shipped feature; a support contact path exists.

### Platform parity — macOS is a full peer in 1.0

Owner's call: **macOS ships at full parity in 1.0, not as a "functional core."** Every study/reader/player capability runs on Mac, plus a Mac-native batch pipeline. This is cross-cutting — it means each wedge above must land on Mac too, not just iOS.

- **Already built on Mac** (verified in `Echo macOS/`): player (`MacPlayerModel`, options/more menus, audio-boost tap), reader + karaoke (`MacTriPaneView`, `MacReaderFeedView`, `MacTOCTreeView`, transcript pane), on-device alignment (`MacAlignmentService`, `TranscriptionManager`), Anki **export** (`MacApkgExportService`), notes pane, Settings scene — and the **batch pipeline** (`MacBatchProcessingService` / `MacBatchQueueView`): *import → transcribe → align → word-timings* + overnight **Narrate EPUB(s)**. So **"batch transcribing/alignment/narrating" is largely shipped**; 1.0 = complete + harden it (resumable, unattended, progress, error handling) and keep it first-class.
- **The parity gap 1.0 must close on Mac** — the **study layer**: in-playback **flashcard creation**, **FSRS/SM-2 review** (`DailyReview` has no Mac UI today), **Chapter Study Mode**, **Card Inbox / editor / decks & tags**, **deep-analytics Insights**, **Context Memory** — plus applying the persisted **custom font/theme** to the macOS UI (known follow-up: values persist but aren't applied).
- **Legitimately excluded from "parity"** (platform-inherent, not gaps): watchOS review (no watch on Mac — though Mac gets its own full-screen review), CarPlay, and camera-photo bookmarks (Mac uses the photo library / files instead).
- **Implementation note:** the macOS-specific surface — windows/scenes, menu-bar commands & shortcuts, App Sandbox + security-scoped file access, Developer-ID notarization/distribution, AppKit bridging — is handled with the **axiom-macos** skill during the build phase; out of scope for this design.

This is a material scope addition (the study layer on a second platform) and reinforces the *arrive-late-but-deep* posture.

---

## 4. The 1.0 launch gate

1.0 ships **only when all six wedges are green**:

- **Moat is deep** — FSRS + Chapter Study Mode + polished snippet review + `.apkg` round-trip + watch + align-or-synthesize narration + **deep-analytics Insights**.
- **Rock-solid** — ≥99.5% crash-free sessions / zero P0 families (MetricKit/ASC), CI test execution restored, no-lost-progress verified, A14 narration resolved-or-gated.
- **Clear** — **UI overhaul shipped** (owner sign-off), onboarding shipped, ux-flow audit clean.
- **Trusted** — no-ads / honest-Pro / verifiable-privacy all true, paywall UX done.
- **Synced** — full study-state sync **and** full Audiobookshelf, no lost progress.
- **Supported** — in-app feedback live.
- **At parity on macOS** — the full study/reader/player + batch pipeline ship on Mac (study layer added; watch/CarPlay legitimately excluded).

**Launch date:** gate-driven (ship-when-green). The fixed Aug 1 2026 target is retired.

---

## 5. Deferred to 1.x (post-1.0)

Photo-of-page → audio jump (the one row Echo is behind on; reuses the existing transcription index) · multi-voice / per-character narration · **AI-generated Q&A flashcards** from chapter content (distinct from Chapter Study Mode's chapter-as-card, which does *no* generation) · CarPlay capture buttons · ABS streaming · AnkiConnect · focus-soundscape expansion.

*(Removed from this list — now in 1.0: Audiobookshelf, deep analytics, full macOS parity.)*

---

## 6. Current-state ground truth (verified 2026-06-19)

Grounding facts the ROADMAP rewrite must reflect honestly:

- **Audiobookshelf = foundations only.** Built: `abs_server` table (Schema_V18, registered), `ABSServerDAO`, `ABSModels`, `ABSEndpoints` (URL builders), `ABSTokenStore`, schema tests, and a paywall benefit label. **Not built:** any networking client (nothing calls the endpoints — no `URLSession`, no login flow), the download-to-local pipeline, and all UI. So "full ABS in 1.0" = build the service + auth + browse + download-to-local + progress sync + UI on top of the existing data layer.
- **A14 narration:** the `OnnxKokoroEngine` ONNX pivot spike builds and `make build-tests` is green; the make-or-break gate is a real-device iPhone 12 Pro (A14) RTF/first-word measurement. CoreML stays in-tree until that gate passes.
- **CI:** build-gate is live on PRs, but the full multi-scheme simulator **test** action is disabled because of the Apple iOS 26 isolated-deinit simulator runtime crash on `PlayerModel` teardown. Restoring test execution is a Wedge-2 gate item.

---

## 7. Documentation mechanics

- **`ROADMAP.md`** — rewrite Part A so the **six wedges are the canonical forward plan**. Keep the §A.1 narration detail and §A.2 monetization under the relevant wedges. Move the historical **Phase 1–9 blueprint (Part B) to a clearly-labeled appendix** ("completed-foundation history"). Carry the §A.3 competitive-priorities insights into the wedges.
- **`README.md`** — resync "The Road to v1.0" workstream table to the wedges (doc-sync rule). Keep the wedge ↔ old-WS mapping discoverable for one release so nothing looks orphaned.
- **`docs/product-strategy.md`** — update the 1.0 scope section (FSRS, Chapter Study Mode, deep analytics, and full Audiobookshelf now in-scope; **macOS reframed from "functional core" to full peer**; Aug 1 date retired).
- Keep the wedge ↔ weakness mapping explicit so the "why" survives.

---

## 8. Risks & open dependencies

- **CI test-execution restore** depends on the Apple iOS 26 sim-deinit bug (external). If it persists, Wedge 2 may need a pinned-runtime or device-test workaround — it must not silently stay build-only.
- **A14 narration** could still fail its real-device RTF gate; the fallback is a clean A15+ capability gate with honest messaging (don't market narration breadth on older phones until resolved).
- **ABS in 1.0 widens scope materially** (an "L"-sized download pipeline + auth + UI) and pushes the date further — accepted, but it is the largest single addition.
- **Holding for a deep moat** gives Voxlight (pre-launch) and the rest of the sync cohort more time to ship first. Mitigation: bank reviews/ASO via the beta while uncontested; the study-layer + founder-story lines are launch-proof.
- **Solo-dev sustainability** — the 1.0 is large. The wedges are independently shippable, so the order within 1.0 can be tuned in the implementation plan; reliability/clarity/trust can land incrementally in the beta while the moat deepens.

---

## 9. Out of scope for this spec

This is a **roadmap-structure design**, not an implementation plan. Task-level breakdown, sequencing within 1.0, sizing, and dependencies are produced next by the writing-plans step. Public marketing copy already reflects the moat repositioning (done 2026-06-19); this spec governs the *product* roadmap only.
