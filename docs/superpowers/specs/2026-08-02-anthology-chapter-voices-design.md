# Anthology Chapter Voices

- **Status:** Approved; implementation plan written
- **Date:** 2026-08-02
- **Author:** Dan Fakkeldy with Codex
- **Branch base:** `origin/nightly` at `fca76dd0`
- **Supersedes:** The unimplemented narration portion of Task 14 in
  `docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-08-02-anthology-chapter-voices.md`

## 1. Summary

Echo anthologies will honor the optional narration voice already stored for
each anthology chapter. A chapter with an explicit override uses that voice. A
chapter without one inherits Echo's current preferred narration voice at render
time.

The feature reuses Echo's existing Kokoro voice catalog, narration service,
chapter cache, track persistence, pronunciation handling, read-along anchors,
and M4B export. It does not introduce another TTS engine, an anthology-level
default voice, a new database column, or custom voice metadata in the EPUB.

The implementation must also complete the stable anthology narration identity
that the original anthology design intended. Reordering chapters must not
re-synthesize unchanged audio. Changing one chapter's text or explicit voice
must make only that chapter stale. Changing Echo's preferred voice must make
only inherited chapters stale.

## 2. Product decision

The approved rule is **preferred-voice inheritance**:

```text
effective voice = chapter override ?? Echo preferred narration voice
```

`nil` remains meaningful: it means the chapter follows the user's current Echo
preference. Echo does not copy the current preference into every anthology
entry, and an anthology does not gain its own default-voice field.

Consequences:

- choosing a chapter voice persists an exception with the anthology project;
- choosing **Echo Preferred Voice** clears that exception;
- a later preferred-voice change affects only chapters that still inherit;
- explicit overrides remain unchanged across preferred-voice changes;
- existing anthology records and synced manifests need no migration.

## 3. Current repository state

The feature is partially present on `nightly`:

- `AnthologyEntryRecord.narrationVoiceID` already persists and privately syncs
  an optional chapter voice;
- `AnthologyService` validates the voice against `VoiceCatalog` and freezes it
  into `AnthologyChapterManifest.voiceID`;
- the iPhone/iPad anthology editor already shows a chapter voice picker, though
  its inherited option is incorrectly labelled **Project Default**;
- generated anthology import already assigns every imported chapter a stable
  `sourceChapterKey` derived from the anthology entry UUID;
- `NarrationService.renderChapter` and `renderSegment` already accept a voice
  for each call and persist it on `TrackRecord.narrationVoice`;
- `echo-cli narrate --chapter-voice` already proves that the renderer can
  synthesize and assemble mixed-voice chapter plans;
- the normal iOS player and macOS batch narrator still resolve one preferred
  voice before their chapter loops and pass it to every chapter;
- narration cache names and persisted track IDs still use the mutable EPUB
  chapter index, so anthology reordering changes identity;
- the current startup sweep keeps one voice suffix for the whole book, which
  would delete valid files belonging to other chapter overrides;
- export still has a filename-glob fallback whose numeric chapter ordering is
  insufficient for stable-key anthology files.

This is therefore a wiring and identity-completion feature, not new synthesis
research.

## 4. Goals

- Let each anthology chapter use any voice in `VoiceCatalog` or inherit Echo's
  preferred narration voice.
- Honor the same frozen chapter voice plan in iOS playback, macOS batch
  narration, narration readiness, pronunciation repair, and M4B export.
- Preserve chapter voice exceptions through existing private workshop sync and
  deterministic anthology rebuilds.
- Reuse unchanged rendered audio when an anthology is reordered.
- Re-render only chapters whose spoken content, effective voice,
  pronunciation policy, or renderer identity changed.
- Keep generic EPUB/PDF narration and imported audiobooks byte-for-byte
  compatible at their existing identity boundaries.
- Keep narration completion, export success, and human listening acceptance as
  separate states.

## 5. Non-goals

- An anthology-level default voice.
- Different voices within one chapter or automatic speaker/quotation casting.
- Voice cloning, cloud TTS, downloaded third-party voices, or new voice models.
- Voice preview audio in the anthology editor.
- Encoding Echo chapter voice choices into exported EPUB metadata.
- Recovering chapter voice choices from a standalone exported/re-imported EPUB
  when its trusted local anthology build receipt is absent.
- Changing the existing `echo-cli --chapter-voice` command contract.
- Reworking narration quality, pronunciation, alignment, or media playback APIs
  except where stable chapter identity must be threaded through them.

## 6. User experience

### 6.1 Anthology editing

Each anthology chapter has a **Narration Voice** picker with:

1. **Echo Preferred Voice**;
2. the existing `VoiceCatalog.sections` and voice descriptors.

