// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V24 compatibility migration for databases created before the V1 baseline squash.
///
/// V2…V23 remain merged into this identifier so GRDB can expose the identifiers
/// already present on an old installation and run only the missing historical
/// steps. A database created from the squashed V1 already has the complete V24
/// shape, so it is stamped as V24 without replaying additive DDL against itself.
enum Schema_V24 {
    nonisolated static let mergedMigrationIdentifiers: Set<String> = [
        "v2_timeline_support",
        "v3_missing_indexes",
        "v4_materialized_timeline",
        "v5_epub_alignment",
        "v6_indexes_and_fixes",
        "v7_epub_reader_columns",
        "v8_epub_block_word_count",
        "v9_epub_block_markers",
        "v10_epub_block_chapter_theme",
        "v11_bookmark_pdf_state",
        "v12_epub_block_front_matter",
        "v13_epub_toc_entries",
        "v14_capture_and_context",
        "v15_anki_decks",
        "v16_fsrs_cloze_transcript",
        "v17_track_narration_voice",
        "v18_abs_server",
        "v19_word_timing",
        "v20_batch_queue",
        "v21_batch_kind",
        "v22_fsrs_seed",
        "v23_audiobook_abs_provenance",
    ]

    nonisolated static func migrate(
        _ db: Database,
        appliedIdentifiers: Set<String>
    ) throws {
        if try hasCompleteSquashedBaseline(db) {
            return
        }

        if !appliedIdentifiers.contains("v2_timeline_support") {
            try Schema_V2.migrate(db)
        }
        if !appliedIdentifiers.contains("v3_missing_indexes") {
            try Schema_V3.migrate(db)
        }
        if !appliedIdentifiers.contains("v4_materialized_timeline") {
            try Schema_V4.migrate(db)
        }
        if !appliedIdentifiers.contains("v5_epub_alignment") {
            try Schema_V5.migrate(db)
        }
        if !appliedIdentifiers.contains("v6_indexes_and_fixes") {
            try Schema_V6.migrate(db)
        }
        if !appliedIdentifiers.contains("v7_epub_reader_columns") {
            try Schema_V7.migrate(db)
        }
        if !appliedIdentifiers.contains("v8_epub_block_word_count") {
            try Schema_V8.migrate(db)
        }
        if !appliedIdentifiers.contains("v9_epub_block_markers") {
            try Schema_V9.migrate(db)
        }
        if !appliedIdentifiers.contains("v10_epub_block_chapter_theme") {
            try Schema_V10.migrate(db)
        }
        if !appliedIdentifiers.contains("v11_bookmark_pdf_state") {
            try Schema_V11.migrate(db)
        }
        if !appliedIdentifiers.contains("v12_epub_block_front_matter") {
            try Schema_V12.migrate(db)
        }
        if !appliedIdentifiers.contains("v13_epub_toc_entries") {
            try Schema_V13.migrate(db)
        }
        if !appliedIdentifiers.contains("v14_capture_and_context") {
            try Schema_V14.migrate(db)
        }
        if !appliedIdentifiers.contains("v15_anki_decks") {
            try Schema_V15.migrate(db)
        }
        if !appliedIdentifiers.contains("v16_fsrs_cloze_transcript") {
            try Schema_V16.migrate(db)
        }
        if !appliedIdentifiers.contains("v17_track_narration_voice") {
            try Schema_V17.migrate(db)
        }
        if !appliedIdentifiers.contains("v18_abs_server") {
            try Schema_V18.migrate(db)
        }
        if !appliedIdentifiers.contains("v19_word_timing") {
            try Schema_V19.migrate(db)
        }
        if !appliedIdentifiers.contains("v20_batch_queue") {
            try Schema_V20.migrate(db)
        }
        if !appliedIdentifiers.contains("v21_batch_kind") {
            try Schema_V21.migrate(db)
        }
        if !appliedIdentifiers.contains("v22_fsrs_seed") {
            try Schema_V22.migrate(db)
        }
        if !appliedIdentifiers.contains("v23_audiobook_abs_provenance") {
            try Schema_V23.migrate(db)
        }

        // V41 carries the same V24 DDL with existence guards. Reusing it keeps
        // upgrades safe for databases that already received the emergency V41
        // repair before this historical chain was restored.
        try Schema_V41.migrate(db)
    }

    /// A fresh database created by the squashed Schema_V1 has no V2…V23
    /// migration rows, but it already contains their schema. These structural
    /// sentinels cover every historical step that added a table or column.
    private nonisolated static func hasCompleteSquashedBaseline(_ db: Database) throws -> Bool {
        let requiredColumns: [String: Set<String>] = [
            "audiobook": ["source_type", "server_id", "remote_item_id", "topics_json"],
            "track": ["narration_voice"],
            "bookmark": ["pdf_view_state_json", "latitude", "longitude", "place_name"],
            "flashcard": [
                "deck_id", "tags", "media_json", "source_block_id", "stability", "difficulty",
                "card_type", "cloze_index",
            ],
            "transcription_word": ["id"],
            "note": ["is_global", "voice_memo_path", "epub_block_id"],
            "timeline_item": [
                "epub_block_id", "timestamp_source", "alignment_status", "alignment_confidence",
                "pdf_view_state_json",
            ],
            "epub_block": [
                "html_content", "card_color", "word_count", "markers", "text_formats",
                "chapter_theme_color", "is_front_matter",
            ],
            "deck": ["anki_deck_id"],
            "batch_queue": ["kind"],
            "voice_memo": ["epub_block_id", "media_timestamp", "file_path"],
        ]

        for (table, columns) in requiredColumns {
            guard try db.tableExists(table) else { return false }
            let actualColumns = Set(try db.columns(in: table).map(\.name))
            guard actualColumns.isSuperset(of: columns) else { return false }
        }

        let requiredTables = [
            "planned_session",
            "real_time_event",
            "alignment_anchor",
            "epub_toc_entry",
            "session_location",
            "marked_passage",
            "standalone_transcript",
            "abs_server",
            "word_timing",
        ]
        for table in requiredTables {
            guard try db.tableExists(table) else { return false }
        }

        return true
    }
}
