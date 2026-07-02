# AI Cards Ride the Study Plan (Design) — Slice 2

**Date:** 2026-07-01
**Status:** Approved by owner (brainstorming session); ready for implementation planning
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

The card's chapter is derived at acceptance time from its `sourceBlockID` → the containing chapter (the timeline mapping in `StudyDeckAcceptanceService` already resolves audio ranges from block IDs; chapter index comes from the same lookup).

## 4. Release: chapter introduction + daily card budget

`StudyQueueBuilder` gains a **fourth phase** after due reviews → in-progress assignments → new assignments:

- **New cards** are released only when (a) their chapter has been introduced by the plan (its `study_plan_item.introducedAt` is set — i.e. the chapter assignment was released, regardless of whether the chapter card was since retired), and (b) the **new-cards-per-day** budget allows.
- **New setting: `newCardsPerDayLimit`** — default 20, clamped 1–100; a global cross-plan cap plus a per-plan override, mirroring the existing chapter-limit pattern. The global cap is a `SettingsManager` UserDefaults key (no migration). The per-plan override needs a new `study_plan` column (like `newChapterLimit`) — that is **one small schema migration** at the next free version number (check nightly for the current highest — V30 was taken by the transcript-QA work; run the schema-migration-reviewer agent before committing it).
- Release marks the card's plan item `introducedAt` and seeds `nextReviewDate = now`, after which normal FSRS scheduling owns it.
- Catch-up policy (gentle/strict) applies to the card budget with the same semantics as chapters.

## 5. Generation & acceptance flow changes

- **Draft sheet grouped by chapter** (`StudyDeckGenerationSheet`): section per chapter with per-chapter accept-all, plus the existing per-card toggles. Whole-book generation order already follows the spine, so grouping is a presentation change over data the drafts carry (`sourceBlockID` → chapter).
- **Acceptance into a plan:** if the book has an active study plan, accepted cards get plan items (§3) and deferred seeding; the acceptance summary states how they will drip ("released with each chapter, up to 20/day").
- **Retire interplay:** accepting one or more cards into a chapter with an active listening assignment fires slice 1's retire-chapter prompt, phrased for bulk: "N cards now cover this chapter — retire its re-listen card?" (once per chapter).
- **If no plan exists yet**, the acceptance flow offers to create one (routing to the existing `StudyPlanSheet`) but does not require it.

## 6. Checkpoint quiz (screen-on)

Extends slice 1's `StudyCheckpointCoordinator`:

- After the chapter-grade resolution, **screen on only**: if the finished chapter has released, due Q&A cards, the checkpoint overlay flows into a short quiz — existing `FlashcardReviewCard` flip UI, **capped at 5 cards** per checkpoint (the rest stay in the due queue), full four-button FSRS grading.
- **Q&A cards are never auto-graded.** Quiz inactivity, screen-off, or dismissal leaves the remaining cards in the due queue untouched. The slice-1 timeout semantics apply only to the chapter listening-assignment grade.
- Screen off: no quiz; the audio cue may mention "3 cards waiting for review" as a nudge, nothing more.
- macOS: same flow in the checkpoint panel.

## 7. macOS

The **generation entry point** lands on macOS: a "Generate Study Deck" action on the Mac book surface (menu command + button near the reader/book context) presenting the same cross-platform `StudyDeckGenerationSheet`. Provider settings already exist in Mac Preferences; slice 1 delivers Mac plan creation, so the full loop (generate → accept → plan drip → review) works on the Mac.

## 8. Out of scope (recorded)

- **Hands-free TTS audio quiz** (card read aloud at checkpoint, lock-screen-button grading, no-answer defers) — its own future slice; the differentiator, deliberately sequenced after the screen-on quiz proves the flow.
- Generation UX debt (progress wiring, dedup, silent fixture fallback, key validation) — slice 3.
- Lazy / N-ahead generation; per-position mid-chapter card popups (deliberately retired in WS6; the inline reader feed already covers screen-on read-along).

## 9. Testing (TDD)

- Queue builder: card release gated on chapter introduction; budget enforcement (per-plan + global), catch-up semantics, ordering with the three existing phases.
- Acceptance: plan-item creation with correct chapter index; deferred vs due-now seeding by plan presence; retire-prompt bulk trigger (once per chapter).
- Checkpoint quiz: eligibility (released + due + same chapter), 5-card cap, no auto-grades on abandonment.
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
