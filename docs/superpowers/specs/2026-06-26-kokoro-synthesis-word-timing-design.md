# Synthesis-Time Word Timing for Kokoro-Narrated Books

- **Status:** Approved design (pending implementation plan)
- **Date:** 2026-06-26
- **Author:** Dan Fakkeldy (with Claude)
- **Branch base:** `nightly` (worktree `claude/awesome-cerf-c24f18`)
- **Origin:** Adapted from the "Forced alignment" idea in Paul Hudson's *The Swift AI Playbook* — see the broader evaluation in this session. Hudson's own aligner (a privately-hosted MLX Qwen3 model) was rejected for Echo (GPL-incompatible, iOS-26/Apple-silicon-only, weaker on imported audio). The transferable lesson — **"when you already know the text, take the timing from synthesis instead of running speech-to-text"** — is what this spec implements for Echo's own narrated books.

## 1. Summary

Echo can narrate EPUBs on-device with the Kokoro (ONNX) TTS engine. Today, a Kokoro-narrated book gets its per-word "karaoke" highlight timing from **linear interpolation** between block-level anchors (`source:"interpolated"`, confidence 0.5) — and an imported audiobook gets it from the heavyweight WhisperKit + `TokenDTW` alignment pipeline.

For narrated books, both are the wrong tool: we synthesized the audio from text we already have, and the Kokoro model **already computes an exact per-phoneme duration** to generate that audio. This spec captures that duration at synthesis time and folds it into exact per-word timings, replacing interpolation for narrated books with no new network dependency, no DB migration, and no UI change. Worst case degrades gracefully to today's interpolation.

## 2. Background & problem

- Kokoro is a StyleTTS2-class model: it predicts an integer **duration per phoneme token** (in frames), then upsamples each phoneme to that many audio frames. The timing is therefore known precisely at synthesis time and then discarded.
- The current narrated-book timing path is interpolation-only: [`NarrationService`](../../../EchoCore/Services/Narration/NarrationService.swift) calls `WordTimingMaterializer.materializeChapter(...)`, which linearly distributes words across each block's duration (`WordTimingRecord(source:"interpolated", confidence:0.5)`).
- Karaoke highlighting already consumes `word_timing` rows live ([`ParagraphCardCell`](../../../EchoCore/Views/Cells/ParagraphCardCell.swift), [`ReaderFeedViewModel`](../../../EchoCore/ViewModels/ReaderFeedViewModel.swift)). It reads times regardless of `source`, so better data improves the existing experience with zero UI work.

## 3. Feasibility findings (verified this session)

Both linchpins were checked directly against the on-disk model and repo, not inferred:

1. **The model computes durations but hides them.** Echo's runtime model `onnx-community/Kokoro-82M-v1.0-ONNX → onnx/model_fp16.onnx` (163 MB, the exact pinned SHA in [`OnnxKokoroEngine`](../../../EchoCore/Services/Narration/OnnxKokoroEngine.swift)) declares **only** outputs `waveform [1, num_samples]` for inputs `input_ids [1, seq]`, `style [1, 256]`, `speed [1]`. But the graph contains a live duration predictor: `/encoder/predictor/duration_proj/linear_layer` → `[1, n, 50]` → `ReduceSum` → **`/encoder/predictor/ReduceSum_output_0` `[1, n_tokens]`** (StyleTTS2 "duration as sum of 50 bins").
2. **The duration head extracts cleanly and small.** `onnx.utils.extract_model(inputs=[input_ids,style,speed], outputs=[/encoder/predictor/ReduceSum_output_0])` produces a **28.2 MB** submodel (938 nodes) whose single output is the per-token duration vector `[1, n_tokens]`. It stops before the decoder/vocoder, so it is small and cheap.
3. **Word boundaries are recoverable from the token stream.** In [`_kokoro_vocab.json`](../../../EchoCore/Services/Narration/_kokoro_vocab.json) the space character is token **id 16** (punctuation is also tokenized). Durations are per-token, so each word is the run of phoneme tokens between id-16 tokens; summing their frames gives the word's duration.

**Verdict:** feasible now, on Echo's current floor (iOS 18 / macOS 15), with no model re-hosting.

## 4. Goals / non-goals

**Goals**
- Exact per-word `word_timing` for Kokoro-narrated books, derived at synthesis time.
- No new runtime network dependency; the 163 MB waveform model stays byte-identical to its pinned download.
- No DB schema change; no karaoke-UI change.
- Strictly additive: any failure falls back to today's interpolation.

**Non-goals**
- Imported-audiobook alignment (keeps WhisperKit + `TokenDTW` — audio ≠ text there).
- watchOS (narration is not run there).
- The AVSpeechSynthesizer fallback narrator, `NLTagger` sentiment, drag-import, and AI study generation — tracked in the roadmap, not this spec.

## 5. Architecture

One new stage inside the existing narration flow:

```
block text ─▶ NarrationTextChunker.split ─▶ [chunk text]
  for each chunk:
    KokoroFrontEnd.encode ─▶ input_ids (phoneme tokens; space = id 16), style, speed
       ├─▶ waveform session   ─▶ samples              (unchanged)
       └─▶ duration head (NEW) ─▶ per-token frames [1, n]
    KokoroWordTimer (NEW): split input_ids on id 16 → phoneme word-groups,
       sum frames/group, normalize so frames sum to actual sample count, frames→sec
       ─▶ [chunk-relative word timings]  (or nil on mismatch)
  NarrationService: accumulate chunk time offset + running block word index
     ─▶ WordTimingRecord(source:"synthesis", confidence 0.9) ─▶ word_timing table
        ─▶ existing karaoke UI reads it unchanged
```

## 6. Components & boundaries

