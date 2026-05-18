# Plan AWG: WatchOS Hands-Free Flashcard Review ✅ DONE (2026-05-18)

## Summary

Implement a hands-free flashcard review mode on the Apple Watch using the Double Tap gesture (`handGestureShortcut`) and haptic feedback. Sync the due flashcard queue from the iOS app via WatchConnectivity and provide a gesture-navigable review UI.

## Current State

The watch app has been decomposed (Plan A2) into separate model, service, and view files. `WatchViewModel` handles `WCSessionDelegate` communication with the iOS app. `PlayerPage` is the main playback UI. The watch uses `AVPlayer` for local playback. There is no flashcard concept on the watch yet. watchOS 11 APIs for `handGestureShortcut` are available.

## Proposed Implementation

### 1. WatchFlashcard Model

Create a lightweight watch-side flashcard model (subset of the full iOS `Flashcard`):

```swift
struct WatchFlashcard: Codable, Identifiable {
    let id: UUID
    let frontText: String
    let backText: String
    // No SM-2 properties on watch — grading result is sent back to iOS
}
```

### 2. Sync Due Queue via WatchConnectivity

Extend `WatchViewModel` to request and receive the due flashcard queue:

- iOS side: when the watch requests due cards, query `FlashcardStore.dueCards()` and send the top N cards (limit to ~20 to avoid overwhelming the watch)
- Watch side: store received cards in `WatchViewModel.dueCards: [WatchFlashcard]`
- After the user grades a card, send the result back to iOS for SM-2 processing and persistence

```swift
// WatchAction additions
enum WatchAction {
    // ... existing cases
    case requestDueCards
    case gradeCard(id: UUID, grade: Int)
}
```

### 3. WatchReviewView

The primary workflow must be navigable without touching the screen:

```
┌─────────────────────────┐
│    Due: 5 of 12         │  ← Progress header
│                         │
│  ┌───────────────────┐  │
│  │   frontText       │  │  ← Large card area
│  │                   │  │
│  └───────────────────┘  │
│                         │
│  ┌───────────────────┐  │
│  │    REVEAL  ✋      │  │  ← Primary action with .handGestureShortcut(.primaryAction)
│  └───────────────────┘  │
│                         │
│  Again   Hard   Easy    │  ← Secondary buttons (smaller)
└─────────────────────────┘
```

After reveal:

```
┌─────────────────────────┐
│  ┌───────────────────┐  │
│  │   backText        │  │  ← Answer revealed
│  └───────────────────┘  │
│                         │
│  ┌───────────────────┐  │
│  │    GOOD   ✋       │  │  ← Default action always "Good" with handGestureShortcut
│  └───────────────────┘  │
│                         │
│  Again   Hard   Easy    │  ← Alternate grades
└─────────────────────────┘
```

Key interactions:
- Double tap on "Reveal" → shows answer
- Double tap on "Good" → grades as Good, advances to next card
- Manual tap on Again/Hard/Easy for alternate grades
- Haptic notification (`WKHapticType.notification`) when a new card appears — prompts the user to speak their answer aloud

### 4. Gesture Implementation

```swift
Button {
    viewModel.revealCard()
} label: {
    Label("Reveal", systemImage: "eye")
}
.handGestureShortcut(.primaryAction)
```

After reveal, the primary action button changes to "Good" (still with `.primaryAction`), so the user can double-tap → reveal, double-tap again → pass.

### 5. No Audio Snippets on Watch (MVP)

For the initial implementation, skip playing audio snippets on the watch. The card shows the text front/back only. Audio snippet playback on watch can be added later (it complicates the architecture significantly — managing background AVPlayer, file transfer for the media, battery concerns).

## Files to Create/Modify

| Action | File |
|--------|------|
| Create | `Orbit Audiobooks Watch App/Models/WatchFlashcard.swift` |
| Create | `Orbit Audiobooks Watch App/Views/WatchReviewView.swift` |
| Modify | `Orbit Audiobooks Watch App/Services/WatchViewModel.swift` (add due card sync) |
| Modify | `Orbit Audiobooks Watch App/Views/ContentView.swift` (add review tab/entry) |
| Modify | `OrbitAudioBooks/Models/WatchAction.swift` (add flashcard cases) |
| Modify | `OrbitAudioBooks/ViewModels/PlayerModel.swift` (handle flashcard sync from watch) |

## Dependencies

- **Depends on:** Plan ASRS (Flashcard model, FlashcardStore on iOS), Plan A2 (watch decomposition)
- **Blocked by:** Plan A2 must be complete for clean watch file structure
- **Conflicts with:** Nothing significant. Touches `WatchAction` and `WatchViewModel` but these are additive changes.

## Complexity

**Medium.** Watch UI is simple by design. The sync adds ~4 new `WatchAction` cases and ~50 lines to `WatchViewModel`. The gesture-only navigation is straightforward with watchOS 11 APIs. No audio on watch keeps scope manageable.
