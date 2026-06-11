# Echo: Audiobook Study Player — Code Audit

Generated 2026-06-09. Scope: ~35,300 LOC across 295 Swift files in targets **Echo (iOS)**, **Echo Watch App**, **Echo WidgetExtension** (watchOS), **Echo macOS**, plus `Shared/` and `Tools/`. Excluded: `build/`, `vendor/`, `scratch/` (audited only as an artifact), `docs/`, `fastlane/`, `Tools/OrbitTranscriptionCLI/.build/` (untracked SPM leftovers), asset catalogs.

Compiler ground truth (at audit time): a forced full rebuild of the **Echo scheme (iOS app + embedded watch app + widget) produced zero source warnings** in Swift 5 language mode with Approachable Concurrency. The **Echo macOS scheme failed to build** — now fixed on the remediation branch (see §5.1). The previous audit (2026-05-31, 55 findings) was fully remediated; 163 Swift files changed since, and this audit weights that delta (auto-alignment, watch sync/Pomodoro, colour-accent pipeline, EPUB import).

Findings cite `path/to/file.swift:LINE`. Every Critical/High was personally verified by opening the cited lines; several agent-reported claims were demoted or dropped after verification (see §12). The audit pass itself made no code changes — remediation followed on `feat/code-audit-remediation`; see **Remediation progress** below for what is done and what remains.

---

## Remediation progress

_Updated 2026-06-10 on branch `feat/code-audit-remaining`. All 34 findings now resolved — 26 in PR #25 (`feat/code-audit-remediation`) + 8 in this branch. Code-complete; the rebrand (§9.5) requires App Store Connect provisioning profile updates before device testing._

**Legend:** ✅ done · 🔶 partial · 🔲 open

### ✅ Done (34)

- **§2 Quick wins** — "Audiobookk" typo (`7c63954`); `print`→`Logger` + `@MainActor` hop (`706ab56`, also §8.3); `TranscriptDidUpdate` constant (`fcc1c30`); CLAUDE.md Tools text (`9710c49`); `build.log` gitignored (`5eb2a02`); Orbit dirs + `scratch/` removed (`ccee339`, also §9.1); `LoopMode`/`SleepTimerMode` → `Models/`.
- **§3.1** WhisperSession unload race → `ModelRetainBox` (`e1a862f`) · **§6.1** zip-slip extraction guard (`15690bb`).
- **§5.1 [Critical]** macOS target revived — WhisperKit linked, orphaned CLI script phase removed, app-group entitlement added (`307c236`, `ba1f439`).
- **§3.2 [High]** hot-path GRDB reads → async (`ef40c2d`) · **§3.4** TimelineService queue → GRDB async write (`44ec744`) · **§3.6** dropped `@unchecked Sendable` on `ReaderCardItem` (`b8106ee`).
- **§4.1** AudioRingBuffer `OSAtomic` → `Synchronization.Atomic` (`b4324ca`) · **§4.2** async `AudioEngine.seek` (`c3f5432`).
- **§5.2** full security-scoped bookmark options (`84916e7`) · **§5.4** artwork palette cache poison (`c82e44b`) · **§5.5 / §5.6 / §5.7** speed-divide / CarPlay unwrap / unbalanced security scope (`b8106ee`) · **§5.8** watch context key-set DEBUG assertion (`3204b69`).
- **§6.2** XML external-entity hardening (`c82e44b`) · **§7.2** watch marquee now paused (`TimelineView(.animation(minimumInterval:paused:))`, code-verified) · **§7.3** cache watch artwork JPEG by version (`d84f554`).
- **§8.1** AutoAlignmentProgressView reads `@Observable` directly, no Timer (`1f6c93f`) · **§8.3** app-icon completion `@MainActor` hop (`706ab56`).
- **§9.2** unified snippet players (`2f51268`) · **§9.4** removed `AudiobookPlayerUIArchitect` scaffold + `add_architect.rb` · **§9.7** named JPEG / watch-message-key constants (`7d1e6bc`).
- **§3.3** Task cancellation — `ContinuousAlignmentService` cancels in-flight work (`2f51268`); ReaderTab `.onDisappear` cancels `autoAlignmentTask`; `TimelineService` load-window Tasks gated by generation counter (`e45685c`).
- **§9.3** macOS dedup — Shared alignment utilities extracted to `Shared/TextAlignmentUtilities.swift`; `MacGlobalAlignmentService` delegates tokenize/score/formatTime to shared free functions; all five macOS Logger sites use `Logger(category:)` instead of hardcoded subsystem (`87bd4a8`).
- **§3.5** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` now set on all 8 targets (was only 2); consistent implicit isolation across all configurations (`e30c0a9`).
- **§5.3** UserDefaults persistence refactored to per-book keys with one-time legacy migration; eliminates unbounded dictionary growth and cross-process write conflicts (`4622b6e`).
- **§6.3** Split shared `Echo.entitlements` into per-target files — watch app and widget each have their own least-privilege entitlements (`4662fcf`).
- **§8.2** ReaderTab alignment-workflow `@State` moved into `ReaderFeedViewModel` — `autoAlignmentTask`, presentation flags, and error state now owned by the ViewModel (`0014dbd`).
- **§8.4** Accessibility labels added to icon-only buttons in Bookmarks view — delete-image, preview-toggle, and delete-voice-memo (`4798ac7`).
- **§9.5** Full rebrand: all `com.orbit*` bundle IDs, app groups, iCloud containers, Keychain service, Logger subsystem, IAP product ID, notification identifier, URL scheme (`orbitaudio://`→`echoaudio://`), playlist manifest (`.orbitplaylist.json`→`.echoplaylist.json`), database file, and widget display name migrated to `com.echo.*` domain (`0f568aa`).

