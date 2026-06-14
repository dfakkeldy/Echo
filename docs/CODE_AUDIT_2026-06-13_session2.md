# Echo: Audiobook Study Player — Code Audit

Generated 2026-06-13. Scope: ~48,512 Swift LOC across 404 files + 1 Metal shader, in targets **Echo (iOS 18)**, **Echo Watch App (watchOS 11)**, **Echo Widget**, **Echo macOS (15)**, plus shared `EchoCore/` and `Shared/`. Excluded: `Tools/` (Python pipeline), `Scripts/`, `docs/`, `fastlane/`, asset catalogs, SPM dependency internals (GRDB, WhisperKit, ZIPFoundation, swift-transformers, swift-crypto), and the test targets (light scan only).

This audit weights the **Wave-1 delta**: the prior audit (2026-06-09, 34 findings) was fully remediated, and ~28,600 insertions across 262 files have landed since (soundscapes/chimes, Metal visualizers, `.apkg`/AnkiConnect interop, FSRS scheduler, auto-draft chapter cards, CarPlay, location capture, stats, fidget views, macOS tri-pane). Those new subsystems received the bulk of scrutiny. _(The 2026-06-09 report this replaces is preserved in git history.)_

**Compiler ground truth (at audit time):** the first (incremental) Debug build of the Echo scheme reported **1 hard error and 17 warnings**, but the single error was build-breaking and **masked an entire chain** — neither the iOS `EchoCore` module nor the `Echo macOS` target had ever cleanly compiled. Forcing a full build surfaced ~8 distinct compile errors across both targets (Wave-1 code that was committed without a green build). **All were fixed and verified during this session** — see the "Build repair" box below; every scheme (`Echo`, `Echo macOS`, `Echo Watch App`) now builds `** BUILD SUCCEEDED **`. The 17 warnings cluster into a small number of Swift-6-readiness root causes, all cited below. The pre-existing hygiene is otherwise excellent: **0 TODO/FIXME markers, 0 stray `print()` calls, 1 `try!`, 0 `as!`, 0 `ObservableObject`**, and the 13 `fatalError` sites are all `init?(coder:)` boilerplate in programmatic UIKit cells (acceptable).

> ### ✅ Build repair (fixed & verified this session)
> The `@frozen` error (§5.1) aborted compilation before the type-checker reached the rest of the module, hiding these. Each fix was confirmed by a full `xcodebuild` to `** BUILD SUCCEEDED **`:
>
> | File | Error | Fix |
> |---|---|---|
> | `EchoCore/Views/Visualizer/VisualizerView.swift:7` | `@frozen` on internal `VisualizerUniforms` (§5.1) | removed the attribute |
> | `EchoCore/Views/Visualizer/VisualizerView.swift:22` | `UnsafeMutableBufferPointer` over a Float-tuple not rebound → `Float`-to-tuple assignment error (§5.8) | wrapped in `withMemoryRebound(to: Float.self, capacity: 16)` |
> | `EchoCore/CarPlay/CarPlayManager.swift:153,216,229,273` | `CPListItem.handler` assigned a 1-arg closure; needs `(item, completion)` (§5.9) | `{ _, completion in … completion() }` |
> | `EchoCore/Services/DefaultChimePlayer.swift:64` | bare `scheduleFile(_:at:)` resolved to the new `async` overload (§5.10) | passed `completionHandler: nil` to keep it non-blocking |
> | `EchoCore/ViewModels/PlayerModel.swift:7,371` | GRDB `Column` used without `import GRDB` (§5.11) | added `import GRDB`, qualified `GRDB.Column` |
> | `Echo macOS/Views/MacAnkiExportView.swift:11,140` | missing `import GRDB`; un-awaited `async` `export(...)` (§5.11) | added import; `try await` |
> | `Echo macOS/Services/MacApkgExportService.swift:64,78` | un-awaited `async` `DatabaseWriter.read` (§5.11) | `try await db.read { … }` |

Findings cite `path/to/file.swift:LINE`. Every Critical/High was personally verified by opening the cited lines; several agent-reported "Critical" claims (Metal/CarPlay force-unwraps, a ClozeParser "panic", `.apkg` SQL-injection) were **demoted or dropped** after verification — see §12. No code changes were made.

---

## Remediation progress

_2026-06-13 (session 2), branch `claude/elegant-heyrovsky-309173` (fast-forwarded onto the build-repair + CarPlay §5.2 commits). Verified with `make build-tests` → `** TEST BUILD SUCCEEDED **` and targeted `xcodebuild test-without-building` runs (`StatsAggregatorTests`, `StatsRepositoryTests`, `ChapterCardDrafterTests` all green)._

**Legend:** ✅ fixed & verified · ⏭ delegated · 🔲 open

### ✅ Swift-6 readiness milestone (the three Highs + quick wins)
- **§3.1 [High]** Both Widget `AppIntent.perform()` methods marked `@MainActor`, so they may legally touch the main-actor, non-Sendable `AppGroupDefaults`/`Bookmark` (an `async` protocol requirement is satisfiable by a `@MainActor` witness). 5 warnings cleared.
- **§3.2 [High]** `ChapterCardDrafter` captured-`var card` race → `let card` + a local mutable copy inside the `@Sendable` `db.write` closure.
- **§3.3 [High]** The four pure stats/FSRS functions (`retentionCurve`, `dueForecast`, `gradeDistribution`, `plannerAdherence`) marked `nonisolated static` — per-function, *not* whole-type: the other aggregators legitimately call main-actor helpers (`Calendar.startOfPeriod`, `ListeningSegment.adjustedDuration`). 4 warnings cleared.
- **§3.4 [Low]** `AudioEngine` subsystem refs: the `nonisolated(unsafe)` was a no-op (all access is main-actor) — removed it → plain `var`, clearing 3 "has no effect" warnings and restoring the observation the settings/visualizer views rely on. (Plain `nonisolated` is illegal on a mutable `@ObservationTracked` stored property.)
- **§3.9 [Low]** Removed the two spurious `await`s on synchronous GRDB reads in `ChapterCardDrafter`.
- **§9.5 [Low]** Removed the dead `dailyTotals` binding in `StatsRepository`.

### ✅ Bugs surfaced by repairing the test target (beyond the original audit scope)
- **The EchoTests target had never compiled** — `EchoTests/SchedulingAlgorithmTests.swift` was missing `import Foundation` (`Date` unresolved under the `MemberImportVisibility` upcoming feature). Added the import. _The prior audit verified `xcodebuild build` (app), not `build-for-testing`, so this and the two bugs below were invisible._
- **All flashcard creation was broken (`card_type NOT NULL`)** — `Flashcard.cardType` was `String?` with no default while V16's `card_type` column is `NOT NULL`; the memberwise initializer defaults an omitted optional to `nil`, which GRDB writes as an explicit `NULL` (the column default only applies when the column is *omitted from the INSERT*). **10 construction sites** omitted it — 9 production paths (manual creation, card inbox, watch, deck/`.apkg` import, …) plus the auto-draft drafter — so every insert failed. Root-caused at the model: `var cardType: String? = "normal"`, fixing all sites at once. `ChapterCardDrafterTests` and `RealTimeEventIntegrityTests` now pass. (The earlier per-site `cardType: "normal"` in `ChapterCardDrafter` is now redundant but harmless.)

