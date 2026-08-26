# Auto Flashcard Study Plan — Design Spec

**Date:** 2026-06-24
**Status:** Design approved in chat; written spec pending review
**Topic:** Generate book-level listening-assignment flashcards from EPUB chapters and images, then schedule them Anki-style as daily/weekly study work.

## 1. Summary

Echo already has most of the raw material for this feature:

- `ChapterCardDrafter` can create one card per visible, non-front-matter EPUB heading.
- `deck` and `flashcard` are GRDB-backed records, with FSRS scheduling already active through `FlashcardDAO.grade`.
- EPUB import persists chaptered `epub_block` rows, including `image` blocks with local `image_path` values copied into Application Support.
- Read & Study already threads flashcards inline in the reader feed and has a chapter off-state menu.
- `DailyReviewViewModel` and `FlashcardReviewSession` can review due cards, and watchOS can receive due-card snapshots.

The missing piece is a real study-plan layer. Auto-generated cards should not be loose Q/A trivia. They should be **listening assignments**: "cover this chapter/image today, then grade how well you retained it." The plan decides how many new chapter assignments become available per day/week, while FSRS continues to handle later review timing.

The recommended design adds `study_plan` and `study_plan_item` tables. Existing `flashcard` rows remain the review/scheduling unit. The new tables define book-level pacing, release order, image inclusion, per-item enablement, and queue behavior.

## 2. Goals / Non-goals

### Goals

- Let a user tap a book's flashcard/study button and generate a book study plan when no generated plan exists.
- Generate one listening-assignment card per included chapter.
- Let the user exclude chapters before generation, reusing the same hidden/off semantics used by the reader feed where possible.
- Optionally generate cards for EPUB images, introduced alongside the chapter that contains each image.
- Support Anki-like "new material" pacing: N chapters per day or N chapters per week.
- Support two daily queue modes:
  - **Book by book:** finish one book/deck before moving to the next.
  - **Mixed:** mix due cards across active plans while preserving each book's new-chapter order.
- Keep FSRS as the review scheduler for generated cards after the user grades an assignment.
- Keep manual/imported cards working as normal due-review cards.

### Non-goals

- AI-generated question/answer text.
- Replacing FSRS or adding a second spaced-repetition algorithm.
- Watch-first plan creation. watchOS can keep reviewing due cards, but plan setup is iOS first.
- Full macOS parity in the first implementation. The data model should be shared so macOS can follow.
- Rewriting the reader feed or audio engine.

## 3. Product Flow

### First-run generation

Entry points:

- A **Study Plan** action in Read & Study / book settings.
- The existing flashcard button can route here when the current book has no generated plan.
- The existing due-review dashboard card should launch the review/study sheet; `RootTabView.launchReview()` exists but needs to be wired from `DashboardShelf`.

Flow:

1. User taps **Study Plan**.
2. If no generated plan exists for the book, show a generation sheet.
3. The sheet previews detected chapter candidates.
4. Front matter and hidden chapters are excluded by default.
5. The user can toggle chapter inclusion before generation.
6. The user can enable **Create picture cards from EPUB images**.
7. The user selects pacing:
   - 1 chapter per day
   - 1 chapter per week
   - Custom N chapters per day/week
8. The user selects default queue mode:
   - Book by book
   - Mixed
9. Echo creates the deck, generated flashcards, `study_plan`, and `study_plan_item` rows.

### Existing-plan management

If the book already has a plan, the same surface becomes plan management:

- Pause/resume plan.
- Change cadence and chapter limit.
- Toggle image assignment inclusion for future/missing generated items.
- Enable/disable individual chapters/items.
- Regenerate missing cards without duplicating existing generated cards.
- Show plan progress: introduced, new remaining, due today, reviewed today.

## 4. Assignment Model

### Chapter listening assignments

Generated chapter cards are listening assignments.

Recommended `flashcard` shape:

