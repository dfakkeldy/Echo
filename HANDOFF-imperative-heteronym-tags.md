# HANDOFF — imperative-heteronym-tags

## 2026-08-22 — implementation pushed, PR open to nightly
Done: MisakiSwift `EnglishG2P.applyImperativeVerbTags` (sentence-initial gold heteronym + determiner/object-pronoun follower → `.verb` before lookup) + `Lexicon.hasPartOfSpeechVariants`; `ImperativeHeteronymTests` (MisakiSwift 46/46 green via `swift test`); `renderVersion` 23→24 (+ test pin, CHANGELOG). Probe: 12/12 intended pins flipped, 0 regressions, "Readable Record" 51-line corpus byte-identical. Exact-Penn-tag lookup fix deliberately excluded (Apple tagger emits no tense → cannot reach read/wound; only reachable effect stresses every demonstrative "that").
Next: local `make test` not yet run (Mac build window opens 22:00); confirm hosted CI on the PR, then merge to nightly. Follow-up finding: MisakiSwift never applies gold `None` (utterance-final strong-form) keys — port divergence, separate PR.
Resume:
```
git checkout claude/echo-narration-preprocessing-e017f8 && /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

## 2026-08-22 — CI round 1 failed on stale renderVersion pins; fixed and re-pushed
Done: first CI run failed ONLY in `NarrationFileNamingTests` (6 `-v23.m4a` name pins) + `NeuralG2PReceiptProvenanceTests:129` (`renderVersion == 23`); every other suite passed. All seven pins moved to v24 / previous=v23. Lesson: a renderVersion bump touches `NarrationFileNamingTests` (7 lines) AND `NeuralG2PReceiptProvenanceTests`, not just the one `== N` line.
Next: watch CI round 2 on PR #588; local `make test` still pending the 22:00 build window.
Resume:
```
gh pr checks 588 --repo dfakkeldy/Echo
```

## 2026-08-22 — CI round 2 green; PR #588 ready for review/merge
Done: hosted `Build gate + tests` passed on 14bef5d3 (EchoTests step success; macOS + echo-cli builds ran). Branch = origin/nightly + 2 commits.
Next: merge #588 into nightly (squash); delete this handoff in the closing PR if it survives the squash. Local `make test` never ran on the Mac (build window) — hosted CI is the gate of record for this PR.
Resume:
```
gh pr view 588 --repo dfakkeldy/Echo --json mergeable,reviewDecision,statusCheckRollup
```
