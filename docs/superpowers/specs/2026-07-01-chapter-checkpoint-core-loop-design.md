# Chapter Checkpoint — Core Study Loop Closeout (Design)

**Date:** 2026-07-01
**Status:** Approved by owner (brainstorming session); ready for implementation planning
**Slice:** 1 of 3 in the study-workflow program (2 = AI cards into the plan, 3 = provider expansion — both explicitly out of scope here)

## 1. Context & goal

Chapter Study Mode ("book = deck, one listening-assignment card per chapter") shipped in Schema V25: `StudyPlanGenerator`, `StudyPlan` (cadence day/week, 1–12 chapters, gentle/strict catch-up, book-by-book vs. mixed queue), `StudyQueueBuilder` (due → in-progress → newly released), FSRS-4.5 grading with the deliberate **Again/Good** two-button policy for assignments.

Three behaviors from the Wedge-1 spec remain unbuilt (named ROADMAP closeout items), plus a macOS parity gap. This design closes them:

1. **End-of-chapter grade checkpoint** with a no-tap auto-default timeout (hands-free).
2. **Skippable re-listen** semantics for due chapters with no user cards.
3. **Retire-chapter prompt** when real flashcards exist inside a chapter.
4. **macOS study-layer parity** for chapter mode (plan creation UI, study settings, checkpoint presentation).

The driving use case: hands-free listening (screen off, walking a mail route or driving). The user presses play; when a due chapter finishes, Echo prompts for a retention grade and keeps the day's study queue flowing — across books — without requiring hands or eyes.

## 2. Owner decisions (recorded verbatim from the design session)

| Question | Decision |
|---|---|
| Where does the checkpoint fire? | **Due/introduced chapters, any playback** — study-launched or casual. Books without an active plan are untouched. |
| What does Again do (tap or timeout)? | **User-selectable 3-way setting**: Replay chapter now (default) / Grade Again and move on / Tap replays, timeout defers without grade. |
| How far does auto-advance go after Good? | **Full cross-book**: playback continues through today's entire due queue. |
| Architecture | **Approach 1**: player-owned `StudyCheckpointCoordinator` + `StudyPlaybackQueueService` (SleepTimerManager pattern), overlay + audio cue + remote-command grading, interactive notifications as a parallel channel. |

## 3. Architecture

Two new concrete services (no protocols — per the house DI rule, a seam is added only when a second implementation exists). Both are platform-neutral Swift over GRDB, shared by iOS and macOS. Presentation is thin and per-platform.

```
AudioEngine (0.5s tick)
   └─ PlaybackController ── chapter transition ──┐
                                                 ▼
PlayerModel ──owns──▶ StudyCheckpointCoordinator ──reads──▶ StudyPlanDAO / FlashcardDAO
   ▲     ▲                    │        │
   │     │                    │        └─grades──▶ FlashcardDAO.grade() → FSRS
   │     └─replay/advance/announce closures
   │                          ▼
   └────────────── StudyPlaybackQueueService ──wraps──▶ StudyQueueBuilder
```

### 3.1 `StudyCheckpointCoordinator` (new, `EchoCore/Services/`)

Concrete `@Observable` state machine: `idle → armed → checkpointActive → resolved`. Constructor-injected with `DatabaseService` (or the DAOs), the checkpoint settings values, and three closures supplied by PlayerModel: `replayChapter()`, `advance(to: StudyPlayableItem)`, `announce(cue:)`.

- **Arming.** Hooked into the same chapter-transition path `SleepTimerManager.evaluateAtChapterEnd()` uses. Only a **naturally played** chapter end arms the checkpoint — a seek or manual skip across the boundary does not (skipping is not listening; FSRS grades must follow real exposure). On a natural end, the coordinator asks `StudyPlanDAO` whether the finished chapter is a due or introduced assignment in an active (non-paused) plan.
- **Firing.** Playback pauses at the boundary. A short earcon plus a spoken one-liner via `AVSpeechSynthesizer` (deliberately not the Kokoro engine — model load latency is seconds; a checkpoint cue must be instant). The countdown starts (user-set duration, default 30 s).
  - Screen on: in-player overlay with **Again / Good** (+ **Skip** when eligible, §5.1) and a countdown ring.
  - Screen off: for the duration of the window, lock-screen/CarPlay skip commands are reinterpreted — **skip-forward = Good, skip-back = Again** — and an interactive notification with Good/Again actions posts in parallel. First channel to answer wins.
