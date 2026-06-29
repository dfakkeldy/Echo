# PDF Reader M2 — Per-Word Interaction (Define + Save + Tap-to-Seek) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-word interaction to the iOS reader card feed — long-press a word for **Look Up** + **Save to study** (vocabulary flashcard), and tap a word to seek to it — without breaking the existing block-level tap-to-seek or context menu.

**Architecture:** The reader's block interactions are collection-view-mediated (tap → `didSelectItemAt` → seek-to-block; long-press → `contextMenuConfigurationForItemsAt:point:` → `buildContextMenu(block:)`). So instead of a *selectable* `UITextView` (which would intercept and break both), we convert the cell's `UILabel` → a **non-selectable** read-only `UITextView` purely to gain TextKit hit-testing (`wordIndex(at:)`), then **augment** the existing tap and context-menu paths with word-resolved behavior. Look Up uses `UIReferenceLibraryViewController` (the on-device dictionary). iOS-only; the macOS reader is a separate SwiftUI path.

**Tech Stack:** Swift 6, UIKit (UICollectionView, UITextView/TextKit, UIReferenceLibraryViewController, UIContextMenuConfiguration), GRDB, Swift Testing.

## Global Constraints

- **Swift 6** (`-default-isolation MainActor` in app targets); honor `Sendable`/actor isolation. UIKit cell code is `@MainActor`; pure helpers are `Sendable`/nonisolated.
- **SPDX header line 1** of every new file: `// SPDX-License-Identifier: GPL-3.0-or-later`. A SwiftFormat PostToolUse hook reflows the whole file on edit — re-confirm SPDX is line 1 after edits.
- **Tests are Swift Testing** (`import Testing`, `@Suite struct`, `@Test func`, `#expect`), module `Echo`. In-memory DB via `DatabaseService(inMemory: ())`.
- **iOS deployment target 18.0** — `UIReferenceLibraryViewController`, `UIEditMenuInteraction`, modern TextKit all available.
- **New files in `EchoCore/`, `Shared/`, `EchoTests/` auto-compile** (synchronized Xcode groups) — no `.pbxproj` edits.
- **Build/test** (16 GB Mac — never two `xcodebuild`s at once, gate every build):
  - Compile: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → `** TEST BUILD SUCCEEDED **` (there is no `make build` target).
  - Run a suite: `make test-only FILTER=EchoTests/<Suite>` (full Swift Testing output; the grep in `make test` hides Swift Testing results — use `test-only`).
- **iOS-only.** Do NOT touch `Echo macOS/`. Do NOT touch watchOS/Widget.
- **Preserve existing behavior:** the block-level tap-to-seek (`tapBlock`) and the existing `buildContextMenu(block:)` actions (Auto-Align, Change Color, bookmark, copyText, …) must keep working. Word actions are *added*, not replacements.
- **Pro cap (D6):** "Save word" must gate on `FreeTierGate.canCreateFlashcards(adding: 1)` and show the paywall (`model.paywallContext = .flashcardCap; model.showPaywall = true`) when over cap — mirror `FlashcardCreationSheet`/`CardInboxView`.
- **Dedupe (D7):** a vocabulary card is keyed by `(audiobookID, lowercased frontText)`; re-surface the existing one instead of inserting a duplicate.
- **Vocabulary card `backText` stays empty** (no public API for the definition); the sentence context goes in `mediaJSON`.
- **Spec:** `docs/superpowers/specs/2026-06-26-pdf-alignment-define-design.md` (§6.1 M2 revised). This plan = milestone **M2**.

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|-----------|
| `Shared/Study/StudyPlanTypes.swift` | add `StudyFlashcardType.vocabulary = "vocabulary"` | **Modify** |
| `Shared/Study/VocabularyCardBuilder.swift` | pure builder: (word, context, anchors, times) → `Flashcard` | **Create** |
| `Shared/WordSentenceContext.swift` | pure: sentence containing a word range in a text | **Create** |
| `Shared/Database/DAOs/FlashcardDAO.swift` | add `vocabularyCard(for:word:)` dedup lookup | **Modify** |
| `EchoTests/VocabularyCardBuilderTests.swift` | builder + sentence-context unit tests | **Create** |
| `EchoTests/FlashcardVocabularyDedupeTests.swift` | dedup lookup test (in-memory DB) | **Create** |
| `EchoCore/Views/Cells/ParagraphCardCell.swift` | `UILabel` → non-selectable `UITextView`; add `wordIndex(at:)` | **Modify** |
| `EchoCore/Views/Cells/HeadingCardCell.swift` | same conversion + `wordIndex(at:)` | **Modify** |
| `EchoCore/Views/ReaderFeedCollectionView.swift` | thread the menu `point:` to the cell; add word tap-to-seek | **Modify** |
| `EchoCore/Views/ReaderTab+Alignment.swift` | augment `buildContextMenu` with Look Up + Save (word-resolved) | **Modify** |
| `EchoCore/Views/DictionaryLookupPresenter.swift` | present `UIReferenceLibraryViewController` from the key window | **Create** |