### ⏸ Deferred

- **§9.6** Oversized files (>600 LOC) — refactor when next touched; not a blocking issue for v1.0.

---

## 1. Executive summary

Top items, in priority order:

1. **[Critical] The Echo macOS target does not build — two independent root causes** — §5.1 — `Echo macOS/Services/MacGlobalAlignmentService.swift:4` + `Echo.xcodeproj/project.pbxproj:577-601`.
2. **[High] Zip-slip path traversal in EPUB extraction** — §6.1 — `EchoCore/Services/EPUBAutoImportScanner.swift:314-321`. A malicious EPUB can write outside its destination directory (inside the sandbox), including over the app's own data.
3. **[High] `WhisperSession.forceUnload()` race guard is self-defeating** — §3.1 — `EchoCore/Services/WhisperSession.swift:70-80`. The generation snapshot is taken *inside* the unload Task, so the guard always passes and can unload a freshly re-acquired model.
4. **[High] Synchronous GRDB work on the main actor (23 call sites)** — §3.2 — `DAO(db: db.writer)` pattern across `EchoCore/Services/`.
5. **[Medium] Security-scoped bookmark saved with `.minimalBookmark`** — §5.2 — `EchoCore/Services/Persistence.swift:172-178`. May not survive relaunch as a security-scoped grant.
6. **[Medium] `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on only 2 of 5 targets** — §3.5 — same `Shared/` source compiles with different implicit isolation per target.
7. **[Medium] Rebrand residue is a decision, not a cleanup** — §9.5 — bundle IDs, app-group/iCloud container IDs, logger subsystem all still `com.orbit*`; changing them breaks app/CloudKit identity, so decide deliberately before first release.
8. **[Medium] Progress view polls `@Observable` state on a 0.3 s timer** — §8.1 — `EchoCore/Views/AutoAlignmentProgressView.swift:132-157`.
9. **[Medium] Watch marquee runs `TimelineView(.animation)` at frame rate whenever the title overflows** — §7.2 — `Echo Watch App/Views/PlayerPage.swift:911-947`.
10. **[Medium] Two parallel audio snippet players** — §9.2 — `SnippetPlayer.swift` vs `AudioSnippetPlayer.swift`.

---

## 2. Quick wins (≤30 min each)

- **Fix user-visible display-name typo "Audiobookk"** — `Echo.xcodeproj/project.pbxproj:709` and `:751` (`INFOPLIST_KEY_CFBundleDisplayName` for Echo macOS, Debug + Release).
- **Replace the only bare `print()` with `Logger`** — `EchoCore/Views/SettingsView.swift:315` (app-icon change failure path). See also §8.3.
- **Delete the empty rebrand leftover directories** — `OrbitAudioBooks/` (assets only) and `Orbit Audiobooks macOS/` (empty). Zero references in `project.pbxproj` (verified).
- **Untrack `scratch/`** — `scratch/NowPlayingTab_before.swift`, `scratch/NowPlayingTab_after.swift`, and 4 icon SVGs are git-tracked design leftovers; move anything worth keeping into `docs/` and gitignore the rest.
- **Delete untracked tool leftovers** — `Tools/OrbitTranscriptionCLI/` (only `.build/` + `Package.resolved` remain; package was deleted from git) and `Tools/__pycache__/`. Add `build.log` to `.gitignore` explicitly.
- **Extract the `"TranscriptDidUpdate"` notification name literal** — `Echo macOS/Views/TranscriptStore.swift:29`, `Echo macOS/Views/TranscriptionManager.swift:184`, `:255` → one `Notification.Name` constant.
- **Move model enums out of Services/** — `EchoCore/Services/LoopMode.swift`, `EchoCore/Services/SleepTimerMode.swift` → `EchoCore/Models/`.
- **Fix stale CLAUDE.md project context** — `CLAUDE.md:9` still describes the "SwiftUI CLI" in `Tools/`, which was deleted in the rebrand commit (`751e89c`).

---

## 3. Concurrency

### 3.1 `WhisperSession.forceUnload()` captures its generation snapshot too late
- **Status:** ✅ **FIXED 2026-06-09** (TDD). The reference-counted lifecycle was extracted into `EchoCore/Services/ModelRetainBox.swift` (`@MainActor`, generic, injected load/unload closures); both `release()` and `forceUnload()` now call one `scheduleUnload(ifGenerationEquals:)` helper that takes the snapshot as a synchronously-evaluated **argument**, making late capture impossible by construction. `WhisperSession` is now a thin adapter over the box. Regression test: `EchoTests/ModelRetainBoxTests.swift::forceUnloadDoesNotEvictAModelReacquiredBeforeTheUnloadRuns` (watched RED against the original bug, now GREEN). The box also tracks its `pendingUnload` task, which resolves the WhisperSession half of §3.3.
- **Location:** `EchoCore/Services/WhisperSession.swift:70-80` (compare the correct pattern in `release()`, `:49-66`)
- **What:** `release()` snapshots `generation` *before* spawning the unload Task; `forceUnload()` reads `capturedGeneration` *inside* the Task body, so the guard compares `generation` to itself and always passes.
- **Why:** The documented protection ("don't nil out a freshly-loaded model") is dead code in `forceUnload()`. Sequence: `forceUnload()` → `acquire()` (book switched, model reloads) → stale Task runs → unloads and nils the model a live caller just received. Cancel-then-restart alignment is the stated use case for `forceUnload()`, so this is user-reachable.
- **Action:** Hoist the `let capturedGeneration = generation` line outside the `Task` closure, mirroring `release()`. Consider one shared `scheduleUnload(after:)` helper so the pattern exists once.
- **Severity:** High

### 3.2 Synchronous GRDB reads/writes on the main actor
- **Location:** 23 sites matching `DAO(db: db.writer)` under `EchoCore/Services/` — hot examples: `InlineFlashcardTriggerController.swift` (runs during playback ticks), `PlayerTimelinePersistenceService.swift`, `ChapterLoadingCoordinator.swift`, `TimelineIngestionService.swift`, `EPUBAutoImportScanner.swift`, `PDFImportCoordinator.swift`
- **What:** `@MainActor` services construct DAOs over `db.writer` and execute queries synchronously on the main thread.
- **Why:** GRDB serializes internally so this is safe, but it blocks the main thread for the duration of each query; EPUB transcript tables hold thousands of block rows per book, so worst-case reads can produce visible jank — and under a future Swift 6 / DatabaseActor migration each site needs touching anyway.
- **Action:** Profile the per-tick and per-gesture paths first (Instruments → Time Profiler, main thread); convert hot paths to GRDB's async `read`/`write` or `ValueObservation`. One-shot loads at import time can stay synchronous.
- **Severity:** High

### 3.3 Unstructured `Task {}` without cancellation tracking
- **Status:** ✅ **FIXED 2026-06-10.** `ContinuousAlignmentService` stores `transcriptionTask` and cancels in `stop()` (`2f51268`); `WhisperSession` / `ModelRetainBox` tracks its unload Task as `pendingUnload` (see §3.1); `ReaderTab` cancels `autoAlignmentTask` in `.onDisappear`; `TimelineService` load-window Tasks (`loadEarlier`, `loadLater`, `loadCurrentWindow`) are gated by a `loadGeneration` counter so stale results are dropped when a newer load supersedes them (`e45685c`).
- **Location:** `EchoCore/Services/ContinuousAlignmentService.swift:97-109`; `EchoCore/Services/TimelineService.swift:79`, `:101`, `:123`; `EchoCore/Views/ReaderTab.swift:27`
- **Severity:** Medium

### 3.4 `@MainActor` service hops to a private queue for DB work
- **Location:** `EchoCore/Services/TimelineService.swift:36` (queue declaration), `:172-184` (`pushForwardUncompletedItems`)
- **What:** A `@MainActor` class dispatches onto `pushForwardQueue` capturing `self` and `db.writer`.
- **Why:** Functionally safe today (GRDB locks internally; `Logger` is thread-safe), but capturing MainActor-isolated `self` in a plain queue closure is exactly what Swift 6 strict mode rejects — this is the codebase's main Swift-6-migration exemplar.
- **Action:** Replace the queue with GRDB's own async write API (`try await db.writer.write { … }`) so isolation is compiler-checked; drop `pushForwardQueue`.
- **Severity:** Medium

### 3.5 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` drift across targets
- **Status:** ✅ **FIXED 2026-06-10.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` now set on all 8 targets (all Debug + Release configurations). Previously only the iOS and Watch App targets had it; widget, macOS, and all 4 test targets defaulted to nonisolated. Shared/ files now compile with consistent implicit isolation across every target.
- **Location:** `Echo.xcodeproj/project.pbxproj` (8 targets × 2 configurations = 16 occurrences)
- **Severity:** Medium

### 3.6 Unnecessary `@unchecked Sendable` on `ReaderCardItem`
- **Location:** `EchoCore/Models/ReaderCardItem.swift:54`; payload type `Shared/Database/EPubBlockRecord.swift:6`
- **What:** `ReaderCardItem` is marked `@unchecked Sendable` even though `EPubBlockRecord` already declares plain `Sendable` (it's a value-type GRDB record).
- **Why:** `@unchecked` opts out of compiler verification for a conformance the compiler could verify — it will silently mask a future non-Sendable member.
- **Action:** Replace with a plain `Sendable` conformance; if it doesn't compile, the error identifies the actual unsafe member to fix.
- **Severity:** Low

**Verified clean:** `AudioRingBuffer` is a correctly designed lock-free SPSC buffer (no locks/allocations on the producer side; release/acquire barriers present); `WCSessionDelegate` handlers consistently hop to `@MainActor`; `XMLParser` delegates run synchronously on the calling thread (no cross-thread access); no `nonisolated(unsafe)` anywhere.

---

## 4. API modernity

### 4.1 Deprecated `OSAtomicAdd32Barrier` in the audio ring buffer
- **Location:** `EchoCore/Services/AudioRingBuffer.swift:59`, `:68`, `:83`, `:89`
- **What:** Producer/consumer index publication uses `OSAtomic*` functions, deprecated since iOS 10.
- **Why:** Deprecated-and-flagged API; taking `&head` of a stored property for atomic ops also relies on pointer-stability assumptions Swift doesn't formally guarantee.
- **Action:** Migrate to the `Synchronization` framework's `Atomic<Int32>` (available at the 26.x deployment targets) with `.releasing`/`.acquiring` orderings; semantics map one-to-one onto the existing barriers.
- **Severity:** Medium

### 4.2 Completion-handler seek API bridged with 12 manual main-queue hops
- **Location:** `EchoCore/Services/AudioEngine.swift:150-183` (`seek(to:completion:)`); call sites `EchoCore/Services/PlaybackController.swift:160`, `:317`, `:333`, `:489`, `:509`, `:549`, `:661`, `:693`, `:706`, `:794`, `:847`, `:868`
- **What:** `AudioEngine.seek` takes a completion closure; every `PlaybackController` caller wraps its body in `DispatchQueue.main.async`.
- **Why:** The hops are correct today but unverifiable by the compiler, and each one defers state updates (`isManualSeeking = false`) by a runloop tick whether or not that delay is intentional.
- **Action:** Give `AudioEngine` an `async` seek (and play/pause where applicable); `@MainActor` callers then resume on the right executor automatically and the 12 hops disappear.
- **Severity:** Medium

### 4.3 View-layer `Timer.scheduledTimer` where structured equivalents fit
- **Location:** `EchoCore/Views/AutoAlignmentProgressView.swift:142` (see §8.1), `EchoCore/Views/ManualAlignmentSheet.swift:95`, `:103`, `Echo Watch App/Views/PlayerPage.swift:816`, `Echo Watch App/Views/ContentView.swift:216`
- **What:** Views drive repeating work with Timer + `Task { @MainActor … }` shims.
- **Why:** Lifecycle is manual (invalidate-on-disappear discipline) where `.task(id:)` with an async sleep loop is self-cancelling.
- **Action:** Prefer `.task(id:)`/`Task.sleep` loops in views; keep Timer only where runloop-mode behaviour is actually wanted.
- **Severity:** Low

**Verified clean:** No deprecated SwiftUI API usage found (one-arg `.animation`, `NavigationView`, `UIScreen.main` — all absent); `@Observable` migration is complete (zero `ObservableObject`/`@StateObject`); no stale `#available` guards below the 26.x targets.

