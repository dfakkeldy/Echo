---
name: new-schema-migration
description: Use when adding a new GRDB database migration to Echo — a new SQLite column, table, or index in Shared/Database. Triggers include "add a migration", "bump the schema", "new Schema_Vxx", "add a column to the database".
disable-model-invocation: true
---

# New Schema Migration (GRDB)

Scaffold the next GRDB migration for Echo's on-device SQLite database **without** the version-collision and forgotten-registration bugs that have bitten this project before. Echo uses a GRDB `DatabaseMigrator` (not SwiftData).

## Iron rules

- **Migrations are append-only and immutable once shipped.** Never edit an existing `Schema_Vxx` body or its `registerMigration` identifier — that diverges new installs from upgraded installs. A schema change is always a NEW version.
- **Every migration runs on a fresh install**, in registration order, inside `DatabaseService(inMemory:)` too — so the test suite is the regression guard.

## Steps

1. **Find the next free version.** Run:
   ```bash
   bash .claude/skills/new-schema-migration/scripts/check-schema-version.sh
   ```
   It prints the next free `V<N>` and flags any existing inconsistency. Use that N. (Re-run right before committing — a rebase may have taken N.)

2. **Create the enum** at `Shared/Database/Migrations/Schema_V<N>.swift`:
   ```swift
   import GRDB

   /// V<N> — <one-line purpose>
   enum Schema_V<N> {
       nonisolated static func migrate(_ db: Database) throws {
           // Adding a column: NOT NULL requires a default (SQLite can't add a
           // non-null column to an existing populated table without one).
           try db.alter(table: "bookmark") { t in
               t.add(column: "color_hex", .text)
           }
           // New table: mirror existing style — snake_case, explicit FKs, index hot paths.
           try db.create(index: "idx_bookmark_color", on: "bookmark", columns: ["color_hex"])
       }
   }
   ```

3. **Register it** in `Shared/Database/DatabaseService.swift` → `runMigrations(writer:)`, on a new line after the current last one, in ascending order:
   ```swift
   migrator.registerMigration("v<N>_<short_description>") { db in try Schema_V<N>.migrate(db) }
   ```

4. **Add the test** `EchoTests/SchemaV<N>Tests.swift` (Swift Testing), asserting the new tables/columns exist after all migrations run:
   ```swift
   import Testing
   import GRDB
   @testable import Echo

   @MainActor struct SchemaV<N>Tests {
       @Test func v<N>AddsColorColumn() throws {
           let db = try DatabaseService(inMemory: ())
           let names = Set(try db.read { db in
               try Row.fetchAll(db, sql: "PRAGMA table_info(bookmark)").map { $0["name"] as? String ?? "" }
           })
           #expect(names.contains("color_hex"))
       }
   }
   ```

5. **Update the record struct** in `Shared/Database/*Record.swift` (and its DAO/`Codable` mapping) for any new column, so reads/writes see it.

   If the migration also **backfills or rewrites existing rows** (not just DDL), expose that as a separate `static func` on the enum and unit-test it directly — see `Schema_V14.backfillEventIntegrity(_:)`, exercised by `SchemaV14Tests`. Keep `migrate(_:)` for schema shape, the helper for data.

6. **Run the focused test** (respect the 16 GB serial-build rule — never raw parallel `xcodebuild`):
   ```bash
   make build-tests && make test-only FILTER=EchoTests/SchemaV<N>Tests
   ```

## After scaffolding — answer this explicitly

If the new column/table is populated by the **EPUB importer or alignment pipeline** (anything `epub_*`, `chapter`, `alignment_anchor`, transcript/word tables), existing rows stay empty until the user **re-imports the book or re-runs auto-alignment**. State that clearly so it lands in the PR/changelog.

## Don't forget

CLAUDE.md requires documentation sync: a schema change is an architecture change. Update `ARCHITECTURE.md` (and `CHANGELOG.md`) — the `doc-sync` skill drafts the snippets.
