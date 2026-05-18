# Plan: Playlist Packaging — Folder Manifest + ZIP Export ✅ DONE (2026-05-18)

## Summary

Formalize the implicit "folder = playlist" convention with a `.orbitplaylist.json` manifest file, consolidating scattered sidecar data and UserDefaults keys into a single, portable playlist definition. Add optional ZIP export for sharing.

## Current State

The app already treats a user-selected folder as a playlist unit:
- Audio files (`.mp3`, `.m4a`, `.m4b`) are enumerated from the folder
- `bookmarks.json` sidecar lives in the folder root
- Voice memos (`memo-<UUID>.m4a`) and bookmark images (`bookmark-<UUID>.jpg`) are written to the folder
- Per-track transcripts (`<filename>.transcript.json`) live alongside their audio files
- Cover art is scanned from the folder

But there's no formal declaration that a folder "is" an Orbit playlist. The following data is still trapped in UserDefaults by folder URL string key, invisible to the user and not portable:

| Data | UserDefaults Key |
|------|-----------------|
| Track ordering | `order_<folderURL>` |
| Track enabled states | `enabled_<folderURL>` |
| Per-book playback speed | `speed_<folderURL>` |
| Per-book playback progress | progress dictionary |
| Loop mode per book | loopMode dictionary |

## Why Not ZIP as Primary Storage

| Constraint | Impact |
|------------|--------|
| `AVAudioFile` requires file URLs | Must extract ZIP to play — defeats the purpose |
| Incremental writes | Adding a bookmark or recording a memo would re-compress multi-GB audio |
| iOS temp directory | Extracted files can be purged by the OS at any time |
| Security-scoped bookmarks | OS grants access to folders, not ZIP internals |
| iCloud / `NSFileCoordinator` | ZIP doesn't support coordinated incremental writes |

**ZIP is a distribution/export format, not a live storage format for audio playback.**

## Proposed Design

### 1. `.orbitplaylist.json` Manifest

```json
{
  "version": 1,
  "title": "The Great Gatsby",
  "author": "F. Scott Fitzgerald",
  "createdAt": "2026-05-16T12:00:00Z",
  "tracks": [
    { "file": "01_Chapter01.m4a", "title": "Chapter 1", "duration": 1200.5, "enabled": true },
    { "file": "02_Chapter02.m4a", "title": "Chapter 2", "duration": 1340.2, "enabled": true }
  ],
  "coverArt": "cover.jpg",
  "playbackState": {
    "lastTrackId": "01_Chapter01.m4a",
    "lastPosition": 345.2,
    "speed": 1.25,
    "loopMode": "off"
  },
  "stats": {
    "totalListeningTime": 5400.0,
    "completionPercent": 0.72,
    "lastPlayedAt": "2026-05-16T10:30:00Z"
  }
}
```

Benefits:
- The app can detect "this is an Orbit playlist" by checking for the manifest
- Track order, enabled state, playback progress, speed, and loop mode move OUT of UserDefaults and INTO the folder
- Playlist is portable: copy the folder to another device, reopen in Orbit, everything is restored
- No changes needed to the audio pipeline — audio files stay at their direct URLs
- Incremental writes: updating progress writes ~2KB, not re-compressing 2GB

### 2. Folder Layout Convention

```
TheGreatGatsby/                       ← folder = playlist
  ├── .orbitplaylist.json             ← manifest
  ├── cover.jpg                       ← artwork
  ├── 01_Chapter01.m4a                ← audio
  ├── 01_Chapter01.transcript.json    ← per-track transcript
  ├── 02_Chapter02.m4a
  ├── 02_Chapter02.transcript.json
  ├── bookmarks.json                   ← bookmark sidecar (already exists)
  ├── memo-<UUID>.m4a                 ← voice memo
  ├── bookmark-<UUID>.jpg             ← bookmark image
  └── ...
```

The naming is already consistent. The only new file is `.orbitplaylist.json`.

### 3. Migration

1. On folder load: if `.orbitplaylist.json` exists, read track order, stats, and playback state from it. If not, create it from the current implicit state (enumerated tracks + UserDefaults data)
2. Run a one-time migration that copies per-folder UserDefaults data into the manifest
3. Keep the security-scoped bookmark in UserDefaults (required by the OS — the only alternative)
4. Future reads go to the manifest first; fall back to UserDefaults for backward compatibility
5. Clean up orphaned UserDefaults keys after migration confirmed

### 4. ZIP Export (Phase 2, Optional)

Add "Export Playlist" that zips the folder for sharing via the iOS share sheet. This is purely export — the app never reads ZIP as primary storage.

- Import: receiving user extracts `.zip` in Files.app → opens the extracted folder in Orbit
- No changes to playback pipeline

## Files to Create/Modify

| Action | File |
|--------|------|
| Create | `OrbitAudioBooks/Models/OrbitPlaylistManifest.swift` |
| Modify | `OrbitAudioBooks/ViewModels/PlayerModel.swift` — read/write manifest on folder load |
| Modify | `OrbitAudioBooks/ViewModels/PlayerModel.swift` (Persistence) — migrate UserDefaults keys to manifest |
| Create | `OrbitAudioBooks/Services/PlaylistManifestService.swift` — read/write logic (or fold into Persistence) |
| Modify | `OrbitAudioBooks/Views/PlaylistView.swift` — optional "Export Playlist" button (Phase 2) |

## Dependencies

- **Should follow:** Plan A1 (PlayerModel decomposition) — manifest logic lives in extracted `Persistence` or `PlaylistManifestService`
- **Should follow:** Plan SQL — manifest becomes the on-disk representation; SQL becomes the query/index layer
- **No conflict with:** Any other plan. ZIP export is additive. Manifest replaces UserDefaults keys that no other plan modifies.

## Complexity

**Medium.** The manifest model itself is simple (~50 lines). The migration logic needs care to not lose user data. ZIP export is a separate small feature. The key risk is the UserDefaults → manifest migration corrupting state — must be tested with existing audiobook folders.