---

### Task 1: Vocabulary foundation (pure builder, sentence context, dedup) — TDD

**Files:**
- Modify: `Shared/Study/StudyPlanTypes.swift` (add one constant to `StudyFlashcardType`)
- Create: `Shared/Study/VocabularyCardBuilder.swift`, `Shared/WordSentenceContext.swift`
- Modify: `Shared/Database/DAOs/FlashcardDAO.swift` (add `vocabularyCard(for:word:)`)
- Test: `EchoTests/VocabularyCardBuilderTests.swift`, `EchoTests/FlashcardVocabularyDedupeTests.swift`

**Interfaces:**
- Produces:
  - `StudyFlashcardType.vocabulary` (String `"vocabulary"`)
  - `enum WordSentenceContext { static func sentence(containing wordRange: NSRange, in text: String) -> String }`
  - `enum VocabularyCardBuilder { static func make(id: String, audiobookID: String, word: String, contextSentence: String?, blockID: String?, audioStart: TimeInterval, audioEnd: TimeInterval?, createdAt: String) -> Flashcard }`
  - `FlashcardDAO.vocabularyCard(for audiobookID: String, word: String) throws -> Flashcard?`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/VocabularyCardBuilderTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct VocabularyCardBuilderTests {
    @Test func mapsWordAndAnchorsOntoFlashcard() {
        let card = VocabularyCardBuilder.make(
            id: "vc-1", audiobookID: "book-1", word: "ephemeral",
            contextSentence: "It was an ephemeral moment.", blockID: "s1-b3",
            audioStart: 12.5, audioEnd: 13.0, createdAt: "2026-06-27T00:00:00Z")
        #expect(card.id == "vc-1")
        #expect(card.audiobookID == "book-1")
        #expect(card.frontText == "ephemeral")
        #expect(card.backText == "")                       // no stored definition (spec)
        #expect(card.cardType == StudyFlashcardType.vocabulary)
        #expect(card.mediaTimestamp == 12.5)
        #expect(card.endTimestamp == 13.0)
        #expect(card.sourceBlockID == "s1-b3")
        #expect(card.isEnabled)
        #expect(card.mediaJSON?.contains("ephemeral moment") == true)  // context in mediaJSON
    }

    @Test func toleratesMissingContextAndAnchors() {
        let card = VocabularyCardBuilder.make(
            id: "vc-2", audiobookID: "b", word: "word", contextSentence: nil,
            blockID: nil, audioStart: 0, audioEnd: nil, createdAt: "t")
        #expect(card.endTimestamp == nil)
        #expect(card.sourceBlockID == nil)
    }
}

