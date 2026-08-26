# Narration speed: ONNX tuning + segment streaming — Design

- **Date:** 2026-06-21
- **Status:** Approved (brainstorming) → ready for implementation plan
- **Branch target:** `nightly` (per the promotion ladder)
- **Related code:** `EchoCore/Services/Narration/*`, `EchoCore/ViewModels/PlayerModel+Narration.swift`, `EchoCore/Services/AudioEngine.swift`, `EchoCore/Services/ReaderActiveBlockResolver.swift`, `EchoCore/ViewModels/ReaderFeedViewModel.swift`

## 1. Problem

On-device narration works (ONNX Runtime CPU engine, confirmed on the iPhone 12 Pro / A14), but it is **slow to start**. The architecture is *render-then-play*: chapter 1 must be **fully** synthesized to a single file before any audio plays. Device measurement:

```
Chapter 1: synthesizing 35 block(s)…
Chapter 1 rendered: 35 anchors, ~122s audio, in 73s.
```

→ **~73 seconds of silence** before chapter 1 starts. Per-call RTF climbs 0.48 → 0.85 as the A14 thermally throttles, so sustained throughput barely beats 1× playback and **falls behind above ~1.2–2× playback speed** (render-ahead keeps up only while `speed < 1/RTF`).

Two distinct slownesses:
1. **Time-to-first-audio** (the 73 s) — the headline complaint.
2. **Throughput ceiling** — RTF 0.5–0.85 on the A14 CPU; the CPU path is the safe ceiling (the ANE path SIGTRAP-crashes), so this is improved only modestly.

This is *slow-by-design, newly exposed*: the ONNX engine became the default 2026-06-19 and the real full-EPUB path had never been device-exercised (only a 3-paragraph debug button). Not a regression from any single commit.

## 2. Goals / Non-goals

**Goals**
- Cut time-to-first-audio from ~73 s to **~5 s**.
- Recover modest throughput headroom with zero behavior change.
- Keep read-along correct across the new multi-file-per-chapter model.
- Preserve the chapter-level UX (outline, playlist, exclusion, m4b chapter markers).

**Non-goals**
- Re-architecting the audio engine to play growing files (the engine reads fixed-length files; out of scope).
- Moving synthesis back onto the ANE/GPU (the crash path).
- Squashing the GRDB migration history (deferred to a clean pre-1.0 checkpoint — see §8).

## 3. Key constraint (why the shape is forced)

Narration plays through `AudioEngine` via `AVAudioPlayerNode.scheduleSegment(file:from:frames:)` reading a fixed-length `AVAudioFile(forReading:)` (`AudioEngine.swift:465`). **A partially-written, growing file cannot be played** — the frame count is read at open time. Therefore "streaming" must mean *smaller, complete render units (more, shorter files)*, not appending to a playing file.

## 4. Phase 1 — ONNX tuning + live progress (low risk, ships first)

No change to the file/anchor model; behavior-preserving; `renderVersion` untouched.

### 4a. Session options (`OnnxKokoroEngine.swift:104`)
The session is built today with a bare `ORTSessionOptions()`. Add:
- `setGraphOptimizationLevel(.all)` — op fusion; identical output.
- `setIntraOpNumThreads(n)` — pin to the A14's 2 performance cores; **injectable** (constructor seam) so 1/2/4 can be measured. Default `n = 2`.

Measure RTF from the existing per-synth log (`OnnxKokoroEngine.swift:177`) before/after. If RTF doesn't improve, revert — zero risk. (Exact ObjC selector names on `ORTSessionOptions` to be confirmed in the plan.)

### 4b. Live progress UI
Drive `state.currentSubtitle` (set once at `PlayerModel+Narration.swift:56`) from the `(i+1)/spoken.count` signal already computed at `NarrationService.swift:162` (e.g. "Preparing chapter 1… 40%"). Pure UX so a long render reads as motion, not a hang. Largely subsumed once Phase 2 lands, but valuable while Phase 2 is in flight.

## 5. Phase 2 — Segment streaming

### 5a. Segment planner
New **pure** `NarrationSegmentPlanner`, downstream of `NarrationChapterPlanner`. Splits each `PlannedChapter`'s blocks into ordered `PlannedSegment`s using a **char-based audio estimate** (real duration is unknown pre-synthesis). Adaptive sizing:
- **First segment of the book:** ~1–3 blocks (~8–12 s audio) → ~5 s to first audio.
- **Subsequent segments:** pack blocks to ~45–60 s audio to bound file count.

Pure → fully unit-testable, like the existing planner.

### 5b. Renderer
`NarrationService.renderChapter` generalizes to `renderSegment(chapterIndex:segmentIndex:blocks:)` → one file, one `TrackRecord`, anchors **0-based within the segment**. Cache naming gains a segment component: `syn-<book>-ch<idx>-s<seg>-<voice>.m4a`; `NarrationFileNaming` learns to write/parse it (incl. the resume parser `chapterIndex(fromFileName:)`, which gains a segment-aware sibling).

`TrackRecord.sortOrder` becomes a monotonic key across `(chapterIndex, segmentIndex)`. Track title stays "Chapter N" (segments of a chapter share it).

**Cache invalidation:** the new `-s<seg>` filename scheme means any pre-existing per-chapter files (`syn-<book>-ch<idx>-<voice>.m4a`, no segment component) no longer match the lookup and are simply re-rendered as segments. They become orphans on disk; add a one-time cleanup of old-scheme files for a book on first segmented render (cheap, narration-cache-local) so disk doesn't leak. No `renderVersion` bump — the engine/output is unchanged, only the cache layout.

