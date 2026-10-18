# Character-Level Multi-Voice Narration Design

**Status:** Approved for implementation
**Date:** 2026-08-08
**Owners:** Echo renderer and Explainer Audiobooks governed production workflow

## Outcome

An external fiction-audiobook workflow can assign distinct Kokoro voices to the
narrator, POV characters, and dialogue speakers while Echo still emits exactly
one chaptered M4B and one ordinary alignment sidecar. Echo consumes an explicit,
source-bound JSON plan and chooses one voice for each portable EPUB block. It
does not infer speakers from prose and does not create per-speaker audio files.

The production workflow owns manuscript segmentation, automatic casting, and
user preferences. Echo owns strict plan validation, deterministic voice
resolution, rendering, capture identity, pronunciation evidence, and final
artifact assembly.

## Approved Boundaries

- Version 1 supports EPUB inputs only when `--voice-plan` is present.
- One speakable EPUB block has exactly one effective speaker and voice.
- Explicit assignments may name blocks or one inclusive range whose endpoints
  are in the same narrated chapter.
- Unassigned speakable blocks use `defaultSpeakerID`.
- `--voice-plan` and `--chapter-voice` are mutually exclusive.
- `--voice` remains the legacy default when no plan is supplied. When a plan is
  supplied, an explicitly supplied `--voice` must equal the default speaker's
  voice; omitting `--voice` uses the plan default.
- Existing uniform and chapter-level narration remains behaviorally compatible,
  including its capture schema and pronunciation-audit schema.
- Voice changes happen while streaming PCM into the existing hidden chapter
  capture. Echo creates no per-block or per-speaker clips.
- The normal alignment sidecar schema and word-timing schema do not change.
- No crossfades, per-voice gain calibration, or dialogue detection are included.
- Intermediate chapter M4As, marker files, and optional pronunciation reels are
  internal workflow artifacts. A fiction delivery directory contains one EPUB,
  one M4B, one alignment sidecar, and one cover image; it contains no listening
  reel.
- No new third-party dependency is permitted.

## Portable Voice-Plan Contract

The JSON document is UTF-8 and uses this exact schema:

```json
{
  "schemaVersion": 1,
  "source": {
    "epubSHA256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "defaultSpeakerID": "narrator",
  "speakers": [
    { "id": "narrator", "voiceID": "am_michael" },
    { "id": "mara", "voiceID": "bf_emma" },
    { "id": "jon", "voiceID": "am_fenrir" }
  ],
  "assignments": [
    { "speakerID": "mara", "blocks": ["s2-b3", "s2-b7"] },
    {
      "speakerID": "jon",
      "range": { "start": "s2-b8", "end": "s2-b10" }
    }
  ]
}
```

### Lexical rules

- Objects reject unknown keys and duplicate keys.
- `schemaVersion` is the integer `1`.
- `source.epubSHA256` is exactly 64 lowercase hexadecimal characters and hashes
  the exact source EPUB bytes.
- Speaker IDs match `^[A-Za-z][A-Za-z0-9_-]{0,63}$` and are unique.
- `defaultSpeakerID` names one declared speaker.
- `voiceID` names an English voice in `VoiceCatalog`, and its voice resources
  must be available before a render clears prior artifacts.
- Portable block IDs match `^s[0-9]+-b[0-9]+$` and use Echo's existing
  zero-based spine and block indexes.
- An assignment has exactly `speakerID` plus either `blocks` or `range`.
- `blocks` is a non-empty array with no duplicate IDs.
- `range` has exactly `start` and `end`; expansion is inclusive in the imported
  narratable-block sequence.
- Range endpoints exist, are narratable, occur in forward order, and belong to
  the same narrated chapter.
- Every assigned block exists, is visible, and contains speakable text.
- Explicit lists and expanded ranges cannot overlap.
- Empty `assignments` is valid and assigns every speakable block to the default
  speaker.

### Canonical resolved plan

Echo validates the source and expands the authored plan against the imported
blocks before rendering. The canonical resolved representation is sorted by
portable block order and contains every speakable block:

```json
{
  "schemaVersion": 1,
  "sourceEPUBSHA256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "defaultSpeakerID": "narrator",
  "blocks": [
    { "blockID": "s0-b0", "speakerID": "narrator", "voiceID": "am_michael" },
    { "blockID": "s2-b3", "speakerID": "mara", "voiceID": "bf_emma" }
  ]
}
```

