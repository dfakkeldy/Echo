# Echo Narration Pipeline Audit

> Status note (2026-07-02): this is the original PR #368 audit snapshot. For current completed/pending remediation status on `origin/nightly`, use `docs/superpowers/reports/2026-07-02-narration-audit-remediation-map.md`. Do not treat this file as the live ledger.

Generated: 2026-07-01
Branch audited: `claude/peaceful-herschel-867461` at `76610d0` (contains `origin/nightly`)
Scope: the on-device narration pipeline only — EPUB text → `TextNormalizer`/`FMNormalizer` → pronunciation overrides → `NarrationTextChunker` → Kokoro ONNX synthesis (`OnnxKokoroEngine` + `KokoroFrontEnd`/`KokoroG2P`) → `NarrationSilenceGuard` → word timing → ALAC cache writing → m4b export → narration QA / re-transcription / pronunciation repair, plus `HeadlessNarrationRunner` and `echo-cli`. Focus: performance optimization and output quality.
Method: six read-only dimension finders (engine performance, text quality, orchestration/concurrency, audio output, export + QA loop, narration UI) fanned out in parallel; **every finding was independently adversarially verified** by an agent instructed to refute it by reading the code (several verifiers compiled the actual chunker/normalizer sources standalone and reproduced the claimed outputs); a completeness critic then swept for gaps and its findings were verified the same way. 75 raw findings → 3 refuted → deduplicated to the 60 below. The Highs were additionally spot-verified by direct reading of the cited lines. This is a companion snapshot to the rolling full-repo `CODE_AUDIT.md` (2026-06-26), not a replacement for it.

## Severity Summary

| Severity | Count | Notes |
| --- | ---: | --- |
| Critical | 0 | No crash-on-launch / data-corruption certainty found. |
| High | 15 | Audible-on-most-books output defects, dead QA loop on iOS, jetsam-class memory, real races. |
| Medium | 31 | Quality, performance, and correctness work that should ride along with the next narration milestone. |
| Low | 14 | Quick wins and polish. |

## 1. Executive summary

1. **[High] Every bare decimal is split at the “.” and misread** — §5.1 — `NarrationTextChunker.swift:134`. “98.6” is narrated as “ninety-eight. six” with a sentence-final stop mid-number; reproduced by compiling the real chunker. One-line fix.
2. **[High] The built-in `"re"` pronunciation override corrupts every *’re* contraction** — §5.2 — `PronunciationOverrides.swift:81`. “you’re / we’re / they’re” become “you ree / we ree / they ree” in every narrated book, on by default.
3. **[High] The whole QA/repair loop is dead on iOS** — §5.3 — QA looks for *chapter* files, iOS renders only *segment* files; accepted fixes re-render audio the player never queues and never evict stale segments. Three connected defects.
4. **[High] Cancelled/killed renders leave truncated audio that is reused forever** — §5.4 — the writer streams to the final cache name and reuse is a bare `fileExists` check; a cut-off chapter heals only on a voice change, and exports bake it into the m4b.
5. **[High] The rendered-audio cache key omits all text-affecting state** — §5.5 — new pronunciation overrides, FM refinements, and “Not in Audio” edits never invalidate cached segments; users hear no change and can’t force a re-render.
6. **[High] No ONNX memory lifecycle** — §7.1 — the CPU arena is never shrunk between runs and the 163 MB session is never released; this is the most likely root of the documented ~8-chapter OOM ceiling.
7. **[High] QA re-transcription loads a whole chapter of PCM into RAM** — §7.2 — ~400 MB for a 40-minute chapter before WhisperKit’s working set; Run QA is a jetsam crash waiting on long chapters.
8. **[High] QA/repair resolve the *global* voice preference, not the book’s recorded voice** — §5.6 — narrate book A with Ava, book B with Fenrir → QA on A finds nothing; accepting a fix renders one chapter in the wrong voice.
9. **[High] All 8 British voices are phonemized with the American G2P** — §5.7 — accent-hybrid pronunciation on every word; the gb_* lexicons were deliberately removed but the voices stayed in the picker.
10. **[High] `startNarrationPlayback` cancels the previous render without awaiting it** — §3.1 — two render loops can write the same segment file concurrently; combined with §5.4 the file survives as a “valid” render.
11. **[High] No background-task protection for render-only phases** — §3.2 — pocketing the phone during “Preparing narration…” (or when playback catches up with rendering) suspends synthesis mid-book.
12. **[High] Deterministic pronunciation “fixes” are circular** — §5.9 — without Foundation Models the suggested IPA is the same G2P output the engine already used, so accepting a fix burns a full re-render + re-QA and changes nothing.

## 2. Quick wins

Each is ≤ ~30 minutes and independently shippable:

- **§5.1** — add the existing `hasDigitNeighbor` guard to tier-1 sentence boundaries (one line + tests). Highest quality-per-minute fix in this report.
- **§5.2** — remove (or apostrophe-guard) the built-in `"re"` override; add a contraction regression test.
- **§5.12** — expand comma-grouped ordinals (“1,000th” currently becomes “1,zeroth”): extend one regex or reorder two normalizer passes.
- **§5.36** — fix the stale “~850 MB” download copy (real size ~163 MB).
- **§5.35** — surface the `try?`-swallowed persistence error when adding a pronunciation entry.
- **§7.9** — pass a platform-derived `intraOpThreads` on macOS/echo-cli instead of the A14’s 2 (the injectable init already exists); large batch-narration speedup for a few lines.
- **§7.12** — replace the byte-at-a-time model-download loop with `URLSession.download(from:)`.
- **§7.14** — precompile the pronunciation-override regex + lowercased lookup once per instance.
- **§7.15** — add `OSSignposter` intervals to the synthesis hot path (alignment already has them).

## 3. Concurrency

### 3.1 Previous render task cancelled but not awaited — concurrent writers on the same segment files
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:44-82`
- **What:** `narrationRenderTask?.cancel()` is followed immediately by the stale-voice file sweep and a new render task; cancellation is cooperative and one ONNX call runs for seconds, so the old task keeps appending to its open stream (and can even reach persistence) while the new task starts. The new task’s `fileExists` gate (line 236) can queue the old task’s half-written file; on a voice change the sweep deletes files the old task still has open. Both tasks also pass the paywall counter independently.
- **Why:** Restarting narration (reopen, retry, voice change) can corrupt segment audio, queue a partial file as a finished track, or double-count free-tier renders. No test covers `startNarrationPlayback`.
- **Action:** Capture the previous task, `cancel()`, then `await previous?.value` inside the new task before the sweep and first render.
- **Severity:** High

### 3.2 No background-task protection for render-only phases
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:82-330`
- **What:** The render-ahead loop is a plain `Task` with no `beginBackgroundTask` and no audio keep-alive in the two windows where no audio plays: (a) initial “Preparing narration…” (model download + first segment) and (b) when playback catches up and pauses awaiting the next chapter. The app already uses `beginBackgroundTask` elsewhere (pause bookkeeping, ABS import) but not here.
- **Why:** Locking the phone during either window suspends synthesis; the user gets a frozen preparing screen or permanent dead air mid-book until foregrounded. A jetsam kill while suspended also produces the §5.4 truncated file.
- **Action:** Wrap render-only phases in a background-task assertion (ending it while audio is live); on expiry cancel cleanly and delete the in-flight file.
- **Severity:** High

