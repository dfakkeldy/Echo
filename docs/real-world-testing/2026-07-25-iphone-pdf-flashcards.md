# iPhone PDF narration and flashcard overnight QA — 2026-07-25

## Evidence boundary

- Physical iPhone 12 Pro running iOS 27.0, operated through iPhone Mirroring.
- Echo Debug build from `feature/overnight-pdf-flashcards`.
- Tested source base: `origin/nightly` at
  `08a0c0acc25399c19050789e53ce645e7880dc98`.
- Initial full physical-flow patch SHA-256:
  `d22b8e13115e8fb223bfc827e6cc7839f66fdc37bbacde21f02f0837693c8ff0`.
- Final source/test patch SHA-256:
  `716228331ce1d74da68e63d97b28c1c930b09eea0d446118455060bb60170fd8`.
- Final-patch device smoke: signed Debug build installed and launched; shelf reopen retained
  Page/Reflow and the visual PDF page rendered.
- Visual checks are device observations, not human listening or comprehension acceptance.
- The PDF probe contains synthetic pronunciation text. No copyrighted book text, private
  storage paths, or stable device identifiers are recorded here.

## Exercised flow

1. Open a standalone text PDF from iCloud Drive.
2. Render its first on-device narration segment with the installed voice models.
3. Open Read, expand the parsed chapter, replay it, and observe synchronized reader state.
4. Mark a passage, open Stats → Card Inbox, edit a question and answer, and save the card.
5. Open *The High-Conflict Couple* as an EPUB/M4B/alignment package.
6. Play the saved Chapter 10 position and observe the Read view track the active paragraph
   and word.
7. Import a private 55-card JSON deck bound to the loaded book.

## Findings and fixes

### Standalone PDFs were disabled in the library picker

The library folder button opened Files, but a valid PDF was grey and could not be chosen.
`FolderPicker` omitted `UTType.pdf` even though the downstream loader and reader supported
direct PDF files.

The picker now has explicit book and folder modes. Book opening accepts PDF; recovery and
root-relocation pickers remain folder-only.

Device recheck: the same PDF became selectable and loaded.

### Direct PDF display used the parent-folder name

After import, the player labelled the standalone PDF with its containing iCloud folder.
The audio-less import path now derives the fallback display title from the selected document,
and narration no longer overwrites a resolved title with the container name.

Device recheck: the PDF filename appeared in the mini-player. The persisted shelf-title
correction and direct-file page-mode path are covered by focused regression tests. Echo also
persists a security-scoped source-document bookmark under the existing parent book identity,
so a shelf reopen restores the exact PDF without moving notes or progress to a new key.

Device recheck: after returning to the shelf and reopening the PDF, both Page and Reflow were
available; the visual page rendered and the parsed-text feed remained selectable.

### iCloud deck import did not begin security-scoped access

The valid synced JSON deck was visible in Files but import failed with a provider permission
error. `DeckImportService` now holds the selected URL's security scope through file reading,
releasing it afterward. Decks with sibling image files must be imported by selecting their
folder, which gives Echo a recursive security grant for the manifest and media.

Device recheck: Echo reported `Imported 55 cards`.

### Audio-less documents inherited the previous book's artwork

Opening the PDF after the EPUB/M4B book could retain the previous cover even though the
document title and content had changed. The no-audio reset now invalidates the artwork
coordinator as well as clearing its thumbnail state.

Regression check: the focused model test seeds both artwork layers, opens an audio-less
document, and verifies both are cleared.

## Verification

- Focused Swift suites: 71 passed, 0 failed, 0 skipped, with no warnings or build errors.
  The selected suites were `AudiolessEPUBImportTests`, `DeckImportServiceTests`,
  `DeckImportImageTests`, `Wedge3ClarityOnRampTests`, `PlayerModelTests`, and
  `ReaderPDFViewModePreferenceTests`, run through XcodeBuildMCP with the equivalent
  `-only-testing:EchoTests/<Suite>` arguments.
- Complete simulator suite: 2,719 passed, 0 failed, 3 intentionally skipped, including
  all seven UI tests.
- One preceding complete-suite attempt aborted in Apple's simulator
  Accessibility/TextToSpeech stack (`AXSpeech`) while the Foundation Models availability
  test was active. Crash classification found no Echo or Foundation Models frame. The named
  test then passed five consecutive isolated iterations, and the final complete-suite run
  above passed cleanly.
- Physical-device Debug build: succeeded.
- PDF narration: first synthesized segment rendered and entered the normal playback pipeline.
- PDF reflow reader: parsed text displayed while the synthesized track was loaded.
- High-Conflict Couple read-along: active paragraph edge and current-word highlight observed.
- Manual card path: save completed and the SRS card count increased.
- Deck import: 55 cards accepted; the private artifact was separately checked as five cards
  in each of 11 chapters.
