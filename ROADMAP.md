# Echo: Audiobook Study Player — Roadmap

<!-- Last updated: 2026-06-20 (MERGED origin/main into the wedge rebuild: integrated the shipped **ONNX narration engine swap** — `OnnxKokoroEngine` replaced the CoreML/FluidAudio stack and **A14 narration is now DE-GATED** (§A.1; reconciled into Wedge 2, which previously listed it as to-do) — plus main's competitor findings (AudioBookSync = closest tech competitor §7.11–§7.12; Voxlight confirmed chapter-level; SyncBooks/Vlume notes; §A.3.6 "defend the alignment moat" + §A.3.7 research backlog folded into priorities 6–9). 2026-06-19 EVENING — ROADMAP REBUILT into six competitive wedges per docs/superpowers/specs/2026-06-19-roadmap-rebuild-design.md: Part A is now wedge-structured (Study Moat / Rock-Solid / Clarity / Trust / Sync / Support) + macOS full-peer parity; 1.0 holds for a DEEP moat with FSRS, Chapter Study Mode, deep analytics, and full Audiobookshelf all pulled INTO 1.0; Aug-1 target retired → gate-driven; old WS0–WS10 re-slotted under the wedges. PRIOR PM — moat reassessment vs the "Sync cohort". 2026-06-18: WS0–WS10 workstream model; On-Device Narration (Kokoro) workstream; Echo Pro / FreeTierGate; schema V21. The Phase 1–9 blueprint is preserved in Part B.) -->

---

## How this roadmap is organized

This roadmap has two layers:

- **Part A — Road to v1.0 competitive wedges (canonical, forward-looking).** Rebuilt 2026-06-19 around six wedges that turn competitor weaknesses into Echo strengths. The single source of truth for *what's next*. The old WS0–WS10 work re-slots under the wedges (mapping kept inline as "*(was WSx)*").
- **Part B — Original blueprint (Phases 1–9, historical).** The foundational hardening/feature phases that predate the wedge model. Phases 1–7 are complete and kept as engineering history; the forward-looking items in Phases 8–9 are now tracked under the wedges in Part A (cross-referenced).

> [!IMPORTANT]
> Keep this file in sync with `README.md`'s "Road to v1.0" section. When a wedge item's status changes, update both. **Current schema version: V23** (see `ARCHITECTURE.md` for the full migration ledger).

---

## Part A — Road to v1.0 (Competitive Wedges)

> **Echo 1.0:** a deep, trustworthy study *system* on **iPhone (full), Apple Watch (companion), and Mac (full peer)** — the audiobooks you already own turned into spaced-repetition study; rock-solid and obviously usable; free and verifiably private; with study-state **and** self-hosted-library sync that never loses your place. **Launch is gate-driven (ship-when-green), not calendar-dated.**

Rebuilt 2026-06-19 around **six competitive wedges**. Each turns a recurring competitor weakness — mined from competitor reviews — into an Echo strength: *"competitors fail at X → Echo ships Y."* Full rationale and the launch-gate criteria: [`docs/superpowers/specs/2026-06-19-roadmap-rebuild-design.md`](docs/superpowers/specs/2026-06-19-roadmap-rebuild-design.md).

> [!IMPORTANT]
> This 1.0 is a **program**, not a single feature. Each wedge (often each feature within it) gets its own spec → plan → implementation cycle; per-feature implementation plans live in `docs/superpowers/plans/`. The wedges below are the dependency-ordered program. *(was WSx)* tags map each item to its old workstream for one release.

### Wedge 1 — STUDY MOAT *(lead; the core differentiator)*

The fused study system no sync-app and no TTS-app has. **This is the "deep" the launch gate holds for** — the study layer is the differentiator we lead with.

- [ ] **FSRS scheduling** *(was post-1.0 → now 1.0)* alongside the existing SM-2.
- [ ] **Chapter Study Mode ("Anki mode" — chapter-as-card)** — book = deck; auto one chapter-card per chapter; listen → grade **Again / Good** (Again auto-default on no tap = hands-free); a due chapter with no cards = a **skippable re-listen**, and creating a flashcard inside a chapter prompts *"retire the chapter card and review with your cards?"*; **one interleaved FSRS queue**; **per-book + global** new-cards/day limits. *(Net-new — see spec Wedge 1 for the full design.)*
- [ ] **Card Inbox / mark-later**, full **card editor**, **decks & tags** (retire mid-playback popups). *(was WS6)*
- [ ] **Narrator-audio-snippet cards** + **watchOS haptic review** — core shipped; harden against eviction/relaunch.
- [ ] **Align-or-synthesize narration** — real-narration alignment + on-device Kokoro narration of text-only EPUBs (core shipped); remaining polish in §A.1. *(was WS-N)*
- [ ] **`.apkg` round-trip** (import + export; export shipped) + Markdown second-brain export. *(was WS7)*
- [ ] **Deep analytics / full Insights** *(was 1.x → now 1.0)* — retention curves, per-chapter coverage heatmaps, streaks, speed trends, time-of-day patterns, grade distributions, 30-day forecast, all on-device. *(was WS3–4)*
- [ ] **Context Memory** (opt-in, on-device, deletable). *(was WS5)*

### Wedge 2 — ROCK-SOLID *(beats competitor reliability/crash/perf complaints)*

Competitors crash, freeze, and lose progress after updates → **Echo never loses your place and never crashes.**

- [ ] **Restore CI test execution** — the build-gate is live, but the full simulator **test** action is blocked by the Apple iOS 26 isolated-deinit runtime bug. Unblock / pin a runtime so the suites gate every PR. *(was WS2)*
- [ ] **Crash-free gate:** **≥99.5% crash-free sessions (stretch 99.9%), zero unresolved P0 crash families**, measured via **MetricKit + App Store Connect** (no third-party SDK — keeps the no-tracking promise; symbolicate with `xcsym`).
- [ ] **No-lost-progress guarantee** — durable persistence + clean resume after call / eviction / relaunch, extended from the watch-persistence rigor to every surface.
- [ ] **Performance budget** — fast cold launch, no playback freeze, smooth big-library scrolling.
- [x] **A14 narration — ✅ resolved (merged from main).** The `OnnxKokoroEngine` ONNX pivot **shipped** (ONNX Runtime CPU EP, off the ANE); the A15+ `NarrationCapability` gate is **removed**, verified on an iPhone 12 Pro (≈0.7 s load, RTF ≈ 0.5, no crash/jetsam). See §A.1. *(Remaining cleanup: drop the now-unused FluidAudio/KokoroPipeline SPM packages.)*

### Wedge 3 — CLARITY *(beats confusing UI / poor onboarding)*

Competitors are confusing → **Echo is obvious from first launch. This is a genuine UI overhaul, not polish** — the PR #77 BookPlayer-style redesign was *net-sideways* ("a few steps forward, as many steps back") and is a step, not the target state.

- [ ] **UX audit first** — name the specific regressions across player / reader / library (incl. #77) before rebuilding.
- [ ] **UI overhaul** of the core surfaces to a coherent, obvious standard (owner sign-off that it's forward progress).
- [ ] **Onboarding** that teaches the curb-cut workflow in under 60 seconds (import → align → capture → review).
- [ ] **UX-flow audit** (no dead-ends/dismiss-traps; loading/empty/error states everywhere); clean navigation + library organization; reader speed controls; iOS/macOS parity. *(was WS9)*

### Wedge 4 — TRUST *(beats ads / paywalls / hidden-fees + privacy complaints)*

Competitors hide fees, gate features, and run ad-SDKs → **Echo is free, open, ad-free, and verifiably private.**

- [x] **Free-tier gate** — `FreeTierGate` (20 cards / 1 narrated chapter free); Pro unlocks. *(shipped; see §A.2)*
- [ ] **Honest Echo Pro paywall UX** — BookPlayer tip-jar / simple-unlock style, never an aggressive carousel. *(§A.2)*
- [ ] **Verifiable privacy** — on-device, no accounts, no tracking, privacy manifest accurate; *provable* because GPL-3.0 ("verifiably private, not just promised").
- [ ] **No lock-in** — open formats, full data export.

### Wedge 5 — SYNC DONE RIGHT *(beats sync / file-management failures)*

Competitors lose progress and corrupt files → **Echo's BYO library + iCloud just works, and your self-hosted shelf comes with it.**

- [ ] **Full CloudKit study-state sync** — position, bookmarks, cards, decks (today **anchors-only**), conflict handling, no lost progress across iPhone / Watch / Mac. *(was WS8)*
- [x] **Full Audiobookshelf** *(was 1.x → now 1.0)* — auth (JWT login + refresh-with-rotation), browse libraries/items, server-side search, **download-to-local** (whole-item zip → `ABSLibrary/<remoteItemID>/`; sibling EPUB auto-discovered so alignment + flashcards fire unchanged), and two-way progress sync (ABS-authoritative last-write-wins reconciler, throttled push + reconcile-on-load). *Shipped on branch `claude/romantic-wing-0dc47b` (V23 migration; progress-sync live-playback wiring device-unverified; pull re-seek single-track-only in v1; full `URLSessionConfiguration.background` + multi-server + macOS UI are fast-follows; streaming deferred post-1.0.)* *(was WS8b)*

### Wedge 6 — SUPPORT *(beats poor support / feedback)*

Competitors give slow, unhelpful support → **Echo is responsive and open.** In-app feedback path, responsive GitHub issues, the beta-tester funnel, living docs/manual/glossary as self-serve support. *(was WS10 — ongoing.)*

### Platform parity — macOS is a full peer in 1.0

**Already built on Mac:** player, reader + karaoke, on-device alignment, Anki export, and the **batch pipeline** (`MacBatchProcessingService` / `MacBatchQueueView`: import → transcribe → align → word-timings + overnight Narrate-EPUBs) — so **batch transcribe/align/narrate is largely shipped** (1.0 = complete + harden). **Parity gap 1.0 closes:** the **study layer** on Mac — flashcard creation, FSRS + Chapter-Study review (`DailyReview` has no Mac UI today), Card Inbox / editor / decks, deep Insights, Context Memory — plus applying the persisted custom font/theme (§A.1 follow-up). **Excluded** (platform-inherent, not gaps): watch review, CarPlay, camera bookmarks (Mac uses the photo library / files). macOS build specifics (sandbox, notarization, menus, AppKit bridging) → handled with `axiom-macos` at build time.

### The 1.0 launch gate — ship when ALL are green

**Moat deep** (FSRS + Chapter Study Mode + snippet review + `.apkg` round-trip + watch + align-or-synthesize + deep Insights) · **Rock-solid** (≥99.5% crash-free sessions / zero P0 families, CI tests restored, no-lost-progress, A14 narration ✅ resolved via ONNX) · **Clear** (UI overhaul shipped — owner sign-off — + onboarding + clean flows) · **Trusted** (no-ads / honest-Pro / verifiable-privacy) · **Synced** (full iCloud **and** full Audiobookshelf, no lost progress) · **Supported** (in-app feedback live) · **macOS at full parity.**

### Deferred to 1.x (post-1.0)

Photo-of-page → audio jump (the one row Echo is behind on; reuses the existing transcription index) · multi-voice / per-character narration · **AI-generated Q&A flashcards** from chapter content (distinct from Chapter Study Mode, which does *no* generation) · CarPlay capture buttons · ABS streaming (Part B §9.5) · AnkiConnect · `.apkg` export polish · focus-soundscape expansion · hyperfocus/transition alarms · Context Memory map view.

### A.1 — On-Device Narration (Kokoro) — ✅ Core shipped

Echo's direct answer to TTS-reader competitors (notably Voice Dream). Generates spoken audio for study EPUBs that have **no audiobook**, entirely on-device.

- [x] **Engine core (Schema V17)** — `TTSEngine`/`AudioFileWriting` seams, `VoiceCatalog` (default "Ava"), pure `TextNormalizer`, `@Observable` `NarrationState`, and `NarrationService.renderChapter` (**render-then-play**: synthesize each chapter → one AAC file + one `.synthesized` `AlignmentAnchorRecord` per block). `track.narration_voice` column marks synthesized tracks.
- [x] **Kokoro-82M voice** — `OnnxKokoroEngine` (ONNX Runtime, CPU EP; `model_fp16.onnx` from `onnx-community/Kokoro-82M-v1.0-ONNX`, ~163 MB) + MisakiSwift lexicon-only G2P (Apache, no GPL espeak-ng), via `NarrationEngineFactory` on iOS + macOS. Replaced the CoreML stack (FluidAudio `KokoroTTSEngine` → fixed-shape `KokoroFixedShapeEngine` + `NarrationModelStore`), whose on-device AOT compile took ~20 min on A14 and whose ANE vocoder trapped (`libBNNS` SIGTRAP). ONNX interprets the graph → ≈0.7 s session-load (no compile), RTF ≈ 0.5 on A14, runs off the ANE so the trap can't occur. The legacy CoreML/FluidAudio stack was deleted. *(Pivot decision: `docs/superpowers/research/2026-06-19-kokoro-onnx-pivot-decision.md`.)*
- [x] **A14 narration de-gate (done)** — the A15+ `NarrationCapability` gate is removed; narration is available on every device meeting the iOS 18 / macOS 15 floor. The gate existed only because the CoreML vocoder trapped on the A14 ANE; the ONNX engine never touches the ANE, verified on an iPhone 12 Pro (≈0.7 s load, RTF ≈ 0.5, no crash/jetsam).
- [ ] **Remove the unused FluidAudio + KokoroPipeline SPM packages** — now unimported (the legacy engines are deleted) but still linked; drop them via Xcode ▸ Package Dependencies and delete `ThirdParty/KokoroPipeline`.
- [x] **Word-level read-along / karaoke (Schema V19)** — `word_timing` table; char-proportional interpolation refined to real WhisperKit/DTW word times; iOS + macOS readers. *(Existing books need a one-time re-align.)*
- [x] **Cross-platform chaptered `.m4b` export (iOS + macOS)** — `AudioExportService` (`EchoCore/Services/Export/`) composes + transcodes any book (narrated EPUB via `NarrationCacheSource`, or imported m4b/mp3 via `ImportedBookSource`) and writes Nero `chpl` + QuickTime `chap` markers plus title/author/cover art in one in-place pass via `swift-audio-marker` (now linked on both targets). iOS entry: player More menu → share sheet. macOS entry: File menu → `NSSavePanel`. **mp3 export deferred** (needs LAME; per-chapter-file strategy decided).
- [x] **macOS port + overnight narrate queue (Schema V21)** — Kokoro de-gated to iOS+macOS via `NarrationEngineFactory`; `batch_queue.kind` carries text-only **narrate** items; Batch ▸ "Narrate EPUB(s)…" (⌘⌥N).
- [ ] **Read-first Listen UI polish** — finish the read-first narration wiring on iOS.
- [ ] **macOS custom font/theme application** — `appFont`/`themeColor` persist but aren't yet applied to the macOS UI (documented follow-up).
- [ ] **Hybrid streaming-start narration (latency parity vs Fox Reader)** — today `NarrationService.renderChapter` is pure **render-then-play** (synthesize the whole chapter → AAC → play), which adds an up-front wait before the first word. Competitor **Fox Reader** ships the *same* Kokoro model but starts near-instantly, even on an iPhone 12 Pro (A14). Evaluate a hybrid: **play the first chunk as soon as it's synthesized while rendering the rest ahead, then persist the finished AAC** so replays/exports/read-along keep the render-then-play battery+thermal win (the Voice Dream moat below). Concrete architecture (research-grounded — `docs/superpowers/research/2026-06-19-kokoro-a14-streaming-research.md`):
    - **First chunk = first sentence/clause** (~5–15 words, fits the smallest 3s bucket); **never split mid-sentence** (mid-sentence cuts cause choppy pitch). Subsequent chunks stay at the existing `NarrationTextChunker` ≤200-char cap, each routed to its smallest fitting bucket.
    - **Pre-warm is the real lever, not bucket choice.** Cold start (one-time CoreML compile, "a few seconds") dominates first-launch — compile + load + one throwaway synth **when the reader view opens**, so the visible time-to-first-audio is only first-chunk inference. On A14 a 3s chunk is ~1.2–1.5 s *warm*, so frame the goal as **"near-instant via pre-warm," not a literal sub-1s promise.**
    - **Playback primitive: `AVAudioEngine` + `AVAudioPlayerNode` + `scheduleBuffer`** (a self-clocking queue via each buffer's completion handler), **not** the current `AVAudioPlayer`/finished-file path. Convert Kokoro's 24 kHz mono → the mixer's 48 kHz float per chunk with `AVAudioConverter`. `.interrupts` only on seek/stop.
    - **Backpressure:** start playback at ~0.5 s buffered; **pause synthesis once the queue is ~3 s ahead** to cap CPU/ANE/thermal load (what makes long-form on-route listening sustainable). Keeping the heavy decoder on the ANE helps both latency and power.
    - **Invariant to keep:** streaming produces *ephemeral PCM for immediate playback only*; a chapter is marked rendered **only once the full AAC + per-block anchors/word-timings exist** in `NarrationCache`. A partially-streamed chapter must never be recorded as rendered, or resume/seek/karaoke read incomplete state. (Sequencing: lands **after** the A14 fixed-shape on-device verify — don't optimize start latency before confirming the engine renders wedge-free on A14.)

> **Why this is the right architecture (not a standalone moat — reworded 2026-06-19):** render-then-play falls out of the features that *are* the moat — replayable cached audio, word-level read-along anchors, and chaptered `.m4b` export — and as a bonus playback is just a finished AAC file (hardware decoder, near-zero power), so no overheating / charging-pause vs Voice Dream's *old* engines. **Do not market this as a moat:** Fox Reader ships the same Kokoro model and *streams* it instantly even on an A14, so "neural narration that doesn't melt your phone" invites a latency comparison Echo currently loses. The §A.1 hybrid (stream first chunk, cache the rest) closes that flank and makes the thermal point moot rather than load-bearing.

### A.2 — Monetization: Echo Pro (`FreeTierGate`)

Tracked here because no prior roadmap section owned it. Detailed pricing is kept in the private strategy docs.

- [x] **Free-tier gate** — `FreeTierGate` caps the free tier at **20 flashcards** and **1 narrated chapter per book**; Pro entitlement (`ProEntitlementProviding`) unlocks both. Idempotent re-renders/voice-changes of an already-narrated chapter are never blocked.
- [ ] **Paywall UX** — model the unlock sheet on BookPlayer's non-intrusive tip-jar/simple-unlock style, not an aggressive carousel.

---

## Part A.3 — Competitive Priorities

Sourced from internal competitor field notes (Voice Dream, BookPlayer, Prologue, the reader/TTS cohort incl. **Fox Reader**, and the closest tech competitor **AudioBookSync**).

> [!NOTE]
> **The six wedges above now carry the forward plan** — this section is retained as the *competitive reasoning* behind them (which weakness each wedge exploits, what to protect, what to reposition). Priorities 6–8 map to Wedge 1 (study moat + word-level read-along), the positioning work, and the 1.x photo-jump/OCR evaluation; priorities 1–2 (VoiceOver, watch persistence) fold into Clarity/Trust and Rock-Solid; priority 9 is the live research backlog.

1. **⬆️ Promote: VoiceOver audit (was Part B §8.2 stretch → P1).** Voice Dream's loyal base is heavily accessibility-driven (blind/low-vision, dyslexia). Echo's a11y story (OpenDyslexic/Lexend fonts, the `ScrubberJoystick` VoiceOver work) is a real wedge — finish a full-screen VoiceOver pass and treat accessibility as a headline feature, not a checkbox.
2. **🛡️ Protect: watch persistence (✅ Part B §1.8).** A stateless watch app is the category's #1 complaint and Voice Dream's biggest weakness. Echo's durable-state watch target is a flagship differentiator — guard it against regression (relaunch / wrist-down / app eviction).
3. **🛡️ Protect: narration thermal behavior (WS-N).** Render-then-play vs Voice Dream's real-time synthesis is *the* narration differentiator. Don't regress it into on-the-fly synthesis. *(Caveat: Fox Reader proves streaming can feel instant — pursue the §A.1 hybrid that gets streaming's start latency **without** abandoning the cached-AAC thermal win.)*
4. **📐 Bar to meet: cross-device sync (WS8) & widget polish.** Prologue's position sync and BookPlayer's widget/complication polish set the quality bar. Keep Audiobookshelf (WS8b) *optional and additive* — never the front door, unlike Prologue's server-first onboarding. **Sharper now:** the solo-dev **Fox Reader shipped working iCloud sync at v1.3** (`§7.9`) while Echo's WS8 is still anchors-only — reinforces WS8 priority.
5. **🔁 Reposition: lead on the STUDY layer; alignment is the on-ramp (broadened 2026-06-19, was Fox-Reader-only).** Fox Reader ships the **same Kokoro model** Echo uses — fully on-device, fast, even on an A14 — so **on-device TTS and voice *quality* are no longer differentiators**. **Broader now:** the *alignment* half is also contested — **Voxlight** (§7.11) clones the recipe and **AudioBookSync** (§7.12) ships on-device ASR of real narration today, while Audible/Spotify/Kindle shipped sync at scale. So narration messaging must lead with "real-narrator alignment + SRS study," **and the overall pitch must lead with the STUDY layer**, with alignment as the on-ramp. Privacy still wins as a *contrast* vs ad-supported (Fox) / cloud-AI (Speechify/Voiser), tied to GPL-3.0 auditability. *Touches README/site/store copy; not a code change.*

6. **🛡️ Protect + DEEPEN: the SRS study layer is now THE moat (Voxlight/AudioBookSync §7.11–§7.12).** Both new sync rivals contest the alignment half but **neither has any study layer** — and the internal moat analysis found study is the uncontested leg. This is an open window, not a permanent fortress: the SRS barrier is product-*identity*, not engineering (SM-2 is public, `.apkg` documented, the audio snippet is a timestamp pointer). **Prioritise FSRS, audio-snippet review polish, watch haptic-review robustness, and `.apkg` round-trip** so catching up means out-building a *study product*, not bolting on one feature. **Also protect the other headline differentiator — continuous _word-level_ DTW read-along** (WS-N / `WordTimingMaterializer`): the sync cohort matches *chapters*, Echo follows every *word*. Keep it bulletproof, and audit/narrow any "only/no-competitor" alignment claims in README/site/store copy.

7. **🆚 Reposition vs Voxlight / AudioBookSync: study SYSTEM, not sync READER (new).** Voxlight needs you to own **both** the audiobook **and** the ebook and needs a **Mac** for word-level; Echo does word-level on-iPhone, adds SRS + capture + watch, and **narrates text-only EPUBs**. **AudioBookSync** (shipping since 2026-04) is a *sync/search* tool with **no study layer**, and its binding looks **position/OCR-level, not continuous word-level** — *verify hands-on*. Voxlight is **pre-launch** (no confirmed App Store ID) — treat its launch as a **copy-audit tripwire**. The study-layer + founder-story lines are launch-proof and should carry the weight.

8. **🔭 Evaluate: photo-of-a-page → audio jump (AudioBookSync §7.12 + Spotify Page Match).** The one row where Echo is *behind* (§8b). Echo **already builds the WhisperKit transcription index** that makes a "scan a page → jump the audio" affordance cheap — extending Echo to the **physical-book-without-an-EPUB** case its EPUB-anchored pipeline can't serve, and matching AudioBookSync's demoable OCR feature. Scope as a **curb-cut feature spike** (camera → find-my-spot), *not* a defensive must-have.

9. **🔎 Research backlog (from origin/main).** Confirm **AudioBookSync**'s App Store ID, exact price, and whether it (or *any* cohort app) does true word-level read-along. **Voxlight** confirmed real but **chapter-level**. Adjacent, noted-not-tracked: **SyncBooks** (id `6761034564`, language-learning, sentence-level, public-domain classics — a *different* target) and **Vlume** (id `1325346984`, **ruled out** — a $7.99/mo content-subscription catalog, not a personal-file sync tool).

---

## Part B — Original Blueprint (Phases 1–9, historical)

Phases 1–7 are complete and preserved as engineering history. Forward-looking items in Phases 8–9 are now tracked under the workstreams in Part A.

## Phase 1: Stability & Correctness Fixes

Goal: eliminate crashes, data races, silent failures, and memory leaks before adding features.
### 1.1 — Concurrency Safety (data race prevention)

- [x] **Add `@MainActor` to `@Observable` classes** — `BookmarkArtworkCoordinator`, `BookmarkStore`, `PlaybackProgressPresenter`, `PlaybackTimelineService`, `TimelineService` all mutate observable state without main-actor isolation. Observed: data races when properties are read from Task continuations or timer callbacks.
- [x] **Add `Sendable` conformance to all model types** — 29 files across Models/ and Shared/ lack explicit `Sendable`. Under Swift 6 strict concurrency, these types cannot safely cross actor boundaries. Every struct (Note, Chapter, Track, TimelineItem, ContentCard, etc.) and protocol needs it.
- [x] **Add `@MainActor` to UI-facing protocols** — `BookmarkStoreProtocol`, `PlaybackControllerProtocol`, `SleepTimerManagerProtocol`, `SettingsManagerProtocol`, `StoreManagerProtocol` all expose UI-bound state without isolation guarantees.
- [x] **Fix `MainActor.assumeIsolated` in migration closures** (`DatabaseService.swift:73-96`) — GRDB runs migrations on internal writer queues (not main actor). If `DatabaseService.init()` is ever called off the main thread, this crashes. Replace with synchronous `try db.write` inside the migration block without the assumeIsolated wrapper.
- [x] **Audit all `DispatchQueue.main.async` inside `@MainActor` classes** — `PlaybackController` has 13+ redundant main-queue dispatches since the class is already `@MainActor`. These mask the actor guarantee and add unnecessary overhead.

### 1.2 — Crash Elimination

- [x] **Replace `fatalError` in `EPUBAssetStorage.rootDirectory`** (line 23) — crashes the app if Application Support is unavailable. Return an optional or throw.
- [x] **Replace force-downcasts in `TimelineFeedCollectionView`** (lines 276, 324) — `as! ElasticScrubberCell` and `as! StickyReviewHeaderView` will hard-crash if cell registration falls out of sync with the data source. Use `guard let` with a fallback cell + log.
- [x] **Fix `TranscriptStore` missing `deinit`** (macOS) — `NotificationCenter.addObserver` in `init()` with no `removeObserver` in `deinit`. Dangling pointer crash on deallocation. Switch to block-based observation or add deinit.
- [x] **Fix `SettingsDAO.getAll()` trap on duplicate keys** — `Dictionary(uniqueKeysWithValues:)` crashes if duplicates exist. Use `Dictionary(_:uniquingKeysWith:)` with a conflict resolver.
- [x] **Fix `EchoPlaylistManifest` Codable fragility** — struct declares defaults (`var version: Int = 1`) but `Decodable` synthesis ignores them. Missing keys in JSON cause decode failure. Implement custom `init(from:)` with fallback values.

### 1.3 — Memory Leaks & Resource Management

- [x] **Fix `AudioEngine.fadeGain` leaking Timer** (lines 201-210) — `Timer.scheduledTimer(withTimeInterval:repeats:true)` is never stored or invalidated. Multiple calls accumulate concurrent timers fighting over gain. Store the timer as a property; invalidate in `stop()`/`cleanup()` and before starting a new fade.
- [x] **Fix `TranscriptStore` NotificationCenter leak** (macOS) — same as crash fix above, also a memory leak.
- [x] **Audit `PlayerModel.deinit` Task capture** (line 626-638) — captures `audioEngine` and `bookmarkStore` in a `Task` during deinit. If deinit runs off-main, the `@MainActor` dispatch races against teardown.

### 1.4 — Silent Failure Remediation

- [x] **Replace `try?` in `InlineFlashcardTriggerController`** (lines 52, 87) — flashcard loading and grading failures silently return empty/no-op. Add `os_log` error logging at minimum; surface failures to UI where appropriate.
- [x] **Replace `try?` in `SnippetPlayer`** (lines 20, 24) — silent failure when audio file unreadable or segment zero-length. Caller never knows playback didn't start. Invoke `onPlaybackDidEnd` with a failure flag.
- [x] **Replace empty `catch` blocks in `FlashcardCreationSheet`** (line 87) and `NoteEditorView` (line 72) — database insert failures silently discarded. Show a user-visible error or at minimum log with `os_log`.
- [x] **Fix `try?` in `DailyReviewViewModel.logFlashcardReviewed`** (line 68) — review history silently lost on logging failure.
- [x] **Fix `try?` in migration `ensureAudiobookExists`** (MigrationService) — genuine failures (disk full, constraint) silently ignored; child records may insert without parent.
- [x] **Fix macOS `try?` transcription/export errors** (`MacContentView:75`, `TranscriptPane:196`) — transcription and export failures disappear with zero user feedback.
- [x] **Replace `print()` with `os_log`** across ~15 locations — `AudioEngine`, `ArtworkCache`, `BookmarkStore`, `Persistence`, `TranscriptService`, `WatchSyncManager`, `WatchCommandRouter` all use `print()` for errors. In production, these go to a console no one reads.

### 1.5 — Database Integrity & Performance

- [x] **Add missing indexes**: `audiobook.added_at` (full scan on every library listing), `playback_state.last_played_at` (same), `transcription_word.segment_id` (zero indexes on this table).
- [x] **Fix LIKE wildcard injection in `EPubBlockDAO.search`** (line 76) — user input `%` and `_` characters act as SQL wildcards. Escape them or use a different matching strategy.
- [x] **Fix JSON injection in `BookmarkDAO` metadataJSON** (line 84) — `voiceMemoPath` interpolated directly into a JSON string. Paths containing `"` or `\` produce invalid JSON. Use `JSONEncoder` or proper escaping.
- [x] **Fix `transcription_word` table** — no primary key, no unique constraint, no indexes. `MutablePersistableRecord` semantics are unreliable without an explicit PK.
- [x] **Fix `flashcard` dead columns** — `created_at`/`modified_at` exist in schema but the `Flashcard` struct has no matching properties. Columns never updated; feature non-functional.
- [x] **Make V4 migration atomic** — individual bookmark/speed/setting migration failures are caught and logged but leave the DB in partial state. Wrap in a single transaction.
- [x] **Fix `speed` type mismatch** — `PlaybackEventDAO` parameter is `Float` but schema column is `Double`. Inconsistent with rest of codebase where speed is `Double`.le`. Inconsistent with rest of codebase where speed is `Double`.

### 1.6 — Pipeline Tooling Fixes

- [x] **Fix hardcoded "OEBPS" base path** (`EPUBAlignmentPipeline.swift:83`) — breaks alignment for EPUBs with non-standard directory layouts (EPUB/, content/, flat). Now derives base path from OPF file location via `opfPath.deletingLastPathComponent()`.
- [x] **Fix XHTMLParser silent XML parse failures** (line 37) — return value of `parser.parse()` discarded; partial/malformed data silently propagated. Now checks the return value and throws `AlignmentError.corruptXHTML` on failure.
- [x] **Fix XHTMLParser silent UTF-8 conversion failure** (line 34) — `guard let data = ... else { return }` silently drops entire spine items. Now throws `AlignmentError.corruptXHTML` with a descriptive reason.
- [x] **Fix orphaned markers appended at end** (`MarkerInjector.swift:117`) — un-timestamped segments always placed after all timestamped segments, breaking EPUB reading order. Now interleaves by `epubCharOffset` between the correct alignment boundaries.
- [x] **Make alignment threshold configurable** (`SlidingWindowAligner.swift:75`) — hardcoded 0.40 match acceptance. Added `matchAcceptanceThreshold` parameter to the initializer (defaults to 0.40).
- [x] **Validate Whisper model name before init** (`TranscribeCommand.swift:56`) — typos like "Base" instead of "base" produce late, cryptic errors. Added `validate()` method checking against known WhisperKit model identifiers.
- [x] **Python: support GPU/MPS device** (`transcription_generator.py:175`) — hardcoded `device="cpu"`. Added `--device` flag with `auto` default that detects CUDA availability; uses `float16` compute on GPU for better throughput.

### 1.7 — View & UI Model Fixes

- [x] **Fix `TransportButton` accessibility** — the custom `PrimitiveButtonStyle` never calls `configuration.trigger()`, breaking VoiceOver, keyboard navigation, and standard press-and-release. Added `configuration.trigger()` calls in both tap and long-press gesture handlers.
- [x] **Fix `NowPlayingTab.formatHhMm` rounding** (line 90-99) — `Int((seconds / 60.0).rounded())` rounds up, causing "2m" at 89.6s instead of "1m". Changed to truncation (`Int(seconds / 60.0)`).
- [x] **Fix `TimelineGroup.id` collision** — `ISO8601Format()` without fractional seconds; two groups in the same second get identical IDs violating `Identifiable`. Now uses `.iso8601(includingFractionalSeconds: true)`.
- [x] **Fix `TranscriptionSegment.id` float precision** — `"\(startTime)-\(endTime)"` can produce different strings for logically identical timestamps (`0.1` vs `0.10000000000000001`). Now uses integer milliseconds.
- [x] **Fix `Note.id` mutability** — `var id: String` violates `Identifiable` stability contract. Already `let` — no fix needed.
- [x] **Add missing `Equatable`/`Hashable`** to `AggregatedChapter`, `M4BBook`, `Chapter` — prevents use in Sets/Dictionary keys and causes unnecessary SwiftUI re-renders. Added compiler-synthesized conformances.

### 1.8 — watchOS Critical Fixes

- [x] **Fix stale `watchQuickBookmarkTimeoutSeconds`** — closure-initialized stored property read once at init. `applyState` writes new UserDefaults value but the property never updates. Changed to computed property with getter/setter backed by App Group defaults.
- [x] **Fix voice memo payload size** — `sendMessage` (65KB limit) and `transferUserInfo` (~65KB) both fail for voice memos. Now uses `WCSession.transferFile(_:metadata:)` which has no payload limit and is handled by existing `handleFile` on the phone side.
- [x] **Fix widget timeline spam** (WatchViewModel:473) — `WidgetCenter.shared.reloadTimelines` called on every WCSession state update (0.5-1s during playback). Now debounced to at most once per 30 seconds.
- [x] **Fix haptic hailstorm** (WatchViewModel:529, 552-558) — haptics fire on every command reply + optimistically before confirmation. Multiple rapid haptics desensitize. Added centralized `playHaptic(_:)` helper gated behind `isHapticFeedbackEnabled`; all 8 haptic call sites now respect the user preference.

### 1.9 — macOS Critical Fixes

- [x] **Fix `process.waitUntilExit()` blocking** (`TranscriptionManager:246`) — synchronous blocking inside `withTaskGroup` blocks a cooperative thread. Replaced with `withCheckedContinuation` + `process.terminationHandler` for proper async suspension.
- [x] **Fix hardcoded 300ms delay** (`MacPlayerModel:300-303`) — `Task.sleep(nanoseconds: 300_000_000)` waiting for duration to load. Replaced with `waitForReadyToPlay()` using KVO on `AVPlayerItem.status` with a 10s safety timeout.
- [x] **Fix `UserDefaults.standard` vs `AppGroupDefaults`** — macOS uses isolated UserDefaults for bookmarks; invisible to iOS/watchOS. Switched to `AppGroupDefaults.shared` with a one-time migration from `UserDefaults.standard`.

### 1.10 — Performance: Hot Path Allocations

- [x] **Cache `DateFormatter`/`ISO8601DateFormatter`** — `SpeedSuggestion.formattedDate` (new formatter every access), `TimelineScope.format()` (new formatter per call), `Note.init(from:)` (3 formatters per record), `RealTimeEvent.init(from:)` (1 per record). Made static lets on the respective types.
- [x] **Batch `AlignmentService.recalculateTimeline` SQL writes** — individual `updateAlignment` calls in a loop; thousands of separate transactions for large books. Wrapped all writes in a single `db.write` transaction via a new fileprivate `writeAlignment(db:...)` overload.
- [x] **Optimize `PlaylistView.playlistRows`** — computed property iterates all chapters/filters/sorts bookmarks on every body recomputation. Cached to `@State` and recomputed only on dependency changes via `.onChange` observers.

---

## Phase 2: Strip Unimplemented Feature References ✅

Goal: remove dead code and forward-looking references that mislead contributors.

- [x] **Remove all video/future-media references** — `MediaPlayable` protocol doc ("future video features"), property names `audioStartTime`/`audioEndTime` (rename to `startTime`/`endTime` since there's no video to disambiguate), any "forward-looking for video" comments.
- [x] **Remove stale `.claude/plans/` directory** — 29 plan files dating back to early refactoring phases. Already staged for deletion (shown in git status). Complete the removal.
- [x] **Remove `ALPHA_OVERNIGHT_NOTES.md` and `neededfixes.md`** — already staged for deletion. Complete.
- [x] **Remove dead code**: `timelineDAO` property on `BookmarkDAO` and `FlashcardDAO` (declared but never assigned), unused `Combine`/`CryptoKit` imports in `TranscriptStore` and `TranscriptionManager`, redundant `Identifiable` conformance on `ContentCard`.
- [x] **Remove `ContentCardEditor.saveChanges()` stub** — empty function with "Phase 6 note: actual DB save wired in later iteration". Either implement or remove the Save button.
- [x] **Remove `contentCard.cardType` default case** — shows "Not Editable" view while still offering a Save button. Misleading UX.
- [x] **Remove single-case `PlayerDeepLink` enum** — convert to struct with optional `time` property.
- [x] **Remove `Optional.isNil` extension** (macOS TranscriptPane) — pollutes global namespace; `== nil` already exists.
- [x] **Remove redundant V3 index registrations** — V3 re-creates indexes V1 already made. `ifNotExists: true` makes this safe but indicates sloppy versioning.
- [x] **Remove macOS `ObjCBool` usage** — use modern `Bool` with new API or `resourceValues(forKeys:)`.
- [x] **Remove duplicated SHA256 hashing** (macOS ×3) — `MacContentView`, `TranscriptionManager`, `TranscriptPane` all have identical hashing. Extract to `Shared/`.
- [x] **Remove `SpeedSuggestion.Scenario.insufficient(Double)` unused associated value** — switch case ignores the payload. Remove or use the value.
- [x] **Remove `ContentCard.isSummaryItem` default case** — use exhaustive switch so compiler catches new enum additions.
- [x] **Remove dead `.transcription` check in `ContentCard.init(from: RealTimeEvent)`** — `isEditable` checks for `.transcription` but the switch never produces that case.

---

## Phase 3: UI Polish & Accessibility

Goal: improve fit-and-finish, Dynamic Type support, and accessibility compliance.

- [x] **Fix hardcoded layout constants** — ✅ GeometryReader pushed down to relevant views only. Dynamic Type via @ScaledMetric on dashboard cards.
- [x] **Add Dynamic Type support** to `ListeningProgressModuleView` (fixed 140pt width), `ChapterTimeBlockView` (hardcoded 28pt bar), `StatsModuleView`, dashboard cards — ✅ replaced with @ScaledMetric.
- [x] **Add `.accessibilityAddTraits(.isButton)`** to custom-styled buttons on macOS and watchOS — ✅ added to 15+ buttons across 8 files.
- [x] **Audit all `UIImpactFeedbackGenerator` calls** for overuse — ✅ created `Haptic` utility gated behind `isHapticFeedbackEnabled`; replaced 20+ call sites.
- [x] **Fix `SpeedCardView` speed cycle inconsistency** — ✅ `SettingsManager.Defaults.speedPresets` as single source of truth; watch synced to 5 speeds.
- [x] **Extract reusable `InlineStepperRow`** — ✅ promoted to `Views/Components/InlineStepperRow.swift`.
- [x] **Push `GeometryReader` down in `NowPlayingTab`** — ✅ restricted to `playerContent` only.
- [x] **Decompose large view bodies**: ✅ `loadFolder` split into 6 helpers, `prepareToPlay` into 5 helpers, `play()` smart rewind into 4 helpers.
- [x] **Fix `playlistRows` performance** — ✅ already memoized via `@State` + `.onChange` (Phase 1.90).
- [x] **Add empty states** to timeline feed, bookmarks list, and review queue — ✅ timeline feed gets `ContentUnavailableView`; playlist and review already covered.
- [x] **Add error states** to flashcard creation, note editing, and content card editor — ✅ save failures now show alert dialogs with localized error messages.
- [x] **Make volume boost gain configurable** — ✅ `SettingsManager.volumeBoostGain` (default 9.0 dB), plumbed through PlaybackController → AudioEngine.
- [x] **Make NowPlaying skip intervals respect user settings** — ✅ `NowPlayingController` reads `seekForwardDuration`/`seekBackwardDuration`.
- [x] **Fix macOS hardcoded audio extensions** — ✅ added `aiff`, `aac`, `ogg`, `opus`, `wma`, `flac`.
- [x] **Fix `NowPlayingTab` chapter/track progress text duplication** — ✅ extracted shared `bookProgressParts()` helper.

---

## Phase 4: Spaced Repetition System (SRS)

Goal: fix existing Anki/flashcard code, then implement proper SM-2 scheduling.

### 4.1 — Fix Existing Flashcard Code ✅

- [x] **Fix silent flashcard grade failures** — ✅ `PlayerModel.gradeFlashcard` now uses `do/catch` with `os_log`. `InlineFlashcardTriggerController` and `DailyReviewViewModel` already hardened in Phase 1.
- [x] **Fix silent flashcard load failures** — ✅ watch state and `TimelineTab.refreshDueCount` now use `do/catch` with error logging.
- [x] **Fix `SnippetPlayer` silent completion failure** — ✅ all failure paths (file read, zero-length, engine start) already call `onPlaybackDidEnd?()`.
- [x] **Fix flashcard `created_at`/`modified_at` dead columns** — ✅ set on creation (`FlashcardCreationSheet`, `DeckImportService`) and on grading (`SpacedRepetitionService.apply`).
- [x] **Fix `flashcardDeckImport.triggerTiming` as free-form String** — ✅ introduced `FlashcardTriggerTiming` String-backed enum with `.beginning`, `.end`, `.manualOnly` cases.
- [x] **Fix `logFlashcardReviewed` silent logging failures** — ✅ already uses `do/catch` with `logger.error` (Phase 1).
- [x] **Fix `DailyReviewViewModel` error swallowing** — ✅ `loadDueCards`, `gradeCard`, and `logFlashcardReviewed` all use `do/catch` with logging (Phase 1).
- [x] **Fix stale `SnippetPlayer` generation counter** — ✅ generation guard `generation == self.currentGeneration` prevents stale callbacks.

### 4.2 — Implement SM-2 Algorithm ✅

- [x] **Design SM-2 data model** — ✅ `Flashcard` already includes easeFactor, intervalDays, repetitions, nextReviewDate, lastGrade, lastReviewedAt.
- [x] **Implement SM-2 core algorithm** — ✅ `SpacedRepetitionService.apply(grade:to:)` implements full SM-2 (interval progression, lapse handling, ease factor).
- [x] **Build daily review queue** — ✅ `FlashcardDAO.allDueCards()` queries by `next_review_date <= now`, used by `DailyReviewViewModel`.
- [x] **Add review session UI** — ✅ `FlashcardReviewSession` + `FlashcardReviewCard` with graded review flow.
- [x] **Add review statistics** — ✅ `FlashcardDAO.reviewStats()` returns dueCount, reviewedToday, totalCards. Wired into `UpcomingReviewsModuleView`.
- [x] **Add push notification trigger** — ✅ `ReviewNotificationService` schedules daily local notification when due cards exist.

### 4.3 — Inline Recall During Playback

- [x] **Fix inline flashcard trigger tolerance** — ✅ tolerances centralized as constants in `InlineFlashcardTriggerController`; trigger logic hardened in Phase 1.
- [ ] **Improve trigger detection** — current approach checks `currentSeconds` against card timestamps. Consider matching against timeline position ranges for robustness. (Deferred: requires timeline-anchored triggering model.)
- [ ] **Fix watch review session sync** — ensure `WatchReviewView` stays in sync with phone-side review state. (Deferred: requires WatchConnectivity review state channel.)

---

## Phase 5: EPUB Viewing

Goal: a dedicated EPUB reader experience integrated with the audiobook timeline.

### 5.1 — Dedicated Reader Tab (Option A) ✅

- [x] **Add 3rd tab to `RootTabView`** — "Read" tab alongside NowPlaying and Timeline. Implemented as `ReaderTab` with 3-tab navigation managed by `RootTabView`.
- [x] **Build paginated EPUB renderer** — Feed-based `UICollectionView` (`ReaderFeedCollectionView`) rendering heading, paragraph, image, and chapter divider cards with CSS-styled attributed text. 4 cell types: `HeadingCardCell`, `ParagraphCardCell`, `ImageCardCell`, `ChapterDividerCell`.
- [x] **Implement font controls** — `ReaderSettings` bundle: font size, line spacing, card background tint color (hex). Persisted per-app-session via `@State` in `ReaderTab`.
- [x] **Add reading position sync** — Active block tracking via binary search on `timelineCache` (O(log N) lookup). Active paragraph highlighted with blue leading bar (`activeBar`). Auto-scroll follows playhead and disengages on manual scroll.
- [x] **Add tap-to-seek** — Tap any paragraph or heading card to seek playback to the block's interpolated audio timestamp. Tap image cards to open in system viewer.
- [x] **Add offline reading** — EPUB blocks rendered from local database (`EPubBlockDAO`). Images copied to Application Support on import. No network dependency for reading.
- [x] **Full-text search** — Search bar in reader header with inline match highlighting. `EPubBlockDAO.searchBlocks()` with escaped LIKE wildcards for safe user-input matching.
- [x] **Table of Contents** — `ChapterPickerSheet` for structural navigation through the EPUB spine.
- [x] **Per-card color override** — Long-press → "Change Color" → `CardColorPickerSheet` for highlighting passages.
- [x] **Bookmark creation from reader** — Long-press any card → "Save Bookmark" creates a timestamped bookmark at the block's audio position.

### 5.2 — Integrated Timeline Reader ✅ (converged with 5.1)

- [x] **Add EPUB content cells to `TimelineFeedCollectionView`** — `TimelineFeedCollectionView` renders paragraphs, chapters, and images as `TimelineItem` rows alongside bookmarks and flashcards, with anchor status icons on aligned items.
- [x] **Implement highlight-tracking** — Timeline feed supports active position tracking with inline anchored-content display.
- [x] **Leverage existing `EPubBlock`/`AlignmentAnchor` data** — Schema V5 tables used throughout. Timeline items linked to EPUB blocks via `epub_block_id` foreign key with `alignment_status` and `timestamp_source` columns.
- [x] **Dual surface support** — Both dedicated Reader tab (card-feed UX) and Timeline tab (list-feed UX) surfaces are live, each offering alignment management and context menus. The Reader tab is the primary reading surface; the Timeline tab shows aligned content in its heterogeneous feed.

### 5.3 — Decision Gate ✅ (resolved)

- [x] Prototype both approaches with a single-book test. → Decided on Option A (dedicated Reader tab) with Timeline feed retaining EPUB-aware cells.
- [x] Measure scroll performance with full EPUB content (thousands of blocks). → `UICollectionView` with `NSDiffableDataSourceSnapshot` handles large datasets performantly via cell reuse.
- [x] Evaluate: does the timeline feed handle EPUB-length content without performance degradation? → Yes, with efficient cell reuse and section grouping.
- [x] Evaluate: does a dedicated reader tab create undesirable context-switching during listening? → No; the Reader tab provides a focused reading experience that complements (not competes with) the NowPlaying tab. Transport controls remain accessible via the `BottomToolbarView`.
- [x] **Decide and commit to one approach.** → Option A: Dedicated Reader tab as primary reading surface; Timeline feed as secondary EPUB-aware surface.

---

## Phase 6: EPUB Manual Alignment ✅ (core complete)

Goal: let users create and edit alignment anchors between EPUB blocks and audio timestamps.

- [x] **Build anchor creation UI** — "Align to Now" / "Align to 5s Ago" context menu actions on every card in both Reader and Timeline feeds. Writes `alignment_anchor` records via `AlignmentAnchorDAO`.
- [x] **Build chapter boundary anchors** — "Align to Chapter Start/End" on heading cards for bulk chapter anchoring.
- [x] **Implement interpolation recalculation** — `AlignmentService.recalculateTimeline()` uses word-count-based proportional interpolation between locked and virtual boundary anchors, replacing the earlier sequence-index-based approach for more accurate positioning (Schema V8).
- [x] **Add visual anchor indicators** — Locked-anchor cards show a green "link" label (Reader) or 🔗 icon (Timeline) with the anchored timestamp. Interpolated/estimated items show appropriate status text.
- [x] **Add anchor management** — "Erase Anchor" to remove a single anchor, "Reset Alignment" to clear all anchors for a book. Both trigger timeline recalculation and UI refresh.
- [x] **Handle edge cases** — Virtual boundary anchors at chapter starts/ends, block-level word-count weighting for proportional distribution, sentinel values (`-1`) for un-timestamped items.
- [ ] **Add anchor import/export** — share alignment data between devices or users. (Deferred: requires export format design.)
- [ ] **Word-count weighting for automatic alignment hints** — use `wordCount` column (Schema V8) for smarter initial estimates without manual anchors. (Deferred: auto-alignment heuristics beyond current proportional interpolation.)

---

## Phase 7: Testing & CI Infrastructure

Goal: prevent regressions as the codebase grows.

- [~] **Expand unit test coverage** — current test files exist but are sparse. Added tests for `PlaybackSessionRecorder` and `PlaybackSegmentBuilder` state machine.
- [ ] **Add snapshot tests** for critical UI — NowPlayingTab, TimelineFeed cells, PlayerScrubberView section ticks.
- [x] **Add database migration tests** — verify each schema version upgrade path with realistic data. (Added SchemaV14Tests covering stats/bookmark columns and backfills).
- [ ] **Add pipeline integration tests** — end-to-end EPUB → align → enhanced transcript with known fixtures.
- [ ] **Set up CI** (GitHub Actions or Xcode Cloud) — build all 4 targets, run tests, enforce Swift 6 concurrency checking.
- [ ] **Add performance regression tests** — timeline feed scroll FPS, database query latency with large datasets.
- [ ] **Add accessibility audit to CI** — flag missing accessibility labels/traits.

---

## Phase 8: Study Workflow & Polish

Priority items for the Echo rebrand and study-player positioning, plus stretch goals.

### 8.1 — Study Workflow Foundation (P0)

- [ ] **Interactive onboarding tutorial** — first-launch walkthrough demonstrating the core study workflow: load audiobook → add EPUB → search → align a paragraph → create bookmark → create flashcard. A 4-step interactive guide that teaches the mental model. The Read tab should always be visible (not hidden behind `hasEPUB`), showing an educational empty state: "Add an EPUB alongside your audiobook to unlock searchable text, alignment, and flashcards."
- [ ] **Reader toolbar speed controls** — add speed adjustment (at minimum) and loop mode to the reader-specific bottom toolbar. Studying means variable playback speed — slowing down for dense passages, speeding up through familiar material. Requiring a tab switch to change speed breaks the study flow.
- [ ] **Alignment as achievement, not chore** — show "% aligned" progress per chapter and per book. Celebrate when a chapter is fully aligned. After creating an anchor, offer contextual actions: "Create flashcard from this passage?" / "Add bookmark with this text?" Anchors are study waypoints — the UI should treat them that way.
- [ ] **Replace inline flashcard popups with mark-later model** — remove `InlineFlashcardTriggerController` auto-popovers that interrupt playback. Replace with: tag passages during listening → review tagged passages and create flashcards in a dedicated session later. Listening should be immersive; flashcard creation should be intentional and separate. (The trigger controller logic was hardened in Phase 1/4; this item is about UX redesign, not code health.)
- [~] **iCloud sync for study state** — sync bookmarks, alignment anchors, flashcards, and playback position across devices via CloudKit (leveraging the existing GRDB database layer). This is the single biggest infrastructure gap blocking the multi-device study workflow. A user who aligns 200 paragraphs on iPhone should see those anchors on iPad and Mac. **Progress:** `CloudKitSyncService` infrastructure in place with deterministic SHA-256 record names and `NSNumber`-based predicates. Sync currently covers alignment anchors. Full bookmark/flashcard/position sync still needed.
- [~] **Ship the Echo rebrand** — update app display name, bundle identifiers, App Store Connect metadata, screenshots, and marketing site. The name "Echo" reflects the core value: your spoken words echoing back as searchable, referenceable knowledge. Screenshots must demonstrate the study workflow within 10 seconds (search → align → bookmark → flashcard). **Progress:** Documentation (README, ARCHITECTURE, CHANGELOG) and the website use Echo branding. Xcode project bundle identifiers and the app group are now migrated to `com.echo.*` (entitlements, code, and `project.pbxproj`). The Fastlane `Appfile` still references `com.orbit.*` (flagged with TODO markers) pending coordinated App Store Connect changes and provisioning-profile regeneration (see `docs/provisioning-rebrand.md`).

### 8.2 — Polish & Stretch Goals

- [ ] **Localization completeness audit** — Dutch localization exists; verify coverage across all user-facing strings.
- [ ] **iPad layout optimization** — current layout targets iPhone; iPad gets a scaled-up version. Consider split-view or sidebar for TimelineTab on iPad.
- [ ] **CarPlay enhancements** — `CarPlaySceneDelegate` exists but is minimal. Add Now Playing template, browse-by-chapter, Siri intents.
- [ ] **Widget enhancements** — multiple widget families (`.accessoryRectangular`, `.accessoryInline`), playback progress complications.
- [ ] **Siri Shortcuts integration** — "Resume my audiobook", "Add a bookmark", "Start daily review."
- [ ] **Stats & insights dashboard** — listening time, books completed, speed trends, review streaks.
- [ ] **Social/sharing features** — share bookmark with quote, export reading progress, book club sync.
- [ ] **Audio effects** — equalizer presets, silence trimming, chapter-level volume normalization.
- [ ] **Accessibility: VoiceOver audit (⬆️ P1 — elevated per Competitive Priorities §A.3)** — full pass through every screen with VoiceOver enabled. Prioritized because Voice Dream's loyal base is accessibility-driven; this is a competitive wedge, not a stretch goal.
- [ ] **macOS polish** — proper menu bar integration, Touch Bar support, keyboard shortcuts for all transport actions.

---

## Phase 9: Audiobookshelf Integration

Goal: connect a self-hosted **Audiobookshelf (ABS)** server as a first-class library source so a self-hosted collection flows into Echo's study pipeline.

**Sequencing:** lands **after the on-device narration (Kokoro) workstream**, **before WS9 "Polish & release"** (README → *The Road to v1.0*; this is WS8b). Targeted for 1.0. Full design rationale + verified source citations: the 2026-06-14 assessment.

**Central decision — download, don't stream.** Echo's audio engine reads bytes via `AVAudioFile(forReading:)` (local-only; `AudioEngine.swift:333`) and a book's identity *is* its folder URL. Once ABS bytes land in a folder the book is indistinguishable from a local import and **every differentiator keeps working** (alignment, phrase search, EPUB sync, flashcards). Streaming would fork the audio engine (XL) and disable those features — it is **deferred post-1.0** (§9.5).

### 9.1 — Foundation: connect & browse (size: M)

- [x] **`AudiobookshelfService`** — concrete `@MainActor` class, injected `URLSession`, no protocol (matches the concrete-type DI style — see §10.1 history).
- [x] **Auth** — JWT login + refresh-with-rotation (persist the rotated refresh token *every time*; serialize refreshes to avoid self-invalidation). Tolerates self-signed certs, LAN `http`, and non-standard ports.
- [x] **Credential storage** — per-server token in `KeychainStore`. `abs_server` table (`id, baseURL, username, defaultLibraryId`); token never goes in SQLite.
- [x] **Settings UI** — Settings ▸ Library Sources (Connections screen, iOS). One server; multi-server is a fast-follow.
- [x] **Browse** — list libraries → items → item detail with covers.

### 9.2 — Download-to-local — the core (size: L)

- [x] **"Add from Audiobookshelf"** action on the library screen.
- [x] **Background-task grace window** — `beginBackgroundTask` keeps an in-flight download alive when the user backgrounds. *Full `URLSessionConfiguration.background` resumable download is a fast-follow (ABS zip lacks `Content-Length`/range headers).*
- [x] **Managed library folder** — audio + EPUB land in `Application Support/ABSLibrary/<remoteItemID>/`.
- [x] **EPUB bundled download** — sibling `.epub` downloaded when `media.ebookFile` exists; `EPUBAutoImportScanner` auto-discovers it; alignment/flashcards/search fire with zero pipeline changes.
- [x] **Hand off to the existing pipeline** — `PlayerLoadingCoordinator.loadFolder` called unchanged.
- [x] **Identity** — `id = folderURL.absoluteString`; V23 provenance columns (`source_type`/`server_id`/`remote_item_id`) stamp ABS origin on the `AudiobookRecord`.
- [x] **Anchor-reuse** — `CloudKitSyncService.downloadAnchors` keys anchors on `title+author+duration`; the persisted ABS title/author ensures a re-downloaded book inherits prior alignment anchors.

### 9.3 — Library discovery: search by topic (size: S–M)

- [x] **Server-side `.searchable`** — search the connected ABS library by title/author/genre/tag from within Echo. Library-level discovery, distinct from within-book phrase search.
- [x] **Topic metadata on import** — `topics_json` V23 column persists ABS genres/tags on the imported `AudiobookRecord`.

### 9.4 — Two-way progress sync — Tier 3-lite (size: M, fast-follow)

- [x] **Push/pull playback position** — ABS-authoritative last-write-wins reconciler; throttled push while playing; reconcile-on-load. *Pure reconciler logic unit-tested; live playback wiring device-unverified. Pull re-seek is single-track-only in v1.*
- [x] **Conflict policy** — ABS is authoritative for ABS-backed books; local sidecar is offline cache.
- [ ] **Offline reconciliation** — `POST /api/session/local-all` on reconnect. (Fast-follow.)

### 9.5 — Deferred (post-1.0)

- [ ] **Tier 1 streaming (XL)** — a parallel `AVPlayer` backend that re-implements pitch-corrected speed / EQ / soundscape / visualizer / progress-tick and re-validates CarPlay + Watch. Revisit only if no-download casual listening becomes a hard, user-validated requirement. On a streamed book the study differentiators are disabled — gate them behind the existing "Coming"-style CTA so the tradeoff is legible.
- [ ] **ABS bookmark / finished-state round-trip** — best-effort and lossy (ABS bookmarks are title+time only, no voice memo).
- [ ] **Multi-server** beyond the v1 single connection.

---

## Summary

### Part A — Road to v1.0 workstreams (canonical)

| # | Workstream | Status |
|---|------------|--------|
| WS0 | Listening capture layer | ✅ Shipped |
| WS1 | Identity & macOS foundation | 🟡 Mostly complete (Fastlane/provisioning pending) |
| WS2 | CI | 🟡 Build gate live; test action blocked by simulator runtime bug |
| WS3–4 | Insights | 🟡 Partial (modules shipped; full Charts screen pending) |
| WS5 | Context Memory | 🟡 Partial (schema groundwork) |
| WS6 | Anki core | 🟡 Partial (deck schema/import; Card Inbox pending) |
| WS6b | Brain Dump / Book Notes | 🟡 Partial |
| WS7 | Import / Export | 🟡 Partial (export exists; import pending) |
| WS-N | On-Device Narration (Kokoro) | ✅ Core shipped (Listen-UI polish + Mac theming pending) |
| WS8 | iCloud study sync | 🟡 Partial (anchors only) |
| WS8b | Audiobookshelf integration | 🟡 Built on branch `claude/romantic-wing-0dc47b` (V23; pending merge + device verify; progress-sync wiring unverified; full background-URLSession + multi-server + macOS UI + streaming = fast-follows/post-1.0) |
| WS9 | Polish & release | 🟡 Partial |
| WS10 | Docs & site content | 🟢 Ongoing |

**Competitive priorities (§A.3):** ⬆️ promote VoiceOver audit to P1; 🛡️ protect watch persistence + narration thermal behavior; 📐 meet Prologue's sync bar / BookPlayer's widget polish; 🔁 reposition narration messaging to real-narrator alignment (Fox Reader ships the same on-device Kokoro); 🧱 defend the alignment moat as "word-level read-along + study" (AudioBookSync now does on-device audiobook↔EPUB alignment too).

### Part B — Original blueprint (historical)

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Stability & Correctness Fixes | ✅ Complete |
| 2 | Strip Unimplemented References | ✅ Complete |
| 3 | UI Polish & Accessibility | ✅ Complete |
| 4 | Spaced Repetition System | ✅ 4.1–4.2 complete; 4.3 1/3 (2 deferred) |
| 5 | EPUB Viewing | ✅ Complete (dedicated Reader tab + Timeline integration) |
| 6 | EPUB Manual Alignment | ✅ Core complete (6/8 items); 2 deferred (anchor import/export, word-count alignment hints) |
| 7 | Testing & CI | Folded into WS2; ~6 items remaining |
| 8 | Study Workflow & Polish | Folded into WS5/6/8/9; Accent Contrast Safety ✅, Now Playing redesign ✅, Watch Connectivity hardened ✅, Pomodoro timer ✅, CloudKit sync infrastructure in place |
| 9 | Audiobookshelf Integration | 🟡 Core built on branch `claude/romantic-wing-0dc47b` (connect/browse/search/download/progress-sync; V23; pending merge + device verify; streaming deferred post-1.0) |

**Foundation (Phases 1–7): complete. Forward work tracked under Part A workstreams. Current schema: V23.**

### June 2026 Highlights (since last update)

- **Accent Contrast Safety Pipeline** — `ColorMetrics` (WCAG/CIELAB), `AccentSafetyNet` (A→B→C rescue ladder), `extractPalette` (shared histogram pass), artwork-derived accent color with legibility guarantees
- **Now Playing UI Redesign** — `UnifiedTopHeader`, `UnifiedBottomDock`, full-bleed artwork split layout, adaptive theming
- **Watch Connectivity Hardened** — Durable application context for significant state, transport commands never ride background queue, stale `userInfo` handling, timer suspension cap
- **Pomodoro Timer** — Hours support, multi-wheel picker, thicker progress indicator, dynamic formatting, persistent alarm
- **Watch Enhancements** — Fullscreen cover art viewer, configurable date overlay
- **Swift Concurrency Modernized** — `MainActor.assumeIsolated` across 9 service files, `nonisolated(unsafe)` annotations, `@preconcurrency import AVFoundation` project-wide
- **Bug Fixes** — Pause on output device disconnect, progress save before track change, EPUB auto-import security scope, security scope URL reuse, TokenDTW gap-cost initialization