### 3.3 No mutual exclusion between Run QA and pronunciation repair
- **Location:** `Echo macOS/Views/MacNarrationQAReviewView.swift:114-121` (macOS), `EchoCore/Views/Narration/NarrationQAReviewView.swift:43,90` (iOS, asymmetric guards)
- **What:** macOS “Save Override” has no busy state at all; iOS disables “Add Pronunciation” and “Run QA” by *different* flags, so QA can start while a repair re-renders the same chapter cache file, and vice versa. Repair takes minutes with no feedback, so double-clicks are inevitable.
- **Why:** Interleaved render + transcription of one file → corrupted chapter audio and/or a queue of garbage divergences persisted via `replaceOpen`.
- **Action:** One shared busy gate in `NarrationQAReviewModel` that Run QA, acceptFix, and ignore-with-render all funnel through; disable both buttons and show progress on both platforms.
- **Severity:** High

### 3.4 No cancellation checks inside the engine or the silence-guard retry ladder
- **Location:** `EchoCore/Services/Narration/NarrationSilenceGuard.swift:144-166`; `OnnxKokoroEngine.swift:214-296`
- **What:** Cancellation is only checked between sub-chunks in `NarrationService`. Below that, the speed-nudge sweep (up to 3 runs), the split recursion (3 more per half), and `session.run` itself never check; a pathological silent fragment queues dozens of full ONNX runs after the user cancelled.
- **Why:** Stopping narration or switching books keeps the CPU pinned for the rest of the ladder — slow stop, heat, battery, and a hostage cooperative-pool thread.
- **Action:** `Task.checkCancellation()` at the top of the speed loop, the split recursion, and before `runModel`.
- **Severity:** Medium

### 3.5 Run QA is an unstoppable fire-and-forget task
- **Location:** `EchoCore/Views/Narration/NarrationQAReviewView.swift:78-82`; `Echo macOS/Views/MacNarrationQAReviewView.swift:55-68`
- **What:** Both buttons spawn an unstored `Task` with no cancel affordance; `NarrationQAService.runQA`’s chapter loop has zero cancellation checks, so it transcribes the whole book even after the view is gone.
- **Why:** An accidental tap commits the device to potentially hours of WhisperKit CPU with no way out; the task retains the model (compounds §7.2).
- **Action:** Store the task, tie it to the view lifetime, add a Cancel button and per-chapter cancellation checks + progress.
- **Severity:** Medium

### 3.6 Excluding a chapter mid-render is undone by the in-flight loop’s stale plan
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:220-330` (loop) vs `:497-527` (toggle)
- **What:** The render loop iterates a segment plan snapshotted at start; `toggleNarrationChapterExcluded` removes queued tracks but the live loop synthesizes the excluded chapter anyway and unconditionally re-appends its track.
- **Why:** Minutes of wasted CPU/battery and the excluded chapter plays anyway; the toggle’s doc comment is only true for *future* runs.
- **Action:** Re-check exclusion per segment inside the loop (consult the outline or an excluded-index set).
- **Severity:** Medium

## 4. API modernity

_No standalone findings._ Compiler-warning ground truth could not be captured this run: a warning-capture build was queued behind the machine’s one-`xcodebuild`-at-a-time rule for 40 minutes and never got a slot (see §12). Concurrency findings above rest on direct code reading, not warning lists. API-usage improvements that surfaced are filed where their impact is: foreground `URLSession` for the model download (§7.8), per-call `LanguageModelSession` construction against Apple’s reuse guidance (§7.5).

## 5. Bugs / logic errors (including audible output-quality defects)

### 5.1 Chunker splits every bare decimal at the “.” — “98.6” narrated as “ninety-eight. six”
- **Location:** `EchoCore/Services/Narration/NarrationTextChunker.swift:131-147`
- **What:** Tier-1 `isSentenceBoundary` accepts every `.` with no digit-neighbor check (tier-2 has exactly that guard for `,`/`:`); `mergedUnits` flushes mid-decimal and re-merges with an injected space, so G2P receives “98. 6”. Verified by compiling the actual file: “3.14159” → “3. 14159”, “$5.5 million” → “$5. 5 million”. `TextNormalizer` never expands bare decimals and Misaki reads intact decimals correctly, so the chunker is the sole corruption point.
- **Why:** Every temperature, version, statistic, and price-with-decimal in every book gets a sentence-final falling stop injected mid-number. Audible on essentially all non-fiction.
- **Action:** Reuse `hasDigitNeighbor(at:in:)` in `isSentenceBoundary` for `.`; add chunker tests for “98.6”, “3.14159”, “$5.5 million”.
- **Severity:** High

### 5.2 Built-in `"re"` pronunciation override corrupts every *’re* contraction
- **Location:** `EchoCore/Services/Narration/PronunciationOverrides.swift:81` (default), `:24` (matching)
- **What:** `builtInDefaults` ships `"re": "ɹi"`; the case-insensitive `\b(?:…)\b` alternation treats the apostrophe as a word boundary, so “you’re” → “you’[re](/ɹi/)”. The gold lexicon’s correct entries (you’re→jʊɹ etc.) are bypassed. Reproduced against both straight and curly apostrophes; the PR that added it tested only “re-rendered”, never contractions.
- **Why:** Ubiquitous fiction dialogue is mispronounced (“you ree”, “they ree”) in every render, on by default and invisible to the user; it also poisons QA ground truth.
- **Action:** Remove the bare `"re"` default or give it an apostrophe-rejecting pattern; add a contraction regression test.
- **Severity:** High

### 5.3 QA + pronunciation repair operate on chapter files while iOS renders segment files
- **Location:** `EchoCore/ViewModels/NarrationQAReviewModel.swift:206-210` (QA scan); `EchoCore/Services/Narration/PronunciationRepairService.swift:127-135` (repair delete/re-render)
- **What:** iOS in-app narration writes only segment files (`-ch<N>-s<M>-`); chapter files are written only by `HeadlessNarrationRunner` and the macOS batch service. `runFullQA` probes `chapterFileName` and finds nothing; `applyFix` deletes the (nonexistent) chapter file, leaves every stale segment intact, and re-renders into a chapter file the player never queues — while `NarrationCacheSource` *prefers* that repaired chapter file for export, so played and exported audio diverge.
- **Why:** On the primary narration platform the entire M2–M4 QA/repair program is inert: “Run QA” reports no audio for a fully narrated book, and an accepted fix is marked resolved while playback keeps the mispronunciation.
- **Action:** Teach `chaptersToQA` and `applyFix` the segment layout (QA the chapter’s segment files; delete chapter + all `-s*` segments; re-render the unit type the platform plays). Use visible-blocks in the repair closures (§5.19).
- **Severity:** High

### 5.4 Partial renders at the final cache name are treated as valid forever
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:419` (stream at final URL); `EchoCore/ViewModels/PlayerModel+Narration.swift:236,351` and `Echo macOS/Services/MacBatchProcessingService.swift:339` (bare `fileExists` gates)
- **What:** The ALAC stream opens directly at the canonical filename with no cleanup on throw/cancel; cancellation between appends abandons a playable-but-truncated m4a (a jetsam kill leaves an unfinalized container). Every reuse site equates existence with validity; `NarrationCacheSource` globs the same directory into m4b export. Only the headless runner protects itself (capture markers + partial sweep).
- **Why:** One cancel or crash mid-segment yields a chapter that permanently cuts off mid-sentence, has no anchors/timeline (read-along dead), and gets baked into exports. Nothing heals it short of a voice change or render-version bump.
- **Action:** Render to `<name>.partial` and atomically rename on successful `finalize()` (or delete the file in a `defer` when exiting unfinalized).
- **Severity:** High