---

## 5. Bugs / logic errors

### 5.1 The Echo macOS target does not build (two root causes)
- **Status:** ✅ **FIXED 2026-06-09** (`307c236`, `ba1f439`). Revived the target: linked WhisperKit to Echo macOS, removed the orphaned "Build and Copy OrbitTranscriptionCLI" shell phase, and added the `group.com.echo.audiobooks` app-group entitlement. Remaining cleanup tracked under §9.3 (move the duplicated `Mac*` logic into `Shared/`).
- **Location:** (a) `Echo macOS/Services/MacGlobalAlignmentService.swift:4` — `import WhisperKit` while the WhisperKit product is linked only to the iOS target (`Echo.xcodeproj/project.pbxproj:220`, sole Frameworks entry); (b) `Echo.xcodeproj/project.pbxproj:577-601` — "Build and Copy OrbitTranscriptionCLI" shell phase owned by the macOS target (`:303`), `alwaysOutOfDate = 1`, `set -euo pipefail`, runs `swift build` against `Tools/OrbitTranscriptionCLI/`, a package deleted from git in commit `751e89c` (only untracked `.build/` remains on disk; a fresh clone has nothing)
- **What:** `xcodebuild -scheme "Echo macOS"` fails at compile ("Unable to resolve module dependency: 'WhisperKit'"); even after fixing that, the unguarded script phase fails every build.
- **Why:** The macOS product is entirely dead on main; CI or a fresh contributor cannot build it. Related: `Echo macOS/Views/MacPlayerModel.swift` uses `AppGroupDefaults` but `Echo macOS/Echo_macOS.entitlements` lacks the `group.com.echo.audiobooks` entitlement, so even a fixed build hits the `assertionFailure` guard in `Shared/AppGroupDefaults.swift:11-13`.
- **Action:** Decide the target's fate. To revive: link WhisperKit to Echo macOS, delete the orphaned script phase, add the app-group entitlement. To park: remove the scheme/target or mark it clearly in README so the broken state is intentional.
- **Severity:** Critical