@Suite struct WordSentenceContextTests {
    @Test func returnsTheContainingSentence() {
        let text = "First sentence here. The ephemeral moment passed! Third one."
        let wordRange = (text as NSString).range(of: "ephemeral")
        #expect(
            WordSentenceContext.sentence(containing: wordRange, in: text)
                == "The ephemeral moment passed!")
    }

    @Test func fallsBackToWholeTextWhenNoBoundary() {
        let text = "no terminal punctuation here"
        let wordRange = (text as NSString).range(of: "terminal")
        #expect(WordSentenceContext.sentence(containing: wordRange, in: text) == text)
    }
}
```

Create `EchoTests/FlashcardVocabularyDedupeTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct FlashcardVocabularyDedupeTests {
    private func makeDB() throws -> DatabaseService { try DatabaseService(inMemory: ()) }

    @Test func findsExistingVocabularyCardCaseInsensitively() throws {
        let db = try makeDB()
        let dao = FlashcardDAO(db: db.writer)
        let card = VocabularyCardBuilder.make(
            id: "vc-1", audiobookID: "book-1", word: "Ephemeral", contextSentence: nil,
            blockID: nil, audioStart: 1, audioEnd: nil, createdAt: "t")
        try dao.insert(card)
        #expect(try dao.vocabularyCard(for: "book-1", word: "ephemeral") != nil)
        #expect(try dao.vocabularyCard(for: "book-1", word: "other") == nil)
        #expect(try dao.vocabularyCard(for: "book-2", word: "ephemeral") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: FAIL — `cannot find 'VocabularyCardBuilder'`, `WordSentenceContext`, `vocabularyCard(for:word:)`, `StudyFlashcardType.vocabulary`.

- [ ] **Step 3: Implement**

In `Shared/Study/StudyPlanTypes.swift`, add to the `StudyFlashcardType` enum (after `imageAssignment`):

```swift
    static let vocabulary = "vocabulary"
```

Create `Shared/WordSentenceContext.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Extracts the sentence containing a given word, for vocabulary-card context.
enum WordSentenceContext {
    /// The sentence within `text` that contains `wordRange.location`. Sentence
    /// boundaries are `.`, `!`, `?` followed by whitespace/end. Falls back to the
    /// whole (trimmed) text when no boundary surrounds the word.
    static func sentence(containing wordRange: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard wordRange.location != NSNotFound, wordRange.location <= ns.length else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let terminators = CharacterSet(charactersIn: ".!?")
        // Start: just after the previous terminator before the word.
        var start = 0
        var i = wordRange.location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if let scalar = Unicode.Scalar(c), terminators.contains(scalar) {
                start = i + 1
                break
            }
            i -= 1
        }
        // End: the first terminator at or after the word's end (inclusive).
        var end = ns.length
        var j = NSMaxRange(wordRange)
        while j < ns.length {
            let c = ns.character(at: j)
            if let scalar = Unicode.Scalar(c), terminators.contains(scalar) {
                end = j + 1
                break
            }
            j += 1
        }
        let sentence = ns.substring(with: NSRange(location: start, length: end - start))
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Create `Shared/Study/VocabularyCardBuilder.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Builds a vocabulary `Flashcard` from a tapped word + its audio anchor.
/// Pure (caller supplies `id`/`createdAt`) so it is deterministically testable.
/// `backText` is intentionally empty — no public API returns the definition;
/// Look Up surfaces it on demand. The sentence context is stored in `mediaJSON`.
enum VocabularyCardBuilder {
    static func make(
        id: String, audiobookID: String, word: String, contextSentence: String?,
        blockID: String?, audioStart: TimeInterval, audioEnd: TimeInterval?, createdAt: String
    ) -> Flashcard {
        var mediaJSON: String?
        if let contextSentence, !contextSentence.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: ["context": contextSentence]),
            let json = String(data: data, encoding: .utf8)
        {
            mediaJSON = json
        }
        var card = Flashcard(
            id: id, audiobookID: audiobookID, frontText: word, backText: "",
            mediaTimestamp: audioStart, endTimestamp: audioEnd, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: 0, easeFactor: 2.5, repetitions: 0,
            lastReviewedAt: nil, lastGrade: nil, isEnabled: true, deckID: nil, tags: nil,
            mediaJSON: mediaJSON, sourceBlockID: blockID, playlistPosition: nil,
            createdAt: createdAt, modifiedAt: createdAt)
        card.cardType = StudyFlashcardType.vocabulary
        return card
    }
}
```

> NOTE: match the `Flashcard(...)` argument list to the project's actual memberwise/custom init (see the existing call site in `CardInboxView`/`FlashcardCreationSheet`). If a field above is not accepted by the init, set it via a `var card` mutation after construction (as done for `cardType`). Do not invent fields.

In `Shared/Database/DAOs/FlashcardDAO.swift`, add:

```swift
    /// Existing vocabulary card for this book + word (case-insensitive), or nil.
    func vocabularyCard(for audiobookID: String, word: String) throws -> Flashcard? {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("card_type") == StudyFlashcardType.vocabulary)
                .filter(Column("front_text").lowercased == word.lowercased())
                .fetchOne(db)
        }
    }
