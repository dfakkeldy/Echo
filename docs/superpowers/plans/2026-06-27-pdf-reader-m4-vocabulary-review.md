# PDF Reader M4 — Vocabulary Review Card + Narrate-PDF Discoverability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make saved vocabulary words first-class in the study review loop (show the word, play its narrated snippet, Look Up the definition, grade it), and make on-device narration of a parsed PDF discoverable from the reader.

**Architecture:** Vocabulary cards (`cardType="vocabulary"`, `frontText`=word, `backText=""`, `mediaTimestamp/endTimestamp`=snippet, context in `mediaJSON`) are already created (M2) and already scheduled + loaded by the study queue (`allDueCards` doesn't filter by type). The only gap is rendering: route `.vocabulary` to a dedicated review card that shows the word, a Play-snippet button (reusing the assignment-playback wiring), a **Look Up** button (M2's `DictionaryLookupPresenter`, since `backText` is empty), and the grade buttons. Separately, a parsed PDF already qualifies as a narration book (`hasEPUB==has-blocks`), so the existing `NowPlayingTab` nudge already triggers PDF narration — M4 adds a discoverability entry in the PDF reader surface and verifies the path.

**Tech Stack:** Swift 6, SwiftUI, UIKit (`UIReferenceLibraryViewController`), GRDB, Swift Testing.

## Global Constraints

