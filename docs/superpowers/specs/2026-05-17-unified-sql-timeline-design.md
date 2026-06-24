# Unified SQL Timeline Design

**Date:** 2026-05-17
**Status:** Approved

## Overview

Replace all UserDefaults and JSON-file persistence with a single SQL database (GRDB.swift) in the App Group container. All five item types — Tracks, Chapters, Bookmarks, Flashcards, and Transcription Segments — live in normalized tables and are exposed through a unified `timeline` VIEW for filtering, sorting, and reordering.

## What Gets Stored

| Entity | Stored? | Reorderable? | Notes |
|--------|---------|-------------|-------|
| Tracks | Yes | Yes | `sort_order` is the default media position |
| Chapters | Yes | Yes | `start_seconds` pinned to media; reorder via `playlist_position` |
| Bookmarks | Yes | Yes | Voice memo paths, image paths, notes |
| Flashcards | Yes | Yes | SM-2 scheduling columns; `next_review_date` for "when due" |
| Transcription segments | Yes | No | Pinned to `start_time`; FTS5 full-text search |
| Transcription words | Yes | No | Per-word timestamps for precise search |
| Playback events | Yes | N/A | Real-world time log: "when did I listen?" |
| Settings | Yes | No | Key-value; replaces scattered UserDefaults |
| Playback state | Yes | No | Per-book last position, speed |

## Schema

```sql
-- Foundation
CREATE TABLE audiobook (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    author TEXT,
    duration REAL NOT NULL,
    file_count INTEGER,
    added_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Five item types
CREATE TABLE track (
    id TEXT PRIMARY KEY,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    duration REAL NOT NULL,
    file_path TEXT NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 0,
    playlist_position REAL
);

CREATE TABLE chapter (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    start_seconds REAL NOT NULL,
    end_seconds REAL NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL,
    playlist_position REAL
);

CREATE TABLE bookmark (
    id TEXT PRIMARY KEY,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    track_id TEXT REFERENCES track(id),
    title TEXT NOT NULL,
    media_timestamp REAL NOT NULL,
    note TEXT,
    voice_memo_path TEXT,
    image_path TEXT,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    playlist_position REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    modified_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE flashcard (
    id TEXT PRIMARY KEY,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    front_text TEXT NOT NULL,
    back_text TEXT NOT NULL,
    media_timestamp REAL NOT NULL,
    end_timestamp REAL,
    trigger_timing TEXT NOT NULL DEFAULT 'beginning',
    -- SM-2
    next_review_date TEXT,
    interval_days INTEGER NOT NULL DEFAULT 0,
    ease_factor REAL NOT NULL DEFAULT 2.5,
    repetitions INTEGER NOT NULL DEFAULT 0,
    last_reviewed_at TEXT,
    last_grade INTEGER,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    playlist_position REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    modified_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE transcription_segment (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    start_time REAL NOT NULL,
    end_time REAL NOT NULL,
    text TEXT NOT NULL
);

CREATE VIRTUAL TABLE transcription_fts USING fts5(
    text, content=transcription_segment, content_rowid=id
);

CREATE TABLE transcription_word (
    segment_id INTEGER NOT NULL REFERENCES transcription_segment(id) ON DELETE CASCADE,
    word TEXT NOT NULL,
    start_time REAL NOT NULL,
    end_time REAL NOT NULL,
    position INTEGER NOT NULL
);

-- Real-world time
CREATE TABLE playback_event (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE,
    track_id TEXT REFERENCES track(id),
    started_at TEXT NOT NULL,
    ended_at TEXT,
    start_position REAL NOT NULL,
    end_position REAL,
    speed REAL NOT NULL DEFAULT 1.0,
    event_type TEXT NOT NULL DEFAULT 'play',
    source TEXT
);

-- Supporting tables
CREATE TABLE playback_state (
    audiobook_id TEXT PRIMARY KEY REFERENCES audiobook(id) ON DELETE CASCADE,
    last_position REAL NOT NULL DEFAULT 0,
    speed REAL NOT NULL DEFAULT 1.0,
    last_played_at TEXT
);

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Unified timeline
CREATE VIEW timeline AS
SELECT id, audiobook_id, 'track' AS item_type, title, NULL AS subtitle,
       sort_order AS media_timestamp, is_enabled, playlist_position,
       NULL AS created_at, NULL AS modified_at
FROM track
UNION ALL
SELECT CAST(id AS TEXT), audiobook_id, 'chapter' AS item_type, title, NULL AS subtitle,
       start_seconds AS media_timestamp, is_enabled, playlist_position,
       NULL AS created_at, NULL AS modified_at
FROM chapter
UNION ALL
SELECT id, audiobook_id, 'bookmark' AS item_type, title, note AS subtitle,
       media_timestamp, is_enabled, playlist_position, created_at, modified_at
FROM bookmark
UNION ALL
SELECT id, audiobook_id, 'flashcard' AS item_type, front_text AS title, back_text AS subtitle,
       media_timestamp, is_enabled, playlist_position, created_at, modified_at
FROM flashcard
UNION ALL
SELECT CAST(id AS TEXT), audiobook_id, 'transcription' AS item_type, text AS title, NULL AS subtitle,
       start_time AS media_timestamp, 1 AS is_enabled, NULL AS playlist_position,
       NULL AS created_at, NULL AS modified_at
FROM transcription_segment;
```

## Architecture

```
SwiftUI Views
     │ @Environment(DatabaseService.self)
     ▼
DAO Layer (stateless, takes DatabaseWriter)
  AudiobookDAO  BookmarkDAO  FlashcardDAO
  TrackDAO      ChapterDAO   TranscriptionDAO
  TimelineDAO   PlaybackEventDAO
     │
     ▼
DatabaseService (owns DatabasePool, WAL mode)
     │
     ▼
orbit.sqlite in App Group container
```

- **DAOs are not `@Observable`** — ViewModels hold them and publish changes.
- **DAOs take `DatabaseWriter` protocol** — production uses `DatabasePool`, tests use in-memory `DatabaseQueue`.
- **`TimelineDAO` queries the unified VIEW** — one query returns all five types mixed, sorted by `playlist_position ?? media_timestamp`.

## Migration

1. On first launch after SQL update, check the legacy one-shot import flag
2. Read bookmarks from JSON sidecar files (primary) → UserDefaults blob (fallback)
3. Read per-book progress and speed from `Persistence`
4. Insert all into SQL tables
5. Mark the legacy one-shot import as complete
6. Keep UserDefaults data as read-only backup for one release cycle

Per-book migration — if one book fails, skip and continue. Never block on one corrupt record.

## Technology

**GRDB.swift** via SPM. Works on iOS, macOS, watchOS, and Widget extensions.

| Criteria | GRDB |
|----------|------|
| SQL access | Direct, full SQL |
| FTS5 | Built-in |
| Cross-target | Yes (SPM, all platforms) |
| Migration support | Explicit, reliable |
| WAL mode | Yes (concurrent reads) |

## Dependencies

- Blocked by: A1 (PlayerModel decomposition) — DAOs replace `BookmarkStore` and `Persistence`
- Blocks: M4B, DASH, CAR, ASRS, AIR, ADR, AWG, ADI — all feature plans use SQL persistence
