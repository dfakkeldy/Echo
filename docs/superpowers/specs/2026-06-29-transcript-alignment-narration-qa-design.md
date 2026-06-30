# Transcript Alignment + Narration QA - Design Spec

**Date:** 2026-06-29
**Status:** Draft spec sheet
**Topic:** Make transcription behave like aligned source text, then use source-aware transcription to find and fix narration mistakes.
**Author:** Dan Fakkeldy (with Codex)

## 1. Product answer

This should ship as a **per-book feature first**, with a separate opt-in path that can improve narration for everyone.

The per-book value is immediate and user-facing: a listener transcribes a specific audiobook or generated narration, gets searchable aligned text, follows the audio with active highlighting, makes study items from the transcript, and reviews likely narration problems for that book. Every book has different audio, text, rights, names, acronyms, and formatting, so the actual alignment artifact is inherently per-book.

The shared product improvement is the second layer: accepted pronunciation fixes, deterministic bug fixes, and public-domain regression fixtures can improve Echo's narration pipeline for everyone. Private books, raw transcripts, audio clips, and copyrighted source text must stay local by default. A future contribution flow can be explicit and narrow: term, corrected pronunciation, language, voice/model version, and confidence, without raw surrounding prose unless the user knowingly opts in.

Recommended default:

- **Build local/per-book first:** transcript reader, source alignment, narration QA report, local pronunciation overrides.
- **Improve everyone through code and safe corpora:** better normalizers, G2P behavior, QA heuristics, public-domain tests.
- **Add opt-in contribution later:** reviewed pronunciation corrections only, never automatic upload of private book content.

## 2. Summary

Echo already has the core ingredients:

- `StandaloneTranscriptionService` can transcribe audio with WhisperKit word timestamps and persist segment rows in `standalone_transcript`.
- `TranscriptionDAO` supports `transcription_segment`, `transcription_word`, and FTS search for timeline-ingested transcripts.
- `StandaloneTranscriptView` displays a searchable transcript when no EPUB/PDF companion exists.
- The EPUB/PDF reader already consumes source blocks, anchors, and `word_timing` rows for read-along highlighting.
- The narration pipeline already has a user pronunciation dictionary (`PronunciationOverrides`) and per-word timing work underway for synthesized books.

The gap is product shape. Standalone transcripts are currently a searchable list, not a first-class aligned reading surface. Generated narration can be played and highlighted from source text, but Echo does not yet run a "listen back to itself" QA pass to find mispronunciations, omissions, substitutions, or drift.

This spec makes transcription a peer of EPUB alignment:

1. Audio-only books get a transcript reader that behaves like an aligned EPUB: active segment/word highlight, search, tap-to-seek, bookmark/study anchors, and persistence.
2. Source-backed books can transcribe their audio and align the heard words against EPUB/PDF source text.
3. Generated narration can be transcribed after render and compared against the source to produce a reviewable narration QA report.
4. Foundation Models can improve formatting, term detection, issue classification, and suggested fixes when available, but the deterministic path must work without AI.

## 3. Goals

- Make audio-only transcripts feel like aligned source text in the reader.
- Preserve word-level timestamps from transcription and use them for highlight, search, seek, and study anchors.
- Let users run a per-book narration QA pass after TTS generation.
- Detect likely pronunciation, omission, insertion, substitution, and timing issues by matching heard text back to source text.
- Convert accepted fixes into local pronunciation overrides or regeneration actions.
- Use Foundation Models for structured post-processing and triage when available.
- Keep private book content local by default.

## 4. Non-goals

- Perfect EPUB-grade punctuation and formatting for audio-only transcripts.
- Automatic cloud training or global upload of private books.
- Phoneme-perfect mispronunciation detection in v1.
- Replacing source text with ASR output for books that already have EPUB/PDF text.
- Adapter training or fine-tuning as the first solution.
- Checking private generated books, transcripts, or copyrighted excerpts into the repository.

## 5. User flows

### 5.1 Audio-only transcript as aligned text

When a book has audio but no EPUB/PDF source:

1. User runs transcription.
2. Echo transcribes chapter/track audio with word timestamps.
3. Echo builds a transcript reading surface from transcript segments.
4. Playback highlights the active segment and, where word timestamps exist, the active word.
5. Search jumps to transcript hits and seeks audio to the hit timestamp.
6. Bookmarks, notes, and study cards can anchor to transcript segment IDs and timestamps.

The transcript will not preserve original typography, but it should still feel like "having the book text aligned" for listening, search, and study.

### 5.2 Source-backed transcript alignment

When a book has EPUB/PDF source and audio:

1. Echo transcribes the audio.
2. Echo aligns transcript words to source blocks with existing TokenDTW-style matching.
3. Source text remains the canonical reading text.
4. ASR output is used as evidence: audio timing, skipped text, substituted words, repeated lines, and low-confidence regions.
5. The reader continues to display source blocks, but can refine word timings and flag mismatched regions.

### 5.3 Generated narration QA