### 5.5 Rendered-audio cache key omits all text-affecting state
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:236-246`; `EchoCore/Services/Narration/NarrationFileNaming.swift:39-43`
- **What:** Reuse is decided purely by filename existence, and the name encodes only book + chapter + segment + voice + renderVersion. Pronunciation overrides, FM-refined text, and the hidden-block set that seeded the segment plan are all absent — and per-block hides even change the segment partition while names stay `-s0,-s1…`, so an old file can be reused for a segment that now maps to *different blocks*, desynchronizing audio from anchors.
- **Why:** A user who adds an override or marks a paragraph “Not in Audio” and replays hears no change, with no indication why and no way to force a re-render short of switching voices. The settings screen even documents “takes effect on next render” — which never comes.
- **Action:** Fold a short content hash of the segment’s post-override, post-FM text into the filename (the FM cache’s hash helper is reusable), or sweep the book’s files whenever the override store / hidden set changes.
- **Severity:** High

### 5.6 QA and repair resolve the voice from the global preference, not the book’s recorded voice
- **Location:** `EchoCore/ViewModels/NarrationQAReviewModel.swift:185-190`
- **What:** `resolveVoice()` reads the `narrationVoiceID` default, which the voice picker overwrites on every narration start of *any* book. Cache filenames embed the voice and each track persists its actual `narrationVoice` in the DB; the export path already treats the DB as truth, QA/repair do not.
- **Why:** Narrate book A with Ava, then B with Fenrir → Run QA on A falsely reports no narrated audio; accepting a stale fix re-renders one chapter of A in Fenrir — an audibly mixed-voice book.
- **Action:** Resolve from the book’s synthesized `TrackRecord.narrationVoice` (as `NarrationCacheSource` does), falling back to the preference only for un-narrated books.
- **Severity:** High

### 5.7 All 8 British voices are phonemized with the American G2P
- **Location:** `EchoCore/Services/Narration/KokoroG2P.swift:28`; `VoiceCatalog.swift:67-76`
- **What:** `EnglishG2P(british: false)` is hardcoded and the front end ignores the voice when phonemizing; MisakiSwift’s gb_* lexicons were deliberately removed, yet the catalog still offers 8 “British” voices. The catalog already excludes non-English voices with exactly this mispronunciation argument.
- **Why:** Kokoro b* voices are trained on en-gb phonemes; feeding them American IPA yields accent-hybrid output (US vowels/rhoticity in a British timbre) on every word, deterministically, for anyone who picks a British voice.
- **Action:** Bundle gb_* lexicons and key the cached G2P on voice accent — or, cheapest honest fix, drop/flag the b* voices in the picker until British G2P exists.
- **Severity:** High

### 5.8 Roman numerals outside “Chapter N” are spelled letter-by-letter
- **Location:** `EchoCore/Services/Narration/TextNormalizer.swift:279-291`
- **What:** Only `Chapter [IVXLC]+` is normalized. The bundled lexicons have no entries for ii/iii/viii…, and Misaki’s uppercase-OOV path spells acronyms letter-by-letter — so “World War II” → “World War eye eye”, “Henry VIII” → “Henry vee eye eye eye”.
- **Why:** Regnal names, war names, and Part/Act/Volume headings are extremely common book text; verifier confirmed the letterization path in the lexicon code.
- **Action:** Generalize to a keyword list (Part/Act/Volume/Book/Section/War → cardinal) plus a name-context rule (proper noun + numeral → “the Eighth”).
- **Severity:** High

### 5.9 Deterministic pronunciation fixes are circular no-ops
- **Location:** `EchoCore/Services/Narration/QA/NarrationQAService.swift:173-181`; `DivergenceClassifier.swift:17-22,42`
- **What:** Without FM, the deterministic classifier’s suggested IPA is filled by the *same* Misaki G2P the synthesis front end used, so the override merely bypasses the lexicon with identical phonemes — re-rendered audio is byte-equivalent. Compounding: `looksLikeProperNounOrAcronym` returns true for *any* capitalized word, so sentence-initial substitutions routinely get these no-op “fixes”.
- **Why:** Accepting a fix costs a full chapter re-render + re-transcription (minutes of device CPU), then the same divergence is re-detected — the repair loop can never converge without FM.
- **Action:** Withhold suggested IPA for deterministic classifications (keep acceptFix gated on genuinely different pronunciation) and require interior capitals/all-caps in the proper-noun heuristic.
- **Severity:** High

### 5.10 `echo-cli narrate --db` fails on every second run: bare INSERT violates the primary key
- **Location:** `EchoCore/Services/Narration/HeadlessNarrationRunner.swift:229-238`
- **What:** The runner computes a deterministic audiobook id and executes a plain `INSERT INTO audiobook`; `audiobook.id` is a TEXT PRIMARY KEY, so any re-run against a persistent `--db` throws a UNIQUE-constraint error before rendering.
- **Why:** The documented workflow is batched multi-process rendering (≤5 chapters/process for jetsam) with `--db` added precisely to persist QA rows across runs — that combination always aborts on run 2.
- **Action:** `INSERT OR IGNORE` / GRDB save so re-runs are idempotent, mirroring the capture-marker resume design.
- **Severity:** High

### 5.11 Abbreviation expansion eats sentence-ending periods; sentence-final “St.” becomes “Saint”
- **Location:** `EchoCore/Services/Narration/TextNormalizer.swift:23-50`
- **What:** “etc.” → “et cetera” and “vs.” → “versus” consume the dot even when it terminates the sentence (“…stamps, etc. The next day…” → “…et cetera The next day…”), and the Saint lookahead misfires when “St.” ends a sentence before a capitalized word (“Main St. Their prices…” → “Main Saint Their prices…”). Both reproduced by executing the real normalizer.
- **Why:** The chunker loses the tier-1 boundary → two sentences run together with no terminal prosody; street abbreviations at sentence end are spoken as the wrong word.
- **Action:** Keep the period when the abbreviation is followed by whitespace+capital or end-of-text; make the Saint branch restore the dot in that context.
- **Severity:** Medium

### 5.12 Ordinal expansion runs before thousands-separator expansion: “1,000th” → “1,zeroth”
- **Location:** `EchoCore/Services/Narration/TextNormalizer.swift:309-316` (order set at `:10` vs `:16`)
- **What:** The ordinal pattern’s lookbehind admits a comma, so it matches “000th”, and `Int("000") == 0` → “zeroth”. Reproduced: “the store’s 1,000th customer” → “the store’s 1,zeroth customer”.
- **Why:** Any comma-grouped ordinal is narrated as garbage.
- **Action:** Let the ordinal pattern consume comma groups (strip commas before parsing), or run thousands expansion first.
- **Severity:** Medium

### 5.13 FM pre-normalization runs before pronunciation overrides and can silently defeat them
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:428-445`
- **What:** Order is rule-normalize → FM refine → overrides. FM’s prompt targets exactly the word class users override (acronyms, CamelCase, jargon); if FM rewrites “Xcode” to “X code”, the override’s whole-word regex no longer matches — and the FM output is persisted as `narration_text`, baking the transformed spelling into QA ground truth.
- **Why:** The accept-fix → re-render loop can silently no-op on FM-enabled devices; built-in defaults (Fakkeldy, Xcode…) are equally vulnerable.
- **Action:** Apply overrides before FM (the chunker already protects link syntax; tell FM to leave `[..](..)` spans alone), or re-check override keys against refined text.
- **Severity:** Medium

