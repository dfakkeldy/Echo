# Handoff — Calibre-vs-Echo chapter parsing

## 2026-08-15 — TOC-preferred chaptering implemented, project build blocked

Done:

- Diagnosed "Blood in the Water" (Libation m4b + Calibre EPUB). Echo's
  `epub_toc_entry` rows are correct (24 entries, right titles, right anchors);
  `EPUBImportService` step 7 overwrote `chapter_index` with a cumulative
  word-count → audio-time estimate, drifting boundaries mid-paragraph, and both
  readers named chapters from the first heading block (`<h1>2</h1>` wins over
  `<h1>COURTROOM 3: …</h1>`).
- Added `Shared/AudioChapterTOCAlignment.swift` (matches audio chapter labels to
  TOC labels; returns nil below a 2-match + majority confidence gate so the old
  estimate still runs) and `Shared/ChapterTitleResolver.swift` (TOC label →
  audio title → caller fallback). Wired into `EPUBImportService`,
  `MacReaderFeedView`, `ReaderFeedViewModel`; tests for both new types.
- Verified the algorithm against the real book via a standalone `swiftc`
  harness: all 16 boundaries land exactly on the TOC anchors, titles match
  Calibre, 38 front-matter blocks unassigned. `swiftc -parse` clean.

Next:

- `make build-tests` + `make test-only FILTER=EchoTests/AudioChapterTOCAlignmentTests`
  — NOT yet run. The build slot held (Saturday, outside 22:00–07:00 / weekday
  09:00–15:00). Needs the 22:00 window or an explicit `XBG_ALLOW_NOW=1`.
- Existing libraries keep their old boundaries until re-imported;
  `EPUBImportCoordinator.importEPUB` is `.replaceAll`, so the macOS Batch
  "Import EPUB" flow re-chapters a book with no migration.
- Then push and open a PR against `nightly`.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/peaceful-jones-5c018f
on branch claude/echo-calibre-chapter-parsing-7680b0. Run
`/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests` (add
XBG_ALLOW_NOW=1 only if Dan asks for an off-hours run), then
`make test-only FILTER=EchoTests/AudioChapterTOCAlignmentTests`.
```
