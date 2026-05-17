# Plan: Bookmark List — Group by Track (Playlist Scope)

## Summary

Replace the current track-scoped bookmark filter with a folder-wide list grouped by track, so users can see all bookmarks in a playlist with section headers showing which file each group belongs to.

## Current State

In `PlaylistView.swift:102-107`, the bookmarks tab filters to show only bookmarks for the currently playing track:

```swift
let sortedBookmarks: [Bookmark] = {
    let trackId = model.tracks.indices.contains(model.currentIndex) ? model.tracks[model.currentIndex].id : nil
    return model.bookmarks
        .filter { $0.trackId == nil || $0.trackId == trackId }
        .sorted { $0.timestamp < $1.timestamp }
}()
```

This means if a user has bookmarks across 3 tracks in the same folder, they can only see the ones for the currently playing track. The other bookmarks are invisible until the user navigates to those tracks.

The `Bookmark` model already stores `trackId` (the URL string of the audio file) and `folderKey` (the folder URL string). No schema changes are needed.

## Proposed Design

1. **Remove the track-scoped filter.** Show all `model.bookmarks` for the current folder.
2. **Group by `trackId`** using `Dictionary(grouping:by: \.trackId)`.
3. **Render one `Section` per track** with the track title as header and bookmarks sorted by timestamp within each section.
4. **Handle nil trackId:** Bookmark rows with no `trackId` go in a catch-all section (e.g., "Folder Bookmarks").
5. **Keep the empty state** but check against the full `model.bookmarks` array.

### Before / After

```
BEFORE (current track only):          AFTER (all tracks, grouped):
┌──────────────────────────┐          ┌──────────────────────────┐
│ Bookmarks                │          │ Chapter 01               │
│ ├ 02:15 "Note about..."  │          │ ├ 02:15 "Note about..."  │
│ ├ 05:30 "Cliffhanger"    │          │ ├ 05:30 "Cliffhanger"    │
│ └ 12:45 "Favorite part"  │          │ └ 12:45 "Favorite part"  │
│                          │          │ Chapter 02               │
│                          │          │ ├ 03:10 "Key quote"      │
│                          │          │ └ 08:22 "Plot twist"     │
│                          │          │ Chapter 03               │
│                          │          │ └ 01:45 "Opening line"   │
└──────────────────────────┘          └──────────────────────────┘
```

## Files to Modify

| Action | File | Lines |
|--------|------|-------|
| Modify | `OrbitAudioBooks/Views/PlaylistView.swift` | 102-151 (bookmarks tab body) |
| Remove | `OrbitAudioBooks/Views/PlaylistView.swift` | 63-69 (`visibleBookmarkIndices`) |

## Detailed Changes

### PlaylistView.swift

1. **Remove `visibleBookmarkIndices`** (lines 63-69) — it's only used for `model.moveBookmarks` which doesn't apply to a grouped view.

2. **Replace the filter + flat list** (lines 102-150) with:

```swift
// Group bookmarks by track, using Track.title for section headers
let trackTitleMap: [String: String] = Dictionary(
    uniqueKeysWithValues: model.tracks.map { ($0.id, $0.title) }
)
let grouped = Dictionary(grouping: model.bookmarks) { $0.trackId }
// Sort groups by track order in the playlist
let sortedKeys = grouped.keys.sorted { a, b in
    let ia = a.flatMap { tid in model.tracks.firstIndex(where: { $0.id == tid }) } ?? Int.max
    let ib = b.flatMap { tid in model.tracks.firstIndex(where: { $0.id == tid }) } ?? Int.max
    return ia < ib
}

if model.bookmarks.isEmpty && !showChapters {
    ContentUnavailableView(...)
} else {
    List {
        if model.chapters.count >= 2 {
            Toggle("Show Chapters", isOn: $showChapters)
        }
        if showChapters {
            Section("Chapters") { ... }
        }
        ForEach(sortedKeys, id: \.self) { trackId in
            let bookmarks = grouped[trackId]?.sorted(by: { $0.timestamp < $1.timestamp }) ?? []
            let header: String = trackId.flatMap { trackTitleMap[$0] } ?? "Folder Bookmarks"
            Section(header) {
                ForEach(bookmarks, id: \.id) { bm in
                    bookmarkRow(bm)
                }
            }
        }
    }
}
```

3. **Optional: Collapse single-track folders.** If the folder has only one track, skip section headers and render a flat list (the current behavior is fine for this case).

## What Does NOT Change

- **`Bookmark` model** — already has `trackId` and `folderKey`
- **Persistence** (`Persistence.swift`, `BookmarkStore.swift`) — already saves/loads all bookmarks
- **Playback logic** — `currentTrackBookmarks`, bookmark-loop, and skip-navigation remain scoped to the current track (they control playback, not display)
- **Voice memo recording** — unchanged
- **Watch app bookmarks** — unchanged (Watch has its own view)

## Edge Cases

| Case | Behavior |
|------|----------|
| Single-track audiobook | Groups collapse to one section (or flat list if preferred) |
| Bookmarks with nil `trackId` | Grouped under "Folder Bookmarks" section |
| Tracks with no bookmarks | No section rendered for that track |
| Empty bookmarks list | `ContentUnavailableView` as before |
| Newly added bookmark | Appears in the correct section immediately via `@Observable` |
| Bookmark deleted via swipe | Removed from its section immediately |

## Dependencies

- **None.** This is a self-contained UI change in one file.
- **No conflict with any existing plan.** It doesn't touch PlayerModel, persistence, or data models.
- **Can be done in parallel with any other work.**

## Complexity

**Small.** ~30 lines changed, single file, no data model or persistence changes.

## Verification

1. Load a folder with 2+ audio files
2. Add bookmarks on different tracks
3. Open Playlist → Bookmarks tab
4. Confirm all bookmarks are visible, grouped under their track names
5. Confirm tapping a bookmark seeks to the correct track and timestamp
6. Confirm swipe actions (enable/disable, edit, delete) work within groups
7. Confirm single-track folders still display correctly
8. Confirm empty state appears when no bookmarks exist
