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

Reader/Timeline were duplicate, mostly empty captures containing collapsed Front Matter, Colophon and Uncopyright. Statistics contained zero listening history. They are unsuitable marketing captures, even though the UI test passed. Representative rejected reader/statistics images for both devices are retained here as diagnostic evidence, outside the upload directory. The Gatsby EPUB contains nine chapter files; the captures alone do not prove whether chapter selection or reader loading caused the empty presentation. Populated reader captures were subsequently obtained in the MacBook follow-up below.

The README and documentation landing page now use the accepted phone captures. The existing Watch image is explicitly labeled as an earlier release; Watch and Mac were not in this lane.

## Host safeguards

Apple builds were serialized for this task and gated against the dispatcher's host-health check and global build count. Fastlane and the repository's existing gem dependencies were installed into temporary host storage with Ruby 3.3.6; no project dependency or lockfile was changed. The temporary Fastlane installation's global `killall Simulator`, shutdown-all-booted-devices and Simulator preference changes were disabled to protect other threads. Only this task's simulators were closed. The project's lane, Snapfile and release/signing/workflow configuration were unchanged.

No archive, signing, upload, account sign-in, purchase, TestFlight or Apple submission was performed. Physical Watch behavior, StoreKit purchase/restore, optional model downloads, remote services and the actual live App Store version remain owner checks.

## Completed MacBook follow-up — November 15

Tested source: `ea9a8630ceaf5acf0e78b0bda35144bf166c89ab`, Xcode 27.2 (27B52), iOS 27.0. A fresh-context Astra review found that `openMenuItem` discarded its destination wait. It now requires the matching Settings/Stats navigation bar. The simulator build passed, and `EchoUITests/EchoScreenshots` passed separately on iPhone 17 Pro Max and iPad Pro 13-inch (M5): one test, zero failures on each. Documentation contracts, documentation automation and Fastlane checks also passed again.

The manual T3 smoke pass covered Books → Listen → Read & Study, table of contents, chapter I, continuous-reader scrolling, reader settings (17 → 18 pt), the voice picker (Ava → Bella), and Watch Inbox settings. No narration, model download, webhook setup or message delivery was started. Voice selection is not evidence of successful audio generation or engine inference.

### Populated reader and remaining behavior

The initial reader showed collapsed Front Matter, Colophon and Uncopyright. On the phone, choosing chapter I while Front Matter remained collapsed left the reader at Titlepage. Expanding Front Matter, then selecting I again revealed the chapter. On the iPad, expanding Front Matter before selecting I also revealed the chapter. Chapter text and scrolling work; this narrows the capture problem to collapsed state/navigation, but does not establish its implementation-level cause or fix it.

Visually inspected populated captures: [phone, 1320 × 2868](reader-phone.png) and [iPad, 2064 × 2752](reader-ipad.png). These are QA evidence outside the upload directory, not a replacement marketing set. The phone shows scrolled reading with its controls hidden; the iPad shows the continuous reader with controls visible. No private media was used.

The fixture also produces a Folder Access Not Saved alert on relaunch; OK allows this session to continue. The fixture's Books shelf is empty even while Gatsby is selected. No signed-device persistence claim follows from this unsigned simulator fixture.

### Build safeguards

The first local attempt stopped before compilation in a SwiftPM Keychain authorization lookup. A later admitted run with the per-command `-packageAuthorizationProvider netrc` option completed. Intervening attempts were deferred for low free swap or an occupied Apple build slot. All Apple builds/tests used the required wrapper; Dan approved the off-hours run and up to 15 GB of temporary output. The existing device-session runner handled subsequent UI commands. Only this task's devices were closed; its dedicated iPad simulator was removed.

This completes the preparation checks, not submission certification. Release binary/baseline selection, signed-device checks and Apple submission remain Dan's steps. The separate marketing-site work remains listed in the PR; collapsed-state navigation remains a follow-up, not a production fix in this PR.