The inherited choice includes help text:

> Uses your current Echo narration voice. Changing that preference updates
> inherited chapters the next time they are narrated.

The picker saves immediately through the existing `AnthologyService.updateEntry`
path. Invalid or unavailable voice identifiers are never presented as valid
choices.

The choice edits the anthology draft. If a built edition already exists, Echo
continues narrating that frozen edition with its frozen voice plan and shows
**Changes available**. The new choice becomes authoritative only after the user
successfully rebuilds the EPUB; a failed rebuild leaves the previous edition
and voice plan intact.

The iPhone/iPad builder keeps its existing picker and changes the misleading
**Project Default** label to **Echo Preferred Voice**. The macOS Article
Workshop adds a compact chapter-editing sheet for the selected anthology so a
Mac user can set or clear the same overrides without requiring iOS. This sheet
may remain narrower than the complete iPhone/iPad anthology editor; it needs
chapter title, current effective voice, the voice picker, and save/error state.

### 6.2 Starting narration

The ordinary **Listen** and **Choose a Voice** controls continue to set Echo's
preferred voice. For an anthology, the selected voice is the fallback for
inherited chapters; it does not overwrite explicit chapter choices.

Where Echo summarizes the narration choice, it should say, for example:

> Default voice: Michael · 3 chapter overrides

This summary is informational. The existing anthology chapter editor remains
the place to change individual overrides.

### 6.3 Status and export

Anthology narration status reports:

- `Not started` when no current chapter audio exists;
- `N of M chapters ready` while the effective plan is incomplete;
- `K chapters need updating` when rendered files exist but text, voice, or
  renderer identity no longer matches;
- `Ready to export` only when every included chapter has current audio.

Changing only anthology order updates track order, M4B chapter order, and any
derived absolute timing without synthesis. Changing a chapter title does
re-render that chapter because the generated chapter heading is spoken.
Removing a chapter excludes its orphaned audio from playback and export;
bounded cache cleanup may remove it later.

## 7. Authoritative data and trust boundary

The latest successful `AnthologyBuildRecord` for the loaded generated edition
is the authority for chapter voice choices. Its canonical `manifestJSON` and
`manifestSHA256` already bind:

- anthology and edition identity;
- ordered chapter entry UUIDs;
- stable slots;
- frozen article revisions and readable-content digests;
- optional `voiceID` values.

The resolver locates that record by the current library `audiobookID`. The
macOS batch path may additionally match the canonical `epubPath` because it
uses the selected EPUB URL as its temporary book identity.

The resolver must validate the receipt before using it: digest, schema version,
EPUB identifier, edition revision, chapter uniqueness and order, readable
content digests, and every non-nil voice identifier. Validation logic should be
shared with existing anthology build/import checks rather than copied into a
third divergent implementation.

Resolution has three outcomes:

- **ordinary book:** no matching anthology build receipt; use legacy narration
  with one preferred voice and legacy index identity;
- **valid anthology:** resolve the complete stable-key voice plan;
- **invalid claimed anthology:** preserve existing audio, stop before cache
  cleanup or synthesis, and present a rebuild-oriented error instead of
  silently narrating with the wrong voices.

A standalone exported/re-imported EPUB with no matching local workshop receipt
is intentionally treated as an ordinary book.

## 8. Narration render plan

The shared narration plan must distinguish three concepts:

| Concept | Meaning | May change on reorder? |
|---|---|---|
| Display position | Current chapter/segment order and visible numbering | Yes |
| Source chapter key | Stable anthology entry UUID | No |
| Effective voice | Explicit override or current preferred voice | Only when its input changes |

`NarrationChapterPlanner` continues grouping imported blocks by current EPUB
chapter index, but each planned chapter also carries an optional stable source
key. A generated chapter receives a stable key only when every narratable block
in that chapter has the same non-nil `sourceChapterKey` and the validated
manifest contains that key. Mixed, missing, or foreign keys invalidate a
claimed anthology plan; they must not be guessed from sequence position.

A shared pure resolver produces one render plan consumed by iOS and macOS:

```swift
nonisolated struct NarrationChapterRenderPlan: Equatable, Sendable {
    let chapterIndex: Int
    let displayNumber: Int
    let sourceChapterKey: String?
    let title: String
    let blocks: [EPubBlockRecord]
    let voice: VoiceID
}
```

For ordinary books, `sourceChapterKey` remains `nil` and `voice` is the
preferred voice for every chapter. For a valid anthology, `voice` follows the
approved inheritance rule.

Segment planning propagates the stable source key and effective voice unchanged
to every segment belonging to that chapter. Neither caller re-resolves voices
inside its render loop.

## 9. Stable cache and track identity

