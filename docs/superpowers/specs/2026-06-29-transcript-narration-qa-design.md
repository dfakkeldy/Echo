# Transcript Alignment + Narration QA — Program Design

**Date:** 2026-06-29
**Status:** Approved design (brainstorming complete) — ready for implementation planning
**Author:** Dan Fakkeldy. Ground-truthed and drafted with Claude (Opus 4.8).
**Supersedes framing in:** the 2026-06-29 draft spec sheet "Transcript Alignment + Narration QA" (Dan + Codex). This document keeps that spec's intent but corrects its assumptions against the codebase and locks the cross-cutting decisions.

> **Grounding note.** Every "we already have X" claim below was verified against the `nightly`-based worktree via a 7-agent code-verification pass on 2026-06-29. Key `file:line` evidence is collected in the Appendix. Where the original spec was overstated or wrong, this document says so explicitly.

---

## 1. Context & thesis

The product goal is two-layered and unchanged from the draft spec:

1. **Per-book, local, user-facing:** make a book's transcript behave like aligned source text — searchable, seekable, highlighted during playback, and study-able — then (for generated narration) "listen back" to find likely mispronunciations, omissions, insertions, and substitutions.
2. **Shared improvement (later, opt-in):** accepted pronunciation fixes and public-domain regression fixtures can improve Echo's narration for everyone, without raw private content ever leaving the device.

### What actually exists (verified)

The hard machinery the draft spec assumed is real:

- **Word-level transcription:** `StandaloneTranscriptionService` runs WhisperKit (`base.en`, `wordTimestamps: true`) and persists per-word `{word, start, end, confidence}` to `standalone_transcript.words_json`.
- **Reusable alignment engine:** `TokenDTW` is a pure, DB-free `nonisolated struct` that already emits `WordMatch{blockID, wordIndexInBlock, token, audioTime, runLength}` — i.e. the ASR-word→source-block mapping the spec wants. `AutoAlignmentWorker` is a pure `nonisolated enum`. `MacAlignmentService` already consumes both standalone, proving they decouple from the iOS import/playback orchestrator.
- **Pronunciation rewrite:** `PronunciationOverrides` rewrites matched words into Misaki `[word](/ipa/)` link syntax (rating 5 → bypasses the lexicon) *before* G2P, applied in `NarrationService` after `TextNormalizer.normalize`.
- **Synthesis word timing:** fully wired end-to-end (duration head `/encoder/predictor/ReduceSum_output_0` → `KokoroWordTimer` → `WordTimingMaterializer.refineWithSynthesis`), not merely "underway."
- **Privacy posture:** the only off-device paths are content-free (CloudKit *public* alignment anchors = block-id suffix + timestamps; Audiobookshelf = numeric playback progress). No raw transcript/audio/source text leaves the device.

### What the draft spec got wrong (corrections)

- **There is no `TranscriptReaderAdapter` seam.** The highlighting reader is hard-wired to `epub_block` via `ReaderActiveBlockResolver`'s anonymous tuple typealiases (`TimelineRow`, `WordRow`) and `ReaderFeedCollectionView`'s `EPubBlockRecord.Kind` data source; the PDF reader reuses the same JOIN. `StandaloneTranscriptView` is a static searchable list with **zero** playback coupling. The spec's "present transcript segments through the same contracts the reader needs" is not a thin adapter — it is a contract change *or* a materialization. (Resolved: Decision D1.)
- **Foundation Models is entirely absent** (zero `import FoundationModels`/`@Generable`/`LanguageModelSession`; only an unbuilt docs proposal). FM exposes no embedding API even on iOS 26. **Echo's deployment floor is iOS 18 / macOS 15 / watchOS 11**, so FM is dark for the large majority of the install base. (Resolved: Decisions D2, D2b.)
- **Standalone transcription has no resume** today: `pause()` == `cancel()`; `start()` resets to chapter 0 and re-inserts duplicate rows (new UUIDs, no dedup). (Resolved: Decision D6.)
- **Per-book pronunciation overrides are inert:** `overrides(forBookID:)` returns empty and `merging(global:book:)` is never called; only the global `global.json` map works. (Resolved: Decision D3.)
- **`narration_quality_issue` does not exist.** It is a new migration (see §5). (Resolved: Decision D-schema.)
- **Two transcript representations exist and do not feed each other:** `standalone_transcript` (TEXT-UUID id, inline `words_json`, no FTS, not in the timeline) vs `transcription_segment` (INTEGER id, normalized `transcription_word` child, FTS5 `transcription_fts`, surfaced into `timeline_item`). Only the latter is searchable today. (Addressed by D1 materialization, which routes audio-only books through the searchable `epub_block` path.)