### 5.14 FM hallucination guard admits truncation: up to two-thirds of a block can silently vanish
- **Location:** `EchoCore/Services/Narration/FMNormalizer.swift:116-131`
- **What:** The guard requires output ≥ ⅓ of input length and ≥ 50 % overlap of the *smaller* word set — a truncated output is a subset (overlap 1.0) and exactly ⅓ passes the integer-division floor. The truncated text is then cached, spoken, and persisted as QA ground truth, so QA can’t flag the loss either.
- **Why:** Silent content loss with no error and no QA divergence — the precise failure the guard exists to stop. (Related: the ≥ 50 %-overlap rule also *rejects* legitimate rewrites of one-word blocks like acronym headings, the case FM is for.)
- **Action:** Measure overlap against the *input* set (≥ ~0.8) and tighten the length window to ±30 %; skip persisting `narration_text` when the edit distance is large.
- **Severity:** Medium

### 5.15 An unbalanced “[” disables all sentence/clause splitting for the rest of the block
- **Location:** `EchoCore/Services/Narration/NarrationTextChunker.swift:99-109`
- **What:** Any `[` sets the in-link flag; without a matching close, every subsequent boundary flush is suppressed in both tiers. Reproduced: one stray bracket forced raw word-wrap seams mid-clause across a 409-char block.
- **Why:** OCR artifacts and editorial brackets are common; everything after one produces arbitrary mid-clause “periods” — the exact artifact the tiered splitter exists to avoid.
- **Action:** Only enter link mode when the bracket plausibly starts an override link (scan ahead for `](`), or bound the protected region’s length.
- **Severity:** Medium

### 5.16 Exact-word-count guards silently discard synthesis word timings for expanded blocks
- **Location:** `EchoCore/Services/Narration/KokoroWordTimer.swift:56`; `EchoCore/Services/WordTimingMaterializer.swift:192`
- **What:** Two independent equality guards drop exact duration-head timings: (1) Misaki expands a bare number into multiple space-joined phoneme groups, failing `groups.count == wordCount` for the whole chunk (assembly is all-or-nothing per block); (2) `refineWithSynthesis` compares timing counts against rows interpolated from the ORIGINAL `eb.text`, while timings count the normalized/FM/override text — every expansion (“e.g.”, “$5”, years, “ — ”→“, ”) shifts the count and fails the guard.
- **Why:** Precisely the number/abbreviation-heavy blocks where interpolation is worst keep 0.5-confidence timings instead of the 0.9-confidence exact ones — degraded read-along highlight and word-tap-to-seek, silently.
- **Action:** Group phonemes by source token (Misaki exposes per-token phonemes) instead of by space id, and carry a source-word→spoken-word index map through the normalizers instead of requiring count equality.
- **Severity:** Medium

