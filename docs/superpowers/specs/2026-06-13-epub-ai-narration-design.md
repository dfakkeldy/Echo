# Echo — On-Device AI Narration for Study EPUBs

**Date:** 2026-06-13
**Status:** Approved design — ready for implementation planning
**Author:** Dan (with Claude)

---

## 1. Goal

Let a user import a **study EPUB that has no audiobook** and, on demand, have Echo **narrate it with an on-device AI voice (Kokoro)** — producing the same sentence-synced, study-ready aligned book they'd get from a real audiobook, fully offline.

This is **additive**. The existing audiobook→EPUB alignment pipeline (WhisperKit + `TokenDTW`) is untouched and remains the path whenever a real audiobook exists. After this feature, Echo produces aligned books two ways: **align a real audiobook** (today) or **generate one** (new).

Primary use case: hands-free study of audio-less material on a commute/route, where the listener is often offline and eyes-occupied.

---

## 2. Scope

### In scope (v1 — core narration)
- Import a **standalone EPUB** with no audio; read + study (flashcards, notes, FSRS) immediately, no narration required.
- Generate narration on demand with an on-device neural voice.
- **Render-ahead** tied to playback (render the current chapter, then keep a chapter ahead; cache as you go).
- A small **curated voice set** with preview.
- Read-along highlighting + study layer over generated audio (reuses existing reader/player).

### In scope (Phase 2 — fast-follow)
- Export the generated narration — as **per-chapter audio files** (nearly free) and/or a single portable **`.m4b`** with chapters, metadata, and cover. (See §7.)

### Out of scope (v1)
- Narrating books that already have a real audiobook.
- **Non-English** narration (clean, GPL-free G2P is English-only — see §5).
- Cloud / premium voices.
- Any change to the existing WhisperKit alignment pipeline.

---

## 3. User experience

### 3.1 Entry point (framing **B** — read-first)
On opening an audio-less study EPUB, the book is **study-ready immediately**: "Read & study" is the primary action. A clear but **secondary** nudge offers narration:

> 🎧 No audiobook for this one — Echo can narrate it on-device so you can study hands-free. **[Listen ▸]**

The study tools (flashcards, notes, FSRS review) work the instant the book is imported. Narration is the only part generated on demand.

### 3.2 Voice picker (the "Listen ▸" sheet)
- **Curated set of 4** Kokoro voices: **Ava** (US, warm — *default*), a US male, a UK female, a UK male.
- **Preview**: each voice ships a short (~4s) **pre-rendered** sample clip so ▶ is instant and offline. (Do not synthesize previews on the fly.)
- The model is the single large bundle; each voice is a tiny style pack, so four voices is effectively free on storage.

### 3.3 Render model (v1.0: render-then-play per chapter)
Compute is tied to listening. On press of **Listen/Play**:
1. Render the **current chapter fully to its file** — "Preparing chapter…" with progress — then begin playback from that file (existing file-based player, unchanged).
2. While a chapter plays, **render ahead** (≥1 chapter) so the next chapter's file is ready before the current one ends — seamless steady-state, *provided* render speed stays above realtime (the NPU gives this; uneven chapter lengths are the edge case — see §9).
3. **Pause** → render-ahead pauses. Battery/heat only accrue while actually listening.
4. **Scrub/jump** into a not-yet-rendered chapter → "Preparing chapter…" wait while it renders, then play. Cached chapters play instantly.

Cold start (first press) and seeks into uncached chapters **wait while that chapter renders** — the accepted v1.0 tradeoff for reusing the file player with **zero engine changes**. As the user listens through the book over a few sessions, the whole thing ends up cached.

**Deferred to v1.1+: live-buffer streaming** (`scheduleBuffer`) for near-instant start — see §4.5 and §10.

### 3.4 Listening states
- **Preparing chapter** (cold start / seek into an uncached chapter): "Preparing chapter…" with render progress, then playback begins.
- **Playing**: the existing read-along reader, same highlighting + transport, plus a small **"AI · <voice>"** tag.
- *(No mid-chapter "catching up" state in v1.0 — chapters play from complete files, so playback never underruns once started. That state only returns if live streaming lands in v1.1+.)*

