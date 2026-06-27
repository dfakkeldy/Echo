# PDF Reader M1 — Page ⇄ Reflow Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the visual PDF page surface reachable for a *parsed* PDF book and let the user switch between it and the reflow card feed via a persisted per-book page⇄reflow toggle.

**Architecture:** A parsed/narrated PDF already has visible `epub_block` rows, so `hasEPUB` is true and the Read tab *already* renders the highlightable card feed (`ReaderTab`) — the visual page (`PDFDocumentView`) is currently unreachable for it. M1 introduces a pure `ReaderSurfaceResolver` that recognises a parsed PDF (`hasPDF && hasReflowableBlocks`), a new `PDFReadingSurface` container that hosts both surfaces behind a segmented toggle, persisted per book via `BookPreferencesService`, and a small intercept in `RootTabView`'s `.read` branch. No schema change, no engine change; the reflow highlight is reused as-is.

**Tech Stack:** Swift 6, SwiftUI, PDFKit (`PDFDocumentView` exists), GRDB (read-only here), Swift Testing (`@Suite`/`@Test`/`#expect`), UserDefaults persistence.

## Global Constraints

- **Swift 6 language mode** — Echo's targets are on Swift 6 (`-default-isolation MainActor` in app targets); honor `Sendable`/actor isolation. Pure types here are `Sendable`/nonisolated; the view is `@MainActor` by default.
- **SPDX header on line 1** of every new Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later`. A SwiftFormat PostToolUse hook reflows the whole file on each edit — after any edit, verify the SPDX comment is still line 1.
- **Tests are Swift Testing**, not XCTest: `import Testing`, `@Suite struct`, `@Test func`, `#expect(...)`, `Issue.record(...)`. Module is `Echo` (`@testable import Echo`).
- **New files in `EchoCore/` and `EchoTests/` auto-compile** (project uses `PBXFileSystemSynchronizedRootGroup`) — no `.pbxproj` edits.
- **Build/test commands** (16 GB Mac — never run two `xcodebuild`s concurrently, never enable parallel testing):
  - Compile the app target: `make build-tests` (build-for-testing also compiles the app target; there is **no** `make build` target). Gate-wrapped form below.
  - Build tests once: `make build-tests` (sets `CODE_SIGNING_ALLOWED=NO`).
  - Run one suite: `make test-only FILTER=EchoTests/<SuiteName>`.
  - Gate every build: prefix with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`.
- **Default reader surface for a parsed PDF is `.page`** (spec D1).
- **Branch base `nightly`; PR target `nightly`** (never `main`/`weekly`). Commit at sensible checkpoints (Conventional Commits).
- **Spec:** `docs/superpowers/specs/2026-06-26-pdf-alignment-define-design.md` (this plan implements milestone **M1** only).

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|-----------|
| `EchoCore/Models/ReaderSurfaceMode.swift` | `ReaderSurfaceMode` enum + pure `ReaderSurfaceResolver` (which surfaces a book offers) | **Create** |
| `EchoTests/ReaderSurfaceModeResolverTests.swift` | Unit tests for the resolver | **Create** |
| `EchoCore/Services/BookPreferencesService.swift` | Add per-book PDF view-mode persistence (key + save/load, injectable `UserDefaults`) | **Modify** |
| `EchoTests/ReaderPDFViewModePreferenceTests.swift` | Unit tests for the persistence round-trip | **Create** |
| `EchoCore/Views/PDFReadingSurface.swift` | Container hosting `PDFDocumentView` ⇄ `ReaderTab` behind a persisted segmented toggle | **Create** |
| `EchoCore/Views/RootTabView.swift` | Intercept a parsed PDF in the `.read` branch → render `PDFReadingSurface` | **Modify** (`:185-205`) |

---

### Task 1: `ReaderSurfaceMode` + pure resolver

**Files:**
- Create: `EchoCore/Models/ReaderSurfaceMode.swift`
- Test: `EchoTests/ReaderSurfaceModeResolverTests.swift`

**Interfaces:**
- Produces:
  - `enum ReaderSurfaceMode: String, CaseIterable, Sendable { case page; case reflow }`
  - `enum ReaderSurfaceResolver { static func availableModes(hasPDF: Bool, hasReflowableBlocks: Bool) -> [ReaderSurfaceMode]; static func offersToggle(hasPDF: Bool, hasReflowableBlocks: Bool) -> Bool }`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderSurfaceModeResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderSurfaceModeResolverTests {
    @Test func parsedPDFOffersPageThenReflow() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: true, hasReflowableBlocks: true)
                == [.page, .reflow])
        #expect(ReaderSurfaceResolver.offersToggle(hasPDF: true, hasReflowableBlocks: true))
    }

    @Test func unparsedPDFOffersPageOnly() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: true, hasReflowableBlocks: false)
                == [.page])
        #expect(!ReaderSurfaceResolver.offersToggle(hasPDF: true, hasReflowableBlocks: false))
    }

    @Test func nonPDFOffersNothing() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: false, hasReflowableBlocks: true)
                .isEmpty)
        #expect(!ReaderSurfaceResolver.offersToggle(hasPDF: false, hasReflowableBlocks: true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (does not compile — type missing)**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: FAIL — `cannot find 'ReaderSurfaceResolver' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `EchoCore/Models/ReaderSurfaceMode.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which reading surface a book presents in the Read tab.
enum ReaderSurfaceMode: String, CaseIterable, Sendable {
    /// The original visual PDF page (`PDFDocumentView`).
    case page
    /// The reflow text card feed (`ReaderTab`), with read-along highlight.
    case reflow
}

/// Pure resolver for which reading surfaces a book can offer. Mirrors the
/// style of `TimelineIngestionFactory.strategy(...)` — no DB, no async, just
/// availability flags in, surfaces out.
///
/// A parsed PDF has visible `epub_block` rows (so `hasEPUB`/`hasReflowableBlocks`
/// is true) AND a `.pdf` file, which is why it can present both surfaces.
enum ReaderSurfaceResolver {
    /// Surfaces a book can present, in display order. Empty for non-PDF books
    /// (EPUB/text/transcript keep their single existing surface).
    /// - A parsed PDF (`hasPDF && hasReflowableBlocks`) → `[.page, .reflow]`.
    /// - A PDF with no parsed text (companion-to-external-audio, or scanned)
    ///   → `[.page]`.
    static func availableModes(hasPDF: Bool, hasReflowableBlocks: Bool) -> [ReaderSurfaceMode] {
        guard hasPDF else { return [] }
        return hasReflowableBlocks ? [.page, .reflow] : [.page]
    }

    /// True when the user should see a page⇄reflow toggle (both surfaces exist).
    static func offersToggle(hasPDF: Bool, hasReflowableBlocks: Bool) -> Bool {
        availableModes(hasPDF: hasPDF, hasReflowableBlocks: hasReflowableBlocks).count > 1
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/ReaderSurfaceModeResolverTests`
Expected: PASS — 3 tests pass. Confirm the SPDX comment is still line 1 of `ReaderSurfaceMode.swift` after any formatter run.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Models/ReaderSurfaceMode.swift EchoTests/ReaderSurfaceModeResolverTests.swift
git commit -m "feat(reader): add ReaderSurfaceMode + resolver for PDF page/reflow"
```

---

### Task 2: Per-book PDF view-mode persistence

**Files:**
- Modify: `EchoCore/Services/BookPreferencesService.swift` (add after the `readerCardTintKey` block, ~`:34`)
- Test: `EchoTests/ReaderPDFViewModePreferenceTests.swift`

**Interfaces:**
- Consumes: `ReaderSurfaceMode` (Task 1)
- Produces (static on `BookPreferencesService`):
  - `static func readerPDFViewModeKey(for audiobookID: String) -> String`
  - `static func savePDFViewMode(_ mode: ReaderSurfaceMode?, for audiobookID: String, store: UserDefaults = .standard)`
  - `static func loadPDFViewMode(for audiobookID: String, default fallback: ReaderSurfaceMode = .page, store: UserDefaults = .standard) -> ReaderSurfaceMode`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderPDFViewModePreferenceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderPDFViewModePreferenceTests {
    /// An isolated UserDefaults suite so tests never touch the shared domain.
    private func makeStore() -> UserDefaults {
        let name = "test.pdfviewmode.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func defaultsToPageWhenUnset() {
        let store = makeStore()
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func roundTripsSavedMode() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .reflow)
    }

    @Test func clearingRestoresDefault() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        BookPreferencesService.savePDFViewMode(nil, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func ignoresUnrecognisedRawValue() {
        let store = makeStore()
        store.set("garbage", forKey: BookPreferencesService.readerPDFViewModeKey(for: "book-1"))
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func keysAreScopedPerBook() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-2", store: store) == .page)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: FAIL — `type 'BookPreferencesService' has no member 'loadPDFViewMode'`.

- [ ] **Step 3: Write the minimal implementation**

In `EchoCore/Services/BookPreferencesService.swift`, add this block immediately after `readerCardTintKey(for:)` (currently ending at line 34):

```swift
    // MARK: - Reader PDF view mode

    static func readerPDFViewModeKey(for audiobookID: String) -> String {
        "book_readerPDFViewMode_\(audiobookID)"
    }

    /// Persists the page⇄reflow choice for a PDF book. `nil` clears it (revert
    /// to the default). `store` is injectable for testing; production passes
    /// `.standard`.
    static func savePDFViewMode(
        _ mode: ReaderSurfaceMode?, for audiobookID: String, store: UserDefaults = .standard
    ) {
        let key = readerPDFViewModeKey(for: audiobookID)
        if let mode {
            store.set(mode.rawValue, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    /// Loads the persisted PDF view mode, falling back to `fallback` (default
    /// `.page`, per spec D1) when unset or unrecognised.
    static func loadPDFViewMode(
        for audiobookID: String, default fallback: ReaderSurfaceMode = .page,
        store: UserDefaults = .standard
    ) -> ReaderSurfaceMode {
        guard let raw = store.string(forKey: readerPDFViewModeKey(for: audiobookID)),
            let mode = ReaderSurfaceMode(rawValue: raw)
        else { return fallback }
        return mode
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/ReaderPDFViewModePreferenceTests`
Expected: PASS — 5 tests pass. Verify SPDX is still line 1 of `BookPreferencesService.swift`.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/BookPreferencesService.swift EchoTests/ReaderPDFViewModePreferenceTests.swift
git commit -m "feat(reader): persist per-book PDF page/reflow view mode"
```

---

### Task 3: `PDFReadingSurface` container view

**Files:**
- Create: `EchoCore/Views/PDFReadingSurface.swift`

**Interfaces:**
- Consumes: `ReaderSurfaceMode` (Task 1); `BookPreferencesService.loadPDFViewMode`/`savePDFViewMode` (Task 2); existing `PDFDocumentView(folderURL:)` and `ReaderTab(folderURL:)`; `@Environment(PlayerModel.self)`.
- Produces: `struct PDFReadingSurface: View { let folderURL: URL }`

This task has no unit test (it is SwiftUI view wiring; the testable logic lives in Tasks 1–2). It is verified by a successful build and on-simulator check.

- [ ] **Step 1: Create the view**

Create `EchoCore/Views/PDFReadingSurface.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Hosts a *parsed* PDF book's two reading surfaces — the visual page
/// (`PDFDocumentView`) and the reflow card feed (`ReaderTab`) — behind a
/// per-book page⇄reflow toggle. Only used when both surfaces are available
/// (see `ReaderSurfaceResolver.offersToggle`).
struct PDFReadingSurface: View {
    let folderURL: URL
    @State private var mode: ReaderSurfaceMode = .page

    private var audiobookID: String { folderURL.absoluteString }

    var body: some View {
        Group {
            switch mode {
            case .page:
                PDFDocumentView(folderURL: folderURL)
            case .reflow:
                ReaderTab(folderURL: folderURL)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Reading mode", selection: $mode) {
                Text("Page").tag(ReaderSurfaceMode.page)
                Text("Reflow").tag(ReaderSurfaceMode.reflow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityLabel(Text("Reading mode"))
        }
        // Re-seed the toggle whenever the book changes; `.page` default avoids a flash.
        .task(id: audiobookID) {
            mode = BookPreferencesService.loadPDFViewMode(for: audiobookID)
        }
        .onChange(of: mode) { _, newMode in
            BookPreferencesService.savePDFViewMode(newMode, for: audiobookID)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: `** TEST BUILD SUCCEEDED **`. Verify SPDX is still line 1.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/PDFReadingSurface.swift
git commit -m "feat(reader): PDFReadingSurface hosts page/reflow toggle"
```

---

### Task 4: Wire `PDFReadingSurface` into the Read tab

**Files:**
- Modify: `EchoCore/Views/RootTabView.swift` (the `.read` branch `Group`, `:79-100`)

**Interfaces:**
- Consumes: `ReaderSurfaceResolver.offersToggle` (Task 1); `PDFReadingSurface` (Task 3); `model.hasPDF`, `model.hasEPUB`, `model.folderURL`.

- [ ] **Step 1: Replace the `.read` branch's surface selection**

In `EchoCore/Views/RootTabView.swift`, replace the existing `Group { if model.hasEPUB { ... } else if model.hasPDF { ... } ... }` in the `.read` case (lines 185-205 as of `nightly` @ #199; match by the `if model.hasEPUB {` block, not the literal line number) with the version below. The only change is the **new first branch** that intercepts a parsed PDF; every other branch is unchanged.

```swift
                        Group {
                            // A *parsed* PDF (has a .pdf file AND visible blocks,
                            // so hasEPUB is true) can show either the visual page
                            // or the reflow feed — render the user-selected one.
                            // `hasEPUB` here means "has parsed reflowable blocks".
                            if ReaderSurfaceResolver.offersToggle(
                                hasPDF: model.hasPDF, hasReflowableBlocks: model.hasEPUB),
                                let folder = model.folderURL
                            {
                                PDFReadingSurface(folderURL: folder)
                            } else if model.hasEPUB {
                                ReaderTab(folderURL: model.folderURL!)
                            } else if model.hasPDF {
                                PDFDocumentView(folderURL: model.folderURL!)
                            } else if model.hasStandaloneTranscript,
                                let folder = model.folderURL,
                                let db = model.databaseService
                            {
                                StandaloneTranscriptView(
                                    audiobookID: folder.absoluteString,
                                    db: db.writer
                                )
                            } else {
                                ReaderEmptyState(
                                    hasLoadedBook: model.folderURL != nil,
                                    canAddEPUB: !model.narrationPlaybackState.isRunning,
                                    onImportBook: { showingFolderPicker = true },
                                    onAddEPUB: { model.showingDocumentImporter = true }
                                )
                            }
                        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: `** TEST BUILD SUCCEEDED **`. Verify SPDX is still line 1 of `RootTabView.swift`.

- [ ] **Step 3: On-simulator verification (manual, with a parsed PDF)**

Preconditions: a PDF book that has been imported/parsed (so it has `epub_block` rows). If narrated, it also has audio for the highlight check.

Verify on the iOS simulator:
1. Open the book → **Read** tab. Expected: a **Page | Reflow** segmented control at the top; **Page** selected by default (D1); the visual PDF page is shown.
2. **Check for header overlap** — the segmented control must not be hidden behind/overlapping `UnifiedTopHeader`. If it collides, move the `Picker` from the `.safeAreaInset(edge: .top)` in `PDFReadingSurface` into `UnifiedTopHeader` (gated by `ReaderSurfaceResolver.offersToggle(...) && model.selectedTab == .read`), threading a `Binding<ReaderSurfaceMode>` down. Re-build and re-verify.
3. Tap **Reflow** → the card feed appears; if narrated and playing, the spoken word highlights (reused path, unchanged).
4. Tap **Page** → returns to the page view.
5. Background/relaunch the app (or switch books and back) → the last-chosen mode is restored (persistence).
6. Open a **companion PDF that has external audio** (no parsed blocks) → no toggle; the page is shown as before (regression check).
7. Open an **EPUB** book → no toggle; the card feed is shown as before (regression check).

Capture a screenshot of the parsed-PDF Read tab showing the toggle for the PR.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/RootTabView.swift
git commit -m "feat(reader): surface page/reflow toggle for parsed PDFs in Read tab"
```

---

## Out of scope for M1 (later milestones)

- In-place karaoke highlight **on the PDF page** (M3) — page mode here shows the PDF with no highlight yet.
- Per-word define / Save-to-study / word-tap-to-seek (M2/M4).
- macOS: the Mac reader is `MacReaderFeedView` (no PDF surface today); PDF page/reflow on macOS is a separate effort. M1 is iOS-only.
- A "Narrate this PDF" affordance (M4).

## Self-review notes

- **Spec coverage (M1):** page surface reachable (Task 4) ✓; page⇄reflow toggle (Task 3) ✓; persisted default = page (Tasks 2–3) ✓; pure resolver seam (Task 1) ✓; reflow highlight reused unchanged (no task needed — it already works via `ReaderTab`).
- **Placeholders:** none — every step has concrete code/commands.
- **Type consistency:** `ReaderSurfaceMode`/`ReaderSurfaceResolver` signatures match across Tasks 1→2→3→4; `savePDFViewMode`/`loadPDFViewMode` signatures match between Task 2 definition and Task 3 use.
- **Known risk:** the top `.safeAreaInset` picker may overlap `UnifiedTopHeader`; Task 4 Step 3 carries the explicit check + fallback.
