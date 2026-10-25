#!/usr/bin/env python3
"""Tests for check-migrations.py against a throwaway git repo.

Run: python3 .claude/skills/new-schema-migration/scripts/test_check_migrations.py
"""
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

TOOL = pathlib.Path(__file__).with_name("check-migrations.py")

SERVICE = '''\
import GRDB

final class DatabaseService {
    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v2_notes") { db in
            try Schema_V2.migrate(db)
        }
        migrator.registerMigration("v2_repair_notes") { db in
            try Schema_V2.repair(db)
        }
        // Inline, no enum.
        migrator.registerMigration("v3_bookmark_index") { db in
            try db.create(index: "idx_bookmark_book", on: "bookmark", columns: ["book_id"])
        }
@@NEW@@        return migrator
    }
}
'''

SCHEMA_V1 = '''\
import GRDB
enum Schema_V1 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "bookmark") { t in
            t.column("id", .text).primaryKey()
            t.column("book_id", .text)
        }
        try db.create(table: "epub_block") { t in
            t.column("id", .text).primaryKey()
        }
    }
}
'''

SCHEMA_V2 = '''\
import GRDB
enum Schema_V2 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "note") { t in
            t.column("id", .text).primaryKey()
        }
    }
    nonisolated static func repair(_ db: Database) throws {}
}
'''


def inline(ident, body):
    return (f'        migrator.registerMigration("{ident}") {{ db in\n'
            f"{textwrap.indent(body, '            ')}\n"
            "        }\n")


ADD_COLOR = 'try db.alter(table: "bookmark") { t in\n    t.add(column: "color_hex", .text)\n}'


class CheckMigrationsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.run_git("init", "-q", "-b", "nightly")
        self.run_git("config", "user.email", "test@example.com")
        self.run_git("config", "user.name", "test")
        self.write("Shared/Database/DatabaseService.swift", SERVICE.replace("@@NEW@@", ""))
        self.write("Shared/Database/Schema_V1.swift", SCHEMA_V1)
        self.write("Shared/Database/Migrations/Schema_V2.swift", SCHEMA_V2)
        self.write("EchoTests/Placeholder.swift", "// tests\n")
        self.run_git("add", "-A")
        self.run_git("commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def run_git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def add_registration(self, block):
        self.write("Shared/Database/DatabaseService.swift", SERVICE.replace("@@NEW@@", block))

    def add_test(self, num):
        self.write(f"EchoTests/SchemaV{num}Tests.swift", f"struct SchemaV{num}Tests {{}}\n")

    def check(self):
        result = subprocess.run([sys.executable, str(TOOL), "--repo", str(self.root)],
                                capture_output=True, text=True)
        return result.returncode, result.stdout

    def test_clean_tree_passes(self):
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("Next free version: V4", out)
        self.assertNotIn("🔴", out)

    def test_new_migration_with_test_passes(self):
        self.add_registration(inline("v4_bookmark_color", ADD_COLOR))
        self.add_test(4)
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertNotIn("🔴", out)
        self.assertNotIn("🟡", out)
        self.assertIn("Next free version: V5", out)

    def test_reused_number_is_blocked(self):
        self.add_registration(inline("v3_bookmark_color", ADD_COLOR))
        self.add_test(3)
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn('"v3_bookmark_color" reuses V3', out)

    def test_number_taken_on_integration_branch_is_blocked(self):
        self.run_git("branch", "feature/color")
        self.add_registration(inline(
            "v4_note_title", 'try db.alter(table: "note") { t in\n    t.add(column: "title", .text)\n}'))
        self.add_test(4)
        self.run_git("add", "-A")
        self.run_git("commit", "-qm", "v4 lands on nightly")
        self.run_git("checkout", "-q", "feature/color")
        self.add_registration(inline("v4_bookmark_color", ADD_COLOR))
        self.add_test(4)
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("v4_note_title (on nightly)", out)
        self.assertIn("Next free version: V5", out)

    def test_unregistered_enum_is_blocked(self):
        self.write("Shared/Database/Migrations/Schema_V4.swift",
                   "import GRDB\nenum Schema_V4 {\n    nonisolated static func migrate(_ db: Database) throws {}\n}\n")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("Schema_V4", out)
        self.assertIn("never registered", out)

    def test_edited_shipped_enum_is_blocked(self):
        self.write("Shared/Database/Migrations/Schema_V2.swift",
                   SCHEMA_V2.replace('t.column("id", .text).primaryKey()',
                                     't.column("id", .text).primaryKey()\n            t.column("title", .text)'))
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("shipped Schema_V2 was edited", out)

    def test_comment_only_edit_to_shipped_enum_passes(self):
        self.write("Shared/Database/Migrations/Schema_V2.swift", "// Notes table.\n" + SCHEMA_V2)
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_edited_inline_body_is_blocked(self):
        edited = SERVICE.replace('columns: ["book_id"]', 'columns: ["book_id", "id"]').replace("@@NEW@@", "")
        self.write("Shared/Database/DatabaseService.swift", edited)
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn('shipped migration "v3_bookmark_index" was edited', out)

    def test_removed_registration_is_blocked(self):
        self.write("Shared/Database/DatabaseService.swift",
                   SERVICE.replace("@@NEW@@", "").replace(
                       '        migrator.registerMigration("v2_repair_notes") { db in\n'
                       "            try Schema_V2.repair(db)\n        }\n", ""))
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn('"v2_repair_notes" was removed or renamed', out)

    def test_not_null_without_default_is_blocked(self):
        self.add_registration(inline(
            "v4_bookmark_favorite",
            'try db.alter(table: "bookmark") { t in\n    t.add(column: "is_favorite", .boolean).notNull()\n}'))
        self.add_test(4)
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("bookmark.is_favorite is added NOT NULL with no default", out)

    def test_not_null_with_default_passes(self):
        self.add_registration(inline(
            "v4_bookmark_favorite",
            'try db.alter(table: "bookmark") { t in\n'
            '    t.add(column: "is_favorite", .boolean).notNull().defaults(to: false)\n}'))
        self.add_test(4)
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_missing_test_and_import_table_are_reported_without_failing(self):
        self.add_registration(inline(
            "v4_epub_block_level",
            'try db.alter(table: "epub_block") { t in\n    t.add(column: "reading_level", .integer)\n}'))
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn('🟡 "v4_epub_block_level" has no test', out)
        self.assertIn("new column on epub_block", out)

    def test_unknown_reference_is_blocked(self):
        self.add_registration(inline(
            "v4_bookmark_deck",
            'try db.alter(table: "bookmark") { t in\n'
            '    t.add(column: "deck_id", .text).references("deck", onDelete: .cascade)\n}'))
        self.add_test(4)
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn('.references("deck")', out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
