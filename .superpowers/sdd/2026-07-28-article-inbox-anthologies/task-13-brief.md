# Task 13 — Stable generated block identity and reconcile import

## Frozen base

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Branch: `codex/article-anthology-design`
- Base: `8fed45ee5343565d3bd4060c6808bee601d1bd62`
- Plan: `docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`, Task 13

Task 12 is complete and reviewed. Task 11’s article-image asset mapping remains dependency-gated; use text/cover fixtures and keep the image gate pending.

## Scope

Implement the exact Task 13 migration/parser/import/reconciler files:

- create `Shared/Database/Migrations/Schema_V38.swift`
- modify `Shared/Database/DatabaseService.swift`
- modify `Shared/Database/EPubBlockRecord.swift`
- modify `Shared/EPUBXMLParsing.swift`
- modify `Shared/EPUBBlockParser.swift`
- modify `EchoCore/Services/EPUBImportService.swift`
- create `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportIdentity.swift`
- create `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportReconciler.swift`
- modify `EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift`
- create `EchoTests/ArticleWorkshop/SchemaV38GeneratedChapterKeyTests.swift`
- create `EchoTests/ArticleWorkshop/GeneratedAnthologyImportTests.swift`

Small demonstrated test-helper/DAO changes are allowed. Do not touch protected narration/project/ARCHITECTURE files, sibling worktree, CloudKit, M4B, or physical devices.

## Core security boundary

Generic/external EPUBs remain `replaceAll` and order-based. Only `AnthologyBuildService`, holding the trusted in-memory frozen `AnthologyBuildManifest` and verified Task 11 receipt, may request `reconcileGenerated`.

Do not trust `data-echo-*` attributes from an external archive by themselves.

Validate before assigning stable IDs:

- exact package identifier and expected internal manifest SHA-256;
- chapter href is a unique member of the trusted manifest map;
- unique nonnegative stable slot and exact expected slot for href;
- unique block index;
- reserved indices exactly 0, 1, 2, 900000;
- body range exactly `1000 + stableOrdinal` and no collision/reserved overflow;
- expected block kind/text/caption/code-language/source-boundary semantics;
- every expected generated block appears exactly once and no unknown stable block is accepted.

Stable block ID:

`epub-<audiobookID>-s<stableSlot>-b<stableBlockIndex>`

Persist optional `sourceChapterKey` without changing generic import identity.

## Migration

Add V38 `source_chapter_key TEXT` to `epub_block`, register migration after V37, update record coding/columns, and preserve downgrade-free additive behavior. Test a real V37→V38 upgrade with existing rows/user fields intact and fresh-schema parity. Do not rewrite or renumber existing generic block IDs.

## Reconcile contract

Add:

```swift
enum EPUBBlockPersistencePolicy: Sendable {
    case replaceAll
    case reconcileGenerated
}
```

For `reconcileGenerated`, perform one database transaction:

1. validate the complete incoming stable-ID set before mutation;
2. fetch existing blocks by ID;
3. when kind/text/source identity are unchanged, preserve user-owned note/bookmark/card-color/hidden/visual fields and existing synthesized data;
4. upsert incoming ordering/location fields;
5. for changed text/kind, preserve only explicitly user-owned fields allowed by the existing model and clear that block’s derived narration/alignment/timing/timeline rows;
6. delete obsolete generated blocks only after successful upserts, allowing cascades only for their derived rows;
7. replace TOC consistently;
8. rollback every mutation on any validation/DB failure.

Prove removed blocks cannot delete another book’s/user’s data and duplicate/forged IDs fail before mutation.

Task 12 rollback must re-import the prior edition using its prior trusted manifest/identity so exact prior generated rows are restored. A candidate failure must not reconcile the prior library to candidate identity.

## Required TDD

First prove RED on current order-based ID/replace-all behavior.

Seed A/B with notes, bookmarks, card color, hidden state, synthesized anchors, word timing, and relevant derived timeline rows. Rebuild B/A and assert:

- block IDs unchanged;
- spine/sequence/chapter indices reflect B/A;
- user annotations stay attached;
- unchanged generated/synthesized data survives;
- changed text clears only its derived data;
- removed block cascades only its derived rows;
- new block receives stable ID;
- rollback after failed Task 12 rebuild restores exact prior stable rows/data.

Also prove:

- generic EPUB IDs/replace-all behavior unchanged;
- external forged `data-echo-*` cannot opt into stable IDs;
- wrong manifest digest/identifier/href/slot/index/kind/text/duplicate/missing block fails closed before mutation;
- V38 upgrade/fresh schema;
- transaction rollback on injected failures;
- two anthology/audiobook identities cannot collide.

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/SchemaV38GeneratedChapterKeyTests
make test-only FILTER=EchoTests/GeneratedAnthologyImportTests
make test-only FILTER=EchoTests/EPUBBlockParserTests
make test-only FILTER=EchoTests/EPUBImportServiceTests
```

Also run Task 11 builder/preflight, Task 12 service/integration, affected DAO/migration/import regressions, format/diff/privacy/protected-file checks. Treat simulator bootstrap kills as unavailable.

## Review and commit

Self-review, commit coherent work, then separate read-only specification and adversarial implementation reviews against exact SHA. Same implementer fixes confirmed findings, maximum five rounds.

Report:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-13-report.md`

Commit subject:

`feat: preserve anthology block identity`

Return exact SHA, clean state, migration receipts, stable-identity/reconcile/failure counts, generic importer regressions, review verdicts, VERIFY items, and pending proof gates.