### 5c. Queue & orchestration
The render-ahead loop (`PlayerModel+Narration.swift:196`) iterates **segments** instead of chapters. `prepareToPlay` fires after **segment 1** is finalized. Existing look-ahead backpressure and book-switch/cancellation guards operate unchanged on the finer unit.

## 6. Read-along (the hard part) — Option B: schema column

### 6a. Why chapter-scoping is insufficient
`ReaderActiveBlockResolver` scopes the active block to the EPUB `chapter_index` values in the currently-playing track, with anchors 0-based per track (`ReaderFeedViewModel.swift:238-300`). With one chapter split across segment files that all share `chapter_index = N`, at segment-2 time = 5 s the resolver cannot distinguish a segment-1 block (~5 s) from a segment-2 block (~5 s) — the highlight collides. Scoping must drop from *chapter* to *segment* granularity.

### 6b. Approach (chosen: B — schema column)
- Add a `segment_key` column to `timeline_item` (a stable per-segment identifier, e.g. the segment's track id `syn-<book>-ch<idx>-s<seg>`). Written when narration materializes a segment's timeline rows.
- Anchors stay **0-based per segment file** (so they continue to match the player's per-track `currentTime` with **no time conversion**).
- `ReaderActiveBlockResolver` generalizes: its scope becomes "the `segment_key` of the current track" (narration) while remaining able to scope by `chapter_index` (imported multi-track books). The resolver is in `Shared/`, so the iOS reader (`ReaderFeedViewModel`) and the macOS reader (`MacReaderFeedView`) share one path and cannot drift.
- The player maps current track → `segment_key` and passes it to `updateActiveBlock`.

Rationale for B over the in-memory derive (A): a queryable column is uniform with how imported multi-track read-along already works and keeps the resolver pure/stateless. Cost: a GRDB migration (see §8) and the timeline rebuild that narration already performs per render.

### 6c. Migration
- Add the **next unused `Schema_V##`** (current tips: `v22_fsrs_seed` on main, a `V23` audiobookshelf migration on a sibling branch — confirm the free number and watch for cross-branch collision; run the `schema-migration-reviewer` before commit).
- Migration adds `segment_key TEXT` (nullable) to `timeline_item`; existing rows keep `NULL` (treated as "no segment scope" → falls back to chapter scope, so imported books are unaffected).
- Add `SchemaV##Tests`.

## 7. Resume, outline, export, errors

- **Resume:** `getLastTrack` returns a segment file; map segment → chapter for the outline, resume at that segment (strictly finer/better than chapter resume).
- **Outline & playlist:** unchanged UX — stay chapter-level (`NarrationOutlineBuilder` is already independent of the queue). Tap-to-exclude still operates per chapter (excludes all its segments).
- **m4b export:** coalesce a chapter's segment files back into a single chapter marker.
- **Errors:** unchanged semantics — a synth throw still routes to `fail()`; a length-capped sub-chunk still skips. Per-segment finalize means a failure loses at most one segment, not the whole chapter.

## 8. Migration-history squash (deferred decision)

Considered and **deferred**. Squashing V1..V## into one baseline is a sound pre-1.0 cleanup, but the timing is wrong now: (1) existing installs (the dev device + TestFlight testers) hold data a squash would force-wipe; (2) ~10+ open feature branches, several schema-touching, would all need rebasing onto a new baseline; (3) the baseline must reproduce the cumulative schema exactly (needs a fresh-vs-migrated DB diff). Revisit at a clean checkpoint (branches merged, just before a 1.0 tag) with: snapshot live schema → single baseline migration → diff fresh-vs-migrated → `eraseDatabaseOnSchemaChange` (or guarded rebuild) for mismatches → tester reinstall heads-up. `segment_key` ships as a normal migration in the meantime (§6c).

## 9. Testing

- `NarrationSegmentPlanner`: adaptive sizing; first-segment-small; chapter→segments grouping; empty/edge chapters.
- `ReaderActiveBlockResolver`: the exact two-segments-same-chapter collision case resolves to the correct segment block; chapter-scope path still works for imported books; `NULL` segment_key falls back to chapter scope.
- Resume: segment file → correct chapter mapping + resume position.
- Export: a chapter's segments coalesce into one chapter marker.
- `OnnxKokoroEngine`: injectable intra-op thread count; options set without changing output (byte-identical ids/refS path unaffected).
- Schema: `SchemaV##Tests` for the `segment_key` add (idempotent, nullable, existing rows untouched).
- Cross-platform parity: run `cross-platform-parity-reviewer` (resolver + reader touch iOS + macOS).

## 10. Risks & open questions

- **RTF gain uncertain.** Phase 1 may yield <10%; it's a measure-and-keep/revert. The real win is Phase 2 latency, not raw throughput.
- **Exact ORT ObjC API** (`setGraphOptimizationLevel`, `setIntraOpNumThreads`) to confirm against `OnnxRuntimeBindings`.
- **Next free schema version** must be confirmed against main + in-flight branches (collision history).
- **Segment-size heuristic** (char→audio estimate) is approximate; first-segment latency depends on it. Tune with device logs.
- **Throughput at high playback speeds** remains bounded by A14 CPU RTF even after Phase 2; persistence (rendered segments cached + reused) is the mitigation on replay.

## 11. Sequencing

1. **Phase 1** (ONNX options + progress UI) — independent PR to `nightly`; measure RTF on device.
2. **Phase 2** (segment planner + renderer + `segment_key` migration + resolver generalization + resume/outline/export) — second PR to `nightly`, after Phase 1 measurement.
