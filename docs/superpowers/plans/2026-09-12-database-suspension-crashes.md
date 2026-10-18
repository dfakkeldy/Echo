# Database suspension crash fix plan

**Goal:** Prevent Echo from retaining SQLite locks when iOS suspends it, while preserving book data, read-along recovery, and background playback.

**Status:** Implementation authorized September 12, 2026, including PR and merge on green CI. Local Apple builds are held by the configured schedule; hosted CI will provide the build/test gate.

**Baseline:** `e2d231d8` on `origin/nightly`, inspected September 12, 2026. Recheck the branch before implementation.

**Architecture:** An iOS process-level database lifecycle coordinator owns finite background execution assertions and GRDB suspension/resumption. Expensive alignment computation runs outside the main actor and outside write transactions; replacement data commits atomically. Interrupted launch/import work remains retryable and cannot report successful completion.

**Stack and constraints:** Swift 6, SwiftUI, UIKit background tasks, existing GRDB 7.11.1, Swift Testing. Preserve iOS 18 / macOS 15 / watchOS 11 floors, existing observation architecture, and the release ladder. No new dependency. Keep raw reports and private book data out of the repository. Use concrete types and injected closures for lifecycle tests.

## Evidence and boundaries

- The three September 11–12 reports are Echo **0.6 (79)** on iOS 27 beta, terminated with `RUNNINGBOARD 0xdead10cc`. Their stacks include `AlignmentService.recalculateTimeline`, `WordTimingMaterializer`, `DocumentImportFinalizer`, and `PlayerLoadingCoordinator` post-load work.
- Two September 6 background reports from build 74 have the same termination code during `ContainerPathRepair`. The August 23 report from build 55 also shows alignment work with this code. Two September 6 launch submissions did not have retrievable crash attachments.
- The code identifies a suspension/file-lock failure; it does not establish that TurnTimer causes an audio conflict or explain why every reported process launched. Do not change TurnTimer or audio-session categories based on these reports.
- Current `DatabaseService.openForLaunch` already moves opening/repair to a dedicated queue. That addresses main-thread blocking but does not grant background execution or prevent lock acquisition during suspension.
- `DatabaseService.Connection` does not enable GRDB suspension notifications. Many DAOs use its exposed `writer`, so adding protection only to `DatabaseService.writeAsync` would leave bypasses.
- `WordTimingMaterializer.materialize` and chapter variants delete old rows in one transaction and insert replacements in another. Introducing interruptible work without repairing this boundary could leave missing timings.
- `AlignmentService` commits block alignment before materializing words. Recovery must account for an interruption between these stages as well as inside an individual transaction.
- `RootTabView` persists state and starts export work on inactive/background transitions. Playback has its own pause background task. Those paths must cooperate with database suspension rather than independently undoing it.