Ordinary books keep the existing index-based cache and track identifiers.
Generated anthology chapters use an opaque digest of their source chapter key:

```text
book token + stable chapter digest + optional segment + content signature
           + voice + render version
```

The raw UUID does not need to appear in filenames or logs. The stable token is
the first 32 lowercase hexadecimal characters of SHA-256 over the canonical
source chapter key. The complete plan rejects a duplicate derived token before
cleanup or rendering. One shared helper owns both generation and parsing.

The content signature continues binding rendered block identity/text,
normalization mode, pronunciation policy, lead-out behavior, and render
version. The voice remains explicit in the filename and persisted track.

Persisted anthology track IDs use the same stable chapter digest. `sortOrder`
is mutable presentation state and is updated to the current anthology order
whenever cached audio is reused. Segment order remains deterministic within a
chapter.

Consequences:

- reorder changes titles/order metadata but not audio identity;
- an explicit voice change produces a cache miss only for that chapter;
- a preferred-voice change produces cache misses only for inherited chapters;
- a text or pronunciation-policy change produces a content-signature miss;
- chapter-title changes re-render that chapter because the title is spoken.

Resume cannot depend solely on parsing a numeric chapter index from a stable
anthology filename. It resolves the last persisted track's stable digest back
through the current render plan and starts at that chapter's current position.
Legacy numeric filename parsing remains the ordinary-book fallback.

## 10. Cache cleanup

The current one-voice startup sweep is incompatible with mixed-voice books.
Cleanup must run only after the complete render plan is validated and expected
cache identities are known.

For the active book, cleanup receives the set of expected durable filenames or
stable render-unit identities for all current chapters and segments. It may
remove:

- obsolete render versions;
- superseded voices for the same stable chapter;
- stale content-signature variants;
- removed anthology chapters;
- abandoned task-owned partial files.

It must never delete a current file merely because another chapter uses a
different voice. If the anthology plan is invalid or incomplete, cleanup does
nothing.

## 11. Platform integration

### 11.1 iOS and iPadOS playback

`PlayerModel+Narration` loads visible blocks, validates/resolves the shared
render plan, and then performs cache cleanup. Each segment cache lookup,
entitlement check, render call, cached-track update, queue insertion, outline
status, and backfill operation uses that segment's resolved identity and voice.

The first ready segment still starts playback immediately. Render-ahead,
cancellation, book-switch detection, interruption behavior, Now Playing, and
read-along timing remain unchanged.

### 11.2 macOS batch narration

`MacBatchProcessingService` resolves the same plan instead of resolving one
voice before its chapter loop. Retry with a fresh engine retains the failed
chapter's resolved voice and stable identity. Sidecar generation continues to
derive absolute timing from persisted tracks in current `sortOrder`.

### 11.3 Pronunciation QA and repair

QA and pronunciation repair resolve the target chapter's effective voice from
the same plan. Repairing one chapter re-renders that stable chapter with its
effective voice; it must not fall back to the global preferred voice when an
override exists.

### 11.4 M4B export

`NarrationCacheSource` treats reachable persisted narration tracks as the
primary export inventory and orders them by current `sortOrder`, including
segments within a chapter. Filename globbing remains only a legacy/recovery
fallback for ordinary books.

For a generated anthology, export validates the current render plan and
requires one complete current render set for every included chapter. It ignores
orphaned files, old voice variants, removed chapters, and obsolete render
versions. Chapter markers use current frozen anthology titles, regardless of
when the audio was synthesized.

Reordering reuses the rendered chapter/segment files but still recomposes the
M4B and recomputes any absolute sidecar offsets. Audio reuse is not permission
to reuse order-dependent export timestamps.

## 12. Compatibility and migration

No database migration is required. Existing anthology entries, build manifests,
CloudKit records, and `TrackRecord.narrationVoice` already carry the necessary
data.

Compatibility rules:

- existing anthologies with nil chapter voices inherit Echo's preferred voice;
- existing explicit overrides begin working after this feature ships;
- existing index-named anthology audio re-renders once into the stable identity;
  the implementation does not add a risky cache-adoption path;
- generic EPUB/PDF narration keeps its current filenames, track IDs, resume,
  and export behavior;
- old app versions continue decoding anthology manifests because the schema is
  unchanged;
- private workshop sync continues carrying `narrationVoiceID` as it does now.

## 13. Error handling

- Saving an unavailable voice leaves the prior chapter choice intact and shows
  the existing anthology save error.
- A valid build receipt containing an unavailable voice blocks mixed-voice
  rendering and asks the user to select a current voice or rebuild; it does not
  delete prior audio.
- An invalid manifest digest, duplicate source key, cross-book key, or
  block-to-manifest mismatch blocks anthology rendering before cleanup.
