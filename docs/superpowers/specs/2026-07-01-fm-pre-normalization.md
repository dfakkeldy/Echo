# FM Pre-Normalization: Proactive TTS Text Refinement

## Problem

The QA pipeline finds narration problems **after** rendering. Many issues are
normalization-type — words the TTS pronounces wrong because the source text
wasn't prepared for speech ("PCalc" → "Peacalk", "2am" → "2M"). These require
re-rendering the chapter to fix.

**FM pre-normalization prevents these problems before rendering** by refining
the text the TTS receives, eliminating the entire QA→repair→re-render cycle for
normalization-type issues.

## Architecture

```
EPUB text
    │
    ▼
TextNormalizer.normalize()     ← rules (fast, always-on, covers ~85%)
    │
    ▼
FMNormalizer.refine()          ← FM (gated, covers tricky remainder)
    │
    ▼
PronunciationOverrides.apply() ← user overrides (highest priority)
    │
    ▼
NarrationTextChunker.split()   ← existing chunking
    │
    ▼
KokoroG2P.phonemes() → TTS     ← existing rendering
```

FM runs **between** rule normalization and pronunciation overrides. Rules handle
the 85% (numbers, abbreviations, dates, ordinals, currency). FM handles the
remaining 15% (proper nouns, acronyms, context-dependent words, edge cases).

## FMNormalizer Design

### Structured Output Contract

```swift
@available(iOS 26, macOS 26, *)
@Generable
struct FMNormalization {
    /// The original word or phrase that needs rewriting.
    let original: String
    /// The rewritten, speakable form. Empty or equal to original = no rewrite.
    let rewritten: String
    /// Why this rewrite is needed (for logging/debug).
    let reason: String
}
```

### API

```swift
nonisolated enum FMNormalizer {
    /// Batch-refines text for TTS. Returns the text with FM-suggested
    /// rewrites applied. Falls back to the input text on any FM error.
    /// Cached per block ID so each block is only FM-processed once.
    static func refine(
        _ text: String,
        blockID: String,
        cache: FMNormalizationCache
    ) async -> String
}
```

### Prompt Design

The FM is asked to identify words/phrases a TTS engine might misread:

```
You review text that will be spoken by a text-to-speech engine.
For each word or phrase the TTS might mispronounce, suggest a
rewrite that sounds correct when spoken.

Rules:
- Acronyms with no vowels → insert spaces: "PCalc" → "P Calc"
- Ambiguous times → disambiguate: "2am" → "two A M"
- CamelCase identifiers → split: "AudioPlayer" → "Audio Player"
- Context-dependent words → use context: "read" (past) → "red"
- Proper nouns with unusual spelling → add pronunciation hint
- Do NOT rewrite words that are already speakable
- Do NOT change meaning or add/remove content
```

### Caching

```swift
@MainActor
final class FMNormalizationCache {
    /// Cached refinements keyed by (audiobookID, blockID).
    /// Survives across chapters within a render session.
    /// DOES NOT persist to disk — cache is session-only.
    private var storage: [String: String] = [:]

    func get(blockID: String) -> String?
    func set(blockID: String, refined: String)
}
```

Cache key = blockID (not audiobookID+blockID) because a block might be
shared across re-imports, but within one narration session the blockIDs
are unique. If the EPUB is re-imported, blockIDs change → cache miss → re-refine.

### Per-Chunk or Per-Block?

**Per-block** — one FM call per EPUB block, not per chunk. A block (~paragraph)
is refined once, then the chunker splits the already-refined text. This keeps
FM calls proportional to book size (~200 blocks/book) rather than chunk count
(~1000+ chunks/book). A typical FM call takes ~1 second, so per-block adds
~3 minutes to a full-book narration — acceptable for an opt-in quality feature.

### Gating

FM normalization uses the same gate as FM QA classification:

```swift
static func isAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26, macOS 26, *) {
        return SystemLanguageModel.default.availability == .available
    }
    #endif
    return false
}
```

Controlled by the existing `narrationQAClassifier` UserDefaults key
(`"auto"` = FM on when available, `"deterministic"` = rules-only, no FM).

## Integration Points

### 1. NarrationService.swift ~line 416