After Echo narrates an EPUB/PDF:

1. Echo optionally runs a post-render "listen back" pass by transcribing the generated audio.
2. The transcript is aligned back to the source.
3. Echo creates reviewable QA issues:
   - likely mispronunciation;
   - source word omitted;
   - extra word inserted;
   - wrong word substituted;
   - acronym/number/name normalized incorrectly;
   - timing drift or low-confidence alignment.
4. User reviews each issue with the source text, heard transcript text, and a short audio clip.
5. User can ignore it, save a local pronunciation override, regenerate the affected block/chapter, or mark it resolved.

## 6. Pipeline

### 6.1 Source intelligence before narration/transcription

Before narration or source-backed transcription, Echo should extract a compact set of term hints:

- proper nouns;
- acronyms and initialisms;
- product names and camel-case terms;
- numbers, dates, symbols, and formulas;
- repeated out-of-vocabulary terms;
- source block IDs and chapter locations.

Foundation Models are a good fit here because the output is structured and bounded. The model should produce typed records such as:

```swift
struct NarrationTermHint {
    let spelling: String
    let sourceBlockIDs: [String]
    let kind: TermKind
    let suggestedSpokenForm: String?
    let suggestedIPA: String?
    let confidence: Double
}
```

Use these hints in three places:

- **Before TTS:** seed `PronunciationOverrides` suggestions and text normalization.
- **Before ASR when supported:** provide a glossary/context prompt or decoding hint to the transcription engine.
- **After ASR:** bias mismatch classification so risky terms get reviewed first.

If the current transcription engine does not expose reliable lexical biasing, keep the hints for post-ASR alignment and QA. The feature should not depend on promptable ASR.

### 6.2 Transcription

Use WhisperKit as the local transcription engine:

- chapter/track-window transcription;
- VAD chunking;
- word timestamps;
- per-word confidence where available;
- cancellation/resume semantics consistent with `StandaloneTranscriptionService`.

Normalize storage so both transcript paths can be searched and rendered:

- Keep `standalone_transcript` as the v1 audio-only persistence layer.
- Prefer normalizing standalone word JSON into `transcription_word` or an equivalent shared accessor so search/highlight code does not need two long-term representations.
- Preserve raw ASR text for auditability; keep source text canonical when source exists.

### 6.3 Transcript reader adapter

Do not write ASR text into `epub_block` just to reuse the reader. It would blur source semantics and make later source-backed features harder to reason about.

Instead, add a `TranscriptReaderAdapter` that presents transcript segments through the same contracts the reader needs:

- stable block ID: `transcript:<segmentID>`;
- display text: transcript segment text;
- time range: segment start/end;
- word timings: decoded `StandaloneTranscribedWord` or normalized `transcription_word` rows;
- chapter grouping from track/chapter metadata;
- search hit mapping to segment IDs and timestamps.

This gives the user the same read-along behavior without claiming the transcript is an EPUB.

### 6.4 Source alignment

For source-backed books, align ASR words against source words:

1. Build source tokens from EPUB/PDF blocks using the existing normalization rules.
2. Build audio tokens from transcript words and timestamps.
3. Run a monotonic aligner (`TokenDTW`/`AutoAlignmentWorker` lineage).
4. Emit:
   - source block -> audio time anchors;
   - source word -> audio time refinements where confidence is high;
   - unaligned spans for review;
   - low-confidence mismatch regions.

The aligner must tolerate ASR errors. A mismatch is evidence, not proof.

### 6.5 Narration QA issue generation

Add a review table or equivalent persisted model:

```sql
CREATE TABLE narration_quality_issue (
    id TEXT PRIMARY KEY,
    audiobook_id TEXT NOT NULL,
    source_block_id TEXT,
    source_word_start INTEGER,
    source_word_end INTEGER,
    audio_start_time REAL NOT NULL,
    audio_end_time REAL NOT NULL,
    expected_text TEXT NOT NULL,
    heard_text TEXT NOT NULL,
    issue_type TEXT NOT NULL,
    confidence REAL NOT NULL,
    suggested_fix_json TEXT,
    status TEXT NOT NULL DEFAULT 'open',
    created_at TEXT NOT NULL,
    resolved_at TEXT
);
```

Suggested issue types:

- `pronunciation`
- `omission`
- `insertion`
- `substitution`
- `normalization`
- `timing_drift`
- `low_confidence`

The issue model belongs to the book. It is not a global telemetry artifact.

## 7. Foundation Models role

Foundation Models should be an optional intelligence layer, not the core dependency.

Good uses:

- identify risky terms before narration;
- classify transcript/source mismatches into issue types;
- suggest user-reviewable pronunciation overrides;
- restore punctuation and paragraph breaks for audio-only transcript display;
- summarize transcript sections for search/study metadata;
- convert raw mismatch windows into concise QA rows.

Avoid:

- treating the model as an authority that a word was definitely mispronounced;
- sending private text off-device;
- generating unstructured JSON by hand;
- requiring AI for transcript alignment, search, or playback.

