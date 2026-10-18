# Echo bug hunt loop — issue + fix log — 2026-06-29

## Current access snapshot

- Repo: dfakkeldy/Echo
- Integration branch: nightly
- Base commit at start: d0c80ff (chore(screenshots): seed Gatsby fixture (#279))
- Dirty state: clean (only untracked `docs/real-world-testing/` ledgers)
- Build under test: iOS Simulator unit tests (`make build-tests` / `make test-only`), `CODE_SIGNING_ALLOWED=NO`
- Device / OS: iPhone 17 simulator, iOS 26.5 (Xcode 26.6 host)
- Live service: ABS at 100.95.69.48:13378 (download-to-local; covered heavily 2026-06-28 — steering this loop toward other subsystems)
- Credentials policy: read-only on live ABS; no secrets in repo/issues/logs
- Local tool gaps: ffprobe/pdfinfo/jq present; bundler 2.5.22 missing (fastlane lanes blocked)

## Strategy

Yesterday's *test hunt* (`2026-06-28-real-world-test-plan.md`, RW-001..RW-058) concentrated on ABS +
import + progress sync, and many of those logic bugs are already fixed/closed. The remaining open
issues are hard build-config/scheme/Swift-6-warning items. This *find-and-fix* loop therefore targets
**fresh, unit-testable logic bugs in under-covered subsystems**: EPUB reader/TOC/block parsing,
flashcards/study, narration engine, alignment (DTW / title matcher), widget + watch state, local
library scanner (V27), PDF alignment (V28), export, search, settings, sleep timer, bookmarks, and the
database/DAO layer.

## Cycle log

| Cycle | Start | Base nightly commit | Issues filed | PR | CI result | Merge | Quiet-timer at close |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-06-29 | d0c80ff | #282–#291 | #294 | Green (14m21s; incl. macOS + echo-cli) | Squash-merged → 094362c | n/a (10 found fast) |
| 2 | 2026-06-29 | 094362c | #296–#305 | #307 | Green (10m58s; incl. macOS + echo-cli) | Squash-merged → 2c43046 | n/a (found fast); #297,#305 deferred-open |
| 3 | 2026-06-29 (in progress) | 2c43046 | #311–#317 | TBD | TBD | TBD | TBD |

## Verification run log

| Time | Command / check | Result | Notes |
| --- | --- | --- | --- |
| 2026-06-29 | `gh issue list` open+closed dedup baseline | Passed | 14 open issues (mostly build-config); RW backlog logic bugs largely closed |
| 2026-06-29 | `make build-tests` (after 10 fix commits) | Failed → fixed | `formatHMS` is `@MainActor` under Swift 6 default isolation; `nonisolated Bookmark.markdownExport` couldn't call it (3 targets). Fixed by marking `formatHMS` `nonisolated`. (Earlier "exit 0" was a `\| tail` masking `make`'s failure.) |
| 2026-06-29 | `make build-tests` (after isolation fix) | Passed | `** TEST BUILD SUCCEEDED **`, 0 errors |
| 2026-06-29 | 7 touched suites + WordSentenceContextTests (iOS sim, codesign off) | Passed | 85 + 4 tests, 0 failures; all 10 new regression tests run & pass |

## Issue + fix log

| ID | Cycle | Area | Severity | Status | GitHub | Fix commit | Summary | Suspected code area |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BL-001 | 1 | Alignment / anchors | Medium | Fixed | #282 | ec1bbd5 | `AnchorSelector` evicted a monotonic middle anchor for a rejected newcomer | `AnchorSelector.select` |
| BL-002 | 1 | Bookmarks / persistence | Medium | Fixed | #283 | bb29c45 | Codable decoder dropped lat/long/placeName on the live load path | `Bookmark.init(from:)` |
| BL-003 | 1 | Reader / vocab context | Medium | Fixed | #284 | e22094f | Any `.`/`!`/`?` treated as sentence boundary (`3.14` truncates) | `WordSentenceContext` |
| BL-004 | 1 | Reader / in-book search | Medium | Fixed | #285 | a1e35e2 | Search returned `is_hidden` blocks absent from the feed | `EPubBlockDAO.searchBlocks` |
| BL-005 | 1 | Local Library / browse | High | Fixed | #286 | 84556a0 | Browse-by-Author collapsed NULL `author_sort` books into one section | `LibraryService.sections(by:.author)` |
| BL-006 | 1 | Local Library / rescan | High | Fixed | #287 | 7fc9475 | Cold rescan never started the security scope → whole shelf hidden | `LibraryService.rescan` |
| BL-007 | 1 | Flashcards / apkg export | Medium | Fixed | #288 | 96930a6 | Review-card `due` written as interval length, not schedule day | `ApkgExportService.dueValue` (+ Mac) |
| BL-008 | 1 | Flashcards / apkg import | Medium | Fixed | #289 | 87868a8 | Decks named after Anki "Default" deck, merging imports | `ApkgImportService.parseFirstDeckName` |
| BL-009 | 1 | Bookmarks / md export | Low | Fixed | #290 | 3771a57 | `markdownExport` dropped the hours component | `Bookmark.markdownExport` |
| BL-010 | 1 | Alignment / title matcher | Low | Fixed | #291 | b1d6462 | Roman-letter words ("Civil") misread as generic track labels | `ChapterTitleMatcher.keywordNumberPattern` |
| BL-011 | 2 | Stats / per-book coverage | High | Fixed | #296 | f4f178e | `fetchChapterCoverage` traps on inverted segment (crash) | `StatsRepository.fetchChapterCoverage` |
| BL-012 | 2 | Settings / watch migration | Med-High | Deferred (open) | #297 | reverted (bdc977f) | Real bug, but correct fix is blocked by `UserDefaults`' process-global registration domain (object() can't tell persisted from registered); needs suiteName/persistentDomain detection — left for human review | `SettingsManager` init |
| BL-013 | 2 | Import / markdown | Medium | Fixed | #298 | 3b28fbf | Thematic breaks (`---`) imported as narrated junk paragraphs | `TextDocumentParser.tokenizeMarkdown` |
| BL-014 | 2 | Narration / chunking | Medium | Fixed | #299 | cd95a00 | Editorial `[sic]` brackets disabled sentence splitting | `NarrationTextChunker` |
| BL-015 | 2 | Narration / silence guard | Medium | Fixed | #300 | 3206f8f | `[...]` blocked silence-recovery split → dead-air gap | `NarrationSilenceGuard.splitForRetry` |
| BL-016 | 2 | Reader / Define + save | Medium | Fixed | #301 | d32c9a9 | Lookup/save term kept attached punctuation | `DictionaryLookupPresenter`, `ReaderTab+Alignment` |
| BL-017 | 2 | Stats / session-length | Low-Med | Fixed | #302 | 79c5e90 | Buckets by content-seconds, inflated by playback speed | `StatsAggregator.sessionLengthDistribution` |
| BL-018 | 2 | Sleep timer / format | Low | Fixed | #303 | b7f592f | Ambiguous "1:00" for the freshly-armed 1-hour preset | `sleepTimerCountdownText` |
| BL-019 | 2 | EPUB parsing / hyperlink | Low | Fixed | #304 | 90114a0 | `<a>` emitted an orphan `</a>` in htmlContent | `EPUBXMLParsing` end handler |
| BL-020 | 2 | EPUB parsing / blockquote | Low | Deferred (open) | #305 | — | Dead `else if`; correct fix entangled with deferred-flush — left for human review | `EPUBXMLParsing` |
| BL-021 | 3 | Playback / auto-advance | High | Fixed | #311 | bb76c78 | End-of-book auto-restarted the whole book with loop off | `PlaybackController.nextChapter/nextTrack` |
| BL-022 | 3 | Playback / track nav | Medium | Fixed | #312 | bb76c78 | `findNextEnabledTrackIndex` range trap (crash) when index past end | `PlaybackController.findNextEnabledTrackIndex` |
| BL-023 | 3 | Flashcards / deck import | Medium | Fixed | #313 | afa52ce | `.echo-deck.json` re-import duplicated every card | `DeckImportService` |
| BL-024 | 3 | Playback / skip-forward | Medium | Fixed | #314 | bb76c78 | `skipForward` seeked to 0 when duration unresolved | `PlaybackController.skipForward` |
| BL-025 | 3 | Flashcards / watch review | Low | Fixed | #315 | 930f6d2 | Watch graded on 0/3/5; persisted invalid `lastGrade` | `WatchReviewView`, `FSRSScheduler` |
| BL-026 | 3 | Now Playing | Low | Fixed | #316 | 068519d | Stale `ChapterNumber` leaked to lock screen | `NowPlayingController` |
| BL-027 | 3 | Flashcards / deck validation | Low | Fixed | #317 | afa52ce | `invalidTriggerTiming` validation was dead code | `DeckImportService`, `FlashcardDeckImport` |