### 3.5 Voice change (decision: forward-only)
Switching voice applies **from the current chapter onward**. Already-rendered chapters keep their existing audio (no wasted re-render). A separate **"Delete narration"** action wipes the cache to start clean in one voice.
- Accepted tradeoff: a book may carry a voice "seam" at the switch point, in exchange for never re-doing work — appropriate for the A14 compute budget.

### 3.6 Voice model delivery (decision: download-on-first-use)
The CoreML model (~80–170 MB) is **downloaded once on first narration** (over wi-fi, with a one-time "setting up the voice…" step), then cached and fully offline forever after. Keeps the app binary lean for users who never narrate.
- Honest tradeoff: one online setup moment for an otherwise-offline feature; framed as a deliberate at-home setup, not a mid-route surprise.

---

## 4. Architecture (MVVM, applied)

**Fit: MVVM — `fit`.** Echo is already `@Observable @MainActor` MVVM with a service layer; `AutoAlignmentService` is the direct template (stateful async pipeline + injected DAOs + a separate observable progress object). State here is moderate (a render loop with cancellation), handled by a service + a background actor — without TCA's reducer machinery or a Combine/Reactive stack. Reference: `references/mvvm.md`.

### 4.1 Data-model mapping (almost no new storage)
A synthesized book is an existing shape with audio filled in later:
- Importing a standalone EPUB creates an `AudiobookRecord` with **`epub_block` rows but zero tracks** — an "audio-less book." Reading/study runs off `epub_block` immediately. (`bookDuration` passed to `EPUBImportService` is `nil` → proportional time estimation is skipped until narration assigns real times.)
- On **Listen**, narration renders **one AAC file per chapter**, each inserted as a `TrackRecord` (`file_path`, `sort_order = chapter index`) under that same `AudiobookRecord` → reuses Echo's existing **multi-track** playback.
- Each `epub_block` gets an `AlignmentAnchorRecord` (block → audio_time) written at synthesis time with a **new `source = .synthesized`** → read-along lights up for free; re-alignment never confuses generated anchors for recovered ones.

> An "audio-less `AudiobookRecord`" isn't a new concept — it's the natural empty state of a record that already separates text (`epub_block`), audio (`track`), and timing (`alignment_anchor`). Narration just populates the last two later.

### 4.2 Component map (vertical slice, mirrors the alignment sibling)
```
EchoCore/Services/Narration/
  NarrationService.swift        // @MainActor orchestrator  ← mirrors AutoAlignmentService
  NarrationState.swift          // @Observable progress      ← mirrors AutoAlignmentState
  TTSEngine.swift               // protocol (the swappable seam)
  KokoroTTSEngine.swift         // actor: model load + synthesize() OFF the main actor
  G2P/
    Phonemizer.swift            // protocol
    MisakiPhonemizer.swift      // Apache, no espeak-ng
    TextNormalizer.swift        // pure: numbers, "Dr.", roman-numeral chapters
  NarrationRenderPlanner.swift  // pure: chapter chunking + how-far-ahead policy
  NarrationAudioWriter.swift    // PCM buffer → AAC file (the cache)
EchoCore/Services/Audio/
  AudioEngine+Streaming.swift   // (v1.1+ only) scheduleBuffer path — NOT needed for v1.0
EchoCore/ViewModels/
  BookDetailViewModel.swift     // owns NarrationService (NOT PlayerModel)
EchoCore/Views/Narration/
  NarrationNudgeView · VoicePickerView · NarrationStatusView
Shared/Database/Migrations/
  Schema_Vxx.swift              // + .synthesized anchor source
```