Sources: [Apple SIGKILL documentation](https://developer.apple.com/documentation/xcode/sigkill), [GRDB database sharing guidance at the pinned revision](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/Documentation.docc/DatabaseSharing.md). GRDB documents suspension support as experimental: validate the pinned behavior directly with disk-backed tests. Its pool `suspend()`/`resume()` methods are internal; use the public notifications and configuration, not those methods.

## 1. Add the database lifecycle safety boundary

**Files:** New `EchoCore/Services/DatabaseLifecycleCoordinator.swift`; modify `EchoCore/EchoCoreApp.swift` and `Shared/Database/DatabaseService.swift`; new `EchoTests/DatabaseLifecycleCoordinatorTests.swift` and `EchoTests/DatabaseSuspensionTests.swift`.

- [ ] Implement a concrete, main-actor coordinator with injected begin/end-background-task and post-notification closures. Own one process-level state machine, with operation tokens and a monotonically increasing lifecycle generation. UIKit-specific code stays in the iOS app; shared database code receives configuration/cancellation inputs without importing UIKit into CLI or other app targets.
- [ ] Define explicit states: foreground; background with a valid finite assertion; suspended/deferred. Starting or ending overlapping operations must not prematurely end protection for another operation. Repeated callbacks and expiration of an old token must not affect a newer generation.
- [ ] Acquire execution protection **before** scheduling database opening, migrations, repair, or potentially long alignment/import work. Handle `.invalid` from UIKit: defer lock-taking work in the background rather than proceeding without protection. Do not wait until an already-blocked main thread receives a background notification.
- [ ] Enable `Configuration.observesSuspensionNotifications` for the iOS-owned disk writer. Suspend using `Database.suspendNotification` when background execution expires, or immediately when backgrounded without protected work. Stop admission of new heavy work and request cancellation before releasing the assertion. Do not wait synchronously for the database queue from the expiration handler.
- [ ] Resume using `Database.resumeNotification` when foregrounded. A background callback may resume database access only within a newly granted finite assertion; merely having `isPlaying == true` or a new async task is not permission. End the assertion and return to suspended state once that background work finishes.
- [ ] Cover pool creation racing with background/expiration: notifications are not sticky. Keep launch protected, and pass a thread-safe cancellation/generation check to the opening operation before migrations/repair and after connection creation. A writer created after expiration must receive the current suspended state before further work or installation.
- [ ] Install lifecycle ownership at the app root before `openDatabaseIfNeeded`, including while the opening screen is visible. Distinguish actual application backgrounding from `.inactive` transitions such as Control Center. Use process lifecycle notifications so window transitions cannot wrongly suspend an active process.

**Tests:** Use injected expiration callbacks, without wall-clock sleeps, to cover foreground → background → expiration → foreground, denial, overlapping operations, duplicate notifications, old expiration after resume, cancellation during opening, and a new connection created during expiration. Add disk-backed GRDB tests showing an in-flight transaction aborts/rolls back and subsequent writes are refused until resume. Use a coordinated SQLite function or transaction hook on a dedicated worker to place interruption deterministically; never block the main actor or a cooperative thread to arrange the test. Serialize tests that post GRDB's process-wide notifications and restore resume state in cleanup.

**Pass condition:** An expired/background-suspended process cannot start another lock-taking write through the actual exposed writer; foreground reopening succeeds without replacing or damaging the database.

## 2. Make timing replacement safe to interrupt

**Files:** `Shared/Database/DAOs/WordTimingDAO.swift`, `EchoCore/Services/WordTimingMaterializer.swift`, `EchoCore/Services/AlignmentService.swift`; extend `EchoTests/WordTimingDAOTests.swift`, `EchoTests/WordTimingMaterializerTests.swift`, `EchoTests/WordTimingSynthesisRefineTests.swift`, and `EchoTests/AlignmentServiceTests.swift`.

- [ ] Add transaction-aware replacement helpers for a whole book and a specified chapter/block set. Generate replacement records before deleting old records; execute delete plus insert inside one GRDB write transaction. Accept an existing `Database` for composition and avoid nested `writer.write` calls.
- [ ] Route whole-book, chapter, and synthesized-chapter materialization through these helpers. Preserve all other books/chapters. Empty replacement input must still deliberately clear the requested scope when that is the correct successful result.
- [ ] Refactor the recalculation path to prepare block updates and interpolated word records from a consistent input snapshot. Commit the block updates and corresponding word replacement together when `materializeWordTimings` is true. Preserve the existing opt-out for callers that materialize once after multiple alignment steps.
- [ ] Audit finalizer sidecar replacement for the same delete/insert gap. Apply sidecar word replacements atomically, preserve manual anchors and existing source-word mapping, and only publish an alignment summary after the matching stage commits successfully.
- [ ] Reject stale prepared results when a newer import/alignment has changed the source snapshot. Serialize same-book rebuilds through their commit boundary and validate a per-book generation before writing; do not let two post-load paths overwrite newer work. Keep independent books independently schedulable.

**Tests:** Seed an existing timing set, inject a failure after deletion and partway through insertion, and assert the entire old set survives after rollback. Test whole-book, chapter, synthesized, sidecar, empty-scope, and unrelated-book cases. Interrupt recalculation between computation and commit and during commit; assert a coherent old or new alignment/timing pair, never a partial replacement. Reuse current timing fixtures to prove timestamps, chapter-local axes, hidden blocks, and narration/source-word mapping stay unchanged.

**Pass condition:** Cancellation or SQLite interruption cannot erase previously valid read-along timings or publish a partially applied replacement.

## 3. Keep long alignment work responsive and retryable

**Files:** `EchoCore/Services/AlignmentService.swift`, `EchoCore/Services/DocumentImportFinalizer.swift`, `EchoCore/Services/EPUBAutoImportScanner.swift`, `EchoCore/Services/PlayerLoadingCoordinator.swift`, `EchoCore/Services/ChapterLoadingCoordinator.swift`, `EchoCore/Services/PlayerTimelinePersistenceService.swift`, and `EchoCore/Services/TimelineIngestionService.swift`. Add focused worker/recovery tests alongside their existing suites.

- [ ] Extract the synchronous, data-only recalculation/materialization operation into a nonisolated worker. Capture Sendable inputs and the GRDB writer; keep view models, observable state, and UI callbacks on the main actor. Use the repository's explicit off-actor execution patterns and a dedicated queue for blocking SQLite work.
- [ ] Move parsing/interpolation/token generation out of write transactions. Check cancellation between bounded computation units and before commit. Do not split the final replacement into independently visible destructive chunks merely to shorten transactions.
- [ ] Give the finalizer a typed success/deferred/failure outcome that reaches `ImportOutcome` and post-load callers. Treat `SQLITE_INTERRUPT`/`SQLITE_ABORT` as lifecycle deferral only when the coordinator's matching generation was suspended/cancelled; do not hide unrelated database failures by matching error-message strings.
- [ ] Stop finalizer fallback branches immediately on lifecycle deferral. Do not interpret suspended reads as “no blocks,” trigger destructive re-import/recovery, set a success summary, or display a corruption alert for expected deferral. Audit the existing `try? hasBlocks` and catch-and-continue branches specifically.
- [ ] Record pending work by book identity and load generation. Resume once on foreground only if the book/load is still relevant; coalesce overlapping chapter-ingestion and EPUB-finalization requests. If the process terminates, the next normal open must detect incomplete finalization and retry even if EPUB blocks already exist. Use the existing unconditional finalization-on-open path where sufficient; add persistent state only if tests demonstrate a gap.
- [ ] Do not cancel playback to cancel alignment. Preserve cancellation propagation, existing network policy, security-scoped file access, and imported/manual anchors.

**Tests:** Suspend during a synthetic large EPUB finalization, resume, and verify one successful rebuild with valid timings. Repeat with pre-existing blocks, a sidecar, an interruption after block import, a book switch before resume, rapid background/foreground cycles, and concurrent chapter/EPUB requests. Prove a main-actor callback runs while the worker is blocked at a deterministic off-main test hook.

**Pass condition:** Returning to Echo restores unfinished read-along work without reimport loops, stale-book writes, duplicate rebuilds, or a frozen lifecycle handler.

## 4. Cover launch repair and legitimate background database access

**Files:** `Shared/Database/DatabaseService.swift`, `Shared/Database/ContainerPathRepair.swift`, `EchoCore/EchoCoreApp.swift`, `EchoCore/Views/RootTabView.swift`, `EchoCore/ViewModels/PlayerModel.swift`, and the existing background callback sites found by writer-access audit. Extend `EchoTests/DatabaseServiceFileURLTests.swift`, `EchoTests/ContainerPathRepairTests.swift`, and focused playback persistence tests.

- [ ] Protect launch before dispatching the opening queue. Defer expected suspension errors; keep the opening state retryable on foreground. Do not present “Continue Offline” for lifecycle interruption or substitute an empty database automatically.
- [ ] Preserve transactional path repairs and rerun an interrupted repair on the next safe open. Ensure `ContainerPathRepair.runIfNeeded` does not swallow lifecycle deferral and let an incomplete launch look fully repaired. Retain best-effort handling for genuinely nonfatal repair errors.
- [ ] Inventory actual database writes from pause/resume, remote commands, Watch/CarPlay, background download completion, state persistence, and export. Wrap each legitimate callback that needs database access in the coordinator's bounded operation scope. Shared-container widget processes need their own execution policy; an app-process notification does not protect another process.
- [ ] Coordinate the existing pause background task with the new owner so ending one assertion cannot reopen or prematurely suspend the database. Preserve immediate in-memory playback controls and schedule small persistence work within valid execution time. Defer optional heavy alignment while suspended.
- [ ] Keep UIKit lifecycle policy out of macOS/watchOS/CLI/in-memory configurations unless that process explicitly opts in. Audit target membership for new files and the synchronized Xcode project exclusions.
- [ ] Add privacy-safe diagnostics for operation category, duration, suspend/defer/resume, and retry outcome. Log no titles, source text, book URLs, or raw reports. Update `ARCHITECTURE.md` with the database lifecycle and recovery contract.

**Tests:** Interrupt migration/repair against a temporary disk database, reopen, and verify original records plus completed repair without duplicated rows. Exercise pause/resume and remote persistence with assertion success, denial, and expiration; verify playback controls remain usable and eventual persistence succeeds. Verify no foreground corruption alert for a deferred launch and no infinite retry on a real database error.

**Pass condition:** Both crash families are covered, and background audio/persistence remain functional without assuming indefinite background execution.

## 5. Verification and delivery when implementation is requested

- [ ] Rebase the plan's assumptions against current `origin/nightly` without rewriting user-owned history; create a `codex/` task branch in an isolated checkout.
- [ ] Run the new failing regressions before their fixes, then the narrow lifecycle, atomicity, import, and repair suites after each change. Use synthetic data only.
- [ ] Run Apple builds/tests through the required resource wrapper:

  ```sh
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/DatabaseSuspensionTests
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/DatabaseLifecycleCoordinatorTests
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make echo-cli
  ```

  Run the other changed suites with the same `test-only` pattern. Consult the wrapper's status if it queues work; do not bypass its limits.

- [ ] Exercise simulator foreground/background behavior with a generated large EPUB and simulated expiration hooks. The deterministic disk-backed tests establish rollback and rejection behavior; do not claim they reproduce the physical device's RunningBoard kill or prove its disappearance.
- [ ] Review expiration ordering, observer-registration races, stale result rejection, transaction boundaries, and successful/error return paths. Confirm no new path bypasses the database policy.
- [ ] Commit coherent fixes, push, and open a ready PR targeting `nightly`. Inspect hosted `Build gate + tests`, fix regressions, and enable supported auto-merge. If native auto-merge is unavailable, merge the verified head normally after reported CI passes. Report CI/merge status separately from TestFlight distribution.
- [ ] The established nightly pipeline handles delivery. Physical-device testing is not a completion gate. Any later comparison of crash reports must use the actual fixed build number; reports from build 79 do not indicate a regression in a newer fix. Do not create a monitoring automation unless requested.

## Completion criteria

1. Suspended/expired Echo refuses lock-taking work until an authorized resume.
2. Expiration interrupts existing work without main-thread waits; mutations roll back coherently.
3. Launch repair and book finalization recover automatically at a safe opportunity.
4. Valid word timings and manual anchors survive interruption; newer book work cannot be overwritten by an old retry.
5. Background playback and legitimate persistence still work, with finite execution protection.
6. Relevant local verification and hosted CI pass; implementation is delivered through a nightly PR with accurate merge status.

## Implementation decisions

- GRDB serializes the commit boundary; exact snapshot validation rejects stale alignment/word inputs. Same-book ingestion requests cancel superseded jobs. This avoids a second database-wide scheduler.
- The opening connection uses a temporary SQLite progress handler to cover the interval before GRDB registers its suspension observers. The handler is removed after launch. GRDB automatic iOS memory management is disabled for lifecycle-owned pools to avoid its independent synchronous background cleanup path.
- Finite execution assertions are shared by overlapping operations, with a foreground assertion armed before synchronous callers can delay background event delivery. Expired tokens remain cancelled after foreground resumes.
- Expected deferral unwinds the protected scope before waiting for foreground. No raw crash attachments or book content are included in this branch.
