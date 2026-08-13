# First-Run Shell (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the shipped 4-step onboarding slideshow with an action-first first-run landing surface, and stop a returning user with moved/deleted files from hitting the same dead end as a newcomer.

**Architecture:** Echo's no-book "Now Playing" surface already shows `NowPlayingEmptyState`, and `RootTabView` presents the slideshow `OnboardingView` on first launch. This phase introduces `FirstRunLandingView` (action-first: open a folder, optional bundled-manual hook, connect a server, plus the no-copy reassurance every new user must see), wires it in place of both the slideshow and `NowPlayingEmptyState`, deletes the slideshow trio, and adds a stale-file recovery path mirroring #199's "Folder Access Not Saved" alert. Source of truth: [the first-run design spec](../specs/2026-06-26-first-run-experience-design.md) §3.1, §3.2, §3.8.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`). Tests in this area are source-string assertions over view files (see `Wedge3ClarityOnRampTests`) plus behavioral unit tests for `Persistence` via injected closures.

## Global Constraints

- **Swift 6 language mode** (migrated in #195): SwiftUI views are `@MainActor` by default — keep new views/model mutations on the main actor; no added `@MainActor` annotations needed for `View` types.
- **SPDX header on line 1** of every Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later`. A PostToolUse SwiftFormat hook reflows the whole file on edit and can push the header below an import — after each edit, confirm the SPDX line is still line 1.
- **16 GB build discipline:** never run two `xcodebuild` invocations concurrently and never enable parallel testing. Use the `make` targets only. If a build is blocked by the memory gate, prefix with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`.
- **Test commands:** `make build-tests` once after a code change, then `make test-only FILTER=EchoTests/<Suite>`. The `make` test targets already pass `CODE_SIGNING_ALLOWED=NO`.
- **Synchronized file groups:** new/deleted `.swift` files under `EchoCore/` are picked up automatically — no `Echo.xcodeproj/project.pbxproj` edits.
- **Copy conventions:** Title Case for button labels (matches existing "Choose Book"/"Add Document"); sentence case for body/description text.
- **Branch:** work on the current feature branch (`claude/ecstatic-borg-a7e8df`); commit per task; do not push protected branches.

---

### Task 1: Distinguish "no book" from "book files missing" in Persistence

**Files:**
- Modify: `EchoCore/Services/Persistence.swift:234-271`
- Test: `EchoTests/PersistenceBookmarkSecurityTests.swift` (add to existing suite)

**Interfaces:**
- Consumes: existing `Persistence(defaults:saveSecurityScopedBookmarkData:loadSecurityScopedBookmarkData:)` test initializer; existing `bookmarkKey`, `loadSecurityScopedBookmarkData()`, `saveSecurityScopedBookmarkData(_:)`, `saveBookmark(url:)`.
- Produces: `enum BookmarkRestoreResult: Equatable { case restored(URL); case none; case missing }` and `func restoreBookmarkResult() -> BookmarkRestoreResult`. `restoreBookmark() -> URL?` is kept as a thin wrapper (returns the URL only for `.restored`), so existing callers/tests are unaffected.

- [ ] **Step 1: Write the failing tests**

Add these two `@Test` functions inside `struct PersistenceBookmarkSecurityTests` in `EchoTests/PersistenceBookmarkSecurityTests.swift` (they reuse the existing private `makeDefaults()` helper):

```swift
    @Test func restoreBookmarkResultIsNoneWhenNothingSaved() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = Persistence(
            defaults: defaults,
            saveSecurityScopedBookmarkData: { _ in true },
            loadSecurityScopedBookmarkData: { nil }
        )

        #expect(persistence.restoreBookmarkResult() == .none)
    }

    @Test func restoreBookmarkResultIsMissingWhenBookmarkUnresolvable() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let junk = Data("not-a-bookmark".utf8)
        let persistence = Persistence(
            defaults: defaults,
            saveSecurityScopedBookmarkData: { _ in true },
            loadSecurityScopedBookmarkData: { junk }
        )

        #expect(persistence.restoreBookmarkResult() == .missing)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/PersistenceBookmarkSecurityTests