---

## 2. Goals / non-goals

**Goals**
- Audio-only transcripts feel like aligned source text: active segment + word highlight, search-to-seek, tap-to-seek, bookmarks/study anchors, persistence.
- Source-backed books can align ASR words to EPUB/PDF source blocks, refining word timings without replacing canonical source text.
- After narrating an EPUB/PDF, run a per-book "listen back" QA pass that surfaces reviewable issues with source text, heard text, and an audio clip.
- Accepted pronunciation fixes feed the override dictionary and trigger targeted regeneration + re-QA.
- Private book content and generated outputs stay local by default.

**Non-goals (v1)**
- EPUB-grade typography for audio-only transcripts.
- Phoneme-perfect mispronunciation scoring (deterministic substitution/omission/insertion detection only in v1).
- Replacing source text with ASR output for books that already have EPUB/PDF text.
- Adapter training / fine-tuning.
- Multilingual transcription (English-only v1; seam left for later).
- Checking any private transcript, audio clip, generated `.m4b`, or copyrighted excerpt into the repository.

---

## 3. Locked decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| **D1** | How an audio-only transcript drives the read-along reader | **Materialize** transcript segments into `epub_block` + `timeline_item` + `word_timing` (with a per-book provenance marker). Source-backed books (M2) **never** materialize — they refine `word_timing`. | Reuses the proven karaoke/seek/search/study reader unchanged; §6.3's "don't pollute `epub_block`" concern is moot for audio-only books (no canonical source exists to blur). |
| **D2** | M3 heard-vs-source judgement | **Deterministic `TokenDTW` detects + classifies (always-on workhorse)**; a **gated Foundation Models classifier enriches** when available. FM **classifies, never detects.** | Detection needs the alignment, which is deterministic; FM stays in the bounded "classify/suggest" role (§7 endorsed) and out of the "authority that hallucinates a mismatch" role (§7 warned). |
| **D2b** | FM timing | **Build the gated FM classifier in M3** (eyes-open re: device minority). | Owner's call; deterministic path independently serves the iOS-18 floor. |
| **D2c** | Per-device FM behaviour | `narrationQAClassifier` setting = `auto` \| `deterministic` (default `auto`). FM used only when `canImport` + `@available(iOS 26/macOS 26)` + runtime availability + preference allows. Owner's phone falls back to deterministic automatically (if not AI-capable) or via the `deterministic` setting. | "Use FM for phones that can use it; default to TokenDTW for my phone." |
| **D3** | Pronunciation-fix scope (M4) | **Both, book-wins merge** — activate the existing inert `overrides(forBookID:)` + `merging(global:book:)`; user picks scope per fix, default per-book. | Matches §9; the merge helper already exists. |
| **D4** | Source-backed anchor identity (M2) | New `AlignmentAnchorRecord.Source.transcriptAlignment`, cleared/protected **by the source column** (code-only; no migration). | Semantic + queryable; follows `MacAlignmentService`'s approach, not the fragile id-prefix `LIKE` convention. |
| **D5** | Language coverage | **English-only v1**; add a `language` parameter seam for later. | Matches today's hardcoded `language: "en"`; avoids multi-language test burden now. |
| **D6** | Re-running transcription | **True resume:** persisted rows are the checkpoint (skip chapters that already have rows); explicit "clear & re-transcribe" path; pause = stop. | Fixes the duplicate-row bug *and* avoids re-processing long books; needs no new schema. |
| **D7** | M5 shared contribution | **New narrow opt-in channel** (term + IPA + language + voice/model version + confidence only; never surrounding prose). **Not** via the CloudKit anchor DB. **Build deferred** until M3/M4 produce real fix data. | Keeps the CloudKit feature's trust posture intact; safest payload; M5 has no useful input until earlier milestones run. |

