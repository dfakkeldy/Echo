# Task 6 report

Added source-bound two-chapter mixed-voice end-to-end acceptance. It verifies plan resolution, interrupted-run resume, one M4B with two embedded chapters, normal alignment sidecar, strict anchors and word timing, delivery/work filenames, and legacy uniform compatibility.

Evidence: focused runner suite passed 64 tests (66 device executions); controlled mutation replacing block mapping with chapter voice failed only the new acceptance; naming suite passed 17 tests after rejecting malformed stable cache names; final `make test` passed 3,623 tests (3,927 device executions, 3 skipped); `make echo-cli` passed; `git diff --check` passed.

Acceptance exposed a Task 4 parser regression: malformed `-s-` and repeated segment tokens were parsed as identity text. The stable-name regex now rejects those boundaries while preserving valid legacy and plan names.

Self-review: reused existing export and sidecar pathways; added no exporter, sidecar, or segment implementation. Concern: full suite is slow due serial catalog-media coverage, but completed without SIGKILL.
