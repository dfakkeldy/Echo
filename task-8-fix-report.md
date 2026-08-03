# Task 8 Fix Report

## Outcome

The three-voice integration test now exercises the production app path rather
than reproducing narration orchestration in the test. The test:

- builds each edition with `AnthologyEPUBBuilder` and imports it with
  `GeneratedAnthologyImportReconciler.importArchive`;
- starts each narration run through `PlayerModel.startNarrationPlayback` and
  awaits `PlayerModel.narrationRenderTask`;
- lets production resolve the receipt, chapter source identity, effective voice,
  cache reuse and cleanup, track persistence, resume target, queue order,
  backfill, and final narration state;
- saves chapter 2's real durable track URL through
  `PlayerModel.persistence.saveLastTrack`, then proves that reorder produces the
  queue `3, 1, 2` while keeping chapter 2 current at index 2;
- proves the render-file deltas `[3, 1, 0, 1, 0]`, effective and persisted
  voices, stable URLs, track sort/source mapping, and export order; and
- corrupts the latest production receipt after creating a book-prefixed stale
  sentinel, then proves failure occurs before synthesis or cleanup: zero raw TTS
  calls, the sentinel remains, and all previously proven audio remains.

The only new production surface is concrete test injection for the existing
audio writer and narration-cache directory. Production defaults remain
`AVFoundationAudioWriter()` and `NarrationCache.directory()`.

## RED evidence

The first focused attempt on the shared simulator compiled the new test but was
killed before XCTest bootstrapped because unrelated Xcode sessions were active;
that attempt is not counted as behavioral RED.

The first uncontended production-path execution produced a behavioral RED. The
real generated import completed (16 blocks and 3 TOC entries), but production
rejected the fixture receipt before rendering because the fixture paired
non-canonical JSON with the builder's canonical sorted-key digest. After the
fixture was corrected to use production's sorted-key encoding, the next run
reached production synthesis and exposed two test-environment issues: the real
AVFoundation sink could not create its simulator partial, and the simulator's
container-length temporary URL made the book-prefixed cache filename invalid.
The final fixture uses an injected streaming audio sink and a unique short
`/tmp/echo-3v-<UUID>` root. These changes preserve production orchestration and
filesystem publication while keeping the player alive for look-ahead behavior.

## GREEN evidence

- Focused production integration:
  `xcodebuild test-without-building -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/EchoTask8DerivedData -only-testing:EchoTests/AnthologyChapterVoicesIntegrationTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO`
  passed 1 test in 1 suite in 50.974 seconds.
- Required test build: `make build-tests` passed with `TEST BUILD SUCCEEDED`.
- Adjacent regression suites passed 60 tests in 5 suites in 87.893 seconds:
  `PlayerModelTests`, `GeneratedAnthologyImportTests`,
  `AnthologyNarrationPlaybackPlanTests`,
  `AnthologyNarrationStatusServiceTests`, and
  `NarrationPrepareStatusTests`.
- Exact unsigned simulator build:
  `xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
  passed.
- Unsigned macOS build:
  `xcodebuild build -project Echo.xcodeproj -scheme 'Echo macOS' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  passed.
- An additional unsigned generic iOS device compile also passed; it is not used
  as a substitute for the requested simulator build.
- `swift-format lint --strict` on the rewritten integration test and
  `git diff --check` passed.

## Boundaries and truthfulness

- The public synthetic fixture
  `EchoTests/ArticleWorkshop/Fixtures/three-voice-anthology-manifest.json` is the
  only content input. No private book, transcript, or generated study material
  was added.
- No pronunciation file or pronunciation behavior was changed.
- The full `make test` gate was not run. Focused and adjacent suites were used to
  avoid colliding with the unrelated active Xcode sessions observed during the
  task.
- No hosted CI, physical-device run, deployment, merge, or human listening
  acceptance was performed.
- The existing Unreleased changelog claim for anthology chapter voices, stable
  narration-file reuse, playback order, and export order is now backed by the
  production-path integration test. No changelog wording was changed.