### 5.2 Security-scoped bookmark created with `.minimalBookmark`
- **Location:** `EchoCore/Services/Persistence.swift:172-178` (creation); `:191-222` (restore — the stale-refresh path itself is correct)
- **What:** The folder-access bookmark is created with `options: [.minimalBookmark]`.
- **Why:** Apple's guidance for security-scoped bookmarks on iOS is to pass empty options; minimal bookmarks store reduced information and may omit the sandbox-extension data needed for `startAccessingSecurityScopedResource()` to succeed after relaunch — i.e. the user's library folder silently becomes inaccessible.
- **Action:** Create with `[]`, then verify the full cycle on device: pick folder → relaunch → confirm `startAccessing…` returns true. (Keychain storage of the bookmark, lines 168-189, is good practice and unchanged.)
- **Severity:** Medium

### 5.3 App-group UserDefaults read-modify-write without coordination
- **Location:** `EchoCore/Services/Persistence.swift:33`, `:51`, `:69`, `:121`, `:149` (whole-dictionary RMW per save); cross-process writers in `Echo Widget/Models/AppIntent.swift:13`, `:50`
- **What:** Progress/speed/loop-mode are stored as one dictionary per key; every save reads the whole dictionary, mutates one entry, and writes it back, while the watch-widget process writes the same suite.
- **Why:** Concurrent writes lose updates (last-writer-wins on the whole dictionary); the dictionaries also grow unboundedly (one entry per book ever played).
- **Action:** Store one defaults key per book (`progress_<id>`) so writes don't collide, or move durable state into GRDB and keep only the widget-display snapshot in the suite.
- **Severity:** Medium