```swift
// Before:
let text = overrides.apply(to: TextNormalizer.normalize(block.text ?? ""))

// After:
let normalized = TextNormalizer.normalize(block.text ?? "")
let refined = await FMNormalizer.refine(normalized, blockID: block.id, cache: cache)
let text = overrides.apply(to: refined)
```

### 2. NarrationService.swift ~line 532

The chunker path also calls `TextNormalizer.normalize()`. Apply the same
FM refinement here if it differs from the per-block path.

### 3. NarrationQAService.swift ~line 49

The QA detector also normalizes text for comparison. FM pre-normalization
means the rendered audio matches the refined text, so the QA comparison
should ALSO use FM-refined text (not just rule-normalized). This requires
the cache to be accessible during QA — or the refined text to be stored
alongside the block.

**Recommendation:** Store the refined text in a new `narration_text` column
on `epub_block` (or a sidecar table). This way:
- Narration reads from `narration_text` if present
- QA compares against `narration_text` (same text TTS received)
- The original `text` column is unchanged (source of truth)
- No cache needed across sessions

## Implementation Plan

### M1: FMNormalizer + Cache (new files)

**New file:** `EchoCore/Services/Narration/FMNormalizer.swift` (~100 lines)
- `FMNormalizer` enum with `refine(text:blockID:cache:)`
- `FMNormalizationCache` actor for session caching
- `FMNormalization` @Generable struct
- FM prompt design
- Fallback on error (return input unchanged)

**New file:** `EchoTests/FMNormalizerTests.swift` (~50 lines)
- Cache hit/miss
- FM unavailable → passthrough
- Known tricky words get refined
- Already-speakable text unchanged

### M2: Integrate into NarrationService

**File:** `EchoCore/Services/Narration/NarrationService.swift`
- Add `fmCache` property to NarrationService
- Insert `FMNormalizer.refine()` between `TextNormalizer.normalize()` and `PronunciationOverrides.apply()`
- Gate behind `narrationQAClassifier == "auto"` and FM availability

### M3: Persist refined text (schema migration)

**New file:** `Shared/Database/Migrations/Schema_V31.swift`
- Add `narration_text TEXT` column to `epub_block`
- Nullable — null means "use original text" (backward compatible)
- No re-import forced

**File:** `Shared/Database/DatabaseService.swift`
- Register `v31_narration_text`

**File:** `Shared/Database/Records/EPubBlockRecord.swift`
- Add `narrationText: String?` property

### M4: QA uses refined text

**File:** `EchoCore/Services/Narration/QA/NarrationQAService.swift`
- Read `narrationText ?? text` instead of just `text`
- This aligns QA comparison with what the TTS actually received

### M5: Add FM normalization toggle to Settings

**File:** `EchoCore/Services/SettingsManager.swift`
- Rename or expand `narrationQAClassifier` → `narrationFMEnabled` (or add a separate key)
- Options: `"auto"` (FM for QA + normalization), `"qaOnly"` (FM for QA only, no pre-normalization), `"off"` (rules only)

## Testing Strategy

1. **Unit tests (FMNormalizer):**
   - "PCalc" → "P Calc" (acronym expansion)
   - "2am" → "two A M" (time disambiguation)
   - "the brown fox" → unchanged (already speakable)
   - FM unavailable → passthrough

2. **Integration tests (NarrationService):**
   - Render a block with FM normalization → audio sounds correct
   - Render same block without FM → audio may have issues
   - Regression: blocks without tricky words are unchanged

3. **QA regression tests:**
   - QA compares against `narrationText` when present
   - Old books without `narrationText` still QA correctly (fallback to `text`)

4. **Performance test:**
   - Full-book narration: FM normalization adds ~3 min (200 blocks × 1s)
   - Cache ensures re-narration of same book is instant

## Risk Assessment

| Risk | Mitigation |
|---|---|
| FM hallucinates text changes | `FMNormalization` uses `@Generable` constrained decoding; only rewrites words it identifies as problematic |
| FM adds latency to narration | Per-block (not per-chunk), cached, opt-in |
| FM changes text meaning | Prompt emphasizes "do NOT change meaning"; QA pass catches any issues |
| FM is unavailable on older devices | Gated behind `#available(iOS 26, macOS 26, *)`; silent passthrough |
| Refined text drifts from source | Stored in separate `narration_text` column; source `text` unchanged |
