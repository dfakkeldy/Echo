# Fix 3 Critical Flashcard Bugs — Implementation Plan

> **Status: Complete** — all three bugs fixed and merged to `main`.
> - Bug 1 (audiobookID mismatch): `c141554`
> - Bug 2 (force-unwrap crash): part of watchOS flashcard review feature
> - Bug 3 (timezone mismatch): `2616887`

**Goal:** Fix three critical bugs: inline flashcard trigger never fires, force-unwrap crash on watch gradeFlashcard, and flashcard scheduling broken by timezone mismatch.

**Architecture:** Three independent, single-file fixes. Bug 1 aligns the audiobookID format between import (bare filename) and query (full URL). Bug 2 adds a guard against nil databaseService. Bug 3 standardizes all date formatting on UTC `ISO8601Format()`.

**Tech Stack:** Swift, GRDB, Foundation

---

### Task 1: Fix inline flashcard trigger audiobookID mismatch

**Files:**
- Modify: `OrbitAudioBooks/ViewModels/PlayerModel.swift:1639-1640`

**Root cause:** `DeckImportService` stores `deck.targetMediaID` (bare filename, e.g. `"my-audiobook.m4b"`) as `audiobook_id`. `checkInlineFlashcardTrigger` queries with `state.tracks[currentIndex].url.absoluteString` (full URL, e.g. `"file:///path/to/my-audiobook.m4b"`). These never match, so the database query always returns zero rows.

**Fix:** Use `lastPathComponent` on the query side to extract the bare filename, matching what was stored at import time. This is consistent with `DailyReviewViewModel.constructSourceURL` which also treats `audiobookID` as a bare filename.

- [x] **Step 1: Replace the trackKey computation**

In `PlayerModel.swift`, replace lines 1639-1640:

```swift
let trackKey = state.tracks.indices.contains(state.currentIndex)
    ? state.tracks[state.currentIndex].url.absoluteString : ""
```

With:

```swift
let trackKey = state.tracks.indices.contains(state.currentIndex)
    ? state.tracks[state.currentIndex].url.lastPathComponent : ""
```

- [x] **Step 2: Build and verify compilation**

```bash
xcodebuild -project "Orbit Audiobooks.xcodeproj" -scheme "OrbitAudioBooks" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [x] **Step 3: Commit**

```bash
git add OrbitAudioBooks/ViewModels/PlayerModel.swift
git commit -m "$(cat <<'EOF'
fix(anki): align inline flashcard trigger audiobookID with import format

DeckImportService stores targetMediaID (bare filename) as audiobook_id,
but checkInlineFlashcardTrigger queried with url.absoluteString (full URL).
Use lastPathComponent to match the stored format.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Fix force-unwrap crash on watch gradeFlashcard

**Files:**
- Modify: `OrbitAudioBooks/ViewModels/PlayerModel.swift:474`

**Root cause:** `databaseService` is `var databaseService: DatabaseService?` (optional, defaults to `nil`). The `gradeFlashcard` handler force-unwraps it with `self.databaseService!`. If the watch sends this command before the database is wired up, the app crashes.

- [x] **Step 1: Replace force-unwrap with guard-let**

In `PlayerModel.swift`, replace line 474:

```swift
try? FlashcardDAO(db: self.databaseService!.writer).grade(cardID: cardID, grade: grade)
```

With:

```swift
guard let writer = self.databaseService?.writer else { return }
try? FlashcardDAO(db: writer).grade(cardID: cardID, grade: grade)
```

- [x] **Step 2: Build and verify compilation**

```bash
xcodebuild -project "Orbit Audiobooks.xcodeproj" -scheme "OrbitAudioBooks" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [x] **Step 3: Commit**

```bash
git add OrbitAudioBooks/ViewModels/PlayerModel.swift
git commit -m "$(cat <<'EOF'
fix(anki): remove force-unwrap on databaseService in watch gradeFlashcard handler

databaseService is optional and defaults to nil. A watch message arriving
before the database is configured would crash. Replace with guard-let.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Fix flashcard scheduling timezone mismatch

**Files:**
- Modify: `Shared/Database/Flashcard.swift:65,69`
- Modify: `OrbitAudioBooks/Services/DeckImportService.swift:56`

**Root cause:** `SpacedRepetitionService.apply` writes dates with `ISO8601DateFormatter()` (local timezone, e.g. `"2026-05-18T15:00:00+0500"`). `FlashcardDAO.dueCards` compares against `Date().ISO8601Format()` (UTC, e.g. `"2026-05-18T10:00:00Z"`). These lexicographic string comparisons do not account for timezone offsets, so `dueCards` returns wrong results for users outside UTC.

**Fix:** Use `Date.ISO8601Format()` (UTC-based) consistently everywhere dates are written to the database, matching what the DAO query side already uses.

- [x] **Step 1: Fix `SpacedRepetitionService.apply` date formatting**

In `Shared/Database/Flashcard.swift`, replace line 65:

```swift
updated.lastReviewedAt = ISO8601DateFormatter().string(from: Date())
```

With:

```swift
updated.lastReviewedAt = Date().ISO8601Format()
```

Replace lines 68-70:

```swift
if let nextDate = Calendar.current.date(byAdding: .day, value: updated.intervalDays, to: Date()) {
    updated.nextReviewDate = ISO8601DateFormatter().string(from: nextDate)
}
```

With:

```swift
if let nextDate = Calendar.current.date(byAdding: .day, value: updated.intervalDays, to: Date()) {
    updated.nextReviewDate = nextDate.ISO8601Format()
}
```

- [x] **Step 2: Fix `DeckImportService.importDeck` date formatting**

In `OrbitAudioBooks/Services/DeckImportService.swift`, replace line 56:

```swift
nextReviewDate: ISO8601DateFormatter().string(from: Date()),
```

With:

```swift
nextReviewDate: Date().ISO8601Format(),
```

- [x] **Step 3: Build and verify compilation**

```bash
xcodebuild -project "Orbit Audiobooks.xcodeproj" -scheme "OrbitAudioBooks" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [x] **Step 4: Commit**

```bash
git add Shared/Database/Flashcard.swift OrbitAudioBooks/Services/DeckImportService.swift
git commit -m "$(cat <<'EOF'
fix(anki): use UTC ISO8601Format for all flashcard date storage

ISO8601DateFormatter() uses local timezone while FlashcardDAO.dueCards
compares against Date().ISO8601Format() (UTC). This lexicographic string
comparison breaks due-card filtering for users in non-UTC timezones.
Standardize on ISO8601Format() everywhere.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```