- **`KokoroDurationHead` model artifact** — the 28 MB extracted `.onnx`, bundled in app resources. Accompanied by a checked-in, reproducible **`Tools/extract_kokoro_duration_head.py`** that documents the source model URL + SHA and the exact output tensor name, and regenerates the artifact. Rationale: an open-source (GPL) repo should not ship an opaque, unreproducible binary blob.
- **`OnnxKokoroEngine`** — gains a second, lazily-loaded ORT session for the duration head, run with the *same* `input_ids`/`style`/`speed` it already builds for the waveform session. The waveform path is untouched. Sessions run sequentially (peak memory = both models resident during a chapter, ~191 MB; cheap compute for the head).
- **`KokoroWordTimer`** (new, pure / no I/O — the testable core) — input: `input_ids`, per-token frames, chunk source text, sample count, sample rate. Output: `[(wordIndexInChunk, start, end)]`. Splits tokens on id 16 (ignoring BOS/EOS id 0), sums frames per group, normalizes to the actual sample count, converts to seconds, and maps the *i*-th phoneme group to the *i*-th whitespace word of the chunk **positionally**. **Returns nil if group count ≠ word count** (caller falls back to interpolation for the block).
- **`TTSChunk`** — gains `wordTimings: [ChunkWordTiming]?` (optional, `Sendable`). Other engines or any failure pass `nil`.
- **`NarrationService`** — its existing chunk loop (tracking `cursor` / `blockDuration`) is extended to accumulate word timings against a running **block-level** word index (a block spans multiple chunks), then write rows. A new writer path (e.g. `WordTimingMaterializer.materializeSynthesis(...)`) inserts `source:"synthesis"` rows, reusing the existing delete-then-rebuild + re-monotonize semantics. The existing `materializeChapter` (interpolation) becomes the fallback.

## 7. Data-flow / correctness details

- **Frames→seconds via normalization.** Normalize the per-token float durations so they sum to the chunk's *actual* sample count, then multiply by `1 / 24000`. This makes per-word times sum exactly to the audio length and absorbs rounding and speed-scaling as a global factor — so the precise choice of internal tensor (pre-round float `ReduceSum`) does not have to be frame-perfect.
- **Block word index.** Carry a running word counter across a block's chunks so `wordIndex` matches the block's whitespace split (what the karaoke resolver expects).
- **No schema change.** `WordTimingRecord` already has `source` and `confidence`; we add the value `"synthesis"` (confidence 0.9). No migration → the schema-migration review surface stays empty.
- **Swift 6 mode.** `nightly` migrated Echo targets to Swift 6 language mode (#195); new types must satisfy strict concurrency (`Sendable` `TTSChunk` addition, actor/`@MainActor` placement consistent with existing narration services).

## 8. Error handling / graceful degradation

Any of the following falls back to today's interpolation for the affected block — never a crash and never worse than current behavior (the feature is strictly additive):

- duration-head model missing or fails to load;
- phoneme-group count ≠ source-word count for a chunk;
- zero / negative / NaN durations;
- task cancellation mid-chapter.

## 9. Testing

- **Pure unit tests (no model):** token→word grouping (BOS/EOS id 0, id-16 splits, punctuation tokens), normalization-to-total, frames→seconds, chunk-offset + block-word-index accumulation, mismatch→nil fallback.
- **Integration (gated on the bundled head, like other narration tests):** run the head on a short phrase; assert output shape `[1,n]`, strictly positive durations, and sum ≈ waveform frame count.
- **Golden:** synthesize a short sentence; assert per-word times are monotonic and within `[0, audioDuration]`.

## 10. Risks

1. **Phoneme-group ↔ source-word mapping (primary).** G2P may merge/split words or emit irregular spacing, breaking the positional 1:1 assumption. Mitigation: positional mapping + per-block interpolation fallback + **log the mismatch rate** so it can be measured on real books before being trusted broadly. If mismatches are common, the follow-up is to have the G2P wrapper emit explicit per-word phoneme spans (larger change, deferred).
2. **App size +28 MB** and a **second session resident during a chapter.** Modest, but noted given narration's existing memory/OOM history. Int8-quantizing the head later (~7–14 MB) is an easy optimization once the approach is proven.
3. **Determinism.** The head and waveform sessions must receive identical `input_ids`/`style`/`speed`; guaranteed because the engine builds them once and feeds both.

## 11. Documentation sync

This changes the narration pipeline (it now emits real word timing), so `ARCHITECTURE.md`, `README.md`, and `CHANGELOG.md` must be updated at implementation time, per Echo's CLAUDE.md doc-sync rule. The `doc-sync` skill covers this.

## 12. Resolved design decisions

- **Bundle vs. runtime-download the head:** bundle (Approach 1 was chosen specifically to avoid model-hosting burden). Runtime-download remains a fallback variant if app size becomes a concern.
- **Timing source value:** new `source:"synthesis"`, confidence 0.9 (above `"dtw"` 0.85, above `"interpolated"` 0.5).
- **Word mapping v1:** positional grouping with interpolation fallback, rather than investing up front in G2P word-span tracking.

## Appendix A — Offline extraction (reproducible)

Source model: `onnx-community/Kokoro-82M-v1.0-ONNX`, file `onnx/model_fp16.onnx` (pinned SHA as in `OnnxKokoroEngine`). Extraction (validated with onnx 1.19.1):

```python
import onnx
onnx.utils.extract_model(
    "model_fp16.onnx",                       # pinned source
    "kokoro_dur_head.onnx",                  # 28.2 MB output, 938 nodes
    ["input_ids", "style", "speed"],
    ["/encoder/predictor/ReduceSum_output_0"],  # per-token durations [1, n_tokens]
)
```

This belongs in `Tools/extract_kokoro_duration_head.py` with the source URL + SHA recorded inline so the bundled artifact is auditable and regenerable.