- `deck_id`: the book deck.
- `audiobook_id`: current book ID.
- `card_type`: `listening_assignment`.
- `front_text`: chapter title.
- `back_text`: a short completion prompt, for example "Review what you retained from this chapter."
- `source_block_id`: the chapter heading block.
- `media_timestamp`: chapter start time when available.
- `end_timestamp`: chapter end time when available.
- `trigger_timing`: `.manualOnly`.
- `next_review_date`: nil until the assignment receives its first grade. The study plan controls initial release; FSRS controls future due dates after grading.
- `tags`: generated source marker such as `auto study chapter`.

The review UI should treat this card type differently from a normal Q/A flashcard:

1. Show the chapter title and a play/continue action.
2. Play or seek to the chapter audio range.
3. When the user finishes or stops, reveal the retention prompt.
4. User grades with the existing four FSRS buttons: Again, Hard, Good, Easy.
5. `FlashcardDAO.grade` schedules the next review.

### Image assignments

Generated image cards are tied to EPUB `image` blocks.

Recommended `flashcard` shape:

- `card_type`: `image_assignment`.
- `front_text`: a contextual label such as "Review this image from Chapter N."
- `back_text`: a short retention prompt.
- `source_block_id`: the image block ID.
- `media_json`: optional structured metadata for the local image path if the review UI cannot cheaply fetch it from `epub_block`.
- `media_timestamp`: nearest known audio position from the block/timeline, or the containing chapter start.
- `end_timestamp`: nil unless a chapter range is available.
- `tags`: generated source marker such as `auto study image`.

Image candidates should skip:

- Front matter.
- Hidden chapters/blocks.
- Image blocks with missing local files.
- Tiny/decorative images when dimensions are cheaply available. If dimensions are not available in the first implementation, ship a conservative missing-file filter first and leave dimension filtering as a follow-up.

Image assignments are introduced with the containing chapter, not independently ahead of that chapter.

## 5. Daily Queue Semantics

The daily study queue combines:

- **Due reviews:** existing FSRS cards with `next_review_date <= now` and `is_enabled = 1`.
- **In-progress assignments:** enabled `study_plan_item` rows that have been introduced but whose generated flashcard has not yet been reviewed.
- **New assignments:** enabled `study_plan_item` rows that have not been introduced and fit the plan's cadence budget.

Due reviews should appear first by default. In-progress assignments come next so quitting a session after a chapter is released does not make the chapter disappear. Newly released assignments come last. This matches SRS expectations and avoids hiding overdue work behind new chapters.

`study_plan_item.introduced_at` means the assignment has been released to the learner, not that it has been completed. Completion should be inferred from the generated `flashcard` scheduling fields, primarily `last_reviewed_at` / `repetitions`, after grading through `FlashcardDAO.grade`.

### Queue modes

#### Book by book

Process one active plan/deck at a time:

1. Due reviews for the book.
2. Introduced but ungraded assignments for the book.
3. New assignments allowed today for the book.
4. Move to the next book.

This is the recommended default because audio chapters are sequential and context-heavy.

#### Mixed

Mix due cards across books while preserving source order for each book's new assignments:

- Due review ordering can be randomized or due-date sorted across all active plans.
- Introduced but ungraded assignments should stay visible until graded.
- New chapter assignments must stay ordered within a book so the user does not hear Chapter 8 before Chapter 7.
- Image assignments ride with their containing chapter.

### Catch-up policy

Plans need an explicit catch-up policy for missed days:

- **Gentle catch-up (recommended):** never introduce more than today's configured budget; missed work waits.
- **Strict catch-up:** introduce accumulated missed chapters until caught up.

Ship with gentle catch-up as the default. Strict catch-up can be a plan setting if it is inexpensive to expose.

## 6. Data Model

Add a fresh migration. Do not edit shipped migrations.

### `study_plan`

Columns:

