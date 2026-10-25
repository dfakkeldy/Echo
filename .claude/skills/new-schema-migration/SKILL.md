---
name: new-schema-migration
description: Use when adding a GRDB migration to Echo (a new SQLite column, table or index in Shared/Database), and before committing any change to Echo's database layer — Shared/Database/ migrations, records or DatabaseService. Triggers include "add a migration", "bump the schema", "new Schema_Vxx", "add a column to the database", "review this migration".
---

# Echo schema migrations (GRDB)

Echo's on-device SQLite database uses a GRDB `DatabaseMigrator`, not SwiftData. A bad migration corrupts real users' databases, and an app update can't undo it.

## Iron rules

- **Shipped migrations never change.** Never edit a shipped `Schema_Vxx` body, an inline registration body, or a `registerMigration` identifier. Installs that already ran it never see the edit, so new and upgraded installs diverge. A schema change is always a new version.
- **Append only.** A new migration takes the next free number and registers after the last one.
- **Fresh install is not upgrade.** `DatabaseService(inMemory:)` runs every migration on empty tables. A migration can pass there and still fail on a user's populated tables.

## How registration looks today

`DatabaseService.makeMigrator()` in `Shared/Database/DatabaseService.swift` is the registration list. It holds `v1_create_schema`, then `v24_…`, which merges the old V2–V23 identifiers (`Schema_V24.mergedMigrationIdentifiers`). V25–V41 call `Schema_Vxx` enums in `Shared/Database/Migrations/`. `v37_repair_…` deliberately reuses 37. V42 onward are small inline closures. `Schema_V2…V23` files still exist but are folded into V1 and V24; they are not unregistered migrations.

## The check tool

```bash
python3 .claude/skills/new-schema-migration/scripts/check-migrations.py
```

It compares your working tree (branch commits plus uncommitted edits) with the merge-base on `origin/nightly`, and checks `origin/nightly` for numbers that landed since you branched. It prints the next free version and exits 1 on any 🔴:

- duplicate identifier; a shipped registration removed, renamed, reordered or edited; a shipped `Schema_Vxx` file edited
- a new number that is already taken here or on `origin/nightly`, or new numbers out of order
- a `Schema_Vxx` enum that is never registered, or a registration that calls a missing enum
- a column added `NOT NULL` with no default; a `.references` to a table no migration creates

It also prints 🟡 for a new migration with no test and for drop/rename DDL, and ⚠ for a new column on a table the importer or aligner fills. Its 🔴 findings are facts, not opinions. Fix them, or, for a deliberate baseline squash or repair, get Dan's explicit approval and say so in the PR.

## Adding a migration

1. **Run the tool** to get the next free `V<N>`. Run it again right before committing, because a rebase may have taken N.
2. **Write the migration.** For a small change, use an inline closure like v42–v44. For anything with logic or a backfill, use an enum at `Shared/Database/Migrations/Schema_V<N>.swift`:
   ```swift
   import GRDB

   /// V<N> — <one-line purpose>
   enum Schema_V<N> {
       nonisolated static func migrate(_ db: Database) throws {
           // NOT NULL needs a default: SQLite rejects it on a table that has rows.
           try db.alter(table: "bookmark") { t in
               t.add(column: "color_hex", .text)
           }
           try db.create(index: "idx_bookmark_color", on: "bookmark", columns: ["color_hex"])
       }
   }
   ```
   Put a backfill in its own `static func` on the enum and test it directly (see `Schema_V14.backfillEventIntegrity(_:)` and `SchemaV14Tests`).
3. **Register it** at the end of `makeMigrator()`:
   ```swift
   migrator.registerMigration("v<N>_<short_description>") { db in try Schema_V<N>.migrate(db) }
   ```
4. **Update the record** in `Shared/Database/*Record.swift`: the property, its `CodingKeys` entry, any custom `init`, and the domain model mapping (`init(from:)`/`toModel()`) when one exists. A non-optional property needs a default value, or every memberwise call breaks.
5. **Add `EchoTests/SchemaV<N>Tests.swift`** (Swift Testing). Assert the new tables or columns exist after `DatabaseService(inMemory: ())`. When the migration alters a table users already have rows in, also test the upgrade path: migrate to the previous identifier with `DatabaseService.makeMigrator().migrate(writer, upTo: "v<N-1>_…")`, insert a row, migrate fully, and read the row back.
6. **Run the focused test** (16 GB machine, serial builds only):
   ```bash
   make build-tests && make test-only FILTER=EchoTests/SchemaV<N>Tests
   ```

## Before committing any database change

Run the tool first, then review what it can't judge. Read the whole diff under `Shared/Database/`, `EchoTests/Schema*` and every caller of a changed record.

1. **Tool output.** Every 🔴 is a blocker.
2. **DDL safety.** Dropping or renaming a column or table, changing `onDelete`, or adding a constraint to an existing table is high risk. `PRAGMA foreign_keys=ON` is set, so a new `.references(...)` must point at an existing table and column.
3. **Indexes.** A new column used in a hot query needs an index named `idx_<table>_<cols>`.
4. **Record drift.** Every new column has a record property and `CodingKeys` entry, every initializer and memberwise call still compiles, and domain-model round trips keep the value.
5. **Tests.** The test asserts the new shape, and covers the upgrade path when the table has user rows. A fresh in-memory test alone cannot catch upgrade failures.
6. **Re-import or re-align.** If the importer, transcription or aligner fills the new column (`epub_block`, `epub_toc_entry`, `chapter`, `alignment_anchor`, `transcription_segment`, `word_timing`, `pdf_block_page`, `timeline_item`), existing books keep NULL until re-imported or re-aligned.

Report it like this:

- One line: **APPROVE**, **APPROVE WITH NITS** or **REQUEST CHANGES**.
- A table: `Severity | file:line | Issue | Fix`, with 🔴 blocker, 🟡 should-fix, 🔵 nit.
- **Re-import / re-align needed?** yes or no, and why.
- **Next free version is** V<N>, from the tool.

Don't run `make test` or `xcodebuild` just to review; reading the diff and the tool output is enough.

## Don't forget

A schema change is an architecture change. Update `ARCHITECTURE.md` and `CHANGELOG.md`; the `doc-sync` skill drafts the text.