---

## 4. Architecture

### 4.1 Component map (each unit: one job, testable in isolation)

```
M1  Transcribe action (UI) ─▶ StandaloneTranscriptionService ─▶ standalone_transcript (raw ASR, audit copy)
                                                              └▶ TranscriptMaterializer ─▶ epub_block(origin=transcript)
                                                                                          + timeline_item + word_timing
                                                                                          └▶ existing Reader (unchanged)

M2  SourceBackedAlignmentCoordinator
       inputs: standalone ASR words + EPUB/PDF source tokens
       core:   TokenDTW.wordMatchesWithBisection → AnchorSelector.select
       output: alignment_anchor(source=.transcriptAlignment) + WordTimingMaterializer.refine

M3  NarrationQAService (post-render)
       re-transcribe generated audio (WhisperSession.shared)
       → TokenDTW heard-vs-source → divergence windows
       → DivergenceClassifier (Deterministic always; FoundationModels gated)
       → narration_quality_issue rows
       → NarrationQAReview UI (source | heard | clip | actions)

M4  PronunciationRepair
       accept fix → PronunciationOverrideStore (per-book | global, book-wins)
       → targeted regeneration (block/chapter) → re-run M3 QA on the window → resolve

M5  PronunciationContribution (deferred)
       opt-in export: term + IPA + language + voice/model version + confidence
```

### 4.2 Data flow notes
- **Audio-only (M1):** `standalone_transcript` is retained as the raw-ASR **audit copy** (per §6.2 "preserve raw ASR for auditability"); the materialized `epub_block`/`timeline_item`/`word_timing` rows are the **reader projection**. Re-transcribe → clear both the raw rows and the materialized projection for that book, then rewrite (idempotent).
- **Source-backed (M2):** `epub_block` stays the canonical EPUB/PDF text; ASR is evidence only. Alignment writes anchors + refines `word_timing`; it never writes block text.
- **Generated narration (M3):** the QA pass is additive and runs after the existing render-then-persist path; it never mutates the rendered audio.

---

## 5. Data-model changes

| Change | Milestone | Kind | Notes |
|--------|-----------|------|-------|
| Per-book provenance marker | M1 | **Migration (tentative V29)** | `text_origin` (`epub` \| `pdf` \| `transcript`) on the book record. Lets the app distinguish ASR-derived books from canonical-source books so M2/labelling/feature-gating behave. Exact host table confirmed in planning (candidate: `audiobook`). |
| `narration_quality_issue` table | M3 | **Migration (tentative V30)** | Columns per the draft spec §6.5 + a `status` (`open`/`resolved`/`ignored`) and `created_at`/`resolved_at`. FK `audiobook` ON DELETE CASCADE. |
| `AlignmentAnchorRecord.Source.transcriptAlignment` | M2 | **Code-only** | The `source` column already stores the enum raw value; adding a case needs no migration. |
| Transcription resume | M1 | **Code-only** | Existing persisted rows are the checkpoint; no schema. |
| Pronunciation scope | M4 | **Code-only** | Existing `global.json` store + activating the inert per-book seam. |

**Migration discipline (mandatory):**
- Latest registered migration on `nightly` is **V28** (`v28_pdf_block_page`). The migrator list is intentionally sparse (`v1` baseline squash, then `v25`–`v28`).
- New migrations: a `Shared/Database/Migrations/Schema_Vxx.swift` enum (`nonisolated static func migrate(_:) throws`, SPDX header line 1, `import GRDB`), registered in `DatabaseService.runMigrations` after the previous block; additive-only, `ifNotExists`, snake_case, FK `.references("audiobook", onDelete: .cascade)`, `idx_<table>_<cols>`.
- Each new migration gets an `EchoTests/SchemaVxxTests.swift` following `SchemaV28Tests` (PRAGMA `table_info` / `index_list` assertions + a DAO round-trip against `DatabaseService(inMemory: ())`).
- **Version numbers are collision-prone across branches** (V28 was itself renumbered when `v27_library` landed first). Re-verify the next free version against `origin/nightly` at the moment each milestone branch opens, and run the `schema-migration-reviewer` agent before committing the migration.

