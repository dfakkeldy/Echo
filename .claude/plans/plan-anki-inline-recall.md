# Plan AIR: Inline Active Recall (AudioEngine Integration) ✅ DONE (2026-05-18)

## Summary

Integrate inline flashcard pop-ups during active audiobook playback. Use `AVPlayer.addBoundaryTimeObserver` to trigger flashcards at their designated timestamps, pause playback, show a grading overlay, and resume playback after the user grades the card.

## Current State

The app's audio pipeline uses `AVAudioEngine` with `AVAudioPlayerNode` for iOS playback and `AVPlayer` for watchOS. There is no boundary time observer mechanism currently in use. The `AudioEngine` class (recently encapsulated per Plan A6) exposes `currentTime`, `playImmediately(atRate:)`, `pause()`, and `seek(to:completion:)`. The UI layer uses `@Observable` with `PlayerModel` as the environment object.

## Proposed Implementation

### 1. Flashcard Registration

Add a method to register an array of `Flashcard` objects for the currently loaded media file. Calculate `CMTime` triggers from each card's `triggerTiming`:
- `.beginning` → trigger at `startTime`
- `.end` → trigger at `endTime`
- `.manualOnly` → skip (these only appear in daily review)

### 2. Boundary Time Observers

```swift
// In AudioEngine or PlayerModel:
func scheduleFlashcardTriggers(_ cards: [Flashcard], forItem item: AVPlayerItem) {
    let times = cards.compactMap { card -> CMTime? in
        guard card.triggerTiming != .manualOnly else { return nil }
        let triggerSecond = card.triggerTiming == .beginning ? card.startTime : card.endTime
        // Validate trigger is within bounds, not already passed
        guard triggerSecond >= 0, triggerSecond <= item.duration.seconds else { return nil }
        return CMTime(seconds: triggerSecond, preferredTimescale: 600)
    }
    // Use multiple observers or a single sorted array watched via addPeriodicTimeObserver
}
```

Use `AVPlayer.addBoundaryTimeObserver(forTimes:queue:using:)` to set up trigger points. When a boundary fires:

1. Pause the `AVPlayer`
2. Set an `@Observable` property `activeInlineCard: Flashcard?` on `PlayerModel`
3. The UI layer reacts to this property change

### 3. FlashcardOverlayView

Create a SwiftUI overlay view:

- Shows `frontText` prominently
- "Reveal" button to show `backText` with animation
- 4 grading buttons (Again, Hard, Good, Easy) with SF Symbols and colors
- Calls `SpacedRepetitionService` to update the card
- Saves the updated card to the database
- Dismisses the overlay
- Automatically resumes `AVPlayer` playback

```swift
struct FlashcardOverlayView: View {
    let card: Flashcard
    let onGrade: (Int) -> Void  // 1-4
    
    @State private var isRevealed = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text(card.frontText)
                .font(.headline)
            
            if isRevealed {
                Text(card.backText)
                    .font(.body)
                    .transition(.opacity)
            } else {
                Button("Reveal") { isRevealed = true }
            }
            
            HStack(spacing: 12) {
                gradeButton("Again", grade: 1, color: .red)
                gradeButton("Hard", grade: 2, color: .orange)
                gradeButton("Good", grade: 3, color: .green)
                gradeButton("Easy", grade: 4, color: .blue)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

### 4. Trigger Deduplication

Prevent the same flashcard from triggering multiple times. Track triggered card IDs in a `Set<UUID>` that resets when the active media changes or playback stops. Skip already-fired cards on seek.

## Files to Create/Modify

| Action | File |
|--------|------|
| Create | `OrbitAudioBooks/Views/Components/FlashcardOverlayView.swift` |
| Modify | `OrbitAudioBooks/Services/AudioEngine.swift` (add `scheduleFlashcardTriggers`) |
| Modify | `OrbitAudioBooks/ViewModels/PlayerModel.swift` (add `activeInlineCard`, grading handler) |

## Dependencies

- **Depends on:** Plan ASRS (Flashcard model, SM-2 algorithm, FlashcardStore)
- **Blocked by:** Plan A6 (AudioEngine gain API) — coordinate on AudioEngine public API surface
- **Conflicts with:** Plan A1 (PlayerModel decomposition) — if A1 extracts playback control, the flashcard trigger/grade flow should live in the extracted `PlaybackController`

## Complexity

**Large.** Touches the audio pipeline boundary observer mechanism, introduces a new overlay UI, and wires grading back to persistence. Careful coordination with the existing audio engine pause/resume flow is critical to avoid audio glitches.
