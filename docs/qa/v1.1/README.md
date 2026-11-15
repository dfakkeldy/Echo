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