- **Resolution.**
  - **Good** → `FlashcardDAO.grade(.good)` → ask `StudyPlaybackQueueService` for the next item → advance (if auto-advance enabled).
  - **Again (tapped)** → `grade(.again)` → replay or advance per the 3-way setting.
  - **Timeout** → per the 3-way setting: *Replay now* grades `.again` and replays; *Grade and move on* grades `.again` and advances; *Defer* records **no grade**; the chapter simply remains due today, so the queue builder naturally resurfaces it at the end of today's queue.
  - All auto-fired grades carry an `auto` flag in the review-event metadata (existing JSON), so Insights can distinguish deliberate taps from silence, and future scheduler tuning can discount autos.

### 3.2 `StudyPlaybackQueueService` (new, `Shared/Services/`)

Materializes today's queue (`StudyQueueBuilder` — which already owns ordering, daily budgets, catch-up, and queue modes) into an ordered sequence of `StudyPlayableItem` values: `(bookID, chapter audio range, flashcardID)`.

- `nextPlayableItem(after:)` honors book-by-book vs. mixed mode and the per-plan + global daily budgets.
- **Cross-book advance** is not a special case: the next item may reference a different book; the coordinator hands it to PlayerModel's existing book-load path.
- **Unplayable items** (ABS book not downloaded; narrated chapter not yet rendered) are skipped with a spoken announcement and surfaced in the study session as "needs attention" — never silently dropped.

### 3.3 Presentation (per platform)