```
Expected: compile error — `restoreBookmarkResult` / `BookmarkRestoreResult` are undefined.

- [ ] **Step 3: Implement the result type and method**

In `EchoCore/Services/Persistence.swift`, replace the existing `restoreBookmark()` function (lines 234-271) with the enum plus a result-returning method and a thin wrapper. Keep all other logic identical:

```swift
    enum BookmarkRestoreResult: Equatable {
        /// A saved bookmark resolved to a usable folder URL.
        case restored(URL)
        /// No bookmark has ever been saved (fresh install / never picked a book).
        case none
        /// A bookmark existed but no longer resolves — the files were moved or deleted.
        case missing
    }

    /// Resolves the persisted security-scoped bookmark, distinguishing "nothing
    /// saved" from "saved but the files are gone" so callers can surface a
    /// recovery prompt for the latter (the former is a normal first launch).
    func restoreBookmarkResult() -> BookmarkRestoreResult {
        // Migration: if Keychain is empty but UserDefaults has legacy data,
        // move it to Keychain and clean up the plaintext copy.  (§6.2)
        var data = loadSecurityScopedBookmarkData()
        if data == nil, let legacy = defaults.data(forKey: bookmarkKey) {
            let success = saveSecurityScopedBookmarkData(legacy)
            if success {
                defaults.removeObject(forKey: bookmarkKey)
                data = legacy
            } else {
                os_log(
                    .error,
                    "Legacy security-scoped bookmark migration failed; folder must be reselected"
                )
                return .none
            }
        }
        guard let data else { return .none }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveBookmark(url: url)
            }

            return .restored(url)
        } catch {
            os_log(.error, "Bookmark restore failed: %{private}@", error.localizedDescription)
            return .missing
        }
    }

    func restoreBookmark() -> URL? {
        if case .restored(let url) = restoreBookmarkResult() { return url }
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/PersistenceBookmarkSecurityTests
```
Expected: PASS — all 6 tests (4 existing + 2 new) green. The 3 pre-existing `restoreBookmark*` tests still pass because the wrapper preserves the old return contract.

- [ ] **Step 5: Confirm the SPDX header is still line 1**

Run:
```bash
head -1 EchoCore/Services/Persistence.swift
```
Expected: `// SPDX-License-Identifier: GPL-3.0-or-later`

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Persistence.swift EchoTests/PersistenceBookmarkSecurityTests.swift
git commit -m "feat(persistence): distinguish missing-files from no-selection on restore"
```

---

### Task 2: Surface a recovery prompt when the last book's files are missing

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift:108` (add flag) and `:1122-1132` (restore switch)
- Modify: `EchoCore/Views/RootTabView.swift:359` (add alert after the existing "Folder Access Not Saved" alert)
- Test: `EchoTests/Wedge3ClarityOnRampTests.swift` (add one source-assertion test)

**Interfaces:**
- Consumes: `Persistence.restoreBookmarkResult()` / `BookmarkRestoreResult` from Task 1; existing `loadFolder(_:autoplay:)`, `MockMediaProvider.sampleAudiobookURL()`, and the `@Bindable var model` already in `RootTabView.body`.
- Produces: `PlayerModel.showingMissingBookWarning: Bool` (observable), set `true` only on `.missing`.

- [ ] **Step 1: Write the failing test**

Add this `@Test` function inside `struct Wedge3ClarityOnRampTests` in `EchoTests/Wedge3ClarityOnRampTests.swift`:

```swift
    @Test func missingBookFilesSurfaceRecovery() throws {
        let root = try Self.viewSource(named: "RootTabView.swift")

        #expect(root.contains("model.showingMissingBookWarning"))
        #expect(root.contains("may have moved or been deleted"))
        #expect(root.contains("Button(\"Choose Book\")"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: FAIL — `missingBookFilesSurfaceRecovery` fails (strings absent). The other tests in the suite still pass.

- [ ] **Step 3: Add the observable flag to PlayerModel**

In `EchoCore/ViewModels/PlayerModel.swift`, directly after the existing line 108 `var showingBookmarkPersistenceWarning: Bool = false`, add:

```swift
    /// Set when a previously-open book can't be restored because its files were
    /// moved or deleted. Drives the "Can't Find This Book's Files" recovery alert.
    var showingMissingBookWarning: Bool = false
```

- [ ] **Step 4: Switch the restore path on the richer result**

In `EchoCore/ViewModels/PlayerModel.swift`, replace the body of `restoreLastSelectionIfPossible()` (lines 1122-1132) with:

```swift
    func restoreLastSelectionIfPossible() {
        switch persistence.restoreBookmarkResult() {
        case .restored(let url):
            loadFolder(url, autoplay: false)
        case .missing:
            showingMissingBookWarning = true
        case .none:
            #if DEBUG && targetEnvironment(simulator)
                if let sampleURL = MockMediaProvider.sampleAudiobookURL() {
                    loadFolder(sampleURL, autoplay: false)
                }
            #endif
        }
    }
```

- [ ] **Step 5: Add the recovery alert to RootTabView**

In `EchoCore/Views/RootTabView.swift`, immediately after the existing "Folder Access Not Saved" alert block (the one ending at line 359), add a second alert:

```swift
        .alert(
            "Can’t Find This Book’s Files",
            isPresented: $model.showingMissingBookWarning
        ) {
            Button("OK", role: .cancel) {}
            Button("Choose Book") { showingFolderPicker = true }
        } message: {
            Text(
                "The files for your last book may have moved or been deleted. Choose the book again to keep listening."
            )
        }
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: PASS — `missingBookFilesSurfaceRecovery` green; all other suite tests still green.

- [ ] **Step 7: Confirm SPDX headers are still line 1**

Run:
```bash
head -1 EchoCore/ViewModels/PlayerModel.swift EchoCore/Views/RootTabView.swift
```
Expected: each prints `// SPDX-License-Identifier: GPL-3.0-or-later`.

- [ ] **Step 8: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoCore/Views/RootTabView.swift EchoTests/Wedge3ClarityOnRampTests.swift
git commit -m "feat(first-run): recover gracefully when a restored book's files are missing"
```

---

### Task 3: Create the action-first landing view

**Files:**
- Create: `EchoCore/Views/FirstRunLandingView.swift`
- Test: `EchoTests/Wedge3ClarityOnRampTests.swift` (add one source-assertion test)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `FirstRunLandingView(onOpenFolder: () -> Void, onOpenHelp: () -> Void, onConnectServer: () -> Void, onPlayManual: (() -> Void)? = nil)`. `onPlayManual` is the phase-2 hook for the seeded bundled manual; when `nil` the manual button is hidden so phase 1 never ships a dead button.

- [ ] **Step 1: Write the failing test**

Add this `@Test` function inside `struct Wedge3ClarityOnRampTests` in `EchoTests/Wedge3ClarityOnRampTests.swift`:

```swift
    @Test func firstRunLandingIsActionFirst() throws {
        let landing = try Self.viewSource(named: "FirstRunLandingView.swift")

        #expect(landing.contains("Welcome to Echo"))
        #expect(landing.contains("Start listening in seconds"))
        #expect(landing.contains("Button(\"Open a Folder\", systemImage: \"folder\""))
        #expect(landing.contains("Connect a Server"))
        #expect(landing.contains("it never copies them"))
        #expect(landing.contains("How do I add books?"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: FAIL — `firstRunLandingIsActionFirst` fails (file `FirstRunLandingView.swift` not found → `viewSource` throws `fileNoSuchFile`).

- [ ] **Step 3: Create the landing view**

Create `EchoCore/Views/FirstRunLandingView.swift` with exactly:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Action-first first-run surface shown whenever no book is open. Replaces the
/// dismissible onboarding slideshow with a "do something now" screen: open a
/// folder (primary), optionally play the bundled manual, connect a server, plus
/// the no-copy reassurance every new user must see.  (Design spec §3.2)
struct FirstRunLandingView: View {
    let onOpenFolder: () -> Void
    let onOpenHelp: () -> Void
    let onConnectServer: () -> Void
    /// Non-nil once the bundled manual is seeded (phase 2). When nil, the manual
    /// action is hidden so phase 1 never shows a non-functional button.
    var onPlayManual: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Welcome to Echo")
                    .font(.title2.weight(.semibold))
                Text("Start listening in seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button("Open a Folder", systemImage: "folder", action: onOpenFolder)
                    .buttonStyle(.borderedProminent)

                if let onPlayManual {
                    Button(
                        "Play the Welcome Manual",
                        systemImage: "headphones",
                        action: onPlayManual
                    )
                    .buttonStyle(.bordered)
                }

                Button(
                    "Connect a Server",
                    systemImage: "externaldrive.connected.to.line.below",
                    action: onConnectServer
                )
                .buttonStyle(.bordered)
            }

            VStack(spacing: 6) {
                Label(
                    "Echo plays your files where they live — it never copies them. Keep the originals where they are.",
                    systemImage: "shield.checkered"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

                Button("How do I add books?", action: onOpenHelp)
                    .font(.footnote)
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: 420)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: PASS — `firstRunLandingIsActionFirst` green; the rest of the suite still green.

- [ ] **Step 5: Confirm the SPDX header is line 1**

Run:
```bash
head -1 EchoCore/Views/FirstRunLandingView.swift
```
Expected: `// SPDX-License-Identifier: GPL-3.0-or-later`

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/FirstRunLandingView.swift EchoTests/Wedge3ClarityOnRampTests.swift
git commit -m "feat(first-run): add action-first landing view"
```

---

### Task 4: Wire the landing in, remove the slideshow, update the Wedge 3 tests

**Files:**
- Modify: `EchoCore/Views/NowPlayingTab.swift:8` (add property) and `:31-35` (swap empty state for landing)
- Modify: `EchoCore/Views/RootTabView.swift:123` (remove flag), `:172-177` (pass `onConnectServer`), `:267-269` (remove slideshow sheet), `:468-477` (remove `firstLaunchOnboardingBinding`)
- Delete: `EchoCore/Views/OnboardingView.swift`, `EchoCore/Views/OnboardingStep.swift`, `EchoCore/Views/OnboardingStepPage.swift`, `EchoCore/Views/NowPlayingEmptyState.swift`
- Modify: `EchoTests/Wedge3ClarityOnRampTests.swift` (replace the two slideshow tests)

**Interfaces:**
- Consumes: `FirstRunLandingView` (Task 3); existing `NowPlayingTab` properties `openFolder`/`showHelp`/`showBookSettings`; `showingSettings` and `showingFolderPicker` state in `RootTabView`.
- Produces: `NowPlayingTab` gains `let onConnectServer: () -> Void`. After this task no code references `OnboardingView`, `OnboardingStep`, `OnboardingStepPage`, `NowPlayingEmptyState`, `hasSeenOnboarding`, or `firstLaunchOnboardingBinding`.

- [ ] **Step 1: Update the Wedge 3 tests (write the new expectations first)**

In `EchoTests/Wedge3ClarityOnRampTests.swift`, **delete** the two slideshow tests `rootPresentsFirstLaunchOnboardingUntilSeen()` (lines 8-14) and `onboardingTeachesCoreWorkflowInFourSteps()` (lines 16-25), and **add** these two:

```swift
    @Test func nowPlayingShowsActionFirstLanding() throws {
        let tab = try Self.viewSource(named: "NowPlayingTab.swift")

        #expect(tab.contains("FirstRunLandingView("))
        #expect(tab.contains("onConnectServer:"))
        #expect(!tab.contains("NowPlayingEmptyState("))
    }

    @Test func rootNoLongerPresentsOnboardingSlideshow() throws {
        let root = try Self.viewSource(named: "RootTabView.swift")

        #expect(!root.contains("OnboardingView()"))
        #expect(!root.contains("firstLaunchOnboardingBinding"))
        #expect(!root.contains("hasSeenOnboarding"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: FAIL — `nowPlayingShowsActionFirstLanding` and `rootNoLongerPresentsOnboardingSlideshow` fail (slideshow still wired, landing not yet in `NowPlayingTab`).

- [ ] **Step 3: Add the connect-server action to NowPlayingTab**

In `EchoCore/Views/NowPlayingTab.swift`, add a property directly after line 8 (`let showBookSettings: () -> Void`):

```swift
    let onConnectServer: () -> Void
```

- [ ] **Step 4: Swap the empty state for the landing**

In `EchoCore/Views/NowPlayingTab.swift`, replace the `NowPlayingEmptyState(...)` block (lines 31-35) with:

```swift
                    FirstRunLandingView(
                        onOpenFolder: openFolder,
                        onOpenHelp: showHelp,
                        onConnectServer: onConnectServer
                    )
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
```

- [ ] **Step 5: Pass the action from RootTabView and remove the slideshow wiring**

In `EchoCore/Views/RootTabView.swift`:

(a) Add `onConnectServer:` to the `NowPlayingTab(...)` call (lines 172-177) so it reads:

```swift
                        NowPlayingTab(
                            showsBookSettings: model.folderURL != nil,
                            openFolder: { showingFolderPicker = true },
                            showHelp: { model.showingHelp = true },
                            showBookSettings: { showingBookSettings = true },
                            onConnectServer: { showingSettings = true }
                        )
```

(b) Delete the slideshow sheet (lines 267-269):

```swift
        .sheet(isPresented: firstLaunchOnboardingBinding) {
            OnboardingView()
        }
```

(c) Delete the `@AppStorage("hasSeenOnboarding")` line (line 123):

```swift
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
```

(d) Delete the `firstLaunchOnboardingBinding` computed property (lines 468-477):

```swift
    private var firstLaunchOnboardingBinding: Binding<Bool> {
        Binding(
            get: { !hasSeenOnboarding },
            set: { isPresented in
                if !isPresented {
                    hasSeenOnboarding = true
                }
            }
        )
    }
```

- [ ] **Step 6: Delete the slideshow and the old empty state**

Run:
```bash
git rm EchoCore/Views/OnboardingView.swift EchoCore/Views/OnboardingStep.swift EchoCore/Views/OnboardingStepPage.swift EchoCore/Views/NowPlayingEmptyState.swift
```

- [ ] **Step 7: Run the full suite to verify everything passes**

Run:
```bash
make build-tests && make test-only FILTER=EchoTests/Wedge3ClarityOnRampTests
```
Expected: PASS — all Wedge 3 tests green (`nowPlayingShowsActionFirstLanding`, `rootNoLongerPresentsOnboardingSlideshow`, `firstRunLandingIsActionFirst`, `missingBookFilesSurfaceRecovery`, `readerEmptyStateIsAnActionableOnRamp`, `studyReviewLaunchFailureIsVisible`).

- [ ] **Step 8: Confirm the app still builds clean (no orphaned references)**

Run:
```bash
make build-tests
```
Expected: BUILD SUCCEEDED — no references remain to the deleted types. (If the build complains about a missing reference, grep the codebase for that symbol and remove the straggler.)

- [ ] **Step 9: Confirm SPDX headers are still line 1**

Run:
```bash
head -1 EchoCore/Views/NowPlayingTab.swift EchoCore/Views/RootTabView.swift
```
Expected: each prints `// SPDX-License-Identifier: GPL-3.0-or-later`.

- [ ] **Step 10: Commit**

```bash
git add EchoCore/Views/NowPlayingTab.swift EchoCore/Views/RootTabView.swift EchoTests/Wedge3ClarityOnRampTests.swift
git commit -m "feat(first-run): replace onboarding slideshow with action-first landing"
```

---

## Notes for later phases (not in scope here)

- **Manual button:** `FirstRunLandingView.onPlayManual` is the seam for phase 2 (bundled-manual seeding). When phase 2 lands, pass a real action from `NowPlayingTab`/`RootTabView`; until then it stays hidden.
- **Connect a Server** currently opens Settings (where Audiobookshelf lives). The one-tap `audiobooks.dev` demo pre-fill (spec §3.6) is a separate task.
- **Companion auto-load**, **content-aware open + auto-play setting**, and the **dismissible nudge system** are later build phases (spec §3.4, §3.5) and intentionally excluded from this shell.

## Self-review

- **Spec coverage:** §3.1 (gate/routing — slideshow removed, landing is the no-book surface) ✓ Task 4; §3.2 (action-first landing + no-copy reassurance + "How do I add books?") ✓ Tasks 3-4; §3.8 (stale-file restore recovery, mirroring the #199 alert) ✓ Tasks 1-2; Wedge3 test rewrite ✓ Task 4. Out-of-scope spec sections (manual seeding §3.3, content-aware/auto-play §3.4, nudges §3.5, ABS demo §3.6, transcription/flashcards §3.7) are explicitly deferred above.
- **Placeholder scan:** none — every step has exact paths, full code, and exact commands with expected output.
- **Type consistency:** `BookmarkRestoreResult`/`restoreBookmarkResult()` defined in Task 1 and consumed in Task 2; `showingMissingBookWarning` defined in Task 2 (PlayerModel) and asserted/used in Task 2 (RootTabView); `FirstRunLandingView` signature defined in Task 3 and called with matching argument labels (`onOpenFolder`/`onOpenHelp`/`onConnectServer`) in Task 4; `onConnectServer` added to `NowPlayingTab` in Task 4 and supplied by `RootTabView` in the same task.