### 5.17 Silence-guard splits invalidate duration-head timings that still persist at 0.9 confidence
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:237-243`; `NarrationSilenceGuard.swift:158-163`
- **What:** Timings are computed once on the original chunk at speed 1.0 and uniformly rescaled to the emitted sample count — valid for a speed nudge, wrong for a split, where the audio is two independent utterances with their own boundary frames and possibly different speeds per half. The word count still matches, so the drifted timings pass §5.16’s guard and are stamped source=synthesis, confidence 0.9 (above DTW).
- **Why:** On silence-recovered chunks (~10 % of chunks in bad runs) every word after the seam drifts by hundreds of ms, recorded at the *highest* confidence.
- **Action:** Compute timings per actually-synthesized piece and offset by real piece durations — or return nil timings whenever the guard split (interpolation is better than confidently wrong).
- **Severity:** Medium

### 5.18 Re-running QA resurrects issues the user explicitly ignored
- **Location:** `EchoCore/Services/Narration/QA/NarrationQAService.swift:142-143`; `NarrationQualityIssueDAO.swift:22-31`
- **What:** `replaceOpen` deletes only open rows; nothing dedupes newly detected windows against ignored rows, so the identical divergence returns as a fresh open issue with a new UUID — including via the automatic re-QA after accepting one fix in the same chapter. (The previously-noted resolved-audit-row deletion IS fixed: resolved audits are upserted.)
- **Why:** “Ignore” doesn’t stick; the review queue refloods with triaged issues after any repair.
- **Action:** Skip windows matching an existing ignored row on (block, word span, heard text), or carry the ignored status forward.
- **Severity:** Medium

### 5.19 acceptFix re-render and re-QA use unfiltered chapter blocks, including hidden “Not in Audio” blocks
- **Location:** `EchoCore/ViewModels/NarrationQAReviewModel.swift:254-269`
- **What:** Both repair closures fetch `blocks(for:chapterIndex:)` (no `is_hidden` filter), unlike the original render (`visibleBlocks`) and the full-QA pass (`!isHidden`).
- **Why:** Accepting one fix re-renders the chapter WITH text the user excluded (audibly re-adding hidden passages to the file export prefers), and the re-QA expected set flip-flops against full QA’s, churning the issue list. The macOS batch service shares the unfiltered pattern.
- **Action:** Filter both closures to non-hidden blocks; audit `MacBatchProcessingService` for the same rule.
- **Severity:** Medium

### 5.20 acceptFix re-render omits chapterNumber/chapterTitle, clobbering the persisted track title
- **Location:** `EchoCore/ViewModels/NarrationQAReviewModel.swift:255-256`
- **What:** The repair’s `renderChapter` closure passes neither, so the service defaults displayNumber to raw index + 1 and upserts the recomputed title over the planner-correct one; every other call site passes planner numbering.
- **Why:** For books with front matter, accepting a fix renames “Chapter 1” to “Chapter 4” in the player, chapter list, and later exports.
- **Action:** Pass the planner’s numbering/title through the closure, or skip the title rewrite when neither is supplied.
- **Severity:** Medium

### 5.21 AudioExportService silently drops a chapter whose audio track fails to load
- **Location:** `EchoCore/Services/Export/AudioExportService.swift:47-48`
- **What:** A source file whose audio track can’t load (0-byte partial, corrupted cache) hits `else { continue }` — no audio, no chapter marker, no error; export reports success.
- **Why:** The user discovers a missing chapter hours into listening. Interacts badly with §5.4 (truncated partials in the same directory).
- **Action:** Throw a descriptive per-chapter export error (or at minimum a warning the caller must acknowledge).
- **Severity:** Medium

### 5.22 runQA aborts the whole book on the first bad chapter
- **Location:** `EchoCore/Services/Narration/QA/NarrationQAService.swift:110-114`
- **What:** A transcription failure or empty transcription throws out of the per-chapter loop; earlier chapters’ issues were already persisted, so the queue is silently partial.
- **Why:** An all-silence chapter — the known Kokoro zero-waveform defect, the very thing QA exists to catch — kills QA for every later chapter instead of being flagged as a whole-chapter issue.
- **Action:** Convert per-chapter failures into persisted issues (whole-chapter omission) or collect-and-continue with a failure summary.
- **Severity:** Medium

### 5.23 Headless QA manifest parses the chapter index from the first “ch<digits>” anywhere in the filename
- **Location:** `EchoCore/Services/Narration/HeadlessNarrationQAManifest.swift:76-81`
- **What:** The regex has no leading-delimiter anchor, and rendered names embed the book token first — “runner_catch22_book-ch0-…” parses as chapter 22 for every file; dictionary uniquing then keeps one file and the capture loop throws for every real chapter.
- **Why:** `echo-cli qa` fails (or QAs the wrong audio) purely as a function of the book’s title (Catch-22, Chapter7Secrets…). The sibling parser anchors on `-ch` and is safe.
- **Action:** Anchor to `-ch[0-9]+` / `.anchors-ch[0-9]+`, or reuse `NarrationFileNaming.chapterIndex(fromFileName:)`.
- **Severity:** Medium

### 5.24 Headless capture markers and export scan are not book-scoped
- **Location:** `EchoCore/Services/Narration/HeadlessNarrationRunner.swift:136,264,354-360`
- **What:** Resume markers are `.anchors-ch<N>.json` with no book identity, and the final export globs every `-ch<digits>` m4a in the workDir regardless of book token.
- **Why:** Reusing a workDir across books (the batch workflow encourages persistent workDirs) makes book B skip chapters book A captured and splice A’s audio into B’s m4b — silently. (A separate voice-staleness variant of this claim was refuted: the CLI defaults to a fresh render and sweeps markers; the cross-book hole remains.)
- **Action:** Namespace markers and the m4a scan with the book’s safe token, or refuse to run in a workDir containing another book’s files.
- **Severity:** Medium

### 5.25 macOS “Save Override” gating drifted from iOS: enabled for any issue with a fix payload
- **Location:** `Echo macOS/Views/MacNarrationQAReviewView.swift:113-117`
- **What:** macOS gates only on `suggestedFixJSON != nil` (and hard-codes book scope); iOS requires pronunciation type + non-empty decoded IPA and offers scope choice. The fix encoder emits JSON for spokenForm-only fixes, and the repair service never checks issue type.
- **Why:** Clicking Save on a spokenForm-only fix dead-ends (“Add an IPA spelling first” — with no way to add one on macOS); clicking it on a non-pronunciation issue that carries IPA writes a phrase-keyed override into the book dictionary and burns minutes re-rendering.
- **Action:** Move the iOS actionability gate into the shared model so both platforms use it; add scope choice on macOS.
- **Severity:** Medium

### 5.26 SilenceDetectionService’s 2.5 s minimum + absolute “ratio” threshold hard-cut alignment windows mid-speech
- **Location:** `EchoCore/Services/SilenceDetectionService.swift:10-11,72`
- **What:** (Alignment-adjacent, surfaced while tracing QA’s transcription path.) Intra-chapter pauses are 0.3–1 s, so a 2.5 s minimum finds almost nothing and the chunk planner falls back to hard cuts at exactly the max window; `thresholdRatio` is compared as an absolute RMS floor, not a ratio of the recording’s level. Both are `let` with no injection point.
- **Why:** Boundary words get garbled in WhisperKit transcription at every ~45 s window across content-aligned books, weakening DTW anchors and read-along.
- **Action:** Parameterize both; use ~0.4–0.6 s minimum for chunk planning and derive the threshold from measured level.
- **Severity:** Medium

### 5.27 Engine enforces no phoneme-length cap; over-long inputs run past the model’s trained length, then get silently skipped
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:271-282`
- **What:** ids of any length are fed to the model while the voice pack silently clamps the style row at 509; the chunker’s char budget assumes ~1.3 phonemes/char, but G2P number expansion explodes that (an 8-digit number ≈ 70+ phonemes). `lengthCapExceeded` is thrown only by the test mock; the render loop’s real protection is a string match on an ORT error that then *skips* the sub-chunk.
- **Why:** Digit-dense chunks produce degraded audio or silently omitted book text (content loss with only a log line).
- **Action:** Check the encoded token count against ~510 in `runModel`; split via the silence guard’s splitter instead of skipping.
- **Severity:** Medium

