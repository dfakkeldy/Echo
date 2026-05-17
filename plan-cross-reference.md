# Plan Cross-Reference & Dependency Analysis

## All Plans

| # | Plan | Complexity | Category |
|---|------|-----------|----------|
| B12 | Volume Control Cleanup | Small | Bug fix |
| B13 | Watch State Consistency | Small | Bug fix | ✅ DONE |
| B16 | Bookmark Cleanup Logging | Small | Bug fix |
| A1 | PlayerModel Decomposition | Very Large | Architecture |
| A2 | Watch ContentView Decomposition | Medium | Architecture |
| A3 | Cross-Target Deduplication | Medium | Architecture |
| A4 | Accessibility Audit | Medium | Architecture |
| A5 | Protocol Extraction (revised) | Medium | Architecture | ✅ DONE |
| A6 | AudioEngine Volume API (rescoped) | Small | Architecture | ✅ DONE |
| A7 | Typed Watch Configuration | Small | Architecture |
| L10N | Localization & Settings | Large | Feature |
| M4B | Audio Queue M4B Folders | Large | Feature |
| DASH | Modular Dashboard UI | Large | Feature |
| CAR | CarPlay Integration | Large | Feature |
| SQL | SQL Database Integration | Large | Feature |
| PLIST | Playlist Packaging (Manifest + ZIP) | Medium | Feature |
| BKMG | Bookmark Playlist Grouping | Small | Feature |

---

## Dependency Graph

```
A5 (Protocols) ─────────────────────────────────────────────────────────────────┐
A6 (AudioEngine) ──────────────────────────────────────────────────────────────┐│
L10N (Localization) ─────────────────────────────────────────────────────────┐ ││
B16 (Bookmark Logging) ──────────────────────────────────────────────────┐   │ ││
                                                                          │   │ ││
B12 (Volume) ───── depends on: A6 ────────────────────────────────────────┤   │ ││
B13 (Watch State) ────────────────────────────────────────────────────────┤   │ ││
                                                                          │   │ ││
A1 (PlayerModel) ─── depends on: A5, A6 ──────────────────────────────────┤   │ ││
A2 (Watch Decomp) ── depends on: B13 ─────────────────────────────────────┤   │ ││
                                                                          │   │ ││
A3 (Deduplication) ─ depends on: A2 ──────────────────────────────────────┤   │ ││
A7 (Typed Watch) ─── depends on: A3 ──────────────────────────────────────┤   │ ││
A4 (Accessibility) ─ depends on: L10N ────────────────────────────────────┤   │ ││
                                                                          │   │ ││
M4B (Audio Queue) ── depends on: A1, A6 ──────────────────────────────────┘   │ ││
DASH (Dashboard) ─── depends on: A1, A5, L10N ────────────────────────────────┘ ││
CAR (CarPlay) ────── depends on: A1, A6, M4B ───────────────────────────────────┘│
SQL (Database) ───── depends on: A1 ─────────────────────────────────────────────┘
PLIST (Playlist) ──── depends on: A1 (manifest in extracted Persistence) ─────────┘
BKMG (Bookmark Grouping) ─ no dependencies, no dependents (self-contained UI change)
```

---

## Recommended Execution Order

### Phase 0: Foundations (parallel-safe)
| Order | Plan | Reason |
|-------|------|--------|
| 0.1 | **A5 — Protocol Extraction (revised)** | Defines component interfaces for A1. Keep PlayerModel concrete in views; extract protocols for internal components and SettingsManager/StoreManager. |
| 0.2 | **L10N — Localization & Settings** | Must go early so EVERY subsequent plan writes localized strings. |
| 0.3 | **B16 — Bookmark Cleanup Logging** | Independent, low risk. |
| 0.4 | **A6 + B12 — AudioEngine Gain API + Volume Cleanup** | A6 adds `setGain(_:)` / `fadeGain(to:duration:)`. B12 removes MPVolumeView hack using that API. Combined as one small change. |

These four have zero dependencies on each other and can be done in parallel (separate worktrees).