### ✅ FSRS / SM-2 scheduler correctness (surfaced by the test target; §11 noted scheduler math was unreviewed)
`SchedulingAlgorithmTests` had 6 failures across 3 tests — all 10 now green:
- **SM-2 `intervalGrowsOverPerfectReviews`** — the *test* was wrong, the impl is canonical. Grades `[3,4,4,4,4]`: the grade-3 review drops EF 2.5→2.36, so intervals are `[1,6,14,33,77]`, not the test's EF-stays-2.5 `[1,6,15,37,92]`. Corrected the expectation.
- **FSRS (`firstFail`, `stabilityGrows`)** — the *impl* was broken. `FSRSScheduler` had the canonical FSRS-4.5 default weights but misapplied them: no first-review path, wrong `S₀` indexing (`w[2]` for fail vs canonical `w[0]`), `easyBonus = exp(w₁₆·(D−1))` (explodes; canonical is `w₁₆`), hard penalty on Good not Hard, inverted difficulty update, and `interval ≈ S/100`. Rewrote to canonical FSRS-4.5 (first-review seeds `S₀/D₀`; recall/lapse stability, mean-reverting difficulty, `R=(1+FACTOR·t/S)^DECAY`, `interval≈S` at 90% retention). Corrected the two tests (fail S₀=`w[0]`=0.4; the growth test now advances the clock so `R<1`, since same-instant reviews correctly yield no gain). **Also fixes §5.4** (interval clamped to 36,500 days). Removed the dead, duplicate `SpacedRepetitionService` SM-2 in `Flashcard.swift` (zero references).

### ✅ Infrastructure + Medium findings (session 2, continued)
- **CI build-gate (§10 rec. 5)** — `.github/workflows/ci.yml` now runs an explicit `build-for-testing` gate (compiles app + widget + watch + `EchoTests`) before `test-without-building`, so compile breaks fail fast. _Action still required: enable branch protection on `main` requiring the "CI" check, and confirm the runner's Xcode matches the project SDK._
- **§5.3** Metal command-buffer/encoder force-unwraps → `guard` + skip frame.
- **§7.2** `VisualizerView` created two `MTLDevice`s → one shared device.
- **§7.1** realtime visualizer tap: FFT setup created once (not per callback) + analyze the buffer pointer in place (no `Array(samples)` copy); vDSP math unchanged.
- **§9.1** triplicated `sanitize()` → `SafeFileName.sanitizeForFilename` (verified iOS + macOS).
- **§8.3** onboarding hero icons → `@ScaledMetric` + `accessibilityHidden`.
- **§7.3** CarPlay library read moved off the main actor (`AudiobookDAO.allAsync()`).
- **§8.1** fidget physics advanced via `.onChange(of:)`, not inside the `Canvas` render closure.
- **§6.1** `.apkg`/EPUB extraction now capped (per-entry 100 MB, total 512 MB) via `ArchiveExtractionLimits` + unit tests.
- **§3.7 (partial)** corrected the stale backdoor comment; the registry refactor remains a deliberate decision.
- **§8.4 (partial)** removed the dead `topBannerColor`; the header-contrast question remains (and the audit headline was inaccurate — see below).
- **§3.5** unwrapped 11 no-op `DispatchQueue.main.async` hops in seek completions (left the one genuine deferral); 22 playback tests pass.
- **§3.8** macOS `waitForReadyToPlay` continuation guarded against double-resume (single-shot `finish()` on main).
- **§8.2** `DeckDetailView` filter hoisted from `body` into `@State` recomputed on change.
- **CI gating** — branch protection enabled on `main` requiring the "Build gate + tests" check (`enforce_admins: false`). Merge this branch first so `main` carries the new `ci.yml`.