### 5.28 No inter-utterance silence is inserted at paragraph or split-retry seams *(split verdict)*
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:458-508`; `NarrationSilenceGuard.swift:163`
- **What:** Chunks, blocks, and split-retry halves are butt-joined with 0 ms inserted silence; the only pad is the end-of-file lead-out (which segment renders skip via `includeLeadOutPad: false`). One verifier CONFIRMED (paragraphs get no more air than sentence gaps; human narration pauses ~0.5–1 s between paragraphs); another REFUTED the click/pause premise for *chunk* seams — Kokoro’s BOS/EOS wrapping emits its own boundary-silence and punctuation-pause frames, which the word timer explicitly accounts for.
- **Why:** Within-sentence seams are fine (model-emitted pauses); the remaining case is *paragraph* transitions and mid-clause split seams sounding rushed. Worth an on-device listen before building anything.
- **Action:** If confirmed by ear: append a short `.silence` between block boundaries (~0.4–0.6 s) and after split seams (~0.15 s), keeping anchor end-times before the pad.
- **Severity:** Medium (impact disputed)

### 5.29 Per-book override merge is case-sensitive while matching is case-insensitive — winner is nondeterministic
- **Location:** `EchoCore/Services/Narration/PronunciationOverrides.swift:64-67` (merge), `:38` (lookup)
- **What:** `merging(global:book:)` uses exact keys, so “Xcode”/“xcode” both survive; the per-match lookup is `first(where:)` on an unordered Dictionary, so which IPA wins varies run to run — violating the documented “book wins” contract.
- **Why:** A per-book fix can intermittently lose to a stale global entry, looking like a random regression.
- **Action:** Dedupe case-insensitively at merge time (as `withBuiltInDefaults` already does); key the runtime lookup by lowercased key.
- **Severity:** Low

### 5.30 M4BRetagger swallows chapter-title resolution failures and reports success
- **Location:** `EchoCore/Services/Export/M4BRetagger.swift:70`
- **What:** `try?` + `?? []` means any failure (most commonly the documented zipped-vs-expanded-EPUB trap) writes an output with the exact stale titles the user ran retag to fix, while the CLI prints success.
- **Why:** The tool’s one job can no-op silently.
- **Action:** Propagate the error (or throw when titles are empty but chapter times aren’t) so the CLI exits non-zero.
- **Severity:** Low

### 5.31 QA detector maps DTW matches to heard words via timestamp equality
- **Location:** `EchoCore/Services/Narration/QA/NarrationQADetector.swift:84-86`
- **What:** `TokenDTW.WordMatch` drops the audio token index it has in hand and the detector recovers it via a time-keyed dictionary; WhisperKit timestamps are frame-quantized, so adjacent short words can tie and the wrong word is marked matched.
- **Why:** Occasional false insertions / missed divergences — the audio-side sibling of the already-fixed epub-side ordinal bug.
- **Action:** Extend `WordMatch` with the audio index and map directly.
- **Severity:** Low

### 5.32 Tier-3 word wrap can split inside a multi-word pronunciation link
- **Location:** `EchoCore/Services/Narration/NarrationTextChunker.swift:159-185`
- **What:** `mergedUnits` and the silence guard are link-aware; the tier-3 fallback `wrapByWords` splits on plain spaces, so a >350-char clause containing `[Jean Valjean](/…/)` breaks the link syntax in both halves.
- **Why:** The user’s accepted fix is defeated and bracket/IPA fragments are narrated as literal text — precisely on the word they corrected.
- **Action:** Reuse the in-link marking in `wrapByWords` (a link is one unbreakable word).
- **Severity:** Low

### 5.33 No peak clamp before ALAC quantization — vocoder overshoot hard-clips *(plausible, unconfirmed by ear)*
- **Location:** `EchoCore/Services/Narration/AVFoundationAudioWriter.swift:76-78`
- **What:** Raw Float32 samples are written verbatim; nothing clamps ±1.0 anywhere in the pipeline, so any vocoder overshoot saturates at integer conversion. (Also: `AVEncoderAudioQualityKey` is a no-op for lossless.) Verified code-side; actual overshoot frequency for Kokoro unmeasured.
- **Why:** Each overshoot is an audible crack baked permanently into the cache and every export; prevention is one vDSP clamp.
- **Action:** Clamp (or −0.5 dBFS headroom-scale) in `append()`; drop the no-op key.
- **Severity:** Low

### 5.34 deleteEntries indexes a live-recomputed array while mutating the store
- **Location:** `EchoCore/Views/PronunciationDictionaryView.swift:88-92`
- **What:** The loop re-evaluates the computed `sortedEntries` after each removal; multi-index IndexSets would delete wrong rows or crash. Latent today (swipe passes one index), armed the moment multi-select lands.
- **Action:** Snapshot the array (or map offsets to words) before removing.
- **Severity:** Low

### 5.35 addEntry swallows persistence errors with `try?` — entry vanishes on relaunch
- **Location:** `EchoCore/Views/PronunciationDictionaryView.swift:83`
- **What:** The store mutates memory before `persist()` can throw and the view clears the inputs unconditionally; on a write failure the row shows, works this session, and is gone next launch. Same pattern in the delete path.
- **Action:** Surface the error, or roll back the in-memory mutation on persist failure.
- **Severity:** Low

### 5.36 Prepare UI reports “~850 MB” for a 163 MB download (stale CoreML-era copy)
- **Location:** `EchoCore/Services/Narration/TTSEngine.swift:107`
- **What:** The batch-prepare status string still cites the deleted CoreML model set’s size; the pinned ONNX download is ~163 MB.
- **Why:** A 5× overstatement can make users on metered connections abort setup.
- **Action:** Format the real `expectedModelBytes`; pin with a test.
- **Severity:** Low

## 6. Security

_No findings._ The model download is pinned to an immutable revision with an exact-size integrity check; no credentials or injection surfaces exist in this subsystem. (SQL in the pipeline is parameterized except the headless runner’s literal INSERT, which is a correctness issue — §5.10 — not an injection risk.)

## 7. Performance

### 7.1 No ONNX Runtime memory lifecycle: arena never shrunk, sessions never released
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:293-296,348-350` (runs), `:364-368` (no unload)
- **What:** Both `session.run` calls pass `runOptions: nil`, so the CPU arena shrinkage config (exposed by the bundled ORT bindings) is never applied — with dynamic shapes the arena grows to the largest chunk’s activation peak and keeps it for the session’s life. There is no unload path, and `PlayerModel` holds the engine for the app’s lifetime, so fp16 weights + duration head + grown arena stay resident during ordinary playback after rendering ends.
- **Why:** This matches the documented jetsam profile (OOM past ~8 chapters/process; the ≤5-chapter batching workaround). Highest-leverage memory fix in the pipeline.
- **Action:** Shared `ORTRunOptions` with `memory.enable_memory_arena_shrinkage = cpu:0` (per run or per chapter boundary); add an `unload()` on the actor called from render completion, re-preparing lazily next render.
- **Severity:** High

### 7.2 QA transcription decodes an entire chapter into RAM at once
- **Location:** `EchoCore/Services/Narration/QA/NarrationQAService.swift:199-208`; `AudioSegmentReader.swift:44-141`
- **What:** `whisperTranscribe` reads the whole chapter in one call; the reader holds the full-duration native-format buffer, the full 16 kHz conversion, and the returned Float array simultaneously (~400 MB for a 40-minute chapter) before WhisperKit’s own working set.
- **Why:** User-initiated “Run QA” can jetsam the app on device for long chapters — the same memory class as the historical render OOM. The alignment pipeline already chunks at silences to avoid exactly this; QA bypasses that design.
- **Action:** Transcribe in bounded windows (reuse the VAD chunking or fixed 60–120 s slices via the reader’s existing offset/duration parameters), concatenating word arrays.
- **Severity:** High

### 7.3 Every sub-chunk runs the full Misaki G2P three times (plus once per silence retry)
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:217,265,334`
- **What:** `fallbackHits` (full G2P), `runModel`’s encode (again, and re-run per speed-nudge attempt though encode is speed-independent), and `tokenDurations`’ encode (a third time) all phonemize identical text; `KokoroFrontEnd` caches the engine/vocab/packs but not per-text results.
- **Why:** Each pass is NLTagger POS tagging + multi-stage lexicon lookups; tens of thousands of sub-chunks per book triple-pay it on the jetsam-sensitive render path for byte-identical results.
- **Action:** Encode once per (text, voice) in `synthesize()` and pass (ids, refS, fallbackHits) into `runModel`/`tokenDurations`; hoist ids out of the speed-retry closure.
- **Severity:** Medium

### 7.4 Whole-book timeline recalc + segment-end restore run once per rendered segment
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:329-353`
- **What:** Each ~8–50 s segment triggers `recalculateTimeline`, which fetches ALL blocks + anchors and UPDATEs every block in the book, plus a whole-book correlated-subquery UPDATE for segment end times. (The O(chapters²) word-timing variant of this was already recognized and avoided; the timeline recalc wasn’t.)
- **Why:** For a large book that is millions of row-writes per render run — WAL churn and writer contention against the UI’s reads, worsening with book size.
- **Action:** Scope the recalc and the restore to the unit’s `spokenBlockIDs` (plus the previous segment’s tail block).
- **Severity:** Medium