### 5.4 Failed artwork load poisons the palette cache for that artwork version
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:206-219`
- **What:** When `currentDisplayArtwork ?? thumbnailImage` is nil, an empty palette is cached under the current artwork version; the empty result is then served until the version changes.
- **Why:** If artwork later becomes loadable without a version bump (e.g. file restored, race at load), accent colouring stays disabled for the session.
- **Action:** Cache only successful extractions; on nil image return the empty palette without recording the version.
- **Severity:** Low

### 5.5 Time-remaining labels divide by unvalidated speed
- **Location:** `EchoCore/Services/PlaybackProgressPresenter.swift:88`, `:100-101`
- **What:** `speed` comes from `speedProvider?() ?? 1.0` and divides elapsed/remaining time with no zero/finite guard.
- **Why:** A zero speed yields `Inf` (not a crash — but "-inf" rendered into the progress label); cheap to make impossible.
- **Action:** Clamp speed to a sane minimum (e.g. `max(0.1, …)`) at the read site.
- **Severity:** Low

### 5.6 Force-unwrap style in CarPlay chapter list
- **Location:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift:44-45`
- **What:** `model?.isMultiM4B == true, !model!.aggregatedChapters.isEmpty` — the `!` is safe today because `model` is a local `let` bound at `:35`, but the pattern invites a crash if the binding ever becomes a property.
- **Why:** Fragile under refactoring; trivially expressible safely.
- **Action:** Rebind with `if let model, model.isMultiM4B, !model.aggregatedChapters.isEmpty`.
- **Severity:** Low

### 5.7 Unbalanced `stopAccessingSecurityScopedResource` in the auto-import scanner
- **Location:** `EchoCore/Services/EPUBAutoImportScanner.swift:38-45` (compare the correct `didStart` pattern at `EchoCore/Services/Persistence.swift:273-274`)
- **What:** The `startAccessing…` result is discarded and the `defer` calls `stopAccessing…` unconditionally, so a failed start still gets a stop.
- **Why:** Apple requires start/stop calls to balance; an unmatched stop can over-release another holder's sandbox extension on the same URL.
- **Action:** Capture the Bool and stop only when start succeeded (the codebase already does this correctly elsewhere).
- **Severity:** Low

### 5.8 `updateApplicationContext` whole-payload semantics deserve a guard rail
- **Location:** `EchoCore/Services/WatchSyncManager.swift` (context send site, ~`:87`)
- **What:** Application context replaces the previous dictionary wholesale; any "significant state" key omitted from a send silently reverts to stale on the watch.
- **Why:** The recent "durable application context" work makes this the watch's source of truth; a future partial-payload send becomes a subtle stale-UI bug.
- **Action:** Funnel all context sends through one builder that always emits the complete key set (document the invariant there); assert key-set equality in DEBUG.
- **Severity:** Low

---

## 6. Security

### 6.1 Zip-slip path traversal in EPUB extraction
- **Status:** ✅ **FIXED 2026-06-09** (TDD). Added `EPUBAutoImportScanner.safeDestination(for:within:)`, which rejects absolute entry paths and any `..`-traversal that escapes the extraction root (standardize + prefix check), and gated the extraction loop on it so no directory is created or file written until the path is validated. New error case `ScannerError.unsafeEntryPath`. Regression tests: `EchoTests/EPUBExtractionPathSafetyTests.swift` (parameterized over `../escape.txt`, `../../etc/passwd`, `OEBPS/../../escape.txt`, absolute paths, plus legitimate and in-root-`..` cases).
- **Location:** `EchoCore/Services/EPUBAutoImportScanner.swift:314-321`
- **What:** Manual entry iteration extracts to `destDir.appendingPathComponent(entry.path)` with no validation; ZIPFoundation's traversal protection applies to `unzipItem(at:to:)`, not to manual `extract(_:to:)`.
- **Why:** A malicious EPUB (books are routinely downloaded from arbitrary sources) containing `../`-prefixed entry paths writes outside `destDir` — within the sandbox that still reaches the GRDB database and imported library, i.e. data corruption/loss.
- **Action:** Standardize each destination URL and require its path to keep `destDir` as a prefix before extracting (also reject absolute entry paths); or switch to `unzipItem`.
- **Severity:** High

### 6.2 XML parser hardening for untrusted EPUB content
- **Location:** `Shared/EPUBXMLParsing.swift:50`, `:82`, `:134`, `:218`
- **What:** Parsers rely on `XMLParser`'s default `shouldResolveExternalEntities == false` rather than setting it explicitly.
- **Why:** The default is safe today (this audit verified the property is never enabled), but the files parse fully untrusted input; an explicit `false` plus a comment documents the trust boundary and survives future refactors.
- **Action:** Set `shouldResolveExternalEntities = false` at all four construction sites.
- **Severity:** Low

### 6.3 One entitlements file shared by watch app and watch widget
- **Location:** `Echo.xcodeproj/project.pbxproj:779`, `:814` (widget), `:1155`, `:1194` (watch app) → both point at root `Echo.entitlements`, which contains the app group *and* the `iCloud.com.echo.audiobooks` container
- **What:** The watch widget inherits the iCloud container entitlement it doesn't use; the file's root-level name doesn't indicate ownership.
- **Why:** Entitlements should be least-privilege per target; the shared file makes future entitlement changes apply to both silently.
- **Action:** Split into per-target entitlements files declaring only what each target uses.
- **Severity:** Low

