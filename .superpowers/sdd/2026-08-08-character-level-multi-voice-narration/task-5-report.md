# Task 5 Report — Plan-Aware Pronunciation Audit

## Evidence

- RED: `XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests` failed as expected because `PronunciationBlockVoiceProvenance`, the manifest fields, and the forwarding API did not exist.
- Implemented schema-7 plan provenance, schema-6 legacy preservation, validation, reel-request forwarding, and resolved-plan runner wiring.
- Systematic debugging: `make clean` is not a repository target. An authorized `xcodebuild clean` succeeded, then the clean `make build-tests` exposed three missing `try` markers on throwing `#require` calls in the new audit tests. After restoring them, the complete captured fresh build reported `** TEST BUILD SUCCEEDED **`.
- Focused audit verification after the clean build: `PronunciationAuditTests` — 29 passed, 0 failed, 29 total.
- First focused runner verification: 62 passed, 1 failed, 63 total. The only failure was the pre-existing `multiPagePDFBatchesByPageChaptersAndResumes()` PDF-resume test, reported solely as `Test crashed with signal kill.` with no assertion, activity, or crash backtrace. The new Task 5 runner test, `planRunSuppliesEveryResolvedBlockVoiceToTheAuditRequest()`, passed.
- Authorized full runner rerun: `HeadlessNarrationRunnerTests` — 63 passed, 0 failed, 63 total.

## Self-review

- Legacy callers retain their original `PronunciationAuditManifest.make` symbol through a compatibility overload.
- Schema 7 carries plan hash plus block-to-voice IDs only; speaker IDs remain excluded.
- Plan manifests require empty chapter provenance and decision block coverage.

## Concerns

- The isolated initial PDF-test SIGKILL did not reproduce on the immediate full-suite rerun. No product behavior was changed to mask it.

## Fix Round 1 — Review Findings

- RED (portable-ID boundary): the focused audit suite reported 28 passed, 1 failed, because schema 7 decoded `s١-b٢`; the test expected decoding to reject that Unicode-numeric key.
- GREEN (portable-ID boundary): portable block-ID validation now accepts only ASCII scalar digits `0x30...0x39`, matching `^s[0-9]+-b[0-9]+$`.
- RED (authoritative provenance): the new decoded-artifact test failed the test build with the expected missing `expectedBlockVoiceProvenance` artifact-validation argument.
- GREEN (authoritative provenance): schema-7 final artifact validation now requires the runner's authoritative resolved provenance and compares both the exact plan SHA-256 and the exact complete block-to-voice map. Legacy schema-6 calls retain the existing two-URL validator path.
- The listening-reel generator forwards the runner-supplied provenance to both audit-only and reel-bearing final artifact validation paths; no reel timing or media assembly changed.
- Fresh captured test build: `** TEST BUILD SUCCEEDED **`.
- Focused audit verification: `PronunciationAuditTests` — 30 passed, 0 failed, 30 total.
- Focused runner verification: `HeadlessNarrationRunnerTests` — 63 passed, 0 failed, 63 total.

## Commit

- `531e7a9b feat(narration): audit block voice provenance`
- This follow-up test/report commit records the completed clean-build diagnosis and verification evidence.
- The next follow-up commit records Fix Round 1 review remediation and its RED/GREEN evidence.
