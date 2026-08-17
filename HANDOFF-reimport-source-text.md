# Handoff — stale read-along after an EPUB spine change

## 2026-08-16 — Second wrong fix reverted; root cause confirmed; no code change owed

Done:
- Reverted `d1960fde` (forced `force: true` in
  `PlayerLoadingCoordinator.importDocumentForAudiolessBook`). Wrong twice over:
  that function is the *load* path (called at :225 when `state.tracks.isEmpty`),
  NOT "Replace Document…", and its existing contract is "idempotent once blocks
  exist" — forcing would wipe blocks on every open and dangle the FK-less
  `timeline_item` / `word_timing` / `note.epub_block_id` columns.
- "Replace Document…" ALREADY forces: PlayerMoreMenu:53 → RootTabView:829 →
  `PlayerModel.importEPUBDocument` → `EPUBImportCoordinator.importEPUB`
  (`force: true`, EPUBImportCoordinator.swift:115).
- Root cause verified on disk: `Blood in the Water.epub` now has 18 spine items
  (s1 = merged `front`); `.epub.bak` has 25 (s1 = `item1`). Device blocks came
  from the 25-item spine; the sidecar targets the 18-item one.
  `AlignmentSidecar.sourceValidation` is fail-closed and returns on the first
  bad anchor (`s1-b0`, 1 of 1572) → `.staleSource` → recalculate-only across
  2 anchors → straight-line drift.
- Read-only DB check: this book has 0 hidden blocks, 0 card colors, 0 flashcards,
  0 notes, and only 4 machine `imported` anchors. A forced re-import costs nothing.

Next:
- User remediation is a menu action, not a code change: More → Replace Document…
- Open (separate, non-trivial) defects, NOT fixed here:
  1. `.staleSource` never re-parses the source, so it is a permanent trap.
  2. `DocumentImportFinalizer.swift:343-345` overwrites `.applied` with
     `.foundButUnresolved` when `blocksApplied == 0`, which is guaranteed for any
     word-less sidecar — a successful 1572-anchor ingest reports a false status.
  Workflow `wf9zm465j` found 19 must-fix items in a "safe re-import" design
  (destroys `is_hidden`/`card_color`, drops `.transcriptAlignment`/`.synthesized`
  anchors, dangles flashcard + study-plan block pins). Design before coding.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/epub-identity-fork
is clean at origin/nightly 8afbd6fa (nightly is now 8 commits ahead). Nothing
pushed, no PR. Next action: decide whether to fix the `.staleSource` dead end
and the false `.foundButUnresolved` status line; read
/private/tmp/claude-501/-Users-dfakkeldy-Developer-Echo/fa65aa4b-9e21-4a8f-a7da-cbd548c5de35/tasks/wf9zm465j.output
(result.mustFix, 19 items) first.
```

## 2026-08-16 — Four-part fix implemented, uncommitted, verification blocked on swap

Done (12 files modified + 1 new test file, ~1284 insertions, NOTHING committed):
- A. `EPUBImportService.replaceAllPreservingUserState` — a forced re-import now
  resolves old block ids to new ones (exact id, then portable `s<i>-b<j>` suffix
  among *unmatched* blocks on both sides; ambiguity refused) and carries user
  state across, inside the SAME write transaction. Never reconstruct an id from
  a suffix: `EPUBBlockParser:257` emits both `epub-<id>-s<i>-b<j>` and
  `epub-<id>-generic-...`, so reconstruction silently drops every generic block.
  Per-table `OrphanPolicy`: FK-less pointer columns (`note`, `voice_memo`,
  `flashcard`, `narration_quality_issue`) use `.preserveDanglingPointer` because
  block ids are a deterministic function of the document — a dangling pointer is
  the address the row re-attaches to if the right EPUB comes back.
  `study_plan_item.source_block_id` is a REAL FK (Schema_V25, ON DELETE SET
  NULL) and must NOT get that policy — see the bug below.
  Anchors: machine anchors are measurements of specific words, so they drop when
  the block's `sourceIdentity` moves; human anchors (`moveToNow`,
  `searchResult`, `chapterBoundary`) are a person's claim about where they are
  and nothing can recompute them, so they survive (`isSourceStable || isHuman`).
- B. `DocumentImportFinalizer` — the `blocksApplied == 0` downgrade to
  `.foundButUnresolved` is now gated on the sidecar actually carrying word
  timings. It fired for ANY word-less sidecar, so a clean 1572-anchor ingest
  reported failure.
- C. `EPUBAutoImportScanner` — automatic `.staleSource` recovery, fused on a
  (size, mtime) fingerprint of source + sidecar so it retries exactly once per
  real revision. Gated behind `sidecarProvesDocumentIdentity` (≥1 anchor with a
  `sourceBlockIdentity`); without that gate the fuse passed *precisely* when the
  EPUB was a different document, i.e. it triggered an unattended destructive
  rebuild in the one case it must not.
- D. `SidecarImportSummary` + `BookSettingsView` — honest status text and a
  `readAlongRecoveryHint` telling the user what to actually do.

Two real bugs the tests caught (both fixed, both would have shipped):
1. `UPDATE study_plan_item SET source_block_id = rebuiltID ?? priorBlockID`
   → `SQLite error 19: FOREIGN KEY constraint failed`, and because it runs
   inside the import transaction the error takes the WHOLE re-import down.
   Unresolvable pins are now left as SET NULL left them and counted lost.
2. `URL` caches resource values on first read, so the recovery fingerprint kept
   reporting the pre-write size/date — it would decline the very recovery the
   user earned by replacing the file. Fixed with
   `removeAllCachedResourceValues()` before each read.

Next:
- Verification has NOT run since those three fixes. Job `b235xaf6l` is waiting
  on the build gate: swapFree pinned at 454MB vs the 512MB hardMin. The
  schedule already passes via `XBG_ALLOW_NOW=1`; swap is the sole blocker.
  Do NOT edit the gate thresholds — quit an app instead (ChatGPT/Codex was
  holding ~1.5GB).
- After it goes green: rebase (branch is 2 behind origin/nightly), commit,
  push, open a PR `--base nightly`.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/epub-identity-fork,
branch fix/reimport-source-text (2 behind origin/nightly), 13 files dirty,
nothing committed. Single next action: re-run
/private/tmp/claude-501/-Users-dfakkeldy-Developer-Echo/fa65aa4b-9e21-4a8f-a7da-cbd548c5de35/scratchpad/verify2.sh
(make build-tests, then the six suites batched into one FILTER, then the
"Echo macOS" build, then make echo-cli). It exits 0 on deferral — grep the
output for "Build deferred" / "NEVER ADMITTED".
```
