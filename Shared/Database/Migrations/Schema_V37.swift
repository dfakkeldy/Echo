// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V37 — Article Workshop captures, editable revisions, anthology projects,
/// ordered entries, and build receipts.
enum Schema_V37 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "article_capture") { t in
            t.column("id", .text).primaryKey()
            t.column("source_url", .text).notNull()
            t.column("canonical_url", .text)
            t.column("title", .text).notNull()
            t.column("author", .text)
            t.column("site_name", .text)
            t.column("language", .text)
            t.column("published_at", .text)
            t.column("captured_at", .text).notNull()
            t.column("capture_method", .text).notNull()
            t.column("package_path", .text).notNull()
            t.column("content_sha256", .text).notNull()
            t.column("extractor_version", .text).notNull()
            t.column("content_state", .text).notNull()
            t.column("warnings_json", .text).notNull().defaults(to: "[]")
            t.column("current_revision_id", .text)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(table: "article_revision") { t in
            t.column("id", .text).primaryKey()
            t.column("capture_id", .text).notNull()
                .references("article_capture", onDelete: .cascade)
            t.column("parent_revision_id", .text)
            t.column("metadata_overrides_json", .text).notNull()
            t.column("recipe_json", .text).notNull()
            t.column("readable_content_sha256", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("device_name", .text)
        }

        try db.create(table: "anthology") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("subtitle", .text)
            t.column("creator", .text)
            t.column("cover_path", .text)
            t.column("next_stable_slot", .integer).notNull().defaults(to: 0)
            t.column("latest_build_revision", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(table: "anthology_entry") { t in
            t.column("id", .text).primaryKey()
            t.column("anthology_id", .text).notNull()
                .references("anthology", onDelete: .cascade)
            t.column("capture_id", .text).notNull()
                .references("article_capture", onDelete: .restrict)
            t.column("sort_order", .integer).notNull()
            t.column("stable_slot", .integer).notNull()
            t.column("chapter_title_override", .text)
            t.column("narration_voice_id", .text)
            t.uniqueKey(["anthology_id", "capture_id"])
            t.uniqueKey(["anthology_id", "stable_slot"])
        }

        try db.create(table: "anthology_build") { t in
            t.column("id", .text).primaryKey()
            t.column("anthology_id", .text).notNull()
                .references("anthology", onDelete: .cascade)
            t.column("revision", .integer).notNull()
            t.column("epub_identifier", .text).notNull()
            t.column("manifest_json", .text).notNull()
            t.column("manifest_sha256", .text).notNull()
            t.column("epub_path", .text)
            t.column("epub_sha256", .text)
            t.column("audiobook_id", .text)
            t.column("status", .text).notNull()
            t.column("error_code", .text)
            t.column("created_at", .text).notNull()
            t.uniqueKey(["anthology_id", "revision"])
        }

        try db.create(
            index: "idx_article_capture_captured_at",
            on: "article_capture",
            columns: ["captured_at"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_article_capture_canonical_url",
            on: "article_capture",
            columns: ["canonical_url"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_article_revision_parent_revision_id",
            on: "article_revision",
            columns: ["parent_revision_id"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_anthology_entry_order",
            on: "anthology_entry",
            columns: ["anthology_id", "sort_order"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_anthology_build_revision",
            on: "anthology_build",
            columns: ["anthology_id", "revision"],
            ifNotExists: true
        )
    }
}
