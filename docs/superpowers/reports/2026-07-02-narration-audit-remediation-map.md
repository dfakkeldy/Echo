# Narration Audit Remediation Map

Date: 2026-07-02
Base checked: `origin/nightly` at `a396d52`
Scope: repo-local narration audit and QA ledger cleanup only. Do not treat this file as a product fix list outside narration. Do not use or edit `~/.codex/memories` for this lane.

## Source Of Truth

- Historical audit: `NARRATION_AUDIT.md`, added by PR #368 from branch `claude/peaceful-herschel-867461`.
- Current remediation map: this file.
- Historical CoreML-era audit: `CODE_AUDIT_NARRATION.md`, retained only for archaeology. It is not current remediation guidance.
- Current living architecture: `ARCHITECTURE.md`, especially the generated narration QA and shared improvement sections.

## Completed Since PR #368

| Audit item | Status on `origin/nightly` | Evidence |
| --- | --- | --- |
| 5.1 Decimal chunking | Fixed | PR #370, commit `a1a8f30`; `NarrationTextChunker` tests cover bare decimals. |
| 5.2 Built-in `re` override corrupting contractions | Fixed | PR #370, commit `a1a8f30`; pronunciation override regression coverage added. |
| 5.8 Roman numerals outside chapter headings | Fixed | PR #370, commit `a1a8f30`; TextNormalizer now covers broader Roman-numeral contexts. |
| 5.10 `echo-cli narrate --db` second-run primary-key failure | Fixed | PR #370, commit `a1a8f30`; headless runner rerun coverage added. |
| 5.11 Abbreviation and sentence-final `St.` handling | Fixed | PR #370, commit `a1a8f30`; follow-up commits preserved saint-name normalization. |
| 5.12 Comma-grouped ordinals | Fixed | PR #370, commit `a1a8f30`; TextNormalizer regression coverage added. |
| 5.4 Partial renders at final cache names | Fixed for the shared render path | PR #372, commit `8456b9f`; `NarrationService` writes hidden `.partial.m4a` siblings and publishes only after finalize. |
| 5.5 Cache key omits text-affecting state | Fixed for signed cache filenames | PR #372, commit `8456b9f`; cache names now include a content signature of rendered inputs. |
| 5.23 Headless QA chapter matching parses title digits | Fixed | PR #374, commit `a396d52`; manifest parsing now requires exact `.anchors-ch<N>.json` and delimited `-ch<N>` audio names. |

## Still Pending Or Partial

| Audit item | Current status | Next useful action |
| --- | --- | --- |
| 3.1 Previous render task cancelled but not awaited | Pending | `PlayerModel+Narration` still calls `narrationRenderTask?.cancel()` before starting the next task. Add an await or generation handoff before stale-file sweeps and new rendering. |
| 3.2 Background-task protection for render-only phases | Pending | Add background-task assertions around prepare/render-only windows and clean cancellation. |
| 5.3 QA/repair chapter files vs iOS segment files | Pending | iOS playback still renders `segmentCacheURL`, while `runFullQA()` discovers `chapterCacheURL`. Unify via a render-unit resolver before claiming the QA loop works for iOS in-app narration. |
| 5.6 QA/repair use global voice preference | Pending | `NarrationQAReviewModel.resolveVoice()` still reads `UserDefaults` rather than the DB-recorded voice for the book or track. |
| 5.9 Deterministic pronunciation fixes can be circular | Pending | Withhold deterministic IPA suggestions unless the proposed override differs from the current G2P output. |
| 5.18 Ignored issues can reappear on re-QA | Pending | Preserve ignored windows across `replaceOpen` by matching block/span/heard text. |
| 5.19 Accept-fix uses hidden blocks | Pending | The repair closures still load `EPubBlockDAO.blocks(for:chapterIndex:)` without filtering hidden/not-in-audio blocks. |
| 5.20 Accept-fix title clobbering | Pending | Pass planner numbering/title through repair renders or skip title overwrite when unavailable. |
| 5.24 Headless markers/export are not book-scoped | Pending | Namespace `.anchors-ch<N>.json` markers and audio scans by book token or reject mixed work dirs. |
| 5.35 Pronunciation dictionary persistence errors are swallowed | Pending | Surface persistence errors or roll back the in-memory row. |
| 5.36 Prepare UI reports stale model size | Pending | Format the real expected ONNX model size. |
| 7.1 ONNX arena/session lifecycle | Pending | Apply ORT arena shrinkage options and add an unload path after render runs. |
| 7.2 QA transcription loads whole chapters | Pending | Transcribe in bounded windows using the existing chunking/offset seams. |

## Ledger Cleanup

- `NARRATION_AUDIT.md` is a historical snapshot. Do not edit its findings in place to track remediation. Add or update dated map files like this one.
- `CODE_AUDIT_NARRATION.md` is a CoreML/FluidAudio-era audit and now has an archive notice. It references deleted engine files and local crash logs that are intentionally absent from git.
- `docs/superpowers/specs/2026-06-29-transcript-alignment-narration-qa-design.md` is a superseded draft. Use `docs/superpowers/specs/2026-06-29-transcript-narration-qa-design.md` for the locked program design.
- `docs/superpowers/plans/2026-06-29-transcript-qa-m3-narration-qa.md` is a completed implementation plan retained for evidence. Do not execute its unchecked checklist or destructive preflight commands.

## Artifact Policy

No generated narration media, ASR transcripts, alignment sidecars, flashcard exports, APKGs, or headless QA capture markers are tracked on this branch. `.gitignore` now covers common repo-local artifacts:

- audio already covered: `*.m4b`, `*.m4a`, `*.mp3`, `*.wav`, and related formats
- generated QA sidecars: `*.alignment.json`, `*.anchors-ch*.json`, `*.transcript.json`
- generated study exports: `*.echo-deck.json`, `echo-import.json`, `*.flashcards.json`, `*.apkg`

If a future regression needs fixtures in git, use public-domain or synthetic data and put it under an intentional fixture path such as `EchoTests/Fixtures`, with a short rights note in the test.