- **Swift 6** (`-default-isolation MainActor`); SwiftUI views `@MainActor`; any pure helper `nonisolated`/`Sendable`.
- **SPDX header line 1** of every new file. SwiftFormat hook reflows on edit — re-confirm SPDX line 1.
- **Tests are Swift Testing**, module `Echo`. Only pure helpers are unit-tested; SwiftUI rendering is build + on-device.
- **iOS-only.** macOS study review (`StudyInlineReviewCard`) is out of scope (note any `#if os(macOS)` branch but don't build it).
- **Build/test** (16 GB Mac — never two `xcodebuild`s; gate every build): `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → `** TEST BUILD SUCCEEDED **` (no `make build`). Suite: `make test-only FILTER=EchoTests/<Suite>`.
- **Reuse, don't duplicate:** `StudyFlashcardType.vocabulary` already exists (M2). Look Up = M2's `DictionaryLookupPresenter`. Snippet playback = the existing `onRequestAssignmentPlayback` → `playStudyAssignment` wiring (seek to `mediaTimestamp` + play). Narration trigger = `model.startNarrationPlayback(voice:)`.
- **Do not regress** existing review of normal / listening / image cards, or the existing `NowPlayingTab` narration nudge.
- **Verifiability:** Task 1 has one pure unit-tested helper (context-sentence decode); the rest is SwiftUI rendering — build-green + the on-device checklist is the gate. Task 2 is build + on-device.
- **Spec:** `docs/superpowers/specs/2026-06-26-pdf-alignment-define-design.md` (§6.3 M4). This plan = milestone **M4** (final).

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|-----------|
| `Shared/Study/VocabularyCardContext.swift` | pure: decode context sentence from `mediaJSON` | **Create** |
| `EchoTests/VocabularyCardContextTests.swift` | unit test for the decode | **Create** |
| `EchoCore/Views/StudyAssignmentCardView.swift` | add a `.vocabulary` rendering branch (word + Look Up, no empty back) | **Modify** |
| `EchoCore/ViewModels/StudySessionViewModel.swift` | allow snippet playback for `.vocabulary` | **Modify** |
| `EchoCore/Views/StudySessionView.swift` | route `.vocabulary` to the assignment-card path | **Modify** |
| `EchoCore/Views/PDFReadingSurface.swift` (M1) and/or `PDFDocumentView.swift` | discoverability "Narrate" entry when a parsed PDF has no audio | **Modify** |

---

### Task 1: Vocabulary review card

**Files:** Create `Shared/Study/VocabularyCardContext.swift`, `EchoTests/VocabularyCardContextTests.swift`; Modify `StudyAssignmentCardView.swift`, `StudySessionViewModel.swift`, `StudySessionView.swift`.

**Interfaces — Produces:**
- `enum VocabularyCardContext { static func sentence(fromMediaJSON json: String?) -> String? }`

- [ ] **Step 1: Write the failing helper test**

Create `EchoTests/VocabularyCardContextTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct VocabularyCardContextTests {
    @Test func decodesContextSentence() {
        let json = #"{"context":"The ephemeral moment passed."}"#
        #expect(VocabularyCardContext.sentence(fromMediaJSON: json) == "The ephemeral moment passed.")
    }
    @Test func returnsNilForMissingOrMalformed() {
        #expect(VocabularyCardContext.sentence(fromMediaJSON: nil) == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: "") == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: "not json") == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: #"{"other":"x"}"#) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL (`VocabularyCardContext` unknown).

- [ ] **Step 3: Implement the helper**

Create `Shared/Study/VocabularyCardContext.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decodes a vocabulary card's stored context sentence from its `mediaJSON`
/// (`{"context": "..."}`, written by `VocabularyCardBuilder`).
enum VocabularyCardContext {
    static func sentence(fromMediaJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let context = obj["context"] as? String, !context.isEmpty
        else { return nil }
        return context
    }
}
```

- [ ] **Step 4: Run to pass** — `make test-only FILTER=EchoTests/VocabularyCardContextTests` → pass.

- [ ] **Step 5: Render vocabulary cards**

In `StudySessionViewModel.swift`, the `requestPlayCurrentAssignment()` guard currently allows only `.listeningAssignment`/`.imageAssignment`. Add `.vocabulary`:

```swift
    func requestPlayCurrentAssignment() {
        guard let entry = currentEntry,
            entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
                || entry.flashcard.cardType == StudyFlashcardType.imageAssignment
                || entry.flashcard.cardType == StudyFlashcardType.vocabulary
        else { return }
        onRequestAssignmentPlayback?(entry.flashcard)
    }
```

In `StudySessionView.swift`, add `.vocabulary` to the condition that routes to `StudyAssignmentCardView` (so it gets the `onPlay`/`onReveal`/`onGrade` wiring):

```swift
    if entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
        || entry.flashcard.cardType == StudyFlashcardType.imageAssignment
        || entry.flashcard.cardType == StudyFlashcardType.vocabulary {
        StudyAssignmentCardView( /* unchanged args */ )
    } else { /* unchanged FlashcardReviewCard / StudyInlineReviewCard */ }
```

In `StudyAssignmentCardView.swift`, add a vocabulary branch. Since `backText` is empty for vocabulary, the revealed state must show a **Look Up** button (not the empty `Text(backText)`), plus the grade buttons; and the prompt should show the word (`frontText`) and its context sentence. Concretely:
- `labelTitle`: vocabulary → `"Vocabulary"`; `labelIcon`: vocabulary → `"character.book.closed"`.
- Add, near the top (after the header), for vocabulary only: the word prominently and the context sentence (via `VocabularyCardContext.sentence(fromMediaJSON: entry.flashcard.mediaJSON)`), e.g.

```swift
    private var isVocabulary: Bool { entry.flashcard.cardType == StudyFlashcardType.vocabulary }

    // in body, after AssignmentHeaderView:
    if isVocabulary {
        Text(entry.flashcard.frontText)
            .font(.title2).bold()
            .frame(maxWidth: .infinity, alignment: .leading)
        if let context = VocabularyCardContext.sentence(fromMediaJSON: entry.flashcard.mediaJSON) {
            Text(context).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

- Keep the existing `Button("Play Assignment", …, action: onPlay)` (plays the snippet for vocabulary too). Optionally relabel to `"Play in context"` for vocabulary.
- Replace the revealed-state body for vocabulary: instead of `Text(entry.flashcard.backText)` (empty), show a Look Up button + the grade buttons:

```swift
    if isRevealed {
        if isVocabulary {
            if DictionaryLookupPresenter.hasDefinition(for: entry.flashcard.frontText) {
                Button("Look Up \"\(entry.flashcard.frontText)\"", systemImage: "book.circle") {
                    DictionaryLookupPresenter.present(term: entry.flashcard.frontText)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text(entry.flashcard.backText) /* unchanged */
        }
        StudyAssignmentGradeButtons(onGrade: onGrade)
    } else {
        Button("Review Retention", systemImage: "checkmark.circle", action: onReveal)
    }
```

> `DictionaryLookupPresenter` is in `EchoCore/Views/` (M2). `StudyAssignmentCardView` is in the same target — confirm it's importable (it should be; same module). Keep the non-vocabulary path byte-identical.

- [ ] **Step 6: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/VocabularyCardContextTests` → SUCCEEDED + pass.

```bash
git add Shared/Study/VocabularyCardContext.swift EchoTests/VocabularyCardContextTests.swift EchoCore/Views/StudyAssignmentCardView.swift EchoCore/ViewModels/StudySessionViewModel.swift EchoCore/Views/StudySessionView.swift
git commit -m "feat(study): vocabulary review card (word + snippet + Look Up + grade)"
```

---

### Task 2: Narrate-PDF discoverability

**Files:** Modify `EchoCore/Views/PDFReadingSurface.swift` (M1's container) and/or `PDFDocumentView.swift`.

Runtime-only — build + on-device. The core path already works (a parsed PDF is a narration book; `NowPlayingTab` shows the nudge). This task adds a discoverability entry so the user can start narration from the PDF reader itself.

- [ ] **Step 1: Confirm the existing path (read-back, no code)**

In your report, confirm from the code that a parsed PDF book reaches narration today: `isNarrationBook` requires `hasEPUB` (== has visible `epub_block` rows) + all-tracks-are-narration-cache (or no tracks); a PDF parsed by `PDFAutoImportScanner` populates `epub_block`, so `isNarrationBook` is true and `NowPlayingTab`'s nudge (`NarrationNudgePolicy.showsNudge(tracksEmpty:isRunning:)`) appears. (This corrects a stale-main-repo report that claimed PDFs aren't parsed.)

- [ ] **Step 2: Add a discoverability "Narrate" entry in the PDF reader**

In `PDFReadingSurface` (shown for a parsed PDF, M1), add a small affordance — e.g. a toolbar/menu button or an overlay button — that, when the book has narratable blocks and no audio yet (`model.isNarrationBook && model.tracks.isEmpty && NarrationCapability.supportsOnDeviceNarration && !model.narrationPlaybackState.isRunning`), starts narration:

```swift
    Button("Narrate", systemImage: "play.circle") {
        model.startNarrationPlayback(voice: /* preferred/selected voice */)
    }
```

> Reuse the same voice resolution `NowPlayingTab` uses (the preferred/selected `NarrationVoice`); read `NowPlayingTab.swift` for how it picks the voice and mirror it (do not invent a voice). Place the button so it does not collide with M1's page/reflow toggle or the bottom action menu. Gate its visibility on the same conditions as the `NowPlayingTab` nudge so it never shows for a book that already has audio.

- [ ] **Step 3: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → SUCCEEDED.

```bash
git add EchoCore/Views/PDFReadingSurface.swift
git commit -m "feat(pdf): discoverability Narrate entry in the PDF reader surface"
```

---

## On-device verification (required before merge)

1. Save a word from the reader (M2/M3) → open the study session → the vocabulary card shows the word + context, a Play button plays the narrated snippet, reveal shows **Look Up** (opens the dictionary), and grade buttons schedule it (FSRS).
2. Normal / listening / image cards review exactly as before (no regression).
3. Open a parsed PDF with no audio → a **Narrate** entry is visible in the reader and starts on-device narration; once narrating, it hides; books with audio never show it. The existing `NowPlayingTab` nudge still works.

## Out of scope for M4

- macOS study review (`StudyInlineReviewCard`) vocabulary rendering.
- Distinct vocabulary-card styling beyond the Look Up affordance.
- Storing the definition text on the card (no public API; Look Up is on-demand — by design).

## Self-review notes

- **Spec coverage (M4, §6.3):** vocabulary card surfaced in review with Look Up + snippet (T1) ✓; scheduling/feed already works (no code — `allDueCards` is type-agnostic) ✓; narrate-PDF reachable + discoverable (T2) ✓.
- **Verifiable vs deferred:** the `VocabularyCardContext` decode is unit-tested; the rest is SwiftUI (on-device checklist).
- **Type consistency:** `VocabularyCardContext.sentence` (T1) used in `StudyAssignmentCardView`; `DictionaryLookupPresenter` (M2) reused in T1+T2; `model.startNarrationPlayback` (existing) reused in T2.
- **Reuse:** no new scheduling, no new playback plumbing — rides `onRequestAssignmentPlayback` + `startNarrationPlayback`.