### 4.3 Seams & dependency injection (real injection — the anti-theater fix)
```swift
protocol TTSEngine: Sendable {
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
}
protocol Phonemizer: Sendable {
    func phonemes(for text: String) -> [Phoneme]
}
actor KokoroTTSEngine: TTSEngine { /* CoreML/ANE model load + inference */ }

@MainActor @Observable
final class NarrationService {
    init(db: DatabaseWriter,
         audiobookID: String,
         engine: AudioEngine,
         tts: TTSEngine,            // injected protocol → MockTTSEngine in tests
         phonemizer: Phonemizer,    // injected protocol
         state: NarrationState)
}
```
- Mirror `AutoAlignmentService.init(db:audiobookID:audioEngine:state:)` (real constructor injection) — **not** `PlayerModel`'s hardcoded `let playbackController = PlaybackController()` ("protocol-DI theater" the audit flagged).
- **Own narration in a new `BookDetailViewModel`, not `PlayerModel`** (already the audit's God-object risk; mvvm.md anti-pattern #1). The book-detail screen is where framing B's nudge lives, so narration state is naturally scoped there.

### 4.4 Async / concurrency strategy
- **Off-main CPU**: G2P, Kokoro inference, AAC encode run on the `KokoroTTSEngine` **actor**. `NarrationService` stays `@MainActor` only to own the `Task` and commit `NarrationState` (mvvm.md anti-pattern #5).
- **Delivery (v1.0)**: the actor renders each chapter to an AAC file (`NarrationAudioWriter`); `NarrationService` inserts it as a `TrackRecord` and the existing file player plays it. (Live `AsyncStream<TTSChunk>` buffer delivery is the v1.1+ streaming path.)
- **Cancellation**: pause/seek `cancel()`s the render-ahead `Task`; `Task.checkCancellation()` between blocks; `cancel()` in `deinit`. Seek cancels render-ahead and restarts at the new chapter.
- **Backpressure**: render-ahead **capped** in `NarrationRenderPlanner` (≥1 chapter ahead, more when time allows, paused on pause) — that *is* the §3.3 cushion, made explicit.
- **Error paths**: model-load fail → `.failed` (+ optional `AVSpeechSynthesizer` fallback tier); single-block synth fail → skip + interpolate (as alignment bridges un-narrated blocks).
- **Swift-6 isolation**: in v1.0 the actor produces **files**, so no `AVAudioPCMBuffer` crosses actor→main for playback — the engine just opens the finished file. Anything returned to `@MainActor` (timings, file URLs) must be `Sendable`. (The not-`Sendable` PCM-buffer hand-off only becomes a concern when live streaming lands in v1.1+.)

### 4.5 Playback feed — v1.0 needs no engine change
v1.0 plays **complete per-chapter AAC files** through the existing file-based `AudioEngine` path (it already plays `AVAudioFile`s and already handles multi-track books). **No new engine code.** Each chapter is rendered to a file, inserted as a `TrackRecord`, and played like any other track.

**Deferred to v1.1+ (live streaming):** `AudioEngine` already runs an `AVAudioPlayerNode` that can `scheduleBuffer`, so a future "play as produced" mode can stream freshly-rendered chunks for near-instant start, behind the same `AudioEngineDelegate` time callbacks. That's the riskier seam — explicitly out of v1.0, and the only reason `AudioEngine+Streaming.swift` exists in the component map.

---

## 5. TTS stack & licensing

- **Model**: **Kokoro-82M**, weights **Apache-2.0** (one-way GPLv3-compatible, so fine under Echo's GPL-3.0). CoreML/ANE backend preferred for battery; final backend (MLX vs CoreML) confirmed after the device benchmark (§6.3).
- **G2P**: **MisakiSwift** (Apache-2.0, pure-Swift — dictionary + MLX neural OOV fallback + Apple `NaturalLanguage`) for **English** — the best-supported Kokoro language and fully on-device with no espeak dependency. ~~**espeak-ng must never enter the dependency graph** — it is GPL and would infect the MIT app~~ — **this no longer holds (see §5.1).** Echo is now GPL-3.0, so GPLv3 espeak-ng is license-compatible and links cleanly. **v1 narration stays English-only by choice** (scope + weak non-English Kokoro quality), with espeak-ng held as the future multilingual G2P backend behind a seam. The old "audit transitive deps for espeak" ship-blocker is **retired**.
- **Text normalization** (`TextNormalizer`): numbers, dates, currency, abbreviations ("Dr.", "St.", "e.g."), Roman-numeral chapter titles, footnote markers, em-dashes. **This is where naturalness lives or dies** and where MisakiSwift's edge-case coverage is unverified — highest testing priority.

### 5.1 Multilingual narration — post-GPL assessment (2026-06-15)

**Context.** Echo relicensed MIT → GPL-3.0 (PR #73), which voids the original rule *"espeak-ng must never enter the dependency graph — it is GPL and would infect the MIT app."* A GPL-3.0 app may link GPLv3 espeak-ng freely. (App Store distribution is fine: Echo's sole copyright holder grants Apple the needed permission — the same exception VLC and BookPlayer rely on.) **The relicense also removes the *architectural* tax:** an MIT app would have had to quarantine espeak-ng inside an XPC-isolated Audio Unit extension to keep copyleft off the main binary (the pattern the official `espeak-ng-ios-app` uses). Echo no longer needs that — it can link espeak-ng directly.

**But the payoff is narrower than it first looks**, because Kokoro + misaki split G2P per language:

| Language(s) | misaki G2P backend | Kokoro voice quality | Swift today |
|---|---|---|---|
| **English** (`a`/`b`) | `misaki.en` — dict + neural fallback (espeak **optional**) | **Production-grade** (the only A-grade voices) | ✅ **MisakiSwift** (pure-Swift, on-device) |
| **Spanish, French, Italian, Portuguese, Hindi** | **espeak-ng** (no native misaki path) | Weak (C/D grade, sparse data; French = 1 voice) | ❌ needs espeak-ng |
| **Japanese, Chinese, Korean, Vietnamese** | native (pyopenjtalk / jieba+pypinyin / g2pkc / Viphoneme) — **no espeak** | Experimental (C/D) | ❌ no Swift port exists |

The languages espeak-ng unlocks (es/fr/it/pt/hi) are exactly Kokoro's **weakest** voices; the better non-English option (Japanese) doesn't use espeak but has **no Swift G2P port**. So "GPL unlocks multilingual" is true, but today's quality ceiling for non-English is low.

**espeak-ng iOS integration cost: MODERATE.** Flat C API (`espeak_Initialize` once → `espeak_TextToPhonemes` in IPA mode; **no audio synthesis**), trivial Swift interop, negligible CPU/latency, ~1 MB library + a prunable `espeak-ng-data` folder (full ≈ 5–12 MB; per-language ≈ a couple MB). No SwiftPM package — build the C sources into an `ESpeakNG.xcframework` (arm64 device + sim). Two Kokoro-on-iOS projects already do exactly this: **`mattmireles/kokoro-swift-mlx`** (uses espeak-ng as its phonemizer) and **`mlalma/kokoro-ios`** (espeak path present, commented out in favor of MisakiSwift). **Key gotcha:** espeak-ng is **not thread-safe** (global state) — serialize all calls behind one actor/serial queue; bundle `espeak-ng-data` as a folder reference and point the runtime path at it.

**Recommendation.**
1. **Keep MisakiSwift for English.** Best-quality language, already pure-Swift and on-device — never route English through espeak.
2. **Ship v1 English-only as planned.** The relicense changes *what's possible*, not the v1 *scope*; Kokoro's non-English quality doesn't yet justify the work.
3. **Put G2P behind a seam now.** A `G2PBackend` protocol selected by language (mirroring misaki's own `KPipeline` backend map) lets espeak-ng slot in per-language later with zero rework — the `TTSEngine` seam already sets this precedent.
4. **Add espeak-ng later, demand-driven.** When a specific supported language has real user demand (Spanish/Italian are the most phonetically tractable first targets) or when Kokoro's non-English voices improve. Integration is moderate and well-precedented; the license is no longer a blocker.

---

## 6. Device floor, fallback, and the benchmark gate

- **Floor device = iPhone 12 Pro (A14).** Published Kokoro RTF (~3.3×) was measured on an iPhone **13 Pro (A15)**; the A14 is a generation back with a tighter thermal ceiling — expect **somewhat less than 3.3×, still > realtime on the Neural Engine**, but a thinner margin (which is exactly why the §3.3 streaming model is the right call).
- **Benchmark gate (early task):** measure real Kokoro RTF on an actual 12 Pro before committing the cushion size and the MLX-vs-CoreML backend. If a device can't sustain ≥1× on the NPU, it falls to a fallback tier.
- **Fallback tier:** devices that can't sustain Kokoro fall back to `AVSpeechSynthesizer` (clearly labeled lower-quality) rather than blocking narration.

---

## 7. Phase 2 (fast-follow): export

**Both forms ship** — per-chapter files is the easy MVP-of-export; m4b is the polished version.

### 7a. Per-chapter audio files (nearly free)
Because v1.0 renders **complete per-chapter AAC files**, exporting them is almost no work: hand the user the existing files via the share sheet / save-to-Files (optionally zipped, named e.g. `01 - <chapter title>.m4a`, with cover + title/author as flat metadata via `AVMutableMetadataItem` — fully AVFoundation-on-iOS). **No concatenation, no re-encode, no atom writer.** The low-risk way to let users take their narration elsewhere (other players, Audiobookshelf, backup). Cheap enough it *could* ride into v1.0 if desired.

### 7b. Single `.m4b` with chapters (verified, harder)
- **AVFoundation does the audio + flat metadata**: `AVMutableComposition` (insert each chapter's audio in order) → `AVAssetExportSession` (`AVAssetExportPresetAppleM4A`); attach title/author/album/cover via `AVMutableMetadataItem`; rename `.m4a` → `.m4b`.
- **Chapters are NOT possible with AVFoundation alone on iOS** (both chapter paths fail; `-12717` on the text-track path). Inject chapter atoms with a permissive pure-Swift atom writer — **`atelier-socle/swift-audio-marker` (Apache-2.0, iOS 17+, zero deps)** writes both Nero `chpl` + QuickTime text-track chapters and the audiobook `stik` flag. We already have exact chapter times + cover + title from the EPUB.
- **Performance**: a gapless join forces a **full re-encode** (AAC priming padding) — *not* a fast passthrough. ~**10–20 min background job for an 8-hour book on A14** (estimate), with a progress bar; run as a `BGProcessingTask`-tolerant long task.

**Validation items before shipping 7b:**
- Confirm `swift-audio-marker` license (Apache-2.0 — re-verify pin) and that it sets the audiobook `stik` atom.
- Real-device readback: open an exported sample in **Apple Books + Audiobookshelf/Bookplayer**, confirm chapters appear.
- Personal-use framing: export is the user's own book, generated and stored on-device.

**Why Phase 2 (not core v1):** 7a is cheap, but keeping all export out of the core keeps v1.0 tight; 7b carries an independent multi-day risk surface (atom writing, re-encode UX, cross-player testing) that should not gate the core route use case.

---

## 8. Testing strategy
- **Pure units (highest ROI, no model):** `TextNormalizer` (table-driven: "Dr.", "1,200", "Chapter IV") and `NarrationRenderPlanner` (deterministic chunk/ahead policy).
- **`NarrationService` with `MockTTSEngine`** (canned chunks, instant) + in-memory GRDB (`makeInMemoryDB()` already exists): assert one `.synthesized` anchor per block, one track per chapter, pause→no stale writes, fall-behind→`.catchingUp`. Continuation-controlled stubs, **no `sleep`-based tests**.
- Per CLAUDE.md: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`; never parallel testing on the 16 GB machine.

---

## 9. Risks & open validation items
1. **A14 render speed** — gates cushion size + backend. → early benchmark.
2. **Cold-start / uneven-chapter wait** — first-chapter and post-seek render waits, plus a possible wait at a short→long chapter boundary if render-ahead can't finish the next chapter in time. Mitigations: render >1 chapter ahead when time allows; finer-grained first-chapter rendering if needed; magnitude bounded by the §6 benchmark.
3. **(Deferred to v1.1+) Live-streaming feed seam + `Sendable` buffer hand-off** — the riskiest engineering; **v1.0 sidesteps it entirely** by playing complete chapter files.
4. **Text normalization / MisakiSwift coverage** — naturalness risk; most test effort here.
5. **Battery/thermals** on multi-hour render — test on the 12 Pro, not just the Mac.
6. **espeak-ng license hygiene** — ship-blocking audit.
7. **Schema version collision** (notes mention V13 collisions across branches) — schema-migration-reviewer pass; new `SchemaVxxTests`.
8. **Phase 2 player compatibility** — validate `.m4b` chapters on real players.

---

## 10. Out of scope / future doors
- **Live-buffer streaming** (`scheduleBuffer`) for near-instant start, replacing the v1.0 cold-start wait (v1.1+).
- Multilingual narration (needs a permissive non-English G2P).
- Narrating books that already have a real audiobook.
- Cloud/premium voices (possible opt-in bring-your-own-key later).
- The exported `.m4b` + EPUB could later re-import and align trivially — a bridge to a future library/Mac feature.

---

## 11. Documentation sync (per CLAUDE.md)
On implementation, update:
- **ARCHITECTURE.md** — new "Narration / synthesis pipeline" section (the second path to aligned books; the streaming engine; the `.synthesized` anchor source).
- **README.md** — feature mention (on-device EPUB narration, English, offline after one-time model download).
- **CHANGELOG.md** — entry.