---

## 6. Per-milestone detailed design

> Confidence: M1/M2 are grounded in verified code. **M3–M5 carry "revisit after M2" markers** — their details depend on behaviour M2 surfaces (what "normal" ASR-vs-source disagreement looks like), so treat their task lists as projected, not final.

### M1 — Transcript reader parity (audio-only)

**Scope:** a real "Transcribe this book" flow; materialize the result so the existing reader highlights/searches/seeks it; true resume; persistence.

**Components & touchpoints**
- `TranscriptMaterializer` (new, `EchoCore/Services/`): reads `standalone_transcript` rows + `words_json` for a book; writes `epub_block` paragraph rows (`origin=transcript`), `timeline_item` rows mapping each block to its `[start,end)` audio range, and `word_timing` rows from the per-word JSON. Idempotent: delete this book's `origin=transcript` projection before rewrite. Maps `StandaloneTranscribedWord` → the reader's `wordIndex`/NSRange model used by `ParagraphCardCell.highlightedWordIndex`.
- Transcription flow + resume (`StandaloneTranscriptionService`): add a user-facing entry point; on `start()`, **skip chapters that already have rows** for `(audiobook_id, chapter_index)`; add an explicit "clear & re-transcribe" that deletes rows + projection first; rename/clarify `pause()` as stop. Fix the `audiobookID` derivation so it matches the `audiobook(id)` FK (today it's derived from `audioFileURL.absoluteString`).
- Provenance: set `text_origin = transcript` on the book record at materialization; `hasEPUB`-style routing then sends the book to the existing reader.

**Acceptance criteria**
- Transcribe an audio-only book → it opens in the reader with active **segment + word** highlight, **search-to-seek**, **tap-to-seek**, and **study-card anchoring**, all inherited from the existing reader.
- Re-running transcription resumes (no duplicate rows); "clear & re-transcribe" produces a clean single copy.
- State persists across relaunch; provenance marker is set and queryable.

**Risks**
- The materialized book must not masquerade as a canonical-source book elsewhere (provenance marker is load-bearing).
- `word_timing` NSRange mapping must match `WordTokenizer` so karaoke highlights land on the right token.

### M2 — Source-backed transcript alignment

**Scope:** for books with EPUB/PDF source + audio, align ASR words to source blocks; persist anchors + refined word timings; source text stays canonical.

**Components & touchpoints**
- `SourceBackedAlignmentCoordinator` (new): builds `EPubToken`/`AudioToken` (or `AutoAlignmentWorker.Input`) from source blocks + standalone ASR words; calls `TokenDTW.wordMatchesWithBisection` (or `AutoAlignmentWorker.alignChapter`) + `AnchorSelector.select`; persists `AlignmentAnchorRecord` with `source = .transcriptAlignment`; refines `word_timing` via `WordTimingMaterializer.refine(dtwMatchesByBlock:)`. **Bypasses `AutoAlignmentService`** (which is `@MainActor` and coupled to `AudioEngine`/WhisperKit/UI), reusing the pure pieces directly — exactly the seam `MacAlignmentService` already uses.
- Re-run clears only `source == .transcriptAlignment` anchors (never hand-placed ones).
- Confirm `TranscribedWord`'s exact field shape (the `Input.words` element type) before constructing it from standalone ASR words. *(Open item OI-1.)*

**Acceptance criteria**
- A book with source + audio aligns ASR→source blocks; anchors persist as `.transcriptAlignment`; re-run clears only its own anchors.
- Source text remains canonical (no block-text writes).
- Low-confidence spans are flagged (debug/hidden) using existing `word_timing.confidence` stamping (synthesis 0.9 vs interpolated 0.5; a new threshold for transcript-derived).

**Risks**
- `TokenDTW.normalize` drops <2-char letter tokens and assumes digit-expansion symmetry → symbol-heavy/short blocks degrade silently.
- `AnchorSelector` `minRunLength = 3` + strict monotonicity → very short blocks may get no anchor.

### M3 — Generated narration QA *(revisit after M2)*

**Scope:** after narrating an EPUB/PDF, re-transcribe the generated audio, align heard→source, detect divergences, persist reviewable issues.

**Components & touchpoints**
- `NarrationQAService` (new): runs after `NarrationService.renderNarrationFile`'s persist step; re-transcribes the rendered audio via `WhisperSession.shared` (the shared model `StandaloneTranscriptionService` already uses); aligns heard words to the block's source tokens with `TokenDTW.wordMatches`; computes divergence windows (substitution/omission/insertion + low-confidence + timing-drift).
- `DivergenceClassifier` **seam** (concrete-type + closure injection; justified by two real implementations):
  - `DeterministicDivergenceClassifier` — always present; classifies from edit-distance + confidence; produces a baseline label and a rule-based suggested fix.
  - `FoundationModelsDivergenceClassifier` — gated; re-labels + suggests fixes via `@Generable` structured output; wraps the deterministic classifier as its **per-issue fallback**.
  - Resolution: FM only when `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)` + `SystemLanguageModel.default.availability == .available` + `narrationQAClassifier == .auto`. Otherwise deterministic. **The deterministic detector always runs**, so the *issue set* is device-independent; only labels/phrasing differ.
- `narration_quality_issue` table + `NarrationQualityIssueDAO`.
- `NarrationQAReviewModel` + view: source text vs heard text vs audio-clip playback; actions = ignore / save override (→ M4) / regenerate (→ M4) / mark resolved.

**Foundation Models specifics** (see §7).

**Acceptance criteria**
- A narration with a planted substituted/omitted word produces a `narration_quality_issue` deterministically (device-independent).
- On an AI-capable, opted-in device with `auto`, FM enrichment changes the label/suggested-fix; with `deterministic` (or on the iOS-18 floor) the deterministic label stands; no crash on any `availability` branch.
- Review surface renders source/heard/clip + actions; issue status persists.

**Risks**
- Re-transcription ~doubles on-device compute per book.
- Divergence heuristic over-reporting → review-queue flood; needs a tuned threshold calibrated against the planted-error fixture.
- VM-based CI can't execute FM at runtime → FM behaviour tests are device/TestFlight-gated; the deterministic path must be independently excellent.

### M4 — Pronunciation repair loop *(revisit after M3)*

**Scope:** turn accepted QA fixes into per-book/global overrides; regenerate affected audio; re-QA; track status.

**Components & touchpoints**
- Activate the inert seam: make `PronunciationOverrideStore.overrides(forBookID:)` return real entries; call `PronunciationOverrides.merging(global:book:)` at the three render call sites (`PlayerModel+Narration`, `HeadlessNarrationRunner`, `MacBatchProcessingService`).
- Accept-fix flow: write the chosen scope (default per-book) into the override store; persist.
- Targeted regeneration: re-render only the affected block(s)/chapter (`NarrationService` already renders per block/chunk); re-run M3 QA on that window; flip the issue to `resolved` when the divergence disappears.
- Status tracking on `narration_quality_issue` (`open`/`resolved`/`ignored`), survives relaunch.

**Acceptance criteria**
- Accepting a fix changes the next render's input for the chosen scope; affected blocks regenerate; re-QA clears the issue; status persists.

**Risks**
- Override map is snapshotted once per render unit → regeneration scope must be ≥ the affected block/chapter, not mid-file.
- `refineWithSynthesis` silently no-ops on word-count mismatch → a regenerated block can drop to interpolated 0.5-confidence timing with only a log.

### M5 — Optional shared improvement *(deferred; revisit after M3+M4)*

**Scope:** local public-domain regression corpus + a narrow opt-in term-level contribution path.

**Design intent**
- Local regression corpus: public-domain fixtures + a harness (closest existing pattern: the headless `EchoTests` narration/align harnesses gated on out-of-repo job JSON). No private content in-repo.
- Contribution payload: **term + IPA + language + voice/model version + confidence only** — never surrounding prose. Explicit, previewable consent. A **new** opt-in transport (not the CloudKit public-anchor DB, whose trust posture must stay intact).
- Caveat to reconcile before building: the CloudKit anchor record name already encodes `SHA-256(title|author|duration)`, so book *metadata* is effectively discoverable today; "fully local" is literally true only for raw text/audio. M5 must not widen this.

**Acceptance criteria (when built)**
- A repo-safe public-domain fixture drives a regression run; an opt-in export carries only the allowed term-level fields; nothing raw leaves the device without explicit consent.

---

## 7. Foundation Models integration (M3)

- **Role:** classification + suggested-fix phrasing only, over an already-detected divergence window. Never detection; never world knowledge.
- **Gating (all required):** `#if canImport(FoundationModels)` (compile) + `@available(iOS 26, macOS 26, *)` (API) + runtime `switch SystemLanguageModel.default.availability` with a tested branch for each `.unavailable` reason (`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`) + `narrationQAClassifier == .auto`. watchOS (target 11) never compiles the FM path.
- **Structured output:** a `@Generable` result type (e.g. `IssueClassification { kind, suggestedSpokenForm?, suggestedIPA?, confidence }`) with `@Guide` constraints; constrained decoding — no manual JSON parsing.
- **Determinism:** `GenerationOptions(sampling: .greedy)` for reproducibility in tests/review.
- **Error handling:** handle `guardrailViolation`, `decodingFailure`, `assetsUnavailable`, `unsupportedLanguageOrLocale`, `rateLimited`, `concurrentRequests` → fall back to the deterministic label for that issue; never crash.
- **Concurrency:** sessions are `async`; never block `@MainActor`. (Pull `axiom-concurrency` when implementing the QA actor.)
- **Testability:** exercise every `availability` branch via the Xcode scheme's *Simulated Foundation Models Availability* override; unit-test the seam via the deterministic impl + a hand-wired test double — **no speculative protocol/mock theater** beyond the two real impls (per CLAUDE.md / CODE_AUDIT §10.1).
- **No bundling of any adapter**; no PCC dependency in v1.

---

## 8. Privacy & local-first

- Per-book local artifacts: transcript segments + words, materialized projection, alignment anchors/refinements, `narration_quality_issue` rows, accepted per-book overrides, issue status.
- Global local artifacts: user-approved global overrides; aggregate local stats ("term failed N times"); public-domain fixtures.
- **Never synced/uploaded by default:** raw transcripts, audio clips, source-text excerpts, generated `.m4b`, copyrighted outputs.
- M5 contribution, if/when built, is explicit, previewable, and term-level only.

---

## 9. Testing strategy

**Unit:** `TranscriptMaterializer` mapping (segment→block/timeline/word + NSRange); resume skip-logic + clear-&-redo; ASR↔source token normalization; `DeterministicDivergenceClassifier` fixtures; override-suggestion mapping; M5 privacy export filter. All against `DatabaseService(inMemory: ())`.

**FM-specific:** `DivergenceClassifier` via the deterministic impl + a test double of the seam; every `availability` unavailable-branch via the scheme override. FM runtime behaviour is device/TestFlight-gated (VM CI can't run it).

**Integration:** transcribe→relaunch→highlight; source+audio→`.transcriptAlignment` anchors + canonical text intact; narration with planted error→issue row (deterministic); accept-fix→next-render input changes; resolved stays resolved after relaunch; re-run clears only own anchors.

**Manual / real-world:** long audio-only book; EPUB narration with proper nouns/acronyms; PDF narration with headings; public-domain repo-safe fixture; private-book run confined to Application Support, never committed.

**Build/test conventions:** `make build-tests` then `make test-only FILTER=EchoTests/<Suite>`; `CODE_SIGNING_ALLOWED=NO` for `make` test targets; never run two `xcodebuild`s or parallel testing (16 GB machine); UI-test action stays excluded.

---

## 10. Sequencing, branching, docs

- **Order:** M1 → M2 → M3 → M4 → (defer M5). Each milestone is its **own `nightly`-based branch + ready PR into `nightly`** (`gh pr create --base nightly …`); never target `main`.
- **Migrations:** re-verify the next free version against `origin/nightly` when each branch opens (M1 ≈ V29, M3 ≈ V30 — tentative); run `schema-migration-reviewer` before committing each migration.
- **Cross-platform:** materialization, alignment, QA, and overrides are shared logic — run `cross-platform-parity-reviewer` after touching `Shared/`/`EchoCore` so watchOS/Widget/macOS/echo-cli are either covered or deliberately gated. (Recall: UIKit/`PlayerModel`-only files must be excluded from **both** the macOS **and** echo-cli targets in `project.pbxproj`.)
- **Docs:** shipping M1/M3 changes architecture + data model → run `doc-sync` and update `ARCHITECTURE.md` (new transcript-materialization + narration-QA subsystems) and `CHANGELOG.md`.

---

## 11. Risks & open items

**Top risks**
1. Migration version collisions across branches → re-verify at every merge.
2. Provenance marker is load-bearing — a materialized book misclassified as canonical-source would corrupt M2/labelling.
3. M3 divergence heuristic over-reporting → tune threshold against the planted-error fixture before exposing the review queue.
4. FM benefits a device minority and can't be CI-tested in VMs → deterministic path must stand alone.
5. `refineWithSynthesis` silent no-op on word-count mismatch → regenerated blocks can degrade timing quietly; add a notice/metric.

**Open items (resolve during planning)**
- **OI-1:** confirm `TranscribedWord`'s exact fields before constructing it from non-WhisperKit/standalone ASR (M2/M3).
- **OI-2:** confirm the `kokoro_dur_head.onnx` duration-head asset is actually bundled in the app and echo-cli targets (synthesis word timing falls back to interpolation if missing).
- **OI-3:** confirm the exact host table/record for the `text_origin` provenance marker (candidate: `audiobook`).
- **OI-4:** decide the global default for `narrationQAClassifier` (currently `auto`; owner may prefer deterministic-everywhere with FM strictly opt-in).

---

## 12. Appendix — ground-truth reference (selected `file:line`)

- `EchoCore/Services/StandaloneTranscriptionService.swift:127-208` — WhisperKit `wordTimestamps:true`, per-word `{word,start,end,confidence}`; `:86-95` pause==cancel; `:139` `language:"en"`.
- `Shared/StandaloneTranscriptRecord.swift:20,40-45` — `standalone_transcript`, `StandaloneTranscribedWord`; `Shared/Database/Schema_V1.swift:318-328` table.
- `Shared/Database/DAOs/TranscriptionDAO.swift` + `Schema_V1.swift:112-134` — `transcription_segment`/`transcription_word`/`transcription_fts` (separate representation).
- `EchoCore/Views/StandaloneTranscriptView.swift` — static searchable list, no playback coupling.
- `Shared/ReaderActiveBlockResolver.swift:34-45` — anonymous tuple typealiases `TimelineRow`/`WordRow`; `EchoCore/Views/ReaderFeedCollectionView.swift:449-515` — `EPubBlockRecord.Kind` data source; `EchoCore/Views/PDFReadAlongController.swift` — same JOIN.
- `EchoCore/Services/TokenDTW.swift:349-399` — `WordMatch`/`wordMatchesWithBisection`; `EchoCore/Services/AutoAlignmentWorker.swift:7-107` — pure enum; `Echo macOS/Services/MacAlignmentService.swift:46-120` — standalone consumer.
- `Shared/Database/AlignmentAnchorRecord.swift:40-56` — `Source` enum; `Shared/Database/DAOs/AlignmentAnchorDAO.swift:42-54` — id-prefix clear (legacy) vs source-column (Mac).
- `EchoCore/Services/Narration/PronunciationOverrides.swift:46,64-67` — Misaki rewrite + `merging(global:book:)`; `PronunciationOverrideStore.swift:65-67` — inert `overrides(forBookID:)`.
- `EchoCore/Services/Narration/OnnxKokoroEngine.swift:104-242` + `NarrationService.swift:285-293` — synthesis word timing wired.
- `Shared/Database/DatabaseService.swift:102-118` — migrator: `v1`,`v25`,`v26`,`v27`,`v28` (latest **V28**).
- Foundation Models: **no matches** in any `.swift` (absent). Deployment floor: iOS 18 / macOS 15 / watchOS 11.