### Phase 1: Bug Fixes ✅ COMPLETE
| Order | Plan | Reason |
|-------|------|--------|
| 1.1 | **B13 — Watch State Consistency** ✅ | Fixed. Consistent optimistic updates with rollback across all watch controls. |

### Phase 2: Architecture Refactoring
| Order | Plan | Reason |
|-------|------|--------|
| 2.1 | **A1 — PlayerModel Decomposition** | Foundation for everything below. Do incrementally, component by component. |
| 2.2 | **A2 — Watch ContentView Decomposition** | Follows same pattern as A1 for watch target. |
| 2.3 | **A3 — Cross-Target Deduplication** | After both iOS and Watch are decomposed, extract shared code. |
| 2.4 | **A7 — Typed Watch Configuration** | After shared package exists (A3). |
| 2.5 | **A4 — Accessibility Audit** | After L10N is in place. |

### Phase 3: Features
| Order | Plan | Reason |
|-------|------|--------|
| 3.1 | **M4B — Audio Queue Folders** | Builds on A1's ChapterService + A6's clean API. |
| 3.2 | **DASH — Modular Dashboard** | Builds on A1's extracted components + A5's protocols. |
| 3.3 | **CAR — CarPlay Integration** | Builds on A1, A6, and M4B's aggregated chapters. |
| 3.4 | **SQL — Database Integration** | After A1 extracts BookmarkStore; swap backend. |
| 3.5 | **PLIST — Playlist Packaging** | After A1 extracts Persistence; manifest replaces UserDefaults keys. Parallel with SQL. |

---

## Conflict Matrix

### PlayerModel (touched by 9 plans)

**Problem:** A1, A5, A6, B12, B16, L10N, M4B, DASH, CAR all modify `PlayerModel.swift`.

**Resolution:** Do A5 and A6 first (add protocols, clean up audio API — surface-level changes). Then do A1 (decompose into 8 files). All subsequent plans touch the EXTRACTED files, not the god class. If any plan is done before A1, it creates merge conflicts in the 2900-line file.

### AudioEngine (touched by 4 plans)

**Problem:** A6, B12, M4B, CAR all want to change AudioEngine's API.

**Resolution:** A6 defines the stable public API (`setGain`, `play`, `pause`, `seek`, `scheduleFile`). B12 uses `setGain`. M4B extends with `scheduleNext`. CAR uses the same play/pause/seek API. Order: A6 → B12 + M4B → CAR.

### Localization vs. Everything

**Problem:** L10N touches every file with user-facing strings. Any plan done before L10N will need a second pass to wrap strings.

**Resolution:** Do L10N in Phase 0. All subsequent plans use `String(localized:)` from the start. This is the single biggest ordering constraint — localization MUST go first among all UI-touching plans.

### SQL vs. UserDefaults/Deduplication

**Problem:** A3 deduplicates `AppGroupDefaults` across targets. But SQL replaces most UserDefaults usage entirely. If SQL is done after A3, A3's work is partially wasted.

**Resolution:** A3 still has value — it deduplicates types (`TranscriptionSegment`, `WordFrequency`, `WatchAction`, `formatHMS`) that SQL doesn't replace. But A3's `AppGroupDefaults` deduplication should be LIMITED to what SQL won't replace (widget-shared state like `isPlaying`, `currentTime`). Settings and bookmarks move to SQL.

### A1 + M4B: ChapterService Shape

**Problem:** A1 extracts `ChapterService` with a single-book chapter model. M4B changes it to an aggregated multi-book model.

**Resolution:** When A1 extracts `ChapterService`, design the API to accommodate aggregation from the start:
```swift
protocol ChapterServiceProtocol {
    func chapters() -> [Chapter]           // flat list for simple case
    func aggregatedChapters() -> [AggregatedChapter]  // for multi-M4B
}
```

M4B then adds the aggregation without changing the protocol signature.

### CAR + Watch: Dual Command Sources

**Problem:** Both CarPlay and the Watch app send playback commands. If `PlayerModel` handles them from separate code paths, they can race.

**Resolution:** After A1 extracts `PlaybackController`, ALL command sources (Watch, CarPlay, Widget, in-app UI) go through a single `PlaybackController.handleCommand(_:)` entry point with an internal serial queue. This is a design rule for A1, not a conflict.