`voicePlanSHA256` is the lowercase SHA-256 of compact JSON for that resolved
representation with sorted object keys and no insignificant whitespace.
`voicePlanID` is `plan-` followed by the first 12 hex characters. Formatting,
speaker declaration order, explicit-list order, and equivalent range/list
spelling therefore do not change identity; any effective block, speaker, voice,
default, or source change does.

## Echo Interfaces

Echo adds these value types in
`EchoCore/Services/Narration/BlockVoicePlan.swift`:

```swift
nonisolated struct BlockVoicePlanDocument: Decodable, Sendable

nonisolated struct ResolvedBlockVoice: Codable, Equatable, Sendable {
    let blockID: String
    let speakerID: String
    let voiceID: VoiceID
}

nonisolated struct ResolvedBlockVoicePlan: Equatable, Sendable {
    let sourceEPUBSHA256: String
    let defaultSpeakerID: String
    let blocks: [ResolvedBlockVoice]
    let voicePlanSHA256: String
    var voicePlanID: String { get }
    var defaultVoice: VoiceID { get }
    func voice(forBlockID blockID: String) -> VoiceID
    func speaker(forBlockID blockID: String) -> String
    func chapterDigest(blockIDs: [String]) -> String
}

nonisolated enum BlockVoicePlanLoader {
    static func decode(data: Data) throws -> BlockVoicePlanDocument
    static func resolve(
        document: BlockVoicePlanDocument,
        sourceEPUBSHA256: String,
        chapters: [PlannedNarrationChapter]
    ) throws -> ResolvedBlockVoicePlan
}
```

Decoding uses strict `CodingKeys` checks and a duplicate-key JSON preflight;
resolution performs source-, catalog-, block-, chapter-, overlap-, and fallback
validation. The runner resolves the plan after source import and chapter
planning, but before fresh-run cleanup.

`NarrationRunConfig` gains `voicePlanURL: URL?`. Its existing `voice` becomes
`VoiceID?`; the runner derives `defaultVoice` from the plan or uses the legacy
voice. `NarrationService.renderChapter` gains a concrete closure:

```swift
blockVoice: @Sendable (String) -> VoiceID
```

Legacy callers pass a closure returning their one selected chapter voice. The
render loop resolves the voice once per original block and uses it for every
synthesis chunk belonging to that block.

## CLI Contract

```sh
echo-cli narrate \
  --epub novel.epub \
  --out novel.m4b \
  --sidecar novel.alignment.json \
  --voice-plan novel.voice-plan.json \
  --work-dir /private/run/novel-work \
  --title "Novel Title" \
  --author "Author Name"
```

`--voice-plan` is a file option. The CLI rejects:

- a plan with a PDF or source directory;
- `--voice-plan` combined with any `--chapter-voice`;
- an explicitly supplied `--voice` that differs from the plan default;
- a missing or invalid plan before destructive cleanup.

ArgumentParser must distinguish an omitted `--voice` from an explicit one, so
the option is `String?`; the no-plan path supplies `VoiceCatalog.defaultVoice`.

The governed workflow needs the resolved identity before it allocates run
storage. Echo therefore also exposes a read-only resolver:

```sh
echo-cli resolve-voice-plan \
  --epub novel.epub \
  --voice-plan novel.voice-plan.json
```

It performs the same source import and validation used by narration, writes no
database or media, and emits one compact sorted-key JSON object to stdout:

```json
{"blockCount":42,"defaultVoice":"am_michael","sourceEPUBSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","voicePlanID":"plan-123456789abc","voicePlanSHA256":"123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"}
```

The narration runner and resolver share `BlockVoicePlanLoader`; the shell
workflow does not reimplement EPUB parsing or range expansion.

## Capture and Resume Identity

Legacy uniform/chapter captures continue using capture schema 1 unchanged.
Plan-backed chapters use capture schema 2. Schema 2 identity adds:

```swift
let voicePlanSHA256: String
let chapterVoicePlanSHA256: String
```

Its existing `voice` field stores the plan's default voice for compatibility,
not proof of every block voice. `captureSetID` hashes the source fingerprint,
renderer identity, render settings, full `voicePlanSHA256`, and ordered chapter
digests. A chapter filename uses `plan-<12>` rather than pretending it has one
voice. The chapter digest hashes only that chapter's ordered resolved block
records, so marker inspection is explicit and deterministic.

Resume accepts schema 1 for legacy invocations and schema 2 for plan-backed
invocations. It never cross-accepts them. A changed plan, source, renderer,
chapter digest, audio hash, marker hash, or content signature rejects the
capture. Equivalent JSON that resolves identically reuses the capture.

## Timing, Audio, and Artifact Semantics

