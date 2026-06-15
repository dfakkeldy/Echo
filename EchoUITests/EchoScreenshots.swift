//
//  EchoScreenshots.swift
//  EchoUITests
//
//  Drives the iOS app through the marketing screens and captures App Store
//  screenshots via fastlane snapshot. Run it with:
//
//      bundle exec fastlane screenshots
//
//  which builds the "Echo Screenshots" scheme, boots each device listed in
//  fastlane/Snapfile, runs ONLY this test class, and writes the PNGs into
//  fastlane/screenshots/<locale>/.
//
//  CONTENT NOTE: In DEBUG simulator builds the app auto-seeds a sample
//  audiobook (EchoCoreApp.init → MockMediaProvider.seedSampleAudiobookIfNeeded,
//  then PlayerModel.restoreLastSelectionIfPossible loads it). That only happens
//  if `BIFF.m4b` is bundled into the app — see fastlane/screenshots README.
//  Without it the library is empty and the content-gated screens (Reader,
//  Timeline) fall back to their empty states. This test is deliberately
//  defensive: every navigation step is guarded, so a missing screen degrades
//  to "skip that shot" rather than failing the whole run.
//
//  NAVIGATION NOTE: The app uses a custom bottom dock, not a standard TabView,
//  and ships no accessibility identifiers, so we navigate by the accessibility
//  *labels* declared in BottomToolbarView / UnifiedTopHeader. The
//  "Toggle chapters list" button cycles nowPlaying → timeline → read → stats.
//

import XCTest

final class EchoScreenshots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true // never abort the whole shoot on one missing screen
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        // Give the DEBUG-simulator sample seed time to load before the first shot.
        _ = app.wait(for: .runningForeground, timeout: 10)
        sleep(3)

        // ① Now Playing — "Turn listening into learning."
        snapshot("01_Player")

        // The cycle button advances nowPlaying → timeline → read → stats.
        let cycleButton = app.buttons["Toggle chapters list"]

        // ② Timeline — bookmarks / chapters on a single canvas.
        if tap(cycleButton, in: app) {
            sleep(1)
            snapshot("02_Timeline")
        }

        // ③ Reader — the synced EPUB following the narration.
        if tap(cycleButton, in: app) {
            sleep(1)
            snapshot("03_Reader")
        }

        // ④ Stats / study — the spaced-repetition surface.
        if tap(cycleButton, in: app) {
            sleep(1)
            snapshot("04_Stats")
        }

        // ⑤ Settings — privacy / "all on-device" frame.
        let moreOptions = app.buttons["More options"]
        if moreOptions.waitForExistence(timeout: 5) {
            moreOptions.tap()
            let settings = app.buttons["Settings"]
            if settings.waitForExistence(timeout: 3) {
                settings.tap()
                sleep(1)
                snapshot("05_Settings")
            }
        }
    }

    /// Taps `element` only if it is present and hittable. Returns whether it tapped,
    /// so callers can skip the matching snapshot when a screen is unavailable.
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5), element.isHittable else {
            return false
        }
        element.tap()
        return true
    }
}