---

## Risks & High-Impact Interactions

| Risk | Plans Involved | Mitigation |
|------|---------------|------------|
| User data loss during SQL migration | SQL, A1 | Thoroughly test migration with real bookmark data. Keep UserDefaults as backup for one release cycle. |
| Audio gap/glitch at M4B boundaries | M4B, A6 | Pre-buffer the next file's first 5 seconds. Test with short and long M4B files. |
| Break watchOS after A2 decomposition | A2, B13 | B13 is the behavior fix. A2 is pure file-splitting. If builds pass, behavior is unchanged. |
| CarPlay rejection from App Review | CAR, B12 | B12 removes the MPVolumeView hack (App Review risk). CAR adds legitimate CarPlay entitlements. |
| Merge hell on PlayerModel | A1, M4B, DASH, CAR | Do A1 first. No exceptions. All feature work targets extracted components. |
| Dutch localization quality | L10N | Use a native Dutch speaker for review. Machine translations are a starting point only. |

---

## Parallelization Opportunities

### Can be done simultaneously (different worktrees, no shared files):
- Phase 0: A5, L10N, B16, A6+B12 — all four at once
- Phase 2: A2 + A3 + A7 — three at once (after B13 and A1)
- Phase 3: M4B + DASH + SQL + PLIST — four at once (after A1 is done, they touch different extracted components)
- Any time: BKMG — zero dependencies, single file, can be done in any phase

### Must be sequential:
- A5 → A1 (protocols define boundaries for decomposition)
- A1 → M4B, DASH, CAR, SQL (all depend on extracted components)
- A2 → A3 (deduplication needs separated files first)
- L10N → A4 (accessibility labels must be localized)

---

## Code Review Findings (May 2026)

*Cross-referenced plans against the current codebase. These findings affect plan scoping and assumptions.*

### Finding 1: Plan A6 is mostly done — rescope to "add setGain"

**Reality:** The AVAudioEngine migration (commit `ef91c5b`) already made AudioEngine well-encapsulated. `playerNode`, `engine`, `eqNode`, `varispeedNode`, `audioFile` are all `private`. PlayerModel accesses AudioEngine through a clean public API: `currentTime`, `isItemLoaded`, `seek(to:completion:)`, `playImmediately(atRate:)`, `pause()`, `cleanup()`, `configureAudioSession()`.

**Impact:** Rescope A6 from "fix broken encapsulation" to "add `setGain(_:)` API for volume control." This reduces A6 from Medium to Small complexity.

### Finding 2: Plan A5 protocol approach breaks with @Observable

**Reality:** All 17 views use `@Environment(PlayerModel.self) private var model`. SwiftUI's Observation framework (iOS 17+) uses the concrete type as the environment key and tracks property reads through the `@Observable` macro. You CANNOT replace `@Environment(PlayerModel.self)` with `@Environment(PlayerModelProtocol.self)` because:
- Protocol-typed environment keys lose Observation tracking — views won't re-render on property changes
- The `.environment(PlayerModelProtocol.self, value)` injection doesn't exist for protocols by default