Implementation constraints:

- Gate on Foundation Models availability at compile time and runtime.
- Use typed structured generation (`@Generable` style models) rather than fragile string parsing.
- Keep chunks small and source-scoped.
- Provide deterministic fallbacks for every AI path.
- Label AI-generated suggestions as suggestions until the user accepts them.

## 8. Mispronunciation detection reality check

Transcription can find many narration problems, but v1 should be honest about confidence.

ASR can miss a mispronunciation if it infers the intended word from context. It can also invent a mismatch when the audio is fine. The highest-signal v1 cases are:

- ASR heard a different common word than the source.
- A risky term repeatedly aligns poorly.
- The same term fails in multiple chapters.
- ASR confidence drops around a source term already marked risky.
- A generated pronunciation override removes the mismatch after regeneration.

True phonetic scoring can be a later tier. That would compare expected phonemes from G2P against observed phonemes or acoustic evidence. The transcript pass is still valuable before that because it finds obvious substitutions, omissions, and normalization failures with tools Echo already has.

## 9. Pronunciation correction loop

Echo already has the right local shape: a user pronunciation dictionary that rewrites matched words into Misaki link syntax before G2P.

The QA loop should feed that dictionary:

1. QA detects a likely term issue.
2. User opens the issue and hears the clip.
3. Echo suggests a spoken form or IPA when confidence is high.
4. User edits/accepts the override.
5. Override is saved locally, with scope:
   - this book only;
   - global on this device/account;
   - future opt-in contribution.
6. Echo regenerates affected blocks/chapters.
7. QA reruns just those windows and marks the issue resolved if the mismatch disappears.

Per-book overrides are important because fictional names, author-specific terms, and private project names may not belong in a global dictionary.

## 10. Persistence and privacy

Persistence should survive app restarts and device sync, but privacy should remain local-first.

Per-book local artifacts:

- transcript segments;
- transcript words/timestamps;
- alignment/refinement records;
- narration QA issues;
- accepted per-book pronunciation overrides;
- resolved/ignored issue state.

Potential global local artifacts:

- user-approved global pronunciation overrides;
- aggregate local statistics such as "this term failed N times";
- public-domain regression fixtures.

Do not sync or upload by default:

- raw private transcripts;
- raw audio clips;
- source text excerpts;
- generated `.m4b` files;
- copyrighted book outputs.

If global contribution is added later, make it explicit, previewable, and narrow. The safest payload is a reviewed term-level correction with no surrounding copyrighted text.

## 11. Suggested milestones

### M1 - Transcript reader parity

- Wire the existing standalone transcription path into a real user flow.
- Replace the basic list transcript with a transcript reader adapter.
- Add active segment/word highlight, search-to-seek, and persistent transcript state.
- Normalize transcript words enough that search and highlight do not depend on `words_json` forever.

### M2 - Source-backed transcript alignment

- Align transcript words to EPUB/PDF source blocks.
- Persist source-backed anchors/refined word timings.
- Keep source text canonical.
- Surface low-confidence spans as debug-only or hidden QA rows.

### M3 - Generated narration QA

- After narration, transcribe generated audio.
- Align heard words to source.
- Persist `narration_quality_issue` rows.
- Add a review surface with source text, heard text, audio clip, and actions.

### M4 - Pronunciation repair loop

- Convert accepted QA fixes into per-book/global pronunciation overrides.
- Regenerate affected blocks/chapters.
- Rerun QA for those windows.
- Track resolved/ignored issues.

### M5 - Optional shared improvement

- Build a public-domain regression corpus.
- Add opt-in term-level contribution.
- Improve built-in defaults and normalizers from safe evidence.

## 12. Testing strategy

Unit tests:

- transcript segment -> reader block adapter;
- standalone word JSON decoding and timestamp mapping;
- transcript search hit -> timestamp mapping;
- source/transcript token normalization;
- issue classifier fixtures;
- pronunciation override suggestion mapping;
- privacy export filters.

Integration tests:

- audio-only book transcribes, persists, relaunches, and highlights during playback;
- EPUB/PDF source plus audio aligns transcript words back to source blocks;
- generated narration with a known substituted word creates a QA issue;
- accepted pronunciation override changes the next render input;
- resolved issue remains resolved after relaunch.

Manual real-world tests:

- long audiobook with no source;
- EPUB generated narration with proper nouns and acronyms;
- PDF generated narration with headings and page text;
- public-domain fixture for repository-safe regression;
- private-book run stored only in local Application Support, not committed.

## 13. Success criteria

- Audio-only transcripts are searchable, seekable, highlighted, and persistent.
- Source-backed transcription improves or verifies read-along alignment without replacing source text.
- Generated narration QA finds obvious wrong/missing words in a controlled fixture.
- Accepted pronunciation fixes can regenerate affected audio and persist.
- Private book content and generated outputs stay out of git and out of any global corpus unless explicitly approved.