**Verified clean:** No hardcoded secrets/tokens (grep for bearer/apiKey/secret/password patterns); security-scoped bookmark stored in Keychain with a UserDefaults→Keychain migration path (`Persistence.swift:191-201`); log statements sanitize home-directory prefixes (`EPUBAutoImportScanner.swift:330-334`); StoreKit 2 transaction listener and entitlement refresh present (`StoreManager.swift:82`, `:96`).

---

## 7. Performance

### 7.1 Main-thread database work
See **§3.2** — the same 23 synchronous DAO sites are the codebase's largest jank risk; profile before converting.

### 7.2 Watch marquee animates at frame rate whenever the title overflows
- **Location:** `Echo Watch App/Views/PlayerPage.swift:911-947` (`TimelineView(.animation)` at `:919`)
- **What:** The scrolling-title marquee uses an unpaused `.animation` schedule, redrawing at display refresh rate any time the text is wider than its container — including while playback is paused.
- **Why:** Continuous per-frame invalidation is one of the most expensive things a watch view can do (battery + thermals); the recent "wrist-down tick fix" commit shows this class of issue already bit once.
- **Action:** Use `TimelineView(.animation(minimumInterval:paused:))`, pausing when not playing and when `@Environment(\.isLuminanceReduced)` is true; consider pausing after one full scroll cycle.
- **Severity:** Medium

### 7.3 Watch artwork JPEG re-encode is uncached
- **Location:** `EchoCore/Services/ArtworkCache.swift:129`
- **What:** The 0.75-quality JPEG for watch transfer is re-encoded from `watchImage` on demand; the send path dedupes by artwork key, but the encode itself isn't cached.
- **Why:** Redundant CPU on artwork-change bursts (book switches); small but free to fix alongside §9.7's constant extraction.
- **Action:** Cache encoded `Data` keyed by the same artwork version used for send-dedupe.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Progress view polls `@Observable` state with a timer
- **Location:** `EchoCore/Views/AutoAlignmentProgressView.swift:132-157`; state type `EchoCore/Services/AutoAlignmentState.swift:5-6` (`@MainActor @Observable`)
- **What:** A 0.3 s `Timer` copies `sharedState.phase/progress/statusMessage` into local `@State` each tick.
- **Why:** `AutoAlignmentState` is already `@Observable` — reading it directly in `body` gives per-property change tracking with zero timers, lower latency, and no invalidate-on-disappear bookkeeping (the copy also makes the progress UI lag up to 300 ms).
- **Action:** Delete the timer and local mirror state; read `sharedState` properties directly in `body` (inject via `@Environment` or a stored `let`).
- **Severity:** Medium

### 8.2 Non-private `@State` across a cross-file extension split
- **Location:** `EchoCore/Views/ReaderTab.swift:11-29` (8 internal `@State` properties); consumer `EchoCore/Views/ReaderTab+Alignment.swift:8`
- **What:** `@State` is left internal so a same-type extension in another file can reach it.
- **Why:** Internal `@State` invites external mutation (undefined behaviour if anything outside the view writes it) and signals the view owns workflow state that belongs in a model; the alignment workflow already has `ReaderFeedViewModel` and `AutoAlignmentState` available.
- **Action:** Move alignment-workflow state (task handle, sheet/alert flags) into the view model; restore `private` on what remains.
- **Severity:** Low

### 8.3 App-icon completion mutates `@State` without an explicit main-actor hop
- **Location:** `EchoCore/Views/SettingsView.swift:313-317`
- **What:** `setAlternateIconName`'s completion (delivery queue undocumented) assigns `currentIcon` and logs via `print`.
- **Why:** Under Swift 5 mode nothing enforces main-thread delivery here; wrapping in `Task { @MainActor … }` makes it compiler-checked and future-proof (and the `print` should be `Logger` — see §2).
- **Action:** Hop to `@MainActor` in the completion before touching view state.
- **Severity:** Low

### 8.4 Accessibility coverage is good where sampled — finish the sweep
- **Location:** Spot-checked exemplar: `EchoCore/Views/TransportControlsView.swift:64-116` (icon-only buttons all labelled); 12 of 52 files in `EchoCore/Views/` reference `accessibilityLabel`
- **What:** Transport controls are properly labelled; the remaining icon-only buttons across the other view files weren't exhaustively verified.
- **Why:** Icon-only buttons without labels read as the SF Symbol name in VoiceOver.
- **Action:** Sweep `Image(systemName:)`-only buttons in the unsampled files (Bookmarks, PlaylistView, ReaderTab toolbars) and label any gaps; run the Accessibility Inspector audit once.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 Files and directories to delete or untrack
- `OrbitAudioBooks/`, `Orbit Audiobooks macOS/` — rebrand leftovers, zero pbxproj references (verified).
- `scratch/` — git-tracked design scraps (2 Swift before/after files, 4 SVGs).
- `Tools/OrbitTranscriptionCLI/` — untracked `.build/` + `Package.resolved` for a deleted package; `Tools/__pycache__/`.
- `build.log` — untracked build output at repo root; gitignore it.
- **Severity:** High (cleanup; zero risk, removes an entire phantom subproject)

### 9.2 Two parallel audio snippet players
- **Locations:** `EchoCore/Services/SnippetPlayer.swift` (used by `PlayerModel`) vs `EchoCore/Services/AudioSnippetPlayer.swift` (used only by `EchoCore/Views/Bookmarks.swift:396`, `:752`)
- **What:** Two implementations of "play a short audio range" with separate AVFoundation setup.
- **Why:** Double maintenance; behavioural drift between bookmark preview and other snippet playback.
- **Action:** Pick one (the protocol-oriented `MediaPlayable` direction in CLAUDE.md suggests folding both behind one service) and migrate the two Bookmarks call sites.
- **Severity:** Medium

