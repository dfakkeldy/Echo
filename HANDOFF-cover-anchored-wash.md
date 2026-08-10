# Handoff — cover-anchored wash + edge continuation

## 2026-08-10 — implementation + headless verification done

Done: Anchored background wash (wash follows cover tone clamped into per-scheme
bands; dark deepen-only ceiling 0.34), edge-continuation (robust OKLab border
consensus reproduces the cover's exact border color, the "Traction effect"),
B/W-dominant pole anchoring, `enforced()` now walks both lightness directions.
New tests in CoverThemeBuilderTests + DominantColorExtractorTests. Headless
probe of real sources: 360-hue + cover-tone sweeps clear all contrast floors;
real-cover harness confirms all 4 screenshot books (Traction light = exact
#ABDAF4 edge continuation). Contact sheet sent to Dan.

## 2026-08-10 — sim tests green, publishing

Done: `make build-tests` succeeded; CoverThemeBuilderTests (28) +
DominantColorExtractorTests (12) passed, 0 failures. Parity review clean
(watch/widget get new tones via phone-resolved hexes; macOS/echo-cli
exclusions predate this change; CoverSignature never serialized).

Next: push branch, open PR `--base nightly`, report CI.

Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71
# branch claude/cover-color-scheme-ideas-0703fa — push + gh pr create --base nightly
```
