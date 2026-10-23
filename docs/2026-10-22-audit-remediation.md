# October 22 audit remediation

This records the implementation against the 30 active findings. The original
audit remains a historical source snapshot. There is no database migration,
dependency addition, book re-import requirement or renderer installation.

| Findings | Change | Verification |
| --- | --- | --- |
| 2.1, 3.4, 4.2 | Remove redundant constructs, use stable weak test holders and modern trait overrides | Hosted compiler diagnostics and existing tests |
| 2.4 | Replace mutable audit-section references with durable PR references | Source review |
| 3.1, 5.5, 5.6 | Discover/read metadata/process covers off-main; sum every track; batch scan writes; reconcile absence only after complete discovery | Synthetic multitrack, incomplete and cancelled scans; existing LibraryService tests |
| 3.5, 5.9 | Forward cancellation to the silence worker and use energy from every channel | Synthetic stereo fixture and cancellation checks |
| 3.6, 7.4 | Guard each alignment run and its commit with cancellation; index block positions and prepare matches/recalculate off-main | Source review, existing alignment tests and platform build gate |
| 5.4, 7.1 | One reload revision across sync, async and debounced search; search leaves playback caches intact; small note/memo edits patch caches | Search superseding a book-open load; existing reader capture/scope tests |
| 5.7, 7.10 | Publish one current-book Mac snapshot; cache chapter groups/positions and skip unchanged clock samples | Shared snapshot/index tests, Mac compilation and source review |
| 5.8, 7.11 | Restore SQL bookmarks on every switch; retain legacy recovery; preserve parent/file ID collisions; coalesce ordered async writes; keep incoming staging until SQL commit | SQL reopen, A/B Library switches, Widget merges, legacy keys/collisions and rollback tests |
| 5.10, 7.7 | Hide unavailable eligibility, restrict text lookup to visible IDs and recheck all existing text before merge | Hidden-text rejection and read-along tests |
| 7.2 | Cache applied section order/lookup and publish headings only on section changes; wait through snapshot transitions | Existing reader follow/accessibility tests and source review |
| 7.3 | Assemble shelf books, requested siblings, folded statuses and eligibility off-main once per revision | Updated async LibraryViewModel tests and existing LibraryService tests |
| 7.5 | Build chapter/segment timeline buckets preserving original overlap order and front-matter policy | Indexed versus array lookup comparisons |
| 7.6 | One grouped chapter-count read and one manifest decode per off-state refresh | Existing OffStateResolver and reader feed tests |
| 7.8 | Cache source cards by block, observing database edits; keep beginning/end triggers and suppression state | Existing source-anchored trigger tests |
| 7.9 | Decode capped ImageIO thumbnails off-main with a bounded cache, no failed-result cache and reused-cell identity checks | Thumbnail size/failure-retry test and source review |
| 7.12, 7.13 | Accumulate reportable indices while tokenizing; use ordered neighbor/range lookups; cache compiled expressions under a mutex | Existing exact QA/normalization tests and concurrent normalization regression |
| 7.14 | Index direct audio files by parent and group members by group ID; compute regroup updates off-main and write only the guarded group column; preserve established families when an edition is unavailable | Deterministic EditionMatcher, missing-edition history and async shelf regroup tests |
| 8.4 | Return save outcomes, retain failed note drafts and memo files, and offer a retry | Failed-save regression and reader capture tests |
| 9.1 | Separate book-state restoration from picker permission persistence and share immutable reader playback snapshots | Book-switch regressions, shared snapshot/index tests and cross-platform review |

Local documentation contracts passed. The local Apple scheduler deferred the
native baseline with exit 75; native compilation, app tests and Apple/CLI target
verification run in the PR's required hosted gate. Source changes and synthetic
tests do not establish a measured device performance improvement.