### 7.5 A fresh LanguageModelSession per FM call — normalizer (per block) and QA classifier (per window) — all serial on the render path
- **Location:** `EchoCore/Services/Narration/FMNormalizer.swift:70-74`; `QA/FoundationModelsDivergenceClassifier.swift:47-50`; `Tools/echo-cli/EchoCLI.swift:34-39`
- **What:** Each uncached block (and each divergence window in QA) constructs a new session and re-processes the instruction prompt, against Apple’s session-reuse guidance; `FMNormalizer.refine` also completes inline before each block’s synthesis starts, serializing LLM inference with CPU-bound TTS. The CLI’s classifier factory additionally skips the availability check, so FM-disabled Macs pay a failed FM round-trip per window.
- **Why:** Per-block session setup + instruction prefill materially inflates render time and time-to-first-audio on FM devices; QA passes pay the same per issue.
- **Action:** One session per narration/QA run; pipeline `refine(block[i+1])` while block *i* synthesizes (bounded to 1 in flight); add the availability check in the CLI factory.
- **Severity:** Medium

### 7.6 Narration cache is lossless ALAC — 5–8× the disk of spoken-word AAC — on a disproved rationale
- **Location:** `EchoCore/Services/Narration/AVFoundationAudioWriter.swift:93-98`
- **What:** Every segment/chapter is ALAC (~70–90 MB per audio-hour, durable Application Support, not purgeable). The justifying comment blames an AAC-encoder whine that the repo’s own version history later attributes to a playback-side time-pitch artifact — and the m4b export path already transcodes the same audio to AAC without complaint.
- **Why:** A long book’s cache reaches several hundred MB to ~1 GB per voice on storage-constrained phones.
- **Action:** Re-test AAC-LC (~96 kbps mono 24 kHz) now that the whine is known playback-side; bump renderVersion to sweep old caches; keep ALAC behind a debug flag for vocoder diagnostics.
- **Severity:** Medium

### 7.7 Multi-hour full-core render has no thermal-state or Low Power Mode pacing
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:249-263` (policy), `:341-397` (backfill, no backpressure at all)
- **What:** The only throttle is look-ahead/play-state; repo-wide there are zero references to `thermalState` or `isLowPowerModeEnabled`. The backfill loop renders every pre-resume chapter flat-out.
- **Why:** Hours of sustained inference heats the device until the OS throttles everything (slower anyway) and silently drains battery in Low Power Mode — against the render-ahead comment’s own stated concern.
- **Action:** Feed thermal state / LPM into `NarrationRenderPolicy.shouldPauseRender` (it’s already extracted and unit-tested) and pace the backfill.
- **Severity:** Medium

### 7.8 163 MB model download is non-resumable and foreground-only
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:399-437`
- **What:** Default (foreground) session, temp file deleted on ANY error, no Range resume, session never invalidated.
- **Why:** Backgrounding or a Wi-Fi drop at 95 % restarts from byte 0; on flaky/metered connections setup may never complete. The pinned exact-size check makes resumption trivial to validate.
- **Action:** Background `URLSession` download task (or Range resume of the kept partial).
- **Severity:** Medium

### 7.9 `intraOpThreads` hardcoded to 2 (A14 tuning) also throttles macOS and echo-cli
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:60`; `NarrationEngineFactory.swift:18`
- **What:** The factory passes no platform-specific value, so Mac batch narration and the CLI — the paths built to render whole books fast — run the model on 2 threads on 8+-performance-core machines. The injectable init already exists.
- **Why:** Roughly forfeits a multiple of synthesis throughput where memory pressure is not the constraint.
- **Action:** Platform-derived default in the factory (keep 2 on iOS; ~min(activeProcessorCount, 6) or ORT default on macOS).
- **Severity:** Medium

### 7.10 QA detector does linear rescans per block / per gap-run
- **Location:** `EchoCore/Services/Narration/QA/NarrationQADetector.swift:102-124,199-227`
- **What:** Per-block full filters of the token-origin array, per-flush full filters of heard-word indices, and full dictionary-key scans for nearest-neighbor lookups — degrading toward quadratic exactly on badly-diverged chapters, QA’s target case.
- **Action:** Pre-group token origins by block, keep sorted matched-index arrays with binary search, advance a cursor over heard words.
- **Severity:** Medium

### 7.11 Synchronous full-book GRDB reads/writes on the main actor throughout the QA flow
- **Location:** `EchoCore/ViewModels/NarrationQAReviewModel.swift:201`; `QA/NarrationQAService.swift:79,142`
- **What:** Tapping Run QA reads every block synchronously on the main actor, then the (also @MainActor) service re-reads ALL blocks a second time and does synchronous per-chapter writes.
- **Why:** Visible main-thread hang on large EPUBs right at the tap — against the project’s own DB-safety rule.
- **Action:** Async `db.read` / background task; pass the already-fetched blocks into `runQA` instead of re-querying.
- **Severity:** Medium

### 7.12 Model download iterates 163 M bytes one at a time through `URLSession.AsyncBytes`
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:420-427`
- **What:** One async-iterator hop + `Array.append` per byte; CPU-bound enough to throttle fast connections and peg a core during first-run setup. One-time only.
- **Action:** `URLSession.download(from:)` (folds into §7.8’s fix).
- **Severity:** Low

### 7.13 Reopening a fully-rendered book issues one serial title UPDATE per cached segment
- **Location:** `EchoCore/ViewModels/PlayerModel+Narration.swift:304-310,383-388`
- **What:** Every cache-hit segment awaits an unconditional `db.write` UPDATE before its track is queued — hundreds of sequential writer round-trips per open to restamp titles that almost never change.
- **Action:** Batch into one transaction, or skip when the stored title matches.
- **Severity:** Low

### 7.14 PronunciationOverrides.apply recompiles the alternation regex and linear-scans entries per match, per block
- **Location:** `EchoCore/Services/Narration/PronunciationOverrides.swift:25,38`
- **What:** The snapshot is fixed per render unit, yet each block re-sorts/re-escapes keys, recompiles the regex, and resolves each match with an O(entries) lowercased scan.
- **Action:** Precompute the compiled regex + lowercased lookup per instance.
- **Severity:** Low