**Impact:** Revise A5's approach:
- Protocols for `SettingsManager` and `StoreManager` are still viable (they're not `@Observable`)
- For PlayerModel: keep it as the central `@Observable` type in the environment. Extract internal components behind protocols (e.g., `BookmarkStoreProtocol`, `PlaybackControllerProtocol`) that PlayerModel delegates to. Testability comes from injecting mock services into PlayerModel's `init()`, not from replacing PlayerModel in the view hierarchy.
- For unit testing views: use snapshot/preview tests with a real PlayerModel configured with mock services, rather than trying to inject a mock PlayerModel via environment.

### Finding 3: CarPlay remote commands need reconfiguration

**Reality:** The current `configureRemoteCommandsIfNeeded()` in PlayerModel (line 1557) explicitly DISABLES `previousTrackCommand`, `skipForwardCommand`, and `changePlaybackPositionCommand` for a "simpler Watch UI." CarPlay needs at minimum `changePlaybackPositionCommand` for the scrubber and possibly `skipForwardCommand`.

**Impact:** Plan CAR must update the remote command configuration to detect the playback context (Watch vs CarPlay) or simply enable all commands — the CarPlay templates and Watch UI filter available commands independently.

### Finding 4: Existing modularization in Components/

**Reality:** The codebase already has `OrbitAudioBooks/Views/Components/TranscriptOverlayView.swift`. The modular dashboard plan should integrate with this existing structure rather than creating a parallel one.

**Impact:** Plan DASH should use the existing `Views/Components/` directory for new modules.

### Finding 5: AudioEngine public API is missing setGain

**Reality:** While AudioEngine is well-encapsulated, there's no `setGain(_:)` method. The `eqNode` is private. For B12 (volume fade) and the sleep timer fade-out, we need a gain control API.

**Impact:** A6's sole remaining task is adding `func setGain(_ gain: Float)` that adjusts `eqNode.globalGain`, plus `func fadeGain(to:duration:)` for smooth transitions.

### Finding 6: PlayerModel is @Observable, not ObservableObject

**Reality:** PlayerModel uses `@Observable` (iOS 17+ Observation framework), not `@ObservableObject` (Combine). This affects:
- No `@Published` property wrappers — Observation tracks directly
- No `objectWillChange` — observation is automatic
- Environment injection uses `.self` pattern, not `.environmentObject()`
- Child views automatically observe only the properties they read

**Impact:** All architecture plans (A1, A5) must account for Observation framework patterns. Extracted components that need to be observable should also use `@Observable` if they feed into SwiftUI directly.

### Finding 7: PlaylistView and BottomToolbarView — untracked file locations

**Reality:** Some files exist at paths not listed in ARCHITECTURE.md (which is auto-generated and may lag). `PlaylistView.swift`, `SmartRewindSettingsView.swift`, `WatchAppSettingsView.swift`, `TransportControlsView.swift`, `VoiceMemoOverlayView.swift` are all in `OrbitAudioBooks/Views/`, and `TranscriptOverlayView.swift` is in `Views/Components/`.

**Impact:** No plan changes needed, but be aware the file tree is larger than ARCHITECTURE.md suggests.

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total plans | 17 (16 files, A6+B12 combined) |
| Independent (Phase 0) | 4 workstreams |
| Bug fixes | 3 |
| Architecture refactors | 7 |
| Feature additions | 7 |
| Plans touching PlayerModel | 9 |
| Plans touching AudioEngine | 3 |
| Maximum parallel workstreams | 4 (Phase 0) |
| Sequential dependency chain (longest path) | A5 → A1 → M4B → CAR (4 steps) |
| Plans revised after code review | A5 (protocol approach), A6 (reduced scope) |

## Completion Status (May 2026)

| Plan | Status | Date |
|------|--------|------|
| A5 — Protocol Extraction | ✅ Done | 2026-05-15 |
| A6 — AudioEngine Gain API | ✅ Done | 2026-05-15 |
| B12 — Volume Control Cleanup | ✅ Done | 2026-05-15 |
| B13 — Watch State Consistency | ✅ Done | 2026-05-16 |
| A1 — PlayerModel Decomposition | 🔄 In Progress | — |
| L10N — Localization & Settings | ✅ Done | 2026-05-17 |
| B16 — Bookmark Cleanup Logging | ⏳ Pending | — |
| A2 — Watch ContentView Decomposition | ⏳ Pending | — |
| A3 — Cross-Target Deduplication | ⏳ Pending | — |
| A4 — Accessibility Audit | ⏳ Pending | — |
| A7 — Typed Watch Configuration | ⏳ Pending | — |
| M4B — Audio Queue M4B Folders | ⏳ Pending | — |
| DASH — Modular Dashboard UI | ⏳ Pending | — |
| CAR — CarPlay Integration | ⏳ Pending | — |
| SQL — SQL Database Integration | ⏳ Pending | — |
| PLIST — Playlist Packaging | ⏳ Pending | — |
| BKMG — Bookmark Playlist Grouping | ⏳ Pending | — |
