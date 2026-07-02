# AI Cards Ride the Study Plan (Design) — Slice 2

**Date:** 2026-07-01
**Status:** Approved by owner (brainstorming session); ready for implementation planning. **Amended 2026-07-02 (§11)** — pacing defaults, chapter-paced introduction, deferred retire prompt, release-on-contact; the implementation plan predates the amendments and carries a delta banner.
**Slice:** 2 of 3 in the study-workflow program. Depends on slice 1 (`2026-07-01-chapter-checkpoint-core-loop-design.md`) for the checkpoint machinery and retire-chapter prompt. Independent of slice 3 (provider expansion) except for the generation sheet file (implement slice 2's sheet restructure first if run concurrently).

## 1. Context & goal

AI card generation shipped in PRs #351/#356 (Anthropic BYO key + on-device Foundation Models, two-pass whole-book generation, accept/reject draft sheet). Its gaps: every accepted card seeds `nextReviewDate = now` — accept a 120-card deck and all 120 are due today; there is **no card-level daily drip anywhere** (the existing cap is chapters/day); generation is not connected to the Chapter Study Mode plan; and there is no retrieval moment tied to listening.

Goal: accepted AI cards join the study plan — released chapter-by-chapter with the plan cadence, dripped under a new-cards-per-day budget, and offered as a short screen-on quiz at the end-of-chapter checkpoint.

## 2. Owner decisions

| Question | Decision |
|---|---|
| Generation timing | **Whole book up front** — one run; cards stored immediately, released with the plan cadence. Offline-safe on the route; one review pass; cost paid once up front. |
| Draft review | **One review pass, grouped by chapter** — extend the existing accept/reject sheet with chapter sections + accept-all-per-chapter. |
| Checkpoint delivery | **Screen-on quiz now, audio quiz later** — due Q&A cards for the finished chapter appear after the chapter grade when the screen is on; screen-off listeners get them in the regular due queue. The hands-free TTS audio quiz is deferred to its own future slice. |

## 3. Data model

No new tables. Two extensions to existing rows:

1. **`study_plan_item.kind` gains a `card` value.** Today the link table schedules `chapter` and `image` assignments with `introducedAt`. An accepted AI card in a plan book gets a `study_plan_item(kind: card, chapterIndex, flashcard_id)` row tying it to its chapter. `kind` is a TEXT column, so no migration is expected — **implementation must verify Schema V25 put no CHECK constraint on `kind`**; if one exists, add a small migration (next free version) relaxing it.
2. **Acceptance seeding changes for plan books:** `nextReviewDate = nil` (released later), instead of today's due-now. Books **without** an active study plan keep the current due-now behavior — there is no cadence to pace against.

The card's chapter is derived at acceptance time from its `sourceBlockID` → the containing chapter (the timeline mapping in `StudyDeckAcceptanceService` already resolves audio ranges from block IDs; chapter index comes from the same lookup). *(Amended 2026-07-02 — §11 A2):* a card whose source block carries **no chapter index** cannot ride the drip — it seeds due-now exactly like a plan-less book, never a NULL-chapter plan item (which would be unreachable).

## 4. Release: chapter pacing + daily card budget

`StudyQueueBuilder` gains a **fourth phase** after due reviews → in-progress assignments → new assignments:

- **New cards** are released only when (a) their chapter has been introduced by the plan (its `study_plan_item.introducedAt` is set — i.e. the chapter assignment was released, regardless of whether the chapter card was since retired), and (b) the **new-cards-per-day** budget allows.
- **New setting: `newCardsPerDayLimit`** — a global cross-plan value (default 20, clamped 1–100; `SettingsManager` UserDefaults key, no migration) plus a **per-plan override defaulting to 2** (clamped 1–100), mirroring the existing chapter-limit pattern. *(Amended 2026-07-02, was 20/20 — §11 A1.)* The per-plan override needs a new `study_plan` column (like `newChapterLimit`) — part of **one small schema migration** at the next free version number (check nightly for the current highest; run the schema-migration-reviewer agent before committing it). The per-plan budget counts release stamps (`introducedAt`) within the current **day** window — always daily, regardless of the plan's chapter cadence (a weekly plan still drips cards daily). The global value caps how many new cards a single queue build may **offer** across plans — a per-build safety valve, not a cross-build daily ledger (§11 A1).
- **Chapter pacing** *(amended 2026-07-02 — §11 A2)*: `study_plan` gains a `chapter_pacing` mode (same migration) — **`card_drain` (default)**: a new chapter is introduced only when the **frontier chapter** (the highest-ordinal introduced chapter) has zero pending card items, on top of the existing chapters-per-cadence budget; and while the plan has any card items, at most **one** new chapter is introduced per queue build (strict catch-up back-fill respects both rules). **`cadence`**: today's pure calendar behavior. **Pending means releasable**: an enabled `card` item with `introducedAt IS NULL` joined to an existing, enabled flashcard — deleted or disabled cards never block the gate. With no card items the gate is vacuously open and the one-per-build cap does not apply, so `card_drain` is behavior-identical to `cadence` until an AI deck is accepted — which makes it a safe default for existing rows.
- **Release is stamped on contact, not on queue build** *(amended 2026-07-02 — §11 A4)*: building a queue *offers* up to budget pending cards as fourth-phase entries but **writes nothing for cards**. `introducedAt` + `nextReviewDate = now` are written (idempotently) when a card is actually **presented** in the study session or **drawn** into a checkpoint quiz — merely opening the Review Queue must not spend the day's card budget. Stamping does not re-check the budget: a stale, still-open queue can release at most one build's worth of extra offers — bounded overshoot, accepted (§11 A4). After the stamp, normal FSRS scheduling owns the card.
- Catch-up policy (gentle/strict) applies to the card budget with the same semantics as chapters (over day windows); in `card_drain` mode, strict chapter back-fill also respects the drain gate and the one-chapter-per-build cap.

## 5. Generation & acceptance flow changes

- **Draft sheet grouped by chapter** (`StudyDeckGenerationSheet`): section per chapter with per-chapter accept-all, plus the existing per-card toggles. Whole-book generation order already follows the spine, so grouping is a presentation change over data the drafts carry (`sourceBlockID` → chapter).
- **Acceptance into a plan:** if the book has an active study plan, accepted cards get plan items (§3) and deferred seeding; the acceptance summary states how they will drip — bound to the **plan's per-plan value**, e.g. "released with each chapter, up to 2 a day", never the global setting *(amended 2026-07-02 — §11 A1)*.
- **Retire interplay** *(amended 2026-07-02 — §11 A3)*: for plan books, acceptance does **not** fire the retire-chapter prompt — every accepted card lands as a pending plan item, and while a chapter's cards are still dripping, the re-listen loop is the point. The prompt fires (once per chapter, bulk-phrased: "N cards now cover this chapter — retire its re-listen card?") when the chapter's **last pending card is released**, surfaced through slice 1's root-level retire alert (`PlayerModel.pendingRetirePrompt`); a drain during a checkpoint-quiz draw defers the prompt until the quiz completes or is dismissed. `StudyChapterRetireService` gains one **chapter-keyed** variant for the release path (the timestamp-keyed manual-card method and the once-per-chapter `retirePromptShownAt` stamp are unchanged). Manual card creation into a chapter with pending card items **also defers** — it must not burn the once-per-chapter stamp mid-drip; manual cards elsewhere, and books without a plan, keep slice 1's immediate behavior. A small chapter that drains in its first quiz draw prompts immediately: coverage-complete is prompt-eligible, and the user can decline.
- **If no plan exists yet**, the acceptance flow offers to create one (routing to the existing `StudyPlanSheet`) but does not require it.

## 6. Checkpoint quiz (screen-on)

Extends slice 1's `StudyCheckpointCoordinator`:

- After the chapter-grade resolution, **screen on only**: if the finished chapter has released, due Q&A cards, the checkpoint overlay flows into a short quiz — existing `FlashcardReviewCard` flip UI, **capped at 5 cards** per checkpoint (the rest stay in the due queue), full four-button FSRS grading.
- **The quiz draw releases** *(amended 2026-07-02 — §11 A4)*: before querying due quiz cards, the draw releases the finished chapter's pending cards up to the remaining daily card budget, so a checkpoint right after listening quizzes freshly released cards. This is the primary drip surface for the listen-first loop; a draw that drains the chapter's pending set fires the deferred retire prompt (§5).
- **Q&A cards are never auto-graded.** Quiz inactivity, screen-off, or dismissal leaves the remaining cards in the due queue untouched. The slice-1 timeout semantics apply only to the chapter listening-assignment grade.
- Screen off: no quiz, and **no release** — the audio cue counts the chapter's **pending + released** due cards ("5 cards ready when you are") as a nudge, nothing more *(amended 2026-07-02 — §11 A4: counting released-only would read zero forever for a hands-free-only listener)*.
- macOS: same flow in the checkpoint panel.

## 7. macOS

The **generation entry point** lands on macOS: a "Generate Study Deck" action on the Mac book surface (menu command + button near the reader/book context) presenting the same cross-platform `StudyDeckGenerationSheet`. Provider settings already exist in Mac Preferences; slice 1 delivers Mac plan creation, so the full loop (generate → accept → plan drip → review) works on the Mac.

## 8. Out of scope (recorded)

- **Hands-free TTS audio quiz** (card read aloud at checkpoint, lock-screen-button grading, no-answer defers) — its own future slice; the differentiator, deliberately sequenced after the screen-on quiz proves the flow.
- Generation UX debt (progress wiring, dedup, silent fixture fallback, key validation) — slice 3.
- Lazy / N-ahead generation; per-position mid-chapter card popups (deliberately retired in WS6; the inline reader feed already covers screen-on read-along).

## 9. Testing (TDD)

- Queue builder: card release gated on chapter introduction; budget enforcement (per-plan + global), catch-up semantics, ordering with the three existing phases.
- Chapter pacing (§11 A2): `card_drain` blocks the next chapter while the frontier chapter has pending cards, unblocks on drain, releases at most one chapter per build when card items exist, is vacuously open without card items; deleting/disabling a pending card unblocks the gate; `cadence` bypasses; strict back-fill respects gate + cap; card budget uses day windows on a weekly-cadence plan.
- Release-on-contact (§11 A4): a queue build writes nothing for cards; presentation/quiz-draw stamps once, idempotently; passive builds (upcoming-count, reminder refresh) never release.
- Acceptance: plan-item creation with correct chapter index; NULL-chapter blocks seed due-now; deferred vs due-now seeding by plan presence; retire prompt deferred for dripping chapters and fired on last release via the chapter-keyed lookup, once per chapter; manual card mid-drip defers (§11 A3).
- Checkpoint quiz: eligibility (released + due + same chapter), release-on-draw up to remaining budget, 5-card cap, no auto-grades on abandonment.
- Sheet grouping: chapter sectioning from draft `sourceBlockID`s; accept-all-per-chapter.
- Schema check: `study_plan_item.kind = 'card'` round-trips (and the CHECK-constraint verification from §3).

## 10. Key existing files

| File | Role |
|---|---|
| `Shared/Services/StudyDeckAcceptanceService.swift` | Seeding change + plan-item creation + retire hook |
| `Shared/Database/StudyPlanItem.swift` / `DAOs/StudyPlanDAO.swift` | `card` kind, introduction writes |
| `Shared/Services/StudyQueueBuilder.swift` | Fourth phase + card budget |
| `EchoCore/Views/StudyDeckGenerationSheet.swift` | Chapter grouping, accept-all |
| `EchoCore/Services/` (slice 1) `StudyCheckpointCoordinator` | Quiz extension |
| `EchoCore/Views/FlashcardReviewCard.swift` | Reused quiz UI |
| `EchoCore/Services/SettingsManager.swift` / `EchoCore/Views/SettingsView.swift` | `newCardsPerDayLimit` |
| `Echo macOS/Views/` | Mac generation entry point |

## 11. Amendment log — 2026-07-02

Amended before implementation (slice 2 unstarted; slice 1 in progress). Driver: the owner's actual routine — **3–4 books per day, 1–2 new cards per day per book, each chapter re-listened over several days until its cards are done**. Reviewing the approved design against that routine surfaced four mismatches; §§3–6 and §9 were edited in place, and this log records what changed and why. The amendments were then adversarially reviewed the same day (consistency + soundness passes) and the refinements below are folded in — these decisions are final for implementation. The implementation plan (`docs/superpowers/plans/2026-07-01-ai-cards-study-plan.md`) was written and verified against the pre-amendment spec — a banner at its top lists the per-task deltas. **Where the plan's verbatim code or prose disagrees with this spec, this spec wins.**

### A1 — Per-plan new-cards default is 2/day (was 20)

The `study_plan.new_cards_per_day` column, `StudyPlan`'s Swift memberwise default, `StudyPlanCreationRequest`, and the plan-sheet stepper all default to **2**; the clamp stays 1–100. The **card budget always uses day windows**, regardless of the plan's chapter cadence — a weekly plan still drips cards daily (the setting is per-day by name and by the owner's mental model; per-window semantics would make a 5-card chapter take 3 *weeks* on a weekly plan). The **global** `newCardsPerDayLimit` stays at default 20, but call it what it is: a **per-queue-build cap on offered new cards** (it has no cross-build memory), a safety valve for users who raise per-plan limits — the per-plan budget, which counts `introducedAt` stamps within the day, is the real drip. Why 2: 20/day per book buries a 5-cards-per-chapter deck's pacing entirely; 2/day finishes a 5-card chapter in about 3 days, which is the intended texture. The plan sheet gets a one-line caption making the arithmetic visible (e.g. "2 a day finishes a 5-card chapter in about 3 days") and the acceptance summary binds the per-plan value, never the global.

### A2 — Chapter pacing: `card_drain` (default) vs `cadence`

New `study_plan.chapter_pacing` TEXT column (same V33 migration as `new_cards_per_day`; registration name `v33_study_plan_card_pacing`), values `card_drain` (default) / `cadence`, surfaced as a picker in the plan sheet. In `card_drain`, a new chapter assignment is introduced only when the **frontier chapter — the highest-ordinal introduced chapter — has zero pending card items**, on top of the existing chapters-per-cadence budget; and while the plan has any card items, **at most one new chapter is introduced per queue build** (so strict catch-up or a raised chapter limit cannot batch several undrained chapters through an open gate). **Pending means releasable**: an enabled `card` item with `introducedAt IS NULL` joined to an existing, enabled flashcard — `study_plan_item.flashcard_id` is ON DELETE SET NULL, so orphaned or disabled rows must never block the gate. The gate is deliberately frontier-scoped: adopting a deck mid-plan (N chapters already introduced) does **not** stall the plan until all N chapters' backlogs drain — earlier chapters' cards keep dripping in ordinal order while only the frontier gates advancement. Why: without the gate, chapters march ahead on the calendar (1/day) while cards drain at 1–2/day, so an unreleased-card backlog grows forever and listening decouples from study — the opposite of "a chapter takes as many days as its cards need." Safety: with no card items the gate is vacuously open and the one-per-build cap does not apply, so the default changes nothing for plans without AI decks (including all pre-V33 rows at migration time). Recorded consequence, stated honestly: release requires screen-on contact (A4), so a listener who **never** opens the session or a screen-on checkpoint releases nothing and the plan waits **indefinitely** — deliberate ("the plan waits for you"), mitigated by the screen-off cue counting pending cards (§6) so the stall is audible, not silent.

### A3 — Retire prompt deferred while a chapter's cards are dripping

For plan books, bulk acceptance never fires the retire-chapter prompt (every accepted card creates a pending plan item). The prompt fires when the chapter's **last pending card is released**, keeping the once-per-chapter `retirePromptShownAt` stamp. Mechanics (settled by review): `StudyChapterRetireService` gains a **chapter-keyed** variant (e.g. `promptForDrainedChapter(audiobookID:chapterIndex:now:)`) — the existing timestamp-keyed method cannot identify the drained chapter because failed timeline mappings leave `mediaTimestamp = 0`; slice 1's `RetirePrompt` gains a covering-card **count** so the root alert (`RootTabView` on `PlayerModel.pendingRetirePrompt`) can phrase bulk ("N cards now cover this chapter…") vs slice 1's single-card copy; the study-session drain path reaches that channel via a constructor-injected callback bound by PlayerModel; and a drain that happens during a **quiz draw defers the prompt until the quiz completes or is dismissed** (no alert colliding with the quiz overlay). **Manual cards mid-drip also defer**: a manually created card in a chapter with pending card items must not fire slice 1's immediate prompt (wrong moment, and it would burn the one-shot stamp); manual cards elsewhere keep slice 1's behavior. Accepted edge: a chapter whose card count fits one quiz draw prompts at its first checkpoint — coverage-complete is prompt-eligible; the user can decline. Why: the pre-amendment design fired the prompt at acceptance — suggesting the user kill the re-listen card at the exact moment the multi-day re-listen window *begins*. Ripple: the draft sheet's post-accept retire follow-ups disappear (the plan-creation offer stays).

### A4 — Release stamped on contact, not on queue build

`loadQueue` (and any passive `StudyQueueBuilder.build` caller — upcoming-count module, reminder refresh) **writes nothing for cards**; queue building only *offers* pending cards within budget (chapter `markIntroduced` at load stays as shipped — see below). The idempotent `releaseCards` write happens when a card is first **presented** in the study session, or when the **checkpoint quiz draws** the finished chapter's pending cards up to the remaining daily budget. Budget plumbing (settled by review): the day-window remaining-budget math lives in **`StudyQueueBuilder`** as a public helper the coordinator can call; PlayerModel injects the global limit alongside the checkpoint settings — the coordinator must not reach into `SettingsManager` itself. Stamping performs **no budget re-check**: a stale, still-open queue can release one build's worth of extra offers — bounded overshoot (≤ the per-plan limit), accepted; the budget is pacing, not an invariant. The screen-off checkpoint cue **never releases** and counts pending + released cards (§6). Why: stamping at queue build means opening the Review Queue spends the day's budget across all books whether or not anything is studied — with a 3–4-book routine, peeking converts the drip into an unpaced due-pile, silently defeating A1/A2. Recorded, out of scope: chapter assignments share this pattern today (`markIntroduced` at load, shipped in V25); aligning chapters with release-on-contact is a candidate future slice, not part of this one.