_A read-only multi-agent pass re-verified the remaining findings against the current tree. Several were over-stated or mis-framed: §3.6 (the one looping task already does what's asked; the others are one-shot/struct where deinit-cancel is impossible/harmful), §8.2 (`StatsView`'s citation has no such problem — only `DeckDetailView`'s per-keystroke filter is real), §8.4 (the flagged color is user-picked, not image-derived; the cover-derived value is already contrast-safe), §7.4 (a naive bounded buffer would hang the test suite via the `pendingCount` leak and corrupt analytics)._

### 🔲 Still open from this audit
Highs: **none remaining.** All low-risk, build/test-verifiable Mediums are now done (§3.5/§3.8/§8.2 above). What remains needs a product/design decision or is deferred:
- **Needs a decision**: §3.6 (transcript-staleness generation token, or close as over-stated), §3.7 (CarPlay registry vs. keep), §5.5 (location auth: in-actor delegate bridge vs. a Settings toggle that doesn't exist yet — feature currently unreachable), §5.7 (pick the single bookmark source-of-truth — split 3 ways today), §7.4 (coalesce idempotent progress-ticks vs. bounded buffer), §8.4 (header foreground contrast approach).
- **Deferred**: §4.1 (`Timer`→structured, 9 sites, not a bug), §9.2 (oversized files). Plus the Lows (§3.4 done; §4.2, §5.6, §6.2–§6.4, §8.5–§8.7, §9.3).

---

## 1. Executive summary

Top items to address, in priority order:

1. **[Critical — ✅ FIXED this session] `@frozen` on an internal struct broke the build** — §5.1 — `EchoCore/Views/Visualizer/VisualizerView.swift:7`. It masked a chain of ~8 compile errors (§5.8–§5.11) across the iOS `EchoCore` module and the `Echo macOS` target — all now fixed; every scheme builds green. Remaining action: add a CI build gate (§10 rec. 5).
2. **[High] CarPlay disconnect teardown never runs** — §5.2 — `EchoCore/CarPlay/CarPlaySceneDelegate.swift:17`. The delegate method name matches no protocol requirement, so `manager?.disconnect()` is dead code.
3. **[High] Data race: captured `var card` mutated in a `@Sendable` GRDB write** — §3.2 — `Shared/Services/ChapterCardDrafter.swift:97`. Swift-6-mode error; latent race in the new auto-draft service.
4. **[High] Widget AppIntents touch a main-actor, non-Sendable `AppGroupDefaults` from a nonisolated `perform()`** — §3.1 — `Echo Widget/Models/AppIntent.swift:11,28,36`. Five Swift-6-mode errors.
5. **[High] Pure stats/FSRS functions are implicitly `@MainActor` but called off-main** — §3.3 — `Shared/Stats/StatsRepository.swift:333,354,374,450`. Forces aggregation onto the main actor; Swift-6-mode errors at the call sites.
6. **[Medium] Metal command-buffer / encoder force-unwraps in the per-frame draw loop** — §5.3 — `EchoCore/Views/Visualizer/VisualizerView.swift:114-115`. Latent crash when Metal returns nil under GPU pressure / backgrounding.
7. **[Medium] Visualizer audio tap copies the full sample buffer every callback on the realtime thread** — §7.1 — `EchoCore/Services/DefaultVisualizerTap.swift:58`.
8. **[Medium] CarPlay library refresh does a synchronous GRDB read on the main actor** — §7.3 — `EchoCore/CarPlay/CarPlayManager.swift:134-140`.
9. **[Medium] FSRS scheduler silently drops the next-review date on calendar overflow** — §5.4 — `Shared/Database/FSRSScheduler.swift:76-77`.
10. **[Medium] `sanitize(_:)` triplicated across three export services** — §9.1 — `ApkgExportService.swift:332`, `StudyNotesExportService.swift:124`, `MacApkgExportService.swift:345`.

---

## 2. Quick wins (≤30 min each)

These deliver outsized value relative to effort and have no architectural ripples.

- ~~Remove `@frozen` from `VisualizerUniforms`~~ ✅ **done this session** (§5.1), along with the rest of the build-repair chain (§5.8–§5.11). Remaining quick win: wire a CI build gate so this can't regress.
- **Drop `nonisolated(unsafe)` → `nonisolated`** — `EchoCore/Services/AudioEngine.swift:71-73`. Compiler says the `unsafe` has no effect; clears 3 warnings (§3.4).
- **Mark the four `StatsAggregator` functions `nonisolated static`** — clears the 4 main-actor-isolation warnings at `StatsRepository.swift:333,354,374,450` (§3.3).
- **Remove the unused `dailyTotals` binding** — `Shared/Stats/StatsRepository.swift:108`. Dead `let` (§9.5).
- **Remove the two spurious `await`s** — `Shared/Services/ChapterCardDrafter.swift:32,112` ("no async operations occur within 'await' expression").
- **Rename the CarPlay disconnect delegate** to the real `CPTemplateApplicationSceneDelegate` requirement — `CarPlaySceneDelegate.swift:17` (§5.2). Small change, restores disconnect teardown.

---

## 3. Concurrency

### 3.1 Widget AppIntents access a main-actor, non-Sendable `AppGroupDefaults` from a nonisolated `perform()`
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — both `perform()` methods marked `@MainActor`; 5 warnings cleared, build verified.
- **Location:** `Echo Widget/Models/AppIntent.swift:11, 28, 36` (root: `Shared/AppGroupDefaults.swift:10`)
- **What:** Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `AppGroupDefaults.shared` (a `UserDefaults`) and `Bookmark.init` are main-actor-isolated, but `AppIntent.perform()` is nonisolated `async`; the compiler emits 5 warnings ("cannot be accessed from outside of the actor" / "non-Sendable type 'UserDefaults' … cannot exit main actor-isolated context" — errors in Swift 6).
- **Why:** This is the project's main Swift-6-language-mode blocker; `UserDefaults` is not `Sendable` and crossing the boundary is a data race the compiler will reject.
- **Action:** Either annotate the two `perform()` methods `@MainActor`, or read the needed primitives inside an `await MainActor.run { … }` and build a `Sendable` snapshot before leaving. Prefer a small main-actor accessor on `AppGroupDefaults` that returns value types.
- **Severity:** High

### 3.2 Data race: captured `var card` mutated inside a `@Sendable` GRDB write closure
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — `let card` + a local mutable copy inside the write closure; warning cleared, `ChapterCardDrafterTests` green.
- **Location:** `Shared/Services/ChapterCardDrafter.swift:72-97` (mutation at `:97`)
- **What:** `var card` (line 72) is captured by the `@Sendable` `db.write { db in try card.insert(db) }` closure (line 97); GRDB's `insert` is `mutating`, so the closure mutates a `var` that also lives in the enclosing scope — "mutation of captured var 'card' in concurrently-executing code" (Swift-6-mode error).
- **Why:** Today the `await` serializes execution so no runtime race occurs, but it is a Swift-6 blocker and a genuinely fragile pattern in the new auto-draft path.
- **Action:** Capture an immutable copy into the closure (`let toInsert = card; try await db.write { db in var c = toInsert; try c.insert(db) }`), or move the insert into a free function that takes the record by value.
- **Severity:** High

### 3.3 Pure stats / FSRS functions are implicitly `@MainActor` but invoked off-main
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — the four functions marked `nonisolated static` (per-function, not whole-type); 4 warnings cleared, `StatsAggregatorTests`/`StatsRepositoryTests` green.
- **Location:** call sites `Shared/Stats/StatsRepository.swift:333, 354, 374, 450`; definitions `Shared/Stats/StatsAggregator.swift:303, 320, 344, 354`
- **What:** `retentionCurve`, `dueForecast`, `gradeDistribution`, and `plannerAdherence` are pure static functions but are implicitly main-actor-isolated under default isolation; `StatsRepository` calls them inside `nonisolated`/DB-reader contexts → "call to main actor-isolated static method … in a synchronous nonisolated context."
- **Why:** Forces analytics math onto the main actor (jank risk on large histories) and is a Swift-6-mode error at each call site.
- **Action:** Mark the four functions `nonisolated static` (or hoist them to free functions in a non-isolated file). They take their inputs as parameters and have no main-actor state, so this is safe.
- **Severity:** High

### 3.4 `nonisolated(unsafe)` has no effect on the AudioEngine subsystem properties
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — annotation removed → plain `var` (all access is main-actor); 3 warnings cleared. NB: plain `nonisolated` is illegal on a mutable `@ObservationTracked` stored property, so removal — not `nonisolated` — is the correct fix.
- **Location:** `EchoCore/Services/AudioEngine.swift:71-73` (`soundscapeMixer`, `chimePlayer`, `visualizerTap`)
- **What:** All three are declared `nonisolated(unsafe) var`; the compiler reports the `unsafe` qualifier "has no effect, consider using 'nonisolated'."
- **Why:** Misleading annotation — it signals a data-race concern that the compiler says doesn't exist here, adding cognitive noise.
- **Action:** Replace with plain `nonisolated`. If these are only ever read on the audio path and set once at graph-configuration time, consider `let` + injection to make the immutability explicit.
- **Severity:** Low

### 3.5 Redundant `DispatchQueue.main.async` inside already-`@MainActor` methods
- **Location:** `EchoCore/Services/PlaybackController.swift:160, 317, 333, 489, 509, 549, 661, 693, 706, 794, 847, 868`; `EchoCore/ViewModels/PlayerModel.swift:683`
- **What:** Completion handlers inside main-actor-isolated methods re-hop to main via `DispatchQueue.main.async`.
- **Why:** Redundant thread hops add latency and obscure the actual isolation; in async contexts they defeat structured-concurrency ordering guarantees.
- **Action:** Where the enclosing context is already `@MainActor`, mutate directly. Where the callback truly arrives off-main (AVFoundation completion), prefer `Task { @MainActor in … }` or `MainActor.assumeIsolated`. Audit each site — several are no-ops.
- **Severity:** Medium

### 3.6 `Task.detached` without a retained handle or cancellation
- **Location:** `EchoCore/Services/InlineFlashcardTriggerController.swift:48, 130`; `EchoCore/Services/TranscriptService.swift:24, 43`; `EchoCore/Services/StandaloneTranscriptionService.swift:59`
- **What:** Detached tasks are spawned without storing the handle or checking `Task.isCancelled` in their loops.
- **Why:** They outlive their owner and keep running after the view/service is gone — wasted CPU and possible access to stale state. Transcription tasks in particular are long-running.
- **Action:** Store each `Task` and `.cancel()` it in `deinit`/`onDisappear`, and add `try Task.checkCancellation()` (or `guard !Task.isCancelled`) inside long loops. Prefer structured `Task {}` tied to the owner over `Task.detached` unless isolation truly must be shed.
- **Severity:** Medium

### 3.7 CarPlay reaches `PlayerModel` through a static weak singleton backdoor
- **Location:** `EchoCore/EchoCoreApp.swift:21` (used by `CarPlaySceneDelegate`)
- **What:** `@MainActor static weak var playerModel: PlayerModel?` is a documented `REFACTOR-TODO (§3.13)` backdoor so the non-SwiftUI CarPlay scene delegate can reach the shared model.
- **Why:** Global mutable state creates initialization-ordering and concurrency hazards and blocks testability; the TODO is already acknowledged.
- **Action:** Replace with a small `@MainActor` registry/container keyed by scene identifier (or inject via the scene's `userInfo`), then delete the static. Low risk because the CarPlay code paths don't change.
- **Severity:** Medium

### 3.8 `withCheckedContinuation` + KVO + `asyncAfter` timeout race (macOS)
- **Location:** `Echo macOS/Views/MacPlayerModel.swift:120-134`; `Echo macOS/Views/TranscriptionManager.swift:244`
- **What:** An AVPlayer status change is awaited via `withCheckedContinuation`, with a `DispatchQueue.main.asyncAfter` timeout fallback; the observer and the timeout can both try to resume.
- **Why:** A checked continuation resumed twice traps; the KVO observer can also dangle if the timeout wins first.
- **Action:** Guard resumption with a single-shot flag, remove the observer on resume, and prefer wrapping the KVO in an `AsyncSequence` or using a `Task` timeout helper. (macOS target received lighter coverage — see §11.)
- **Severity:** Medium

### 3.9 Spurious `await` on synchronous expressions
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — both redundant `await`s removed.
- **Location:** `Shared/Services/ChapterCardDrafter.swift:32, 112`
- **What:** "no 'async' operations occur within 'await' expression" — the awaited GRDB read closures resolve synchronously here.
- **Why:** Harmless but noisy; obscures which awaits are real suspension points.
- **Action:** Remove the redundant `await` (or restructure to the genuinely-async GRDB API). Quick win.
- **Severity:** Low

---

## 4. API modernity

### 4.1 `Timer.scheduledTimer` for periodic work instead of structured concurrency
- **Location:** `EchoCore/Services/TimelineService.swift:171`; `EchoCore/Services/AudioEngine.swift:273, 440` (plus `fadeTimer`/`timeTimer` fields at `:77, :82`); `EchoCore/Services/AutoAlignmentService.swift:509`; `EchoCore/Services/SleepTimerManager.swift:34` (and ~10 more sites)
- **What:** RunLoop-based timers drive 1 Hz / 0.5 Hz ticks across long-lived services; they require manual `invalidate()` and aren't cancellation- or isolation-aware.
- **Why:** Timers leak if invalidation is missed and don't compose with task cancellation/actor isolation, complicating teardown.
- **Action:** Migrate to `Task { for await _ in … }` loops with `Task.sleep`, or an `AsyncTimerSequence`, owned by the service and cancelled on teardown. (UI marquee/clock timers that already use `TimelineView` are fine.)
- **Severity:** Medium

### 4.2 Legacy AVPlayer KVO status observation (macOS)
- **Location:** `Echo macOS/Views/MacPlayerModel.swift:120-134`
- **What:** AVPlayer item readiness is observed via manual KVO wrapped in a continuation rather than an async-friendly abstraction.
- **Why:** KVO bridging is error-prone (see §3.8) and harder to cancel than an `AsyncSequence`.
- **Action:** Wrap the KVO in an `AsyncStream` once and reuse, or adopt the modern timed-metadata/observation patterns. Low urgency.
- **Severity:** Low

> _Positive note:_ the codebase is otherwise modern for its iOS-18/macOS-15/watchOS-11 floor — `@Observable` throughout (no `ObservableObject`/`@Published`), `Synchronization.Atomic` (post-`OSAtomic`), and `CLLocationUpdate.liveUpdates()` rather than the CLLocationManager delegate. No dead `@available(iOS ≤18, *)` guards were found.

---

## 5. Bugs / logic errors

### 5.1 `@frozen` on an internal struct — build-breaking  ✅ FIXED
- **Location:** `EchoCore/Views/Visualizer/VisualizerView.swift:7-8`
- **What:** `@frozen struct VisualizerUniforms` was `internal`; `@frozen` is only valid on `public`/`package`/`@usableFromInline` declarations, so the compiler emitted a hard `error:`.
- **Why:** EchoCore did not compile, which broke the Echo app, macOS, and Widget targets that embed it (mirrors the prior audit's #1 finding where a target didn't build). Critically, this error **aborted type-checking before the rest of the module was reached**, masking §5.8–§5.11 below.
- **Action:** ✅ Deleted the `@frozen` attribute. **Still open:** add a CI build gate (`xcodebuild build`, RAM-capped) so a non-compiling commit can't merge again — see §10 (recommendation 5).
- **Severity:** Critical

### 5.8 `VisualizerUniforms` init writes to a tuple via a mis-typed pointer  ✅ FIXED
- **Location:** `EchoCore/Views/Visualizer/VisualizerView.swift:22-27`
- **What:** `withUnsafeMutablePointer(to: &s)` yields a pointer to the 16-`Float` *tuple*, so `UnsafeMutableBufferPointer(start: ptr, …)` was typed `<(Float×16)>` and `buf[i] = spectrum[i]` was a `Float`-to-tuple assignment error.
- **Why:** Compile error (masked behind §5.1) in the spectrum-upload path of the new visualizer.
- **Action:** ✅ Rebound the pointer with `withMemoryRebound(to: Float.self, capacity: 16)` (valid — a homogeneous tuple is contiguous, identical layout to `[Float]`).
- **Severity:** High (was build-breaking)

### 5.9 CarPlay `CPListItem.handler` closures had the wrong arity  ✅ FIXED
- **Location:** `EchoCore/CarPlay/CarPlayManager.swift:153, 216, 229, 273`
- **What:** Each `item.handler = { _ in … }` (or `{ [weak model] _ in … }`) supplied a **one-argument** closure, but `CPListItem.handler` (via `CPSelectableListItem`) is `(item, completion) -> Void`. The arity mismatch made each enclosing `.map` un-type-checkable ("failed to produce diagnostic for expression").
- **Why:** Compile error (masked behind §5.1) across all four CarPlay list templates (library, aggregated chapters, chapters, bookmarks).
- **Action:** ✅ Changed to `{ _, completion in … completion() }`, calling `completion()` to dismiss CarPlay's loading indicator (used `defer` on the library item that has an early `return`). Distinct from §5.2 (the dead `didDisconnect` delegate), which remains open.
- **Severity:** High (was build-breaking)

### 5.10 `DefaultChimePlayer` scheduled a file via the now-`async` overload  ✅ FIXED
- **Location:** `EchoCore/Services/DefaultChimePlayer.swift:64`
- **What:** Bare `playerNode.scheduleFile(file, at: nil)` resolved, in the `async` `fireChime`, to the iOS-18 `async` overload that suspends until playback finishes — "expression is 'async' but is not marked with 'await'." Adding bare `await` would compile but break the logic (it would wait for playback to complete *before* `play()` is ever called).
- **Why:** Compile error (masked behind §5.1); naive `await` fix would be a silent functional bug.
- **Action:** ✅ Passed `completionHandler: nil` to select the non-blocking overload, preserving the schedule-then-play ordering. (Sibling calls in `DefaultSoundscapeMixer`/`BookmarkStore` pass trailing closures and were already unambiguous.)
- **Severity:** High (was build-breaking)

### 5.11 GRDB symbols used without `import GRDB`; un-awaited async DB reads  ✅ FIXED
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:371`; `Echo macOS/Views/MacAnkiExportView.swift:140, 172`; `Echo macOS/Services/MacApkgExportService.swift:64, 78`
- **What:** Three files referenced GRDB's `Column`/records without `import GRDB` ("cannot find 'Column' in scope"), and two macOS call sites invoked `async` `DatabaseWriter.read`/`export(...)` without `await`. All were masked behind §5.1 (iOS) and the macOS GRDB error (macOS target).
- **Why:** Compile errors blocking both the iOS and macOS builds; the never-compiled Wave-1 code (standalone-transcript check, Anki export) shipped with these.
- **Action:** ✅ Added `import GRDB` (qualifying `GRDB.Column` in `PlayerModel` to avoid an ambiguity with another imported module), and added `try await` to the genuinely-async DB/export calls (sync `db.read` inside the non-async `compactMap` at `MacApkgExportService:67` was correctly left as-is).
- **Severity:** High (was build-breaking)

### 5.2 CarPlay `didDisconnect` delegate method never fires
- **Location:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift:17-23`
- **What:** `templateApplicationScene(_:didDisconnect:)` matches no `CPTemplateApplicationSceneDelegate` requirement (compiler: "nearly matches optional requirement … `didSelect`"), so CarPlay never calls it; `manager?.disconnect()` and `self.manager = nil` are dead.
- **Why:** On CarPlay disconnect the `CarPlayManager` (and its `CPInterfaceController` reference + templates) are never torn down — a leak and stale state on reconnect.
- **Action:** Rename to the exact SDK requirement (`templateApplicationScene(_:didDisconnectInterfaceController:)`, verify against the CarPlay headers) so the disconnect path actually runs.
- **Severity:** High

### 5.3 Metal command-buffer / encoder force-unwraps in the per-frame draw loop
- **Location:** `EchoCore/Views/Visualizer/VisualizerView.swift:114-115`
- **What:** `commandQueue.makeCommandBuffer()!` and `buffer.makeRenderCommandEncoder(descriptor:)!` are force-unwrapped inside `draw(in:)` (called every frame), while the rest of the method correctly `guard let`s its Metal resources (lines 94-97, 105).
- **Why:** Both can return nil under GPU memory pressure, command-buffer exhaustion, or app backgrounding mid-draw — a crash, inconsistent with the safe handling around it.
- **Action:** `guard let buffer = commandQueue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }` and skip the frame.
- **Severity:** Medium

### 5.4 FSRS scheduler silently drops the next-review date on calendar overflow
- **Status:** ✅ **FIXED (2026-06-13 session 2)** — `nextInterval` now clamps to `maximumIntervalDays` (36,500) so `Calendar.date(byAdding:)` cannot overflow, and the (now-unreachable) nil branch logs instead of silently dropping the schedule. Fixed as part of the canonical FSRS-4.5 rewrite (see the FSRS/SM-2 note in the Remediation progress section).
- **Location:** `Shared/Database/FSRSScheduler.swift:76-77`
- **What:** `Calendar.current.date(byAdding: .day, value: interval, to: now)` returns optional; on overflow (very large stability intervals near `Date.distantFuture`) it yields nil with no logging or clamp, leaving `nextReviewDate` unset.
- **Why:** A card with an unset next-review date silently falls out of the spaced-repetition queue — a correctness bug in the scheduling core.
- **Action:** Clamp `interval` to a sane maximum (e.g. 36,500 days) before the calendar add, and log if the result is still nil.
- **Severity:** Medium

### 5.5 `LocationCaptureService` never requests `.notDetermined` authorization
- **Location:** `EchoCore/Services/LocationCaptureService.swift:19-36`
- **What:** `capture()` proceeds only for `.authorizedWhenInUse`/`.authorizedAlways`; on `.notDetermined` it returns nil without ever calling `requestWhenInUseAuthorization()`.
- **Why:** If permission was never requested elsewhere, the location-tagging feature silently no-ops and the user is never prompted, appearing broken.
- **Action:** Handle `.notDetermined` by requesting authorization (or confirm the request is made at onboarding and document the precondition). Also handle `.denied`/`.restricted` with user-visible messaging.
- **Severity:** Medium

### 5.6 Force-unwraps that are provably safe but read as fragile
- **Location:** `EchoCore/CarPlay/CarPlayManager.swift:33-35`; `EchoCore/Services/AlignmentService.swift:232`; `EchoCore/Views/ReaderFeedCollectionView.swift:389`; `Echo macOS/Views/MacAnkiExportView.swift:219, 310`
- **What:** Each `!` is safe given a local invariant — CarPlay templates are assigned non-nil immediately above (lines 27-29); `anchorTimeByBlockID[…]!` keys are guaranteed by the `filter` at `AlignmentService.swift:218`; `uniqueStack.last!` is gated by `count == uniqueStack.count >= 3` (line 375); the AnkiConnect `URL(string:)!` is a static literal.
- **Why:** No crash today, but invariant-dependent force-unwraps are landmines for future edits (e.g. someone mutates `anchorTimeByBlockID` between filter and access).
- **Action:** Replace with `guard let`/`?? <fallback>` to make the invariants explicit. Low priority.
- **Severity:** Low

### 5.7 Widget `CreateBookmarkIntent` writes bookmarks into a UserDefaults JSON blob
- **Location:** `Echo Widget/Models/AppIntent.swift:45-51`
- **What:** The intent appends a `Bookmark` to `bookmarks_<folderKey>` as JSON in `AppGroupDefaults`, while the main app's bookmark persistence was migrated to GRDB/per-book storage in the prior remediation (§5.3 of the 2026-06-09 audit).
- **Why:** If the app no longer reads this UserDefaults path, widget-created bookmarks are silently lost — a data-integrity gap.
- **Action:** Verify the app still ingests `bookmarks_<folderKey>` from the app group on launch; if not, route the widget intent through the shared persistence layer (or a hand-off queue the app drains).
- **Severity:** Medium

---

## 6. Security

### 6.1 `.apkg` extraction has no per-entry or total size cap (zip-bomb DoS)
- **Location:** `EchoCore/Services/ApkgImportService.swift:106-139` (`extractSafely`)
- **What:** Each archive entry is extracted to temp with no size/entry-count ceiling; a crafted `.apkg` (highly compressible payload) could exhaust temp disk during import.
- **Why:** Local DoS / disk exhaustion from an untrusted file. (Zip-slip itself **is** handled — see §6.5.)
- **Action:** Enforce a per-entry uncompressed-size limit and a total-extraction budget; abort with `ImportError.extractionFailed` when exceeded. The same guard belongs in `EPUBAutoImportScanner`.
- **Severity:** Medium

### 6.2 AnkiConnect bridge uses plain HTTP to localhost
- **Location:** `Echo macOS/Views/MacAnkiExportView.swift:219, 310` (`http://localhost:8765`)
- **What:** The JSON-RPC bridge talks plain HTTP to the AnkiConnect addon on loopback.
- **Why:** Acceptable in practice — AnkiConnect offers no TLS and loopback isn't network-exposed — but it warrants two guardrails: the host must be pinned to loopback, and any App Transport Security exception must be scoped to `localhost`, not a blanket `NSAllowsArbitraryLoads`.
- **Action:** Confirm the `Info.plist` ATS exception is `NSExceptionDomains: localhost` only, and keep the host hardcoded to `localhost`/`127.0.0.1`. No protocol change needed.
- **Severity:** Low

### 6.3 Hand-rolled JSON string escaping in the Anki exporter
- **Location:** `EchoCore/Services/ApkgExportService.swift:310-314`
- **What:** `makeDeckJSON` escapes strings via `replacingOccurrences(of:with:)`, which misses control characters (`\u{00}`, `\r`, `\t`) and other JSON edge cases.
- **Why:** Flashcard text containing control characters can produce malformed JSON in the exported deck.
- **Action:** Build the payload with `JSONEncoder`/`JSONSerialization` instead of manual escaping.
- **Severity:** Low

### 6.4 Exported voice-memo URLs copied without container validation
- **Location:** `EchoCore/Services/StudyNotesExportService.swift:38-44`
- **What:** `bm.voiceMemoURL(in: nil)` is copied into `assets/` without asserting the source is inside the app container.
- **Why:** Low risk because the URL is derived from app-controlled `Bookmark` records, but a corrupted record pointing outside the container would copy an unintended file into an export.
- **Action:** Assert the resolved source URL is within Documents/Application Support before copying; skip otherwise.
- **Severity:** Low

### 6.5 _Verified clean: `.apkg` SQLite handling is not injectable_
- **Location:** `EchoCore/Services/ApkgImportService.swift:74-99, 200-320`
- **What:** The untrusted Anki collection DB is opened **read-only** (`config.readonly = true`, line 78); all reads are static `SELECT`s and all writes into Echo's DB use parameterized `arguments:`. Zip extraction is guarded by `safeDestination` (lines 143-156), the same hardened pattern as the remediated EPUB path.
- **Why:** Recorded so the agent-reported "SQL injection from untrusted .apkg" claim isn't re-raised — there is no string interpolation of untrusted data into SQL, and read-only mode mitigates a malicious DB.
- **Action:** None. Optionally add a lightweight schema sanity-check (expected tables present) for friendlier error messages on corrupt files.
- **Severity:** Low (informational)

---

## 7. Performance

### 7.1 Visualizer audio tap copies the full sample buffer every callback on the realtime thread
- **Location:** `EchoCore/Services/DefaultVisualizerTap.swift:52-60` (copy at `:58`)
- **What:** The `installTap` block runs on the realtime audio render thread and does `Array(samples)` (a full allocation + copy) plus an `AsyncStream` yield each callback (~30–60 Hz).
- **Why:** Allocations on the audio render thread risk priority inversion and audio glitches; this is the hottest path in the new visualizer subsystem.
- **Action:** Analyze in place via the `UnsafeBufferPointer` (compute RMS/peak/FFT bins without copying), reuse a preallocated scratch buffer, and yield only the small `VisualizerFrame` — never the raw samples. Keep the tap block allocation-free.
- **Severity:** Medium

### 7.2 `VisualizerView` creates two `MTLDevice`s and re-derives pipeline state
- **Location:** `EchoCore/Views/Visualizer/VisualizerView.swift:50, 81-82`
- **What:** `MTLCreateSystemDefaultDevice()` is called in both `makeUIView` (line 50, for `view.device`) and `Coordinator.init` (line 81, for the command queue). The command queue is built from a *different* device handle than the view's.
- **Why:** Wasteful and subtly inconsistent — commands are encoded on the Coordinator's device but presented to the view's drawable. On iOS there is one system GPU so it works, but it's fragile.
- **Action:** Create the device once in `makeUIView`, pass it to the Coordinator, and build the command queue from `view.device`. Cache the pipeline state keyed by style (already partly done via `needsRebuild`).
- **Severity:** Medium

### 7.3 CarPlay library refresh runs a synchronous GRDB read on the main actor
- **Location:** `EchoCore/CarPlay/CarPlayManager.swift:134-140` (called from `connect` at `:40-42`)
- **What:** `refreshLibrary()` (and the chapters/bookmarks refreshes) do `AudiobookDAO(db: db.writer).all()` synchronously on the `@MainActor`.
- **Why:** A large library blocks the CarPlay UI thread on connect — visible lag or watchdog risk in the car (the prior audit's §3.2 flagged the same synchronous-DAO pattern elsewhere).
- **Action:** Make the refreshes `async` and use `try await db.read { … }`, populating templates once the data returns.
- **Severity:** Medium

### 7.4 `PlaybackSessionRecorder` has an unbounded `AsyncStream` buffer
- **Location:** `EchoCore/Services/PlaybackSessionRecorder.swift:73-76`
- **What:** Events are `yield`ed with the default unbounded buffering policy; a slow consumer (e.g. during fast scrubbing) lets the buffer grow without bound.
- **Why:** Memory growth under bursty playback events.
- **Action:** Construct the stream with `.bufferingNewest(n)` (or `.bufferingOldest`) so backpressure drops rather than accumulates.
- **Severity:** Medium

---

## 8. SwiftUI / UI

### 8.1 Fidget physics mutate `@State` inside the `Canvas` render closure
- **Location:** `EchoCore/Views/Fidget/KineticSandView.swift:21-29` (mutations at `:27-28`)
- **What:** Inside `TimelineView(.animation).Canvas { … }`, the body mutates `@State` (`lastUpdate`, and `particles` via `updateParticles`) during view rendering.
- **Why:** "Modifying state during view update" is undefined behavior in SwiftUI (purple runtime warning); it can also drive extra invalidations. The 60 Hz loop also keeps running while the fidget overlay is open on a paged-away tab.
- **Action:** Drive the simulation from the `TimelineView` date input (compute `dt` from the provided context date, not stored `@State`), keep particle state in an `@Observable` model updated outside `body`, and gate the timeline with `paused:` when the fidget isn't the active page.
- **Severity:** Medium

### 8.2 Stats aggregations computed in `body` instead of being cached
- **Location:** `EchoCore/Views/Stats/DeckListView.swift:30-31` (`reduce` over decks); `EchoCore/Views/Stats/DeckDetailView.swift:17-23` (`filteredCards` computed filter); `EchoCore/Views/Stats/StatsView.swift:89-112`
- **What:** Totals (`decks.reduce`) and case-insensitive filters run on every body evaluation rather than being computed once when data loads or `searchText` changes.
- **Why:** O(n)/O(n·m) work per redraw causes jank as decks/cards grow.
- **Action:** Compute totals in the `load()` task and store in `@State`; drive filtering off `.onChange(of: searchText)` or move it into the view model; split `booksSection` into its own `Equatable` subview to localize redraws.
- **Severity:** Medium

### 8.3 Onboarding icons use fixed point sizes (no Dynamic Type)
- **Location:** `EchoCore/Views/OnboardingView.swift:32-33, 47-48, 62-63, 77-78`
- **What:** Four hero SF Symbols are `.font(.system(size: 60))` — fixed, ignoring Dynamic Type.
- **Why:** They won't scale for accessibility text sizes, breaking the onboarding hierarchy on the first screen users see.
- **Action:** Use `@ScaledMetric` for the icon size (or a text style), and add `.accessibilityHidden(true)` since the adjacent `Text` already carries the meaning.
- **Severity:** Medium

### 8.4 Image-derived theme color may fail contrast in dark mode
- **Location:** `EchoCore/Views/ReaderTab.swift:38, 79`
- **What:** A cover-derived hex theme color is applied as a background/tint without a luminance-based contrast check; line 38 uses semantic `Color(uiColor: .systemBackground)` but line 79 layers the raw theme color.
- **Why:** User/image-derived colors don't auto-invert; a dark cover can yield dark-on-dark text.
- **Action:** Derive a contrasting foreground from the theme color's luminance (the new `OKLCH`/`CoverThemeBuilder` utilities already compute lightness — reuse them), and verify in both appearances.
- **Severity:** Medium

### 8.5 Missing `Equatable` on hot leaf views
- **Location:** `EchoCore/Views/Stats/StatCardView.swift:1-40` (used in a `LazyVGrid` in `StatsView`); pattern also applies to chart row subviews
- **What:** Leaf cards lack `Equatable`, so they re-render whenever the parent's unrelated state (e.g. `selectedBucket`) changes.
- **Why:** Redundant layout/render passes in grids of stat cards.
- **Action:** Conform hot, parameter-only leaf views to `Equatable` (or wrap with `.equatable()`), comparing just their displayed values.
- **Severity:** Low

### 8.6 `PKCanvasView` held in `@State`
- **Location:** `EchoCore/Views/Fidget/DoodlePadView.swift:11`
- **What:** A `PKCanvasView` (UIView) is stored in `@State` and mutated directly.
- **Why:** Accepted PencilKit practice, but `@State` won't observe the reference type's mutations, which can confuse future readers.
- **Action:** Optionally hold the canvas in the representable's `Coordinator` instead, leaving `@State` for value types. Low priority.
- **Severity:** Low

### 8.7 `ForEach(id: \.self)` on `CaseIterable` enums
- **Location:** `EchoCore/Views/Fidget/FidgetOverlayView.swift:54`; `EchoCore/Views/Visualizer/VisualizerPickerView.swift:21`
- **What:** Pickers iterate enum `allCases` with `id: \.self`.
- **Why:** Fine for small immutable enums, but identity shifts if cases are reordered/renamed.
- **Action:** Acceptable as-is; if you want robustness, give the enums an explicit stable `id`. Low priority.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 `sanitize(_:)` triplicated across export services
- **Locations:** `EchoCore/Services/ApkgExportService.swift:332-336`, `EchoCore/Services/StudyNotesExportService.swift:124-128`, `Echo macOS/Services/MacApkgExportService.swift:345` (related: `EchoCore/Services/EPUBAutoImportScanner.swift:365` `sanitizedPath`)
- **What:** Three identical filename-sanitization helpers (strip invalid filesystem chars + trim).
- **Why:** Three copies drift independently; the macOS copy duplicates the iOS exporter wholesale.
- **Action:** Extract one helper into `Shared/SafeFileName.swift` (distinct from the existing SHA-256 `fromAudiobookID`) and call it from all three. Worth checking `MacApkgExportService` vs `ApkgExportService` for further shareable export logic.
- **Severity:** Medium

### 9.2 Oversized files (>500 LOC)
- **`EchoCore/ViewModels/PlayerModel.swift:1360`** — already split into extensions (`+Bookmarks`, `+MarkedPassages`, `+WatchState`, …); continue extracting the playback-delegate and now-playing logic.
- **`Echo Watch App/Services/WatchViewModel.swift:973`** and **`Echo Watch App/Views/PlayerPage.swift:968`** — split watch playback state vs. connectivity, and page subviews.
- **`EchoCore/Services/PlaybackController.swift:922`** — extract the AVFoundation observation/seek code (also the §3.5 hotspot).
- **`EchoCore/Views/PlaylistView.swift:858`**, **`Bookmarks.swift:789`**, **`WatchAppSettingsView.swift:728`**, **`SettingsView.swift:639`**, **`ReaderTab.swift:629`**, **`Shared/EPUBXMLParsing.swift:744`**, **`EchoCore/Views/TimelineFeedCollectionView.swift:601`**.
- **Why:** Large files slow incremental compile and obscure ownership; the prior audit deferred these (§9.6) as "refactor when next touched."
- **Action:** Split opportunistically when editing each; no big-bang refactor needed for v1.0.
- **Severity:** Medium

### 9.3 Magic constants that should be named
- **Locations / values:** JPEG quality `0.8` at `EchoCore/Views/PDFDocumentView.swift:110` (vs the centralized `ImageEncoding.bookmarkJPEGQuality`); `.spring(response: 0.35, dampingFraction: 0.8)` duplicated at `BottomToolbarView.swift:141` and `Components/PlayerControlBar.swift:9`; voice-memo gain `targetPeak 0.9`/`maxGain 3.0`/`peak > 0.001` at `Bookmarks.swift:43-46`; audio chunk `8192` at `Bookmarks.swift:20` and sample rate `44100` at `DefaultVisualizerTap.swift:40`; scale/opacity `0.95`/`0.96` scattered across view transitions.
- **Why:** Tuning these requires hunting multiple files; the project already centralizes such values (`ImageEncoding`, `AnimationDurations`).
- **Action:** Move image-quality constants into `ImageEncoding`, add a named spring/transition preset to `AnimationDurations`, and create a small `AudioTuning` for buffer/sample-rate/gain values.
- **Severity:** Low

### 9.4 Technical-debt markers — essentially clean
- **What:** Repo-wide scan found **0** `TODO`/`FIXME`/`HACK`/`XXX`/`#warning` markers and **0** stray `print()` calls. The single tracked marker is `REFACTOR-TODO (§3.13)` at `EchoCore/EchoCoreApp.swift:21` (covered as §3.7).
- **Action:** None — recorded as a positive baseline.
- **Severity:** Low (informational)

### 9.5 Unused immutable binding
- **Location:** `Shared/Stats/StatsRepository.swift:108`
- **What:** `dailyTotals` is assigned from `StatsAggregator.dailyTotals(...)` and never read.
- **Action:** Delete the binding (or `_ =` if the call has needed side effects — it doesn't). Quick win.
- **Severity:** Low

---

## 10. Cross-cutting recommendations

1. **Close the Swift-6 readiness gap.** The 18 build diagnostics reduce to a handful of root causes: §3.1 (widget/main-actor `UserDefaults`), §3.2 (captured-var write), §3.3 (`@MainActor` pure functions), §3.4 (`nonisolated(unsafe)`), and §5.1 (the build error). Fixing these gets the project compiling cleanly and most of the way to enabling the Swift 6 language mode. Track it as one milestone.
2. **Give the new realtime-audio subsystems an isolation + allocation contract.** The visualizer tap (§7.1), soundscape mixer, and chime player all touch the AVAudioEngine render thread. Establish one rule: tap/callback blocks are allocation-free and `Sendable`-clean, all engine-graph mutation happens on `@MainActor` in `configureEngineGraph`, and only small value snapshots cross to the UI. §3.4 and §7.1 are symptoms of this not being written down.
3. **Unify the export/import support code.** `.apkg` import/export (iOS + macOS), study-notes export, and EPUB import each re-implement filename sanitization (§9.1), zip extraction, and JSON building (§6.3). Extract a shared `ExportSupport`/`ArchiveSupport` with the hardened zip-slip guard, the size cap (§6.1), `JSONEncoder` helpers, and one `sanitize`. One place to harden, one place to test.
4. **Centralize tuning constants** (§9.3) in the existing `Shared/` constant files so audio/animation feel is adjustable in one spot.
5. **Add a CI build-gate.** §5.1 is a one-line error that shipped in a commit; a `xcodebuild build` smoke check on the Echo scheme (RAM-capped per `CLAUDE.md`) in CI would have caught it before merge.

---

## 11. What was NOT audited

- `Tools/` (Python Whisper pipeline), `Scripts/`, `docs/`, `fastlane/` — out of scope.
- Algorithmic correctness of the single Metal shader (`VisualizerShaders.metal`) and the on-device WhisperKit/DTW alignment math — surface issues only.
- Third-party SPM internals (GRDB, WhisperKit, ZIPFoundation, swift-transformers, swift-crypto, yyjson) — treated as black boxes.
- The **Echo macOS** target and **Widget** target received lighter coverage than iOS/EchoCore; their entitlements files were not opened — verify the App Group / iCloud container IDs match the values used elsewhere (the prior rebrand to `com.echo.*`).
- StoreKit 2 product configuration (`StoreManager` / any `.storekit` file) — code structure only, not App Store Connect parity.
- Deep test-coverage review of `EchoTests`/`Echo Watch AppTests` — scanned only, not assessed for adequacy.
- Localization / string catalogs and Dynamic Type at extreme sizes across all screens — spot-checked in new views only.
- Instruments profiling (hangs/hitches/allocations) — §7 identifies *potential* hot paths by inspection, not from traces.
- Build settings / scheme configuration beyond what the shared Echo scheme exposes.

---

## 12. Verification

Spot-check pattern: in Xcode, command-click any `path:line` below — it should land on the cited code. Every Critical/High has an exact range, not "scattered throughout." Several agent-reported "Critical/High" items were **demoted or dropped** during this pass:

- **Dropped** — `Shared/Database/ClozeParser.swift:48-49` "bounds panic": Swift's `dropFirst`/`dropLast` saturate (never trap) and the regex `([^}]+)` requires ≥1 answer char, so `{{c1::}}` never matches. The "ReDoS" claim is also false — a single non-nested character class can't backtrack catastrophically.
- **Dropped** — `.apkg` "SQL injection / unvalidated SQLite": the collection DB is opened read-only with parameterized/static queries (§6.5).
- **Demoted to Low** — `CarPlayManager.swift:33-35`, `AlignmentService.swift:232`, `ReaderFeedCollectionView.swift:389` force-unwraps: each is safe under a verified local invariant (§5.6).
- **Demoted to Low** — AnkiConnect "HTTP is insecure" (§6.2) and `DoodlePadView` `PKCanvasView`-in-`@State` "undefined behavior" (§8.6).

Lines that prove each Critical/High claim:

- **§5.1** — open `EchoCore/Views/Visualizer/VisualizerView.swift`, lines 7-8: `@frozen` sits directly above `struct VisualizerUniforms` (no `public`/`@usableFromInline`). The build log shows the matching `error:` on line 7.
- **§5.2** — open `EchoCore/CarPlay/CarPlaySceneDelegate.swift`, lines 17-23: the method is `templateApplicationScene(_:didDisconnect:)`; the compiler warns it "nearly matches optional requirement … `didSelect`," confirming it satisfies no requirement and never fires.
- **§3.2** — open `Shared/Services/ChapterCardDrafter.swift`, lines 72 and 97: `var card` is declared at 72 and mutated inside the `@Sendable` `db.write { … card.insert(db) }` at 97.
- **§3.1** — open `Echo Widget/Models/AppIntent.swift`, lines 11, 28, 36: `AppGroupDefaults.shared` is read/written in nonisolated `perform()`s and `Bookmark(...)` is constructed at 36; cross-reference the 5 build warnings.
- **§3.3** — open `Shared/Stats/StatsRepository.swift`, lines 333, 354, 374, 450 (call sites) and `Shared/Stats/StatsAggregator.swift`, lines 303, 320, 344, 354 (pure static defs).
- **§5.3** — open `EchoCore/Views/Visualizer/VisualizerView.swift`, lines 114-115: `makeCommandBuffer()!` and `makeRenderCommandEncoder(descriptor:)!`, contrasted with the `guard let`s at 94-97 and 105.
- **§7.1** — open `EchoCore/Services/DefaultVisualizerTap.swift`, lines 52-60: `Array(samples)` (line 58) inside the realtime tap block.
- **§7.3** — open `EchoCore/CarPlay/CarPlayManager.swift`, lines 134-140: synchronous DAO read invoked from `connect` (lines 40-42), class is `@MainActor` (line 12).
- **§5.4** — open `Shared/Database/FSRSScheduler.swift`, lines 76-77: optional `Calendar.date(byAdding:)` result assigned with no clamp/log.
- **§9.1** — open `ApkgExportService.swift:332`, `StudyNotesExportService.swift:124`, `MacApkgExportService.swift:345`: three identical `sanitize(_:)` bodies.

If any finding doesn't reproduce when you open the line, flag the specific §N.M and I'll re-investigate.