### 9.3 macOS target reimplements iOS EPUB parsing and alignment
- **Status:** ✅ **FIXED 2026-06-10.** Pure alignment utility functions (`tokenizeForAlignment`, `jaccardScore`, `formatTimeHMS`) extracted to `Shared/TextAlignmentUtilities.swift`. `MacGlobalAlignmentService` delegates tokenize/score/formatTime to the shared free functions, eliminating private copies. All five hardcoded `Logger(subsystem:)` sites in the macOS target replaced with `Logger(category:)`. `MacEPUBParser` already used `parseXHTML`/`parseOPF`/`parseContainerXML` from `Shared/EPUBXMLParsing.swift` — its thin wrappers add platform-appropriate file I/O.
- **Locations:** `Echo macOS/Services/MacEPUBParser.swift`, `Echo macOS/Services/MacGlobalAlignmentService.swift` vs `Shared/TextAlignmentUtilities.swift` + `Shared/EPUBXMLParsing.swift`
- **Severity:** Medium

### 9.4 `AudiobookPlayerUIArchitect` design scaffold ships in the app target
- **Locations:** `EchoCore/Views/AudiobookPlayerUIArchitect.swift` (no references from any other source file — verified; no `#if DEBUG`); companion script `add_architect.rb` at repo root; positional-identity `ForEach(0..<segments.count, id: \.self)` at `:230`
- **What:** A large interactive design-tuning surface compiled into release builds, plus the one-off Ruby script that injected it.
- **Why:** Dead weight in the shipped binary; the dynamic positional `ForEach` is also the only real identity anti-pattern found in the view layer.
- **Action:** Move behind `#if DEBUG` (or delete) and delete `add_architect.rb` either way.
- **Severity:** Medium

### 9.5 Rebrand residue: identifiers still `com.orbit*` — decide, don't drift
- **Locations:** All 8 `PRODUCT_BUNDLE_IDENTIFIER`s (`com.echo.audiobooks*`); `group.com.echo.audiobooks` (`Shared/AppGroupDefaults.swift:6` + entitlements); `iCloud.com.echo.audiobooks` (entitlements); `Logger.orbitSubsystem` = `"com.echo.audiobooks"` (`Shared/Logger+Subsystem.swift:8`); queue label (`EchoCore/Services/TimelineService.swift:36`); `CLAUDE.md:9`
- **What:** The Orbit→Echo rebrand (`751e89c`) renamed user-facing surfaces but left every machine identifier on the old name.
- **Why:** This is *not* a mechanical fix: bundle IDs, app-group IDs, and the CloudKit container are the app's identity — changing them after release orphans user data and IAP. Before first public release is the only cheap moment to decide.
- **Action:** Make the call now: either migrate all identifiers to an Echo domain in one commit (pre-release), or freeze the Orbit identifiers permanently and document that in README/CLAUDE.md so they stop looking like an oversight.
- **Severity:** Medium

### 9.6 Oversized files (>600 LOC)
- **`EchoCore/ViewModels/PlayerModel.swift` (1255)** — extensions (+Bookmarks, +PlaybackControllerDelegate, +WatchState) already exist; next extractions: artwork/palette caching (`:198-260`) into a `PlayerArtworkPresenter`, and deep-link/chapter-navigation orchestration.
- **`Echo Watch App/Services/WatchViewModel.swift` (973)** — split the Pomodoro state machine and connectivity message handling into separate types.
- **`Echo Watch App/Views/PlayerPage.swift` (964)** — marquee (`:908-947`), quick-bookmark gesture, and cover viewer are separable leaf views/files.
- **`EchoCore/Services/PlaybackController.swift` (922)** — chapter-clamp seek math (`:630-668` and siblings) is a pure-function candidate for extraction + unit tests.
- **`EchoCore/Views/Bookmarks.swift` (778)**, **`WatchAppSettingsView.swift` (728)**, **`ReaderTab.swift` (725)**, **`PlaylistView.swift` (719)**, **`AutoAlignmentService.swift` (663)**, **`TimelineFeedCollectionView.swift` (627)**, **`SettingsView.swift` (624)** — same treatment when next touched.
- **Severity:** Medium (refactor-when-touched; don't big-bang)

### 9.7 Magic constants
- JPEG/artwork: `EchoCore/Views/Bookmarks.swift:694` (`maxDimension: 1600`, quality `0.84`), `EchoCore/Services/ArtworkCache.swift:129` (quality `0.75`) → one `ImageEncoding` constants enum.
- Watch messaging: the `"command"` key appears as a string literal at 6 sites across `Echo Watch App/` and `EchoCore/` → shared `WatchMessageKey` constants.
- **Severity:** Low

### 9.8 Open TODO census
- Exactly one TODO in project code (a documented REFACTOR-TODO in `EchoCore/CarPlay/CarPlaySceneDelegate.swift`); no `#if false` blocks or commented-out code regions found.
- **Severity:** Low (informational — unusually clean)

---

## 10. Cross-cutting recommendations

1. **Run the Swift 6 migration as a project, starting with the settings.** §3.4, §3.5, and §3.6 are facets of one effort: unify `SWIFT_DEFAULT_ACTOR_ISOLATION` across targets, flip one target at a time to the Swift 6 language mode in a branch, and treat its diagnostics as the authoritative concurrency audit. The codebase is unusually close (zero warnings, Approachable Concurrency on, no `nonisolated(unsafe)`) — the remaining cost is concentrated in the queue-hop and fire-and-forget-Task patterns already cited.
2. **Adopt one async-database policy.** The 23 synchronous DAO sites (§3.2) should resolve to a written rule: reads/writes on user-interaction paths are async; import-time batch work may stay sync. Encode it in the DAO layer (offer async variants, deprecate sync entry points for hot tables) rather than relying on per-call-site discipline.
3. **Make Task lifecycle a convention.** §3.1 and §3.3 share a root cause: ad-hoc `Task {}` spawning. A tiny utility (store-replace-cancel, plus snapshot-before-spawn for guards) used everywhere ends the class of bug.
4. **Close the rebrand.** §9.5's identifier decision plus §2's typo/doc fixes and §9.1's deletions retire "Orbit" from the repo in an afternoon — or enshrine it deliberately. Either outcome beats the current half-state, which already produced one Critical (§5.1's orphaned script phase).
5. **Decide the macOS target's status in writing.** Every macOS finding (§5.1, §9.3, the entitlement gap) stems from the target evolving outside the iOS code-sharing path. Revive it through `Shared/`, or park it explicitly.