```

> If GRDB's `Column(...).lowercased` is unavailable in this version, use `.filter(sql: "LOWER(front_text) = ?", arguments: [word.lowercased()])` instead — verify which compiles.

- [ ] **Step 4: Run tests to verify they pass**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/VocabularyCardBuilderTests && make test-only FILTER=EchoTests/WordSentenceContextTests && make test-only FILTER=EchoTests/FlashcardVocabularyDedupeTests`
Expected: all suites pass (look for `✔ Test run with N tests ... passed`). Confirm SPDX line 1 on the new files.

- [ ] **Step 5: Commit**

```bash
git add Shared/Study/StudyPlanTypes.swift Shared/Study/VocabularyCardBuilder.swift Shared/WordSentenceContext.swift Shared/Database/DAOs/FlashcardDAO.swift EchoTests/VocabularyCardBuilderTests.swift EchoTests/FlashcardVocabularyDedupeTests.swift
git commit -m "feat(study): vocabulary flashcard builder + sentence context + dedup lookup"
```

---

### Task 2: Cell render host → non-selectable UITextView + `wordIndex(at:)`

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`, `EchoCore/Views/Cells/HeadingCardCell.swift`

**Interfaces:**
- Produces (on both cells): `func wordIndex(at point: CGPoint) -> Int?` (point in the cell's `contentView` coordinate space → word index over `wordRanges`, or nil).
- Consumes: existing `wordRanges`, `baseAttributed`, `applyWordHighlight`.

This task is UI; verification is a successful build plus a read-back confirming the karaoke/render path is preserved. No unit test (the hit-test needs runtime TextKit layout).

- [ ] **Step 1: Replace the `UILabel` with a configured non-selectable `UITextView`**

In `ParagraphCardCell.swift`, change the `label` declaration (currently a `UILabel`) to:

```swift
    // Read-only, NON-selectable UITextView: gives TextKit hit-testing for
    // per-word interaction without installing selection gestures that would
    // intercept the collection view's block tap / context menu.
    private let label: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()
