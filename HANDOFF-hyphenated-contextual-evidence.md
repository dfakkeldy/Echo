# Handoff — hyphenated-contextual-evidence

## 2026-08-09 — fix + tests committed, PR opening, local test run gated to 22:00

Done: Root cause found — audit-pack entry for "re" mints a comparison seed for
the "re" token of "re-read" at the whole-compound span; first-wins dedup drops
the family "read" seed; evidence attaches to the "re" seed and phase-two
validation throws contextualEvidenceIdentityMismatch. Fix: family-first token
seed ordering in NarrationRenderPlan.swift (both normal and rescue paths).
Regression tests: re-read repro + well-read/pre-record/re-record class with a
rehashed audit-pack fixture. Committed 08f6a03e; parse-checked only.
Next: local `make test` via build slot at 22:00 window; watch PR CI.
Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hyphenated-contextual-evidence
branch fix/hyphenated-compound-contextual-evidence. Run
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests && \
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPlanTests
then full `make test` if green; fix failures; delete this file in the closing commit.
```

## 2026-08-09 — CI failure fixed: family promotion narrowed to evidenced spans

Done: First CI run on PR #530 failed one test —
NarrationServiceTests.plainURLMonitoredComponentDoesNotCreateContextualEvidenceIdentityMismatch.
Unconditional family-seed promotion let "content" inside a /wp-content/ URL
win its span with no evidence to attach → missingContextualEvidence
diagnostic. Fixed in ce4766c8: promote family seeds only at spans with
pending contextual evidence. Pushed; CI re-running.
Next: watch CI; local slot-gated run still queued for 22:00 (tests HEAD as of
run time). Resume: same as above.