- `id TEXT PRIMARY KEY`
- `audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE`
- `deck_id TEXT REFERENCES deck(id) ON DELETE SET NULL`
- `cadence_unit TEXT NOT NULL` — `day` or `week`
- `new_chapter_limit INTEGER NOT NULL DEFAULT 1`
- `include_images INTEGER NOT NULL DEFAULT 0`
- `queue_mode_default TEXT NOT NULL DEFAULT 'book_by_book'`
- `catch_up_policy TEXT NOT NULL DEFAULT 'gentle'`
- `start_date TEXT NOT NULL`
- `is_paused INTEGER NOT NULL DEFAULT 0`
- `created_at TEXT NOT NULL`
- `modified_at TEXT NOT NULL`

Indexes:

- `idx_study_plan_book` on `audiobook_id`
- `idx_study_plan_active` on `is_paused, start_date`

### `study_plan_item`

Columns:

- `id TEXT PRIMARY KEY`
- `plan_id TEXT NOT NULL REFERENCES study_plan(id) ON DELETE CASCADE`
- `flashcard_id TEXT REFERENCES flashcard(id) ON DELETE SET NULL`
- `kind TEXT NOT NULL` — `chapter` or `image`
- `chapter_index INTEGER`
- `source_block_id TEXT`
- `ordinal INTEGER NOT NULL`
- `introduced_at TEXT`
- `is_enabled INTEGER NOT NULL DEFAULT 1`
- `created_at TEXT NOT NULL`
- `modified_at TEXT NOT NULL`

Indexes:

- `idx_study_plan_item_plan_order` on `plan_id, ordinal`
- `idx_study_plan_item_pending` on `plan_id, is_enabled, introduced_at`
- `idx_study_plan_item_flashcard` on `flashcard_id`
- `idx_study_plan_item_source` on `source_block_id`

### Why not only `flashcard.tags` / `media_json`?

Tags and JSON would avoid a migration, but they would make the release queue hard to query, hard to test, and easy to corrupt. The plan/item split keeps "what should be introduced when" separate from "how this card reviews under FSRS."

## 7. Components

### `StudyPlanGenerator`

Pure/service layer that builds generation candidates from `epub_block`.

Responsibilities:

- Query visible, non-front-matter chapter headings.
- Respect `is_hidden` / off-state so excluded chapters do not generate cards.
- Build image candidates when requested.
- Preserve source order.
- Detect existing generated cards/items and avoid duplicates.
- Return a preview model before writing anything.

### `StudyPlanDAO`

GRDB persistence for:

- Fetching plan by book.
- Creating plan and items transactionally.
- Updating cadence/settings.
- Enabling/disabling items.
- Marking items introduced.
- Fetching introduced but ungraded items by plan.
- Fetching pending items by plan.

### `StudyQueueBuilder`

Pure/queryable queue builder.

Inputs:

- Active plans.
- Existing due flashcards.
- Current date/calendar.
- Queue mode.

Outputs:

- Ordered queue sections/items for the study session.
- Counts for dashboard: due reviews, in-progress assignments, new assignments, total today.

### `StudySessionViewModel`

`@MainActor @Observable` view model for the sheet/session.

Responsibilities:

- Load a queue from `StudyQueueBuilder`.
- Present normal cards, chapter assignments, and image assignments.
- Ask `PlayerModel` to play/seek chapter assignments.
- Grade via `FlashcardDAO.grade`.
- Mark new plan items as introduced when the item first enters the study queue/session.
- Keep introduced but ungraded assignments in the queue until the generated card receives its first grade.
- Refresh review notifications after grading.

### Existing components to modify

- `ChapterCardDrafter`: replace or wrap with `StudyPlanGenerator` so there is one generation path.
- `DailyReviewViewModel`: either evolve into `StudySessionViewModel` or become a compatibility wrapper for due-only review.
- `FlashcardReviewSession`: support generated assignment card types.
- `FlashcardReviewCard`: render assignment/image variants without breaking normal Q/A cards.
- `RootTabView` / `DashboardShelf`: wire review taps to the existing launch path.
- `ReaderTab` or book settings: add the Study Plan entry point.
- `DeckListView` / `DeckDetailView`: optionally expose plan status later, not required for first usable flow.

## 8. UX Details

### Generation preview

The preview is a settings sheet, not a landing page:

- Book title and detected count.
- Stepper/segmented controls for cadence.
- Toggle for image cards.
- Queue mode picker.
- Chapter list with toggles.
- Front matter excluded by default and visibly labeled if shown.

Keep the chapter list dense. This is a work surface, not marketing copy.

### Study session

Chapter assignment card:

- Shows chapter title, book title, and progress.
- Primary action: play/continue chapter.
- Secondary action: mark complete / grade after listening.
- If the chapter has no audio, offer to narrate/open text if the book is EPUB-only; do not silently create an unplayable assignment.

Image assignment card:

- Shows the image, chapter context, and prompt.
- Grade buttons appear after the user reviews/reveals.

Normal flashcards:

- Keep the current front/back reveal behavior.

## 9. Testing Strategy

Unit tests first. UI tests only if core behavior cannot be covered otherwise.

Recommended suites:

- `StudyPlanGeneratorTests`
  - Excludes front matter.
  - Excludes hidden chapters.
  - Generates one candidate per included chapter.
  - Generates image candidates only when enabled.
  - Skips missing image files.
  - Does not duplicate existing generated cards/items.

- `StudyPlanDAOTests`
  - Creates plan and items transactionally.
  - Fetches by book.
  - Updates cadence and pause state.
  - Marks items introduced.

- `StudyQueueBuilderTests`
  - Due reviews precede in-progress and new assignments.
  - Introduced but ungraded assignments remain queued until graded.
  - Day cadence introduces the configured count.
  - Week cadence introduces the configured count for a week window.
  - Gentle catch-up does not pile up missed chapters.
  - Book-by-book groups correctly.
  - Mixed mode preserves new assignment order per book.

- `StudySessionViewModelTests`
  - Grades through `FlashcardDAO`.
  - Marks a new item introduced.
  - Refreshes due counts.
  - Handles assignment, image, and normal cards.

- Migration tests
  - Fresh install includes `study_plan` and `study_plan_item`.
  - Migration from previous schema preserves existing `deck`/`flashcard` rows.

## 10. Risks / Mitigations

| Risk | Mitigation |
|---|---|
| Generated cards ignore chapter exclusions | Source generation from visible/non-hidden blocks and add tests. |
| Duplicates from re-generation | Key idempotency on plan item source block + generated card type. |
| Review UI becomes confusing for assignment vs Q/A cards | Use explicit card-type rendering; keep normal cards unchanged. |
| New chapter limits fight FSRS due reviews | Due reviews remain first; in-progress and new assignments are separate queue categories. |
| Missed days create overwhelming queues | Gentle catch-up default. |
| Image cards include cover/ornamental assets | Exclude front matter and missing files first; add size/dimension filter when practical. |
| Schema churn | Use additive tables in a new migration with fresh schema tests. |
| Existing review entry remains unreachable | Include RootTabView/DashboardShelf wiring in the first implementation slice. |

## 11. Decomposition

This should be implemented as a small program, not one sprawling edit.

1. **Foundation:** migration, records, DAO, generator preview model, tests.
2. **Queue:** queue builder, introduction semantics, due/new ordering tests.
3. **Generation UI:** Study Plan sheet with chapter toggles, cadence, image toggle, queue mode.
4. **Study session:** evolve due review into assignment-aware study session, wire dashboard launch.
5. **Reader/book entry points:** expose Study Plan from the book surface and current flashcard action.
6. **Polish:** image-card rendering, stats/counts, docs updates.

## 12. Documentation Impact

This feature changes Echo's user-facing study model. After implementation, update:

- `README.md` study/EPUB section.
- `ARCHITECTURE.md` database and study sections, preferably via the project's architecture generation flow where applicable.
- `docs/guides/testflight-beta-guide.md` daily review test plan.

## 13. Open Decisions For Implementation Planning

The design is approved. These are implementation details to settle in the plan:

- Exact first UI location for the Study Plan entry point: book settings, reader utility row, or both.
- Whether image dimensions are available cheaply enough for first-pass decorative filtering.