---

## 11. What was NOT audited

- `build/`, `vendor/`, `scratch/` contents, `docs/`, `fastlane/`, `Echo.xcodeproj` beyond the build settings/phases cited above.
- Third-party dependency internals (WhisperKit, GRDB, ZIPFoundation, swift-transformers, swift-jinja, yyjson).
- Algorithmic correctness of the alignment math (`TokenDTW.swift`, Levenshtein/Jaccard thresholds in `AutoAlignmentTextMatcher.swift`) — structure was reviewed; constants and matching quality were not.
- `Tools/transcription_generator.py` (Python pipeline) — not reviewed this pass.
- Test targets (`EchoTests/`, `Echo Watch AppTests/`, UI tests) — existence confirmed, coverage and quality not assessed.
- Localization (`Localizable.xcstrings`) and Dynamic Type behaviour beyond spot checks.
- CloudKit schema/record design in `CloudKitSyncService.swift` (concurrency posture sampled only).
- StoreKit product configuration vs App Store Connect (`com.echo.pro.unlock` exists in build settings; not validated).
- Runtime profiling — no Instruments traces were captured; performance findings are static-analysis only.

---

## 12. Verification

Open each cited location; every Critical/High claim below was confirmed by reading the lines during the audit.

- **§5.1** — run `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" build`: fails with "Unable to resolve module dependency: 'WhisperKit'" at `Echo macOS/Services/MacGlobalAlignmentService.swift:4`. Then open `Echo.xcodeproj/project.pbxproj:577-601`: the shell phase runs `swift build --package-path "${SRCROOT}/Tools/OrbitTranscriptionCLI"` under `set -euo pipefail` with no existence guard; `git ls-files Tools` shows the package is not in the repo.
- **§6.1** — open `EchoCore/Services/EPUBAutoImportScanner.swift:314-321`: the loop appends raw `entry.path` to `destDir` and extracts; no `..`/absolute-path check exists in the function.
- **§3.1** — open `EchoCore/Services/WhisperSession.swift:73-75`: `capturedGeneration` is assigned *inside* the `Task` from the already-current `generation`; compare `:53-54` where `release()` assigns it *before* the `Task`.
- **§3.2** — `grep -rn "DAO(db: db.writer)" EchoCore/Services` returns 23 sites; the enclosing services are `@MainActor` (implicitly, via the Echo target's default isolation).
- **§9.1** — `git ls-files scratch` lists 6 tracked files; `grep -c "OrbitAudioBooks" Echo.xcodeproj/project.pbxproj` returns 0.

**Claims investigated and demoted/dropped during verification** (for transparency): CarPlay force-unwrap "Critical crash" → safe local binding, kept as Low style (§5.6); XMLParser XXE "High" → default already safe, kept as Low hardening (§6.2); XMLParser delegate "background-thread race" → delegates run synchronously on the calling thread, dropped; `DominantColorExtractor` NaN-index crash → impossible (saturation guard precedes bucket math), dropped; audio-tap "locks the realtime thread" → ring buffer is lock-free by design, dropped; stale-bookmark "uses stale data" → refresh path is correct, replaced by the `.minimalBookmark` concern (§5.2); `aggregatedChapters[idx]` bounds race → index derived from the same array in the same MainActor turn, dropped.

If any finding doesn't reproduce at the cited line, flag the §number and it will be re-investigated.

---

## 13. Post-audit addendum

### 13.1 `ColorMetrics.isLegible` ΔE76 chroma gate passed unreadable accents (found 2026-06-10, superseded)

The two-gate legibility check (`WCAG ≥ 2.4 OR ΔE76 ≥ 52`) approved accents with
high chromatic distance but near-zero luminance contrast — extractor gold
`#EEC32B` on the Company of One beige surface measured **1.06:1** WCAG with
ΔE76 65, so the `AccentSafetyNet` rescue ladder never ran. Higher saturation
inflated ΔE76, making the most problematic accents the most likely to bypass
rescue. Root cause: human acuity for fine detail is carried by the luminance
channel; a chroma-only gate cannot certify glyph legibility. Resolved by
replacing extract-then-rescue with constructed OKLCH tone recipes
(`CoverThemeBuilder`, spec `docs/superpowers/specs/2026-06-10-cover-tonal-theme-design.md`);
the gate, ladder, and their tests were deleted.