- A voice is selected once before synthesizing an original block.
- All pronunciation-expanded chunks of that block use the selected voice.
- Existing sample-cursor accumulation determines anchor and word timestamps.
- One anchor remains associated with each original block.
- Existing paragraph, heading, section, and chapter silences remain unchanged.
- PCM is appended to the same hidden chapter partial; no voice-switch file join
  is introduced.
- Kokoro workers retain their ONNX sessions; voice changes only select/cache a
  voice style pack.
- Chapter captures remain under `--work-dir`; the final export remains one M4B.
- The ordinary `.alignment.json` format gains no voice or speaker fields.

## Pronunciation Audit Schema 7

Legacy runs continue emitting their current schema. Plan-backed runs emit
schema 7 and retain all schema-6 fields. They add:

```json
{
  "voicePlanSHA256": "64-lowercase-hex",
  "blockVoices": {
    "s0-b0": "am_michael",
    "s2-b3": "bf_emma"
  }
}
```

For schema 7:

- `voice` is `mixed` when more than one effective voice occurs, otherwise it is
  that one voice.
- `blockVoices` contains exactly every speakable block in the resolved plan.
- Every mapped voice is in `VoiceCatalog`.
- Every pronunciation decision's portable block ID exists in `blockVoices`.
- `chapterVoices` is empty because it cannot faithfully represent a block plan.
- Exact final-M4B and optional internal-reel hashes retain current semantics.

The normal sidecar remains the portable timing handoff. The audit is the
voice-provenance handoff.

## Governed Workflow Contract

Explainer Audiobooks adds `--voice-plan ABSOLUTE_PATH` to preflight and narration
wrappers. The plan is copied as canonical JSON into
`$RUN_ROOT/research/echo-voice-plan-$VOICE_PLAN_ID.json`. The input receipt,
attempt state, resume state, success receipt, and delivery verification bind its
SHA-256 and plan ID.

The workflow derives its run ID from the exact EPUB hash, installed Echo package
identity, pronunciation inputs, and resolved plan hash. It invokes Echo with
`--voice-plan` and an explicit work directory. A changed plan creates a new run,
work directory, database, state receipt, and output attempt.

The fiction workflow may author semantic EPUB metadata, but it must compile it
to this JSON after producing the final EPUB. It must enforce the segmentation
rule that one Echo block represents one uninterrupted speaker run.

Automatic casting reads a separate local preference file, outside Git and
outside Echo, with this schema:

```json
{
  "schemaVersion": 1,
  "blacklistedVoiceIDs": ["af_alloy"],
  "preferredNarratorVoiceIDs": ["am_michael", "bm_george"]
}
```

The default path is
`~/Library/Application Support/Explainer Audiobooks/fiction-voice-preferences.json`.
Preferences affect only plan generation. A finished plan is self-contained;
regenerating it after a preference change creates a new run only when the
resolved assignments change.

## Delivery Contract

The fiction delivery set contains exactly these four artifact roles:

1. final EPUB;
2. final chaptered M4B;
3. final `.alignment.json` sidecar;
4. final cover image.

Pronunciation audit JSON, listening reels, chapter M4As, marker JSON, databases,
and plan/state receipts remain under governed run storage. Delivery verification
fails if a second M4B or any intermediate clip is present beside the final M4B.

## Compatibility and Rollout

1. Echo lands and releases `--voice-plan`, capture schema 2, and audit schema 7.
2. The installed-renderer manifest advertises the exact `--voice-plan`
   capability only after that Echo package is installed and attested.
3. The governed wrapper and state validator land against that released contract.
4. The fiction workflow begins generating plans and enforcing segmentation.
5. Listening acceptance on a mixed-voice fixture gates production use.

Uniform and chapter-level commands need no migration. Historical capture,
resume, and audit schemas remain readable through their existing lanes.

## Acceptance Criteria

- A two-chapter EPUB with narrator, POV, and dialogue blocks produces the
  expected ordered Kokoro voice calls.
- Repeated synthesis chunks within one block all use that block's voice.
- Identical resolved plans resume; changed effective plans do not.
- Missing voices, wrong source hashes, invalid blocks, reversed ranges,
  cross-chapter ranges, and overlapping assignments fail before cleanup.
- The final M4B has the expected chapters and the ordinary sidecar has valid,
  monotonic anchors and word timings.
- Plan-backed audit schema 7 binds the plan and complete block-voice map.
- Existing uniform and chapter-voice fixtures remain valid.
- Governed delivery contains one M4B and no intermediate clips or listening
  reel.