```

The existing `label.attributedText = ...` calls in `configure(...)` and `applyWordHighlight(...)` are valid on `UITextView` unchanged. Keep the same Auto Layout constraints (leading/trailing/top/bottom 14). Remove any `label.numberOfLines = 0` line (not a UITextView property); the disabled-scroll text view auto-sizes to its content.

- [ ] **Step 2: Add the word hit-test method**

Add to `ParagraphCardCell`:

```swift
    /// Maps a point in `contentView` coordinates to the index of the word under
    /// it (over `wordRanges`), or nil if the point is outside any word glyph.
    func wordIndex(at point: CGPoint) -> Int? {
        let local = contentView.convert(point, to: label)
        guard label.bounds.contains(local) else { return nil }
        // Character index nearest the touch via the text view's layout.
        let charIndex = label.layoutManager.characterIndex(
            for: local, in: label.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < (label.attributedText?.length ?? 0) else { return nil }
        return wordRanges.firstIndex { NSLocationInRange(charIndex, $0) }
    }
```

- [ ] **Step 3: Apply the identical conversion to `HeadingCardCell.swift`**

Replace its `UILabel` (which sets `font`/`adjustsFontForContentSizeCategory`) with the same non-selectable `UITextView` setup (set its `font` after creation as the original did, or leave font to `configure`), keep constraints, and add the same `wordIndex(at:)` method. The `applyWordHighlight`/`configure` `label.attributedText` calls are unchanged.

- [ ] **Step 4: Build + read-back**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: `** TEST BUILD SUCCEEDED **`. In your report, confirm: (a) both cells compile with the UITextView host; (b) `configure`/`applyWordHighlight` still set `label.attributedText` (karaoke preserved); (c) constraints unchanged; (d) SPDX line 1.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/Cells/ParagraphCardCell.swift EchoCore/Views/Cells/HeadingCardCell.swift
git commit -m "feat(reader): non-selectable UITextView cell host with wordIndex(at:) hit-test"
```

---

### Task 3: Look Up + Save word via the existing context menu

**Files:**
- Create: `EchoCore/Views/DictionaryLookupPresenter.swift`
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift` (thread the menu `point:` → resolve word on the cell, pass word context to the menu builder), `EchoCore/Views/ReaderTab+Alignment.swift` (`buildContextMenu` prepends Look Up + Save).

**Interfaces:**
- Consumes: `ParagraphCardCell/HeadingCardCell.wordIndex(at:)` (Task 2), `VocabularyCardBuilder`/`WordSentenceContext`/`FlashcardDAO.vocabularyCard` (Task 1), `FreeTierGate`, `PlayerModel`.

- [ ] **Step 1: Dictionary presenter**

Create `EchoCore/Views/DictionaryLookupPresenter.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Presents the on-device dictionary (`UIReferenceLibraryViewController`) for a term.
enum DictionaryLookupPresenter {
    static func hasDefinition(for term: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    @MainActor
    static func present(term: String) {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(UIReferenceLibraryViewController(term: term), animated: true)
    }
}
```

- [ ] **Step 2: Resolve the word at the menu point and pass it to the builder**

In `ReaderFeedCollectionView.swift`, the delegate method `contextMenuConfigurationForItemsAt:point:` currently calls `onContextMenu?(block)`. Change it to resolve the word at `point` on the cell and pass it through. Update the coordinator's `onContextMenu` closure type from `(EPubBlockRecord) -> UIContextMenuConfiguration?` to `(EPubBlockRecord, _ word: ReaderWordHit?) -> UIContextMenuConfiguration?`, where:

```swift
    /// A resolved word under a long-press: its block, index, text, and audio start.
    struct ReaderWordHit {
        let blockID: String
        let wordIndex: Int
        let word: String
    }
```

In the delegate, after fetching the `.block(block)` item and its `indexPath`, resolve the hit:

```swift
    var wordHit: ReaderWordHit?
    if let cell = collectionView.cellForItem(at: indexPath) {
        let pointInCell = collectionView.convert(point, to: cell)
        let idx = (cell as? ParagraphCardCell)?.wordIndex(at: pointInCell)
            ?? (cell as? HeadingCardCell)?.wordIndex(at: pointInCell)
        if let idx, idx < /* word count for the block */ 0 == false {
            let words = WordTokenizer.words(in: block.text ?? "")  // see note
            if idx < words.count {
                wordHit = ReaderWordHit(blockID: block.id, wordIndex: idx, word: words[idx])
            }
        }
    }
    return onContextMenu?(block, wordHit)
```

> NOTE: derive the tapped word's *string* from the same tokenizer the ranges come from. If `WordTokenizer` exposes only ranges, add a tiny `static func words(in:) -> [String]` next to `wordRanges(in:)` (map each range to its substring) in `Shared/WordTokenizer.swift`, or read the substring from `block.text` using `WordTokenizer.wordRanges(in:)[idx]`. Use whichever exists; do not duplicate tokenization logic.

- [ ] **Step 3: Prepend Look Up + Save to the menu**

In `ReaderTab+Alignment.swift`, change `buildContextMenu(block:)` to `buildContextMenu(block:word:)` (accept the `ReaderWordHit?`). At the top of the actions array, when `word != nil` and `DictionaryLookupPresenter.hasDefinition(for: word.word)`, prepend:

```swift
    if let hit = word {
        let term = hit.word
        if DictionaryLookupPresenter.hasDefinition(for: term) {
            actions.append(UIAction(title: "Look Up “\(term)”", image: UIImage(systemName: "character.book.closed")) { _ in
                DictionaryLookupPresenter.present(term: term)
            })
        }
        actions.append(UIAction(title: "Save “\(term)”", image: UIImage(systemName: "text.badge.plus")) { [weak model] _ in
            saveVocabularyWord(hit, in: block, model: model)
        }
    }
```

(Insert these as the FIRST children so they lead the menu; keep all existing actions after.) Wire `onContextMenu` in `ReaderTab.swift` to call `buildContextMenu(block: block, word: word)`.

- [ ] **Step 4: Implement `saveVocabularyWord` (cap + dedupe + build + insert)**

Add to `ReaderTab+Alignment.swift` (or a small `ReaderTab+Vocabulary.swift` if the file is large):

```swift
    func saveVocabularyWord(_ hit: ReaderFeedCollectionView.ReaderWordHit,
                            in block: EPubBlockRecord, model: PlayerModel?) {
        guard let model, let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        // Pro cap (D6)
        guard freeTierGate.canCreateFlashcards(adding: 1) else {
            model.paywallContext = .flashcardCap
            model.showPaywall = true
            return
        }
        let dao = FlashcardDAO(db: db.writer)
        // Dedupe (D7): re-surface existing
        if let existing = try? dao.vocabularyCard(for: audiobookID, word: hit.word) {
            Haptic.play(.light)
            _ = existing  // already saved; nothing to do (M4 may navigate to it)
            return
        }
        // Audio anchor from the word cache (fallback to block start)
        let times = viewModel?.wordTiming(blockID: hit.blockID, wordIndex: hit.wordIndex)
        let context = WordSentenceContext.sentence(
            containing: WordTokenizer.wordRanges(in: block.text ?? "")[hit.wordIndex],
            in: block.text ?? "")
        let card = VocabularyCardBuilder.make(
            id: UUID().uuidString, audiobookID: audiobookID, word: hit.word,
            contextSentence: context, blockID: hit.blockID,
            audioStart: times?.start ?? (viewModel?.audioStartTime(for: hit.blockID, audiobookID: audiobookID) ?? 0),
            audioEnd: times?.end, createdAt: Date().ISO8601Format())
        do { try dao.insert(card); Haptic.play(.success) }
        catch { Haptic.play(.error) }
    }
```

> NOTE: `viewModel?.wordTiming(blockID:wordIndex:)` may not exist — if not, add a small lookup on `ReaderFeedViewModel` that searches the existing `wordCache` for `(blockID, wordIndex)` and returns `(start, end)`, OR query `WordTimingDAO(db:).words(forAudiobook:blockID:)[wordIndex]`. Reuse `wordCache`; do not add a new fetch on the hot path.

- [ ] **Step 5: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → expect SUCCEEDED.

```bash
git add EchoCore/Views/DictionaryLookupPresenter.swift EchoCore/Views/ReaderFeedCollectionView.swift EchoCore/Views/ReaderTab+Alignment.swift EchoCore/Views/ReaderTab.swift Shared/WordTokenizer.swift
git commit -m "feat(reader): Look Up + Save word in the card-feed long-press menu"
```

---

### Task 4: Word-tap-to-seek refinement

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift` (add a tap gesture that resolves the word at the tap location and seeks), `EchoCore/Views/ReaderTab.swift` (refine `tapBlock` → seek to a specific word when available).

**Interfaces:**
- Consumes: `wordIndex(at:)` (Task 2), `wordCache`/`WordTimingDAO`, `PlayerModel.seek(toSeconds:)`.

- [ ] **Step 1: Add a word-resolving tap that refines block tap-to-seek**

The collection view already seeks-to-block via `didSelectItemAt` → `onTapBlock(block.id)`. Refine it to word granularity by capturing the tap location. Add a `UITapGestureRecognizer` to the collection view (in the coordinator's setup) whose handler:

```swift
    @objc func handleWordTap(_ gr: UITapGestureRecognizer) {
        let pt = gr.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: pt),
            let itemID = dataSource?.itemIdentifier(for: indexPath),
            case .block(let block)? = card(for: itemID),
            let cell = collectionView.cellForItem(at: indexPath)
        else { return }
        let pointInCell = collectionView.convert(pt, to: cell)
        let wordIdx = (cell as? ParagraphCardCell)?.wordIndex(at: pointInCell)
            ?? (cell as? HeadingCardCell)?.wordIndex(at: pointInCell)
        onTapWord?(block.id, wordIdx)   // wordIdx may be nil → block-level seek
    }
```

Set `gr.cancelsTouchesInView = false` so it does not swallow other touches, and add it so it coexists with the collection view's own selection (it resolves the word but lets `didSelectItemAt` remain the fallback path). Expose `onTapWord: ((String, Int?) -> Void)?`.

- [ ] **Step 2: Seek to the word in ReaderTab**

In `ReaderTab.swift`, wire `onTapWord` to a refined handler that reuses the existing seek path:

```swift
    private func tapWord(_ blockID: String, _ wordIndex: Int?) {
        guard let vm = viewModel else { return }
        let audiobookID = folderURL.absoluteString
        let wordTime = wordIndex.flatMap { vm.wordTiming(blockID: blockID, wordIndex: $0)?.start }
        let time = wordTime ?? vm.audioStartTime(for: blockID, audiobookID: audiobookID)
        switch CardTapDecision.make(time: time) {
        case .seekAndPlay(let seconds):
            model.seek(toSeconds: seconds)
            if !model.isPlaying { model.play() }
        case .noTime:
            Haptic.play(.light)
        }
        viewModel?.activeBlockID = blockID
        model.readerCaptureAnchorBlockID = blockID
    }
```

Keep the existing `tapBlock`/`onTapBlock` path intact as the fallback for non-text taps; `onTapWord` simply provides finer seeks when a word is hit.

- [ ] **Step 3: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → expect SUCCEEDED.

```bash
git add EchoCore/Views/ReaderFeedCollectionView.swift EchoCore/Views/ReaderTab.swift
git commit -m "feat(reader): word-tap-to-seek refines block tap to the tapped word"
```

---

## On-device verification (required before merge — cannot be done in the build-only loop)

With a narrated EPUB or narrated PDF (reflow mode) open and playing:
1. Long-press a word → menu leads with **Look Up "<word>"** (opens the dictionary) and **Save "<word>"**; the existing block actions still follow.
2. **Save "<word>"** creates a vocabulary card (check the study feed); a second save of the same word is deduped (haptic, no duplicate); over the free cap → paywall.
3. Tap a word → playback seeks to that word (finer than block start); tapping an un-narrated word → light haptic.
4. Karaoke highlight still tracks word-by-word (UITextView host didn't regress it); scrolling is smooth; Dynamic Type still scales; VoiceOver reads the text.
5. The existing block context menu (Auto-Align, Change Color, bookmark, copyText) and block tap-to-seek still work for taps that don't land on a word.

## Out of scope for M2

- macOS parity (Mac reader is a separate SwiftUI path).
- In-place highlight/define on the PDF *page* (M3).
- Vocabulary-card review surfacing, narrate-PDF affordance (M4).

## Self-review notes

- **Spec coverage (M2 revised):** non-selectable UITextView host (T2) ✓; `wordIndex(at:)` hit-test (T2) ✓; Look Up via `UIReferenceLibraryViewController` (T3) ✓; Save → vocabulary flashcard with cap (D6) + dedupe (D7) (T1+T3) ✓; word-tap-to-seek (T4) ✓; iOS-only ✓.
- **Risk:** T2/T3/T4 are runtime-behavioral; build-green is necessary but not sufficient — the on-device checklist above is the real gate. T4's tap gesture coexistence with `didSelectItemAt` is the highest-risk item; if it misbehaves on-device, fall back to resolving the word inside the existing `didSelectItemAt` path using the last-touch location, or defer T4.
- **Type consistency:** `ReaderWordHit` defined in T3 Step 2 is used in T3 Step 4; `wordIndex(at:)` from T2 used in T3 + T4; `VocabularyCardBuilder.make`/`vocabularyCard(for:word:)` from T1 used in T3.