- A single synthesis failure retains existing per-chapter retry/skip semantics
  on macOS and the current failure presentation on iOS.
- Cancellation and book switching never persist a partial track or replace a
  proven durable cache file.
- Export refuses an incomplete or stale anthology plan and reports which
  chapters need narration instead of falling back to arbitrary globbed files.

Logs may include display position, public voice ID, and a bounded stable-key
digest. They must not include captured article prose, source URLs, or raw
private anthology UUIDs when the digest is sufficient.

## 14. Accessibility and localization

- **Narration Voice**, **Echo Preferred Voice**, help text, override summary,
  readiness states, and errors are localized.
- Picker rows expose voice display name, descriptor, and selected state to
  VoiceOver.
- The inherited choice does not rely on color or an unlabeled icon.
- macOS voice editing is keyboard reachable and preserves focus after save.
- Dynamic Type does not truncate the selected voice without an accessible
  value.

## 15. Verification strategy

### Pure and persistence tests

- nil override resolves to the supplied preferred voice;
- explicit override wins over preferred voice;
- changing preferred voice changes only inherited chapter plans;
- unknown voice and invalid manifest evidence fail before cleanup;
- ordinary books keep legacy plan and filename identity;
- generated chapter stable identity survives reorder;
- mixed or missing `sourceChapterKey` values reject a claimed anthology;
- chapter-title change invalidates only that chapter because the title is
  spoken;
- text, pronunciation policy, renderer version, or voice change invalidates the
  expected chapter;
- mixed-voice cleanup preserves every current expected voice and removes stale
  variants;
- legacy index-named anthology audio is not adopted as stable-key audio.

### Runtime orchestration tests

- iOS render calls receive the intended voice for every chapter and segment;
- reorder reuses files without calling the fake TTS engine;
- resume maps a stable track to its new current position;
- macOS retry retains the chapter's override;
- pronunciation repair retains the chapter's override;
- readiness counts only exact current plan matches;
- export orders current stable tracks after reorder and emits one marker per
  anthology chapter.

### UI tests

- iPhone/iPad picker saves an override and clears it with **Echo Preferred
  Voice**;
- macOS chapter sheet performs the same two operations;
- preferred-voice summary reports the override count;
- accessibility labels and values distinguish inherited from explicit voices.

### Integration and acceptance

Use a committed synthetic three-chapter anthology fixture with three authored
short texts:

1. chapter one inherits the preferred voice;
2. chapter two explicitly uses a different voice;
3. chapter three explicitly uses a third voice.

Verify the focused tests first, then `make test`. Build the app targets affected
by the final change. Produce one real three-chapter render and verify:

- persisted tracks contain the intended three voice IDs;
- chapter two and three audibly differ from chapter one;
- changing only chapter two's voice renders only chapter two;
- reordering all three chapters synthesizes no new audio;
- M4B marker order follows the new order;
- read-along anchors remain attached to the correct stable chapter;
- mechanical audio evidence is reported separately from a human listening
  verdict.

## 16. Acceptance criteria

- A user can select or clear a chapter voice in an anthology on iPhone/iPad and
  Mac.
- A cleared chapter uses Echo's preferred narration voice without persisting a
  copied value.
- iOS playback and macOS batch narration render every anthology chapter with
  its effective voice.
- Explicit overrides survive preferred-voice changes.
- Reordering an unchanged anthology causes zero synthesis calls.
- Changing one chapter's effective voice causes only that chapter to render.
- Mixed-voice cache cleanup preserves all current chapter files.
- Resume, read-along, narration outline, pronunciation repair, readiness, and
  M4B export resolve the same stable chapter plan.
- Export is blocked when any current chapter is missing or stale.
- Generic EPUB/PDF narration behavior is unchanged.
- No schema migration or third-party dependency is introduced.

## 17. Alternatives considered

### Anthology-level default plus overrides

Rejected for this slice. It adds project persistence, sync, UI, and another
default whose relationship to Echo's existing preference must be explained.
The approved inheritance rule provides the requested control with less state.

### Custom chapter voice metadata inside the EPUB

Rejected for this slice. It makes a standalone EPUB carry the choices, but it
creates a second metadata parser and trust boundary and duplicates the already
hashed local build manifest. Standalone EPUB portability is an explicit
non-goal.

### Copy voice IDs into every imported block or a new chapter table

Rejected. It requires a migration, duplicates manifest state across many rows,
and complicates generated-edition reconciliation. The stable source chapter
key already provides the join needed at render-plan time.

### Resolve voices independently in each caller

Rejected. iOS playback, macOS batch narration, QA, readiness, and export would
drift. One shared pure render plan is the contract all callers consume.