- **iOS:** in-player checkpoint overlay; interactive notification category (`STUDY_CHECKPOINT` with `GOOD`/`AGAIN` actions); remote-command window reinterpretation behind a setting.
- **macOS:** checkpoint panel/sheet on the player window. Timeout default is **Wait** (a Mac screen doesn't sleep mid-session the way a pocketed phone does; auto-Again fired at an empty desk chair would be dishonest data). Remote-command reinterpretation does not apply.

## 4. Existing flows that change

- **"Play Assignment" (study session)** now arms the same coordinator instead of the old return-to-session-and-grade path. One grading brain, two entrances.
- **Sleep timer, end-of-chapter mode:** checkpoint resolves first; the sleep-timer stop is then honored, and the *replay* path is suppressed (the user asked Echo to stop — grade, then stop).
- **Chapter loop / bookmark loop:** loop wins; checkpoints never fire inside an intentional loop.

## 5. Spec-closeout behaviors

### 5.1 Skippable re-listen

When the due chapter has **no user-created cards**, the checkpoint and the study-session card gain a third action, **Skip**: no FSRS grade, due date pushed to tomorrow, logged as a skip in review metadata. This is the retention-neutral escape hatch for "I know this chapter; stop scheduling it" (repeated skips are visible in Insights; the durable fix is retiring the card, §5.2).

### 5.2 Retire-chapter prompt

The first time a user-created flashcard is saved into a chapter with an active listening assignment, prompt once: *"Retire this chapter's re-listen card and review with your cards instead?"* Retiring sets `isEnabled = false` on the assignment card (reversible from plan management). The prompt fires once per chapter, tracked in the assignment card's review-metadata JSON (no new column). The AI-deck slice (slice 2) will reuse this exact hook when accepted AI cards land in a chapter.

## 6. Settings

New "Chapter Checkpoints" group under **Settings › Study & Notes** (iOS) and the new macOS study settings section. Persisted via `SettingsManager` (UserDefaults; app-group-synced where watch/widget later care):

| Setting | Values | Default (iOS / macOS) |
|---|---|---|
| Checkpoint timeout | 10 s / 30 s / 1 min / 2 min | 30 s / n/a (Wait) |
| When the timer runs out | Replay the chapter / Grade Again and move on / Wait (no grade, re-queue today) | Replay / Wait |
| Auto-advance after Good | on / off | on / on |
| Lock-screen button grading | on / off | on / n/a |

No global checkpoint kill switch: checkpoints only exist for books with an active plan, and pausing the plan (existing feature) silences them.

On macOS the default behavior is **Wait**, meaning no countdown runs; if the user selects a non-Wait behavior, the timeout duration setting applies exactly as on iOS.

## 7. macOS parity scope (this slice)

1. **Plan creation:** port `StudyPlanSheet` (`StudyPlanViewModel` is already shared) into the Mac UI (window/sheet chrome only).
2. **Study settings section** in `MacSettingsView` (global new-chapter cap, review reminders, checkpoint group).
3. **Checkpoint panel** per §3.3.

With `MacDailyReviewView` and Card Inbox already shipped, this closes the ROADMAP "Mac study layer" items for chapter mode. (AI generation entry point on macOS is slice 3.)

## 8. Edge cases

- **App killed / audio interrupted mid-window:** the armed checkpoint is not persisted; on next launch the chapter is simply still due. A dead process never writes a grade.
- **CarPlay:** no new CarPlay templates; the audio cue + reinterpreted skip commands + timeout cover the car.
- **Multi-plan overlap on one chapter:** one checkpoint per boundary; earliest-due assignment wins; others remain due.
- **Timeout while a phone call interrupts playback:** the countdown suspends with playback (AVAudioSession interruption) and resumes with it.
- **Notification permission denied:** overlay + remote-command channels still work; the notification channel is additive, never required.

## 9. Data & migrations

**No schema migration.** Grades, skips, auto flags, and retire state ride existing tables (`flashcard`, `study_plan_item`, review events) and the existing review-metadata JSON. New settings are UserDefaults keys. The schema-migration-reviewer agent still runs before the PR because DAO queries change.

## 10. Testing (TDD, `make test` / `make test-only`)

- **Coordinator state machine** (in-memory `DatabaseService`): arming rules (natural end vs. seek/skip), due-vs-not-due lookup, all three timeout behaviors, auto flag on grades, sleep-timer and loop interplay, call-interruption suspend/resume.
- **Queue service:** cross-book ordering under both queue modes, daily-budget respect, unplayable-item skip-and-surface.
- **Skip semantics:** no grade written, +1 day, skip logged.
- **Retire prompt:** fires on first card only, once per chapter, reversibility.
- **Settings:** clamping, defaults per platform.
- UI behavior stays out of unit scope (UI tests are excluded from the Echo scheme by convention).

## 11. Out of scope (recorded for the next slices)

- **Slice 2 — AI cards into the plan:** per-chapter AI generation joining the plan cadence; card-level new-cards/day drip (today every accepted AI card is due immediately); end-of-chapter checkpoint quiz for Q&A cards (never auto-graded — no-response defers); hands-free audio quiz (TTS reads card, remote-command grading); macOS generate entry point.
- **Slice 3 — provider expansion:** OpenAI as a second BYO-key provider (+ its own 5.1.2(i) consent), generalized key store/clients, generation-UX debt (progress wiring, dedup, silent-fixture fallback, key validation). Provider *account login* is deliberately excluded: Anthropic prohibits and server-enforces against consumer-OAuth in third-party apps (Feb 2026 terms); OpenAI's "Sign in with ChatGPT" is identity-only and not generally available (OpenClaw partnership is a one-off). Revisit only if OpenAI ships a public program.

## 12. Key existing files

| File | Role in this design |
|---|---|
| `EchoCore/ViewModels/PlayerModel.swift` | Owns the coordinator; supplies replay/advance/announce closures |
| `EchoCore/Services/PlaybackController.swift` | Chapter-transition source (same hook as sleep timer) |
| `Shared/Services/StudyQueueBuilder.swift` | Queue ordering/budgets the queue service wraps |
| `Shared/Database/DAOs/StudyPlanDAO.swift` | Due/introduced lookup; retire (isEnabled) writes |
| `Shared/Database/FSRSScheduler.swift` + `Flashcard.swift` | Grading path |
| `EchoCore/ViewModels/StudySessionViewModel.swift` | "Play Assignment" entrance rewired to the coordinator |
| `EchoCore/Views/StudyAssignmentCardView.swift` | Gains Skip where eligible |
| `EchoCore/Services/SettingsManager.swift` / `EchoCore/Views/SettingsView.swift` | New checkpoint settings group |
| `Echo macOS/Views/MacSettingsView.swift` / `MacTriPaneView.swift` | Mac study settings + plan sheet + checkpoint panel hosts |