### 7.15 No os_signpost instrumentation on the synthesis hot path
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:292-310`
- **What:** Ad-hoc `Date()` deltas + log strings only; the sibling alignment pipeline already uses `OSSignposter`. Instruments can’t attribute time across G2P vs waveform run vs duration head vs ALAC encode vs retries — every tuning claim in this report has to be validated by log-scraping.
- **Action:** Signpost intervals for encode / run / duration-head / append; keep the RTF log.
- **Severity:** Low

## 8. SwiftUI / UI

### 8.1 Book-scoped pronunciation overrides have no management UI — a bad accepted fix is permanent and invisible
- **Location:** `EchoCore/Views/PronunciationDictionaryView.swift:21-25`
- **What:** The dictionary view lists only the global map; QA review’s default scope writes per-book entries no view anywhere reads (repo-wide grep). Book entries also beat global at merge time, so even a correct global entry can’t repair a bad book-scoped one.
- **Why:** Accepting one wrong IPA permanently mispronounces the word in that book with no visible cause and no undo.
- **Action:** Add a per-book section (with delete) to the dictionary view or the QA screen; macOS currently has no pronunciation UI at all.
- **Severity:** Medium

### 8.2 Per-row JSONDecoder allocation + decode inside the QA List row builder
- **Location:** `EchoCore/Views/Narration/NarrationQAReviewView.swift:38,96-104`
- **What:** `hasActionablePronunciationFix` allocates and decodes per visible row on every List invalidation — including every `applyingIssueID` state flip.
- **Action:** Decode actionability once at load; share a static decoder.
- **Severity:** Low

(See also §3.5 — Run QA task lifecycle — and §5.34/§5.35, which live in this view layer.)

## 9. Dead code / duplication / refactor

### 9.1 NarrationSegmentAssembly / NarrationSegmentReadiness / NarrationSegmentCache have no production callers
- **Location:** `EchoCore/Services/Narration/NarrationSegmentAssembly.swift:4` (and siblings)
- **What:** Repo-wide grep: referenced only by their own unit tests. They are v7 segment-cache groundwork whose orchestration never landed — playback builds tracks straight from segment files and export uses `NarrationCacheSource`.
- **Why:** Dead cursor math and a duplicate pad rule that must be kept in sync with the live renderer with no consumer to catch drift — the repo’s own no-speculative-abstraction rule applies.
- **Action:** Wire them into the planned chapter-stitching slice, or delete all three plus tests until that slice lands. Worth noting: teaching QA/export the segment layout (§5.3) may be exactly the consumer these were written for.
- **Severity:** Low

## 10. Cross-cutting recommendations

1. **Make render output transactional.** Write to a temp/partial name, atomically rename on successful finalize. This single pattern fixes §5.4 outright and removes the damage amplification in §3.1, §3.2, and §5.21.
2. **Make cache identity content-addressed.** Filename (or sidecar) should encode voice + renderVersion + a hash of the final spoken text (post-override, post-FM). Fixes §5.5, simplifies repair invalidation (§5.3), and makes future normalizer changes self-invalidating.
3. **Unify the render unit story.** iOS renders segments; macOS/CLI render chapters; QA, repair, and export each guess differently. Either converge on one unit or centralize “what files does chapter N have?” in one resolver (`NarrationCacheSource` is closest) and make QA/repair/export all use it. Root cause of the §5.3/§5.6 cluster.
4. **One G2P result per chunk.** Encode once, thread (ids, refS, fallbackHits) through synthesis, timing, and retries (§7.3). While there, the front end is where a per-accent G2P would slot in (§5.7).
5. **Treat the normalizer as a compiler pass with a source map.** Several findings (§5.16, §5.17, §5.13) reduce to “we lose the original-word ↔ spoken-word correspondence.” Emitting per-replacement word-span deltas from `TextNormalizer` would fix word-timing loss, override/FM interaction checks, and QA index mapping in one design.
6. **Session reuse for Foundation Models.** One `LanguageModelSession` per run for both the normalizer and the QA classifier; prewarm and pipeline ahead of synthesis (§7.5).
7. **Lifecycle policy for long-running work.** Background-task assertions (§3.2), thermal/LPM pacing (§7.7), cancellation checks at every loop level (§3.4, §3.5), and ONNX arena/unload hygiene (§7.1) are one coherent “long render discipline” work package.
8. **Instrument before tuning further.** Add the signposts (§7.15) first so chunk-budget, thread-count, and retry-ladder changes can be measured on device rather than argued.
9. **Main-actor note.** `NarrationService` is `@MainActor`, so per-block normalization/chunking/override work runs on the main thread between engine hops. Individually small, but if profiling (rec. 8) shows hitches during in-app rendering, hoisting the text pipeline off-main is the fix — measure first.

## 11. What was NOT audited

- MisakiSwift / WhisperKit / ONNX Runtime internals (third-party; only their call contracts and bundled resources were checked).
- The alignment pipeline (`AutoAlignmentService`, `TokenDTW`) beyond its QA touchpoints — §5.26 surfaced incidentally and is alignment-scoped.
- The playback engine, gapless scheduling, and Now Playing integration (consumers of narration output, not producers).
- The Python transcription pipeline in `Tools/` (superseded in-app; out of scope).
- watchOS / widget targets, StoreKit/entitlement counting correctness (only the double-count race in §3.1 was noted).
- Localization of narration UI strings.
- **No build or test execution**: a compiler-warning capture was queued for 40 minutes behind an in-flight build and abandoned per the one-`xcodebuild` rule; no Instruments traces were recorded. All findings rest on source reading, standalone compilation of two pure files by verifier agents, and repo-wide grep.

## 12. Verification

Personally re-verified by opening the cited lines (beyond the adversarial-verifier pass):

- **§5.1** — `NarrationTextChunker.swift:131-147`: tier-1 boundary set has no digit guard; tier-2’s `hasDigitNeighbor` exists at 150-155. A verifier additionally compiled the file and reproduced “98. 6”.
- **§5.2** — `PronunciationOverrides.swift:74-92`: `"re": "ɹi"` present in `builtInDefaults`; `apply` builds a case-insensitive `\b`-bounded alternation at :24.
- **§5.3/§5.6** — `NarrationQAReviewModel.swift:185-210`: `resolveVoice()` reads the global default; `runFullQA` probes `chapterFileName`. `PlayerModel+Narration.swift:223-228` renders `segmentFileName` files.
- **§5.4** — `NarrationService.swift:419`: stream opened at final cache URL; `PlayerModel+Narration.swift:236`: bare `fileExists` reuse gate; no cleanup in any catch path.
- **§5.10** — `HeadlessNarrationRunner.swift:229-238`: deterministic id + bare `INSERT INTO audiobook`.
- **§3.1** — `PlayerModel+Narration.swift:44-82`: `cancel()` with no await before sweep + new task.
- **§7.1** — `OnnxKokoroEngine.swift:293-296,348-350,364-368`: both runs pass `runOptions: nil`; `store` is the only session mutation (no unload). Verifier traced the shrinkage config to the bundled binding header.
- **§7.3** — `OnnxKokoroEngine.swift:217,265,334`: three full-G2P call sites read directly.
- **§5.14** — `FMNormalizer.swift:116-131`: guard arithmetic read directly (integer-division floor; overlap vs the smaller set).
- **§5.28** — split verdict documented from both verifier transcripts; needs an on-device listen to settle.

Verifier-confirmed with cited evidence (spot-read but not line-by-line re-derived): §5.7 (lexicon resources listed), §5.8 (lexicon OOV path), §5.9, §3.2 (repo-wide `beginBackgroundTask` grep), §3.3, §7.2 (buffer allocation sites), §5.18-§5.25, §7.4-§7.11.
