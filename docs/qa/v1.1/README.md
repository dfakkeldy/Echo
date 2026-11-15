# Echo 1.1 simulator evidence — November 15, 2026

Candidate: `7f0a71a0af5ac211b361c4f4422b230c700e485d` plus the screenshot-test correction in this PR. Xcode 27.2 (27B52), iOS 27.2 Simulator. This is preparation evidence, not Apple approval.

## Build and tests

- `make test`: simulator app build passed; 4,336 tests passed, 4 skipped, zero failures in the top-level summary. See [sanitized results](../../releases/v1.1-unit-tests.json). The parameterized device-level count is different; do not add the counts together.
- `make doc-contract-test doc-automation-test`: passed (11 contracts, 39 automation tests).
- `make fastlane-test`: passed with Ruby 3.3.6 (10 Ruby tests and routing checks). The host's Ruby 2.6 cannot parse existing tests.
- Required CI selects unit tests, not the whole shared scheme's UI suite. The screenshot lane separately ran `EchoScreenshots` on both devices below.

## Screenshot capture and review

`fastlane ios screenshots` completed successfully after the harness correction on every device in `fastlane/Snapfile`: iPhone 17 Pro Max (1320 × 2868) and iPad Pro 13-inch (M5) (2064 × 2752). Both use the bundled Standard Ebooks Gatsby fixture in dark appearance. No private books or transcripts were used.

The first run passed but all five phone files showed Settings. `dismissBlockingAlerts` tapped the app unconditionally even when no alert existed. That tap opened the underlying menu. The test ignored failed navigation and accepted filenames as evidence. The correction removes that tap, asserts navigation, and stops on failure. [Rejected original phone capture](rejected-phone-player.png) preserves the observed failure.

The rerun produced distinct player, reader, settings and statistics screens. Each image was visually reviewed. Only narration setup (`01_Player`) and book settings (`05_Settings`) are retained under `fastlane/screenshots/en-US`, two per device. The narration screen correctly says the EPUB has no audiobook; it is not evidence of active audio playback. Accepted PNGs are RGB without alpha, with no clipped text or debug overlays. [Manifest and hashes](screenshots.json).

Reader/Timeline were duplicate, mostly empty captures containing collapsed Front Matter, Colophon and Uncopyright. Statistics contained zero listening history. They are unsuitable marketing captures, even though the UI test passed. Representative rejected reader/statistics images for both devices are retained here as diagnostic evidence, outside the upload directory. The Gatsby EPUB contains nine chapter files; the captures alone do not prove whether chapter selection or reader loading caused the empty presentation. A populated reader capture remains a follow-up.

The README and documentation landing page now use the accepted phone captures. The existing Watch image is explicitly labeled as an earlier release; Watch and Mac were not in this lane.

## Host safeguards

Apple builds were serialized for this task and gated against the dispatcher's host-health check and global build count. Fastlane and the repository's existing gem dependencies were installed into temporary host storage with Ruby 3.3.6; no project dependency or lockfile was changed. The temporary Fastlane installation's global `killall Simulator`, shutdown-all-booted-devices and Simulator preference changes were disabled to protect other threads. Only this task's simulators were closed. The project's lane, Snapfile and release/signing/workflow configuration were unchanged.

No archive, signing, upload, account sign-in, purchase, TestFlight or Apple submission was performed. Physical Watch behavior, StoreKit purchase/restore, optional model downloads, remote services and the actual live App Store version remain owner checks.

## Manual smoke blocker and remaining checks

The requested manual T3 interaction pass could not run. Device discovery and opening this task's iPad succeeded, but the runner's first use can build XCTest support. Repeated dispatcher capacity checks remained unhealthy (swap peaked above 15 GB with this task's simulators running; after closing both, later checks still reported 8.1–8.5 GB against the 8 GB limit). No runner build or interaction was started while unhealthy. Other threads' devices and processes were left alone. Screenshot UI-test navigation is the only runtime interaction evidence in this handoff; it must not be reported as a manual smoke pass.

Before submission, on a healthy host:

1. Open a dedicated T3 device session and launch the candidate with the Gatsby fixture arguments used by `EchoScreenshots`.
2. Select chapter I through the table of contents, expand text and scroll the continuous reader. Diagnose the collapsed/empty capture if actual chapter text is unavailable; preserve a screenshot of any failure.
3. Exercise the Books shelf, reader controls and narration-engine selection. Inspect Watch Inbox settings without sending messages or configuring a real endpoint. Test model/audio behavior separately with approved media and downloads.
4. Capture a populated reader on both Snapfile sizes and review it before adding it to the store set. Existing accepted setup/settings images do not demonstrate the new reader.
5. Confirm the live App Store baseline (1.0 versus 1.0.1), reconcile the separate marketing site, and perform the owner-only submission checks in the release checklist.

The candidate is **not certified ready to submit** by this PR. No claim is made that the observed collapsed fixture is a confirmed production regression; its cause remains unresolved.
