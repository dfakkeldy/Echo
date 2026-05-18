# Plan: Audio Queue Parsing for M4B Folders ✅ DONE (2026-05-18)

## Summary

Upgrade the audio parsing engine to accept a folder of multiple chapterized M4B files, parse metadata from each, sort them, and play them seamlessly as a single continuous audiobook with aggregated chapter navigation.

## Current State

**Files:**
- `AudioEngine.swift` (389 lines) — Uses `AVAudioPlayerNode` + `AVAudioUnitEQ` + `AVAudioUnitVarispeed` chain. Loads a single audio file and schedules its buffer.
- `PlayerModel.swift` — `loadURL(_:)` handles single-file and single-directory (folder of loose audio files) selection.
- `MockMediaProvider.swift` — Seeds a single sample M4B file for development.
- `Chapter.swift` — Chapter model with `title`, `startSeconds`, `endSeconds`.

The current flow:
1. User selects a folder OR a single audio file
2. If folder: enumerate audio files, sort alphabetically, play as one flat playlist
3. If single file: load and play with embedded chapters

## Proposed Changes

### 1. Multi-M4B Folder Loading

When the user selects a folder containing multiple `.m4b` files:

1. Enumerate all `.m4b` files (not just loose audio) in the directory
2. For each M4B, extract:
   - `AVAsset` metadata (title, author, album art)
   - Chapter list from `AVAssetChapter` metadata
   - Duration
3. Sort M4B files by:
   - Track number metadata if available
   - Filename (alphabetical/numerical) as fallback
4. Build an aggregated chapter list: `Book 1 → Chapters 1-N`, `Book 2 → Chapters 1-M`, etc.

### 2. Seamless Playback

Two approaches for seamless transition between M4B files:

**Option A (Recommended): Sequential scheduling on AVAudioPlayerNode**

Schedule each M4B's audio buffer on the same `AVAudioPlayerNode` in sequence. When the current buffer finishes, the next one starts automatically without a gap. This keeps the existing AVAudioEngine chain intact.

- Pre-buffer the next M4B while the current one plays
- Use `AVAudioPlayerNode.scheduleBuffer(_:completionCallbackType:completionHandler:)` to detect end-of-file
- In the completion handler, schedule the next file's buffer

**Option B: AVQueuePlayer**

Replace the AVAudioEngine chain with `AVQueuePlayer`. Simpler for sequential playback but loses the EQ boost and varispeed nodes. Would need to reimplement volume boost and speed control differently.

### 3. Aggregated Chapter Model

```swift
struct AggregatedChapter: Identifiable {
    let id: String  // "bookIndex-chapterIndex"
    let bookTitle: String
    let bookIndex: Int
    let chapterTitle: String
    let chapterIndex: Int
    let startSeconds: TimeInterval  // Cumulative across all books
    let endSeconds: TimeInterval
    let duration: TimeInterval
}
```

The chapter navigator shows a two-level hierarchy: book sections with collapsible chapter lists.

### 4. UI Updates

- `PlaylistView.swift`: Show aggregated book/chapter hierarchy
- Chapter skip: Skip to next/previous chapter, crossing book boundaries seamlessly
- Now Playing info: Show "Book Title - Chapter Title" format
- Scrubber: Show book markers on the timeline

## Files to Create/Modify

| Action | File |
|--------|------|
| Create | `OrbitAudioBooks/Models/AggregatedChapter.swift` |
| Modify | `OrbitAudioBooks/Services/AudioEngine.swift` — sequential scheduling, pre-buffering |
| Modify | `OrbitAudioBooks/ViewModels/PlayerModel.swift` — multi-M4B loading, aggregated chapter nav |
| Modify | `OrbitAudioBooks/Views/PlaylistView.swift` — book/chapter hierarchy UI |
| Modify | `OrbitAudioBooks/Views/PlayerScrubberView.swift` — book markers on timeline |
| Modify | `OrbitAudioBooks/MockMediaProvider.swift` — multi-M4B sample data for dev |

## Dependencies

- **Blocked by:** Plan A6 (AudioEngine encapsulation) — AudioEngine needs a clean API before adding sequential scheduling. Do A6 first.
- **Conflicts with:**
  - Plan A1 (PlayerModel decomposition) — coordinate so the new `ChapterService` supports aggregated chapters. Do A1's ChapterService extraction first, then add multi-M4B support.
  - Plan A3 (deduplication) — aggregated chapter model should live in the shared package
  - Plan Phase 4 (CarPlay) — CarPlay chapter list must show aggregated chapters

## Complexity

**Large.** Changes the core audio pipeline, chapter data model, and several views. Requires careful testing to ensure no gaps, glitches, or crashes at M4B boundaries. Pre-buffering correctly is the hardest part.
