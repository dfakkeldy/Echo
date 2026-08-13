// SPDX-License-Identifier: GPL-3.0-or-later
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
//  CONTENT NOTE: In DEBUG simulator builds the app auto-seeds screenshot media
//  (EchoCoreApp.init → MockMediaProvider.seedSampleMediaIfNeeded, then
//  PlayerModel.restoreLastSelectionIfPossible loads it). This test forces the
//  bundled Standard Ebooks Great Gatsby EPUB so App Store captures remain stable
//  even if a local `EchoScreenshotSample.m4b` exists — see fastlane/screenshots
//  README. This test is deliberately defensive: every navigation step is
//  guarded, so one missing screen doesn't stop later captures, but the test
//  fails at the end if any expected category is absent.
//
//  NAVIGATION NOTE: The app uses a custom bottom dock, not a standard TabView,
//  and ships no accessibility identifiers, so we navigate by the accessibility
//  *labels* declared in BottomToolbarView / UnifiedTopHeader.
//

import XCTest

nonisolated final class EchoScreenshots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true // never abort the whole shoot on one missing screen
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += [
            "--echo-screenshot-fixture-gatsby",
            "--echo-screenshot-appearance-dark",
        ]
        addUIInterruptionMonitor(withDescription: "Screenshot bootstrap alerts") { alert in
            if alert.buttons["Continue Offline"].exists {
                alert.buttons["Continue Offline"].tap()
                return true
            }
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap()
                return true
            }
            return false
        }
        app.launch()
        var capturedShots = Set<String>()

        func capture(_ name: String) {
            snapshot(name)
            capturedShots.insert(name)
        }

        // Give the DEBUG-simulator sample seed time to load before the first shot.
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissBlockingAlerts(in: app)
        waitForAny(
            [
                app.buttons["Go to Read & Study"],
                app.buttons["Go to Listen"],
                app.buttons["Open book or folder"],
                app.buttons["More options"],
            ],
            timeout: 12)
        dismissBlockingAlerts(in: app)
        normalizeToListen(in: app)

        // ① Now Playing — "Turn listening into learning."
        capture("01_Player")

        // ② Timeline — the current Read & Study feed replaced the old Timeline tab,
        // but the filename stays stable for App Store release tooling.
        _ = navigate(to: "Read & Study", in: app)
        capture("02_Timeline")

        // ③ Reader — same current read surface, settled after the feed loads.
        _ = waitForAny(
            [
                app.staticTexts["Reader"],
                app.staticTexts["Read & Study"],
                app.buttons["Go to Library"],
                app.buttons["Table of Contents"],
                app.buttons["Reader settings"],
            ],
            timeout: 5)
        capture("03_Reader")

        // ⑤ Settings — privacy / "all on-device" frame.
        let didOpenSettings = openMenuItem("Settings", from: app.buttons["More options"], in: app)
        capture("05_Settings")
        if didOpenSettings {
            closePresentedSheet(in: app)
        }

        // ④ Stats / study — the spaced-repetition surface. Captured after Settings
        // so a Stats presentation cannot block the release-critical Settings shot.
        let didOpenStats = openMenuItem("Stats", from: app.buttons["More options"], in: app)
        capture("04_Stats")
        if didOpenStats {
            closePresentedSheet(in: app)
        }

        let expectedShots: Set<String> = [
            "01_Player", "02_Timeline", "03_Reader", "04_Stats", "05_Settings",
        ]
        let missingShots = expectedShots.subtracting(capturedShots).sorted()
        XCTAssertTrue(
            missingShots.isEmpty,
            "Missing expected App Store screenshot categories: \(missingShots.joined(separator: ", "))"
        )
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

    @MainActor
    @discardableResult
    private func navigate(to label: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons["Go to \(label)"]
        guard tap(button, in: app) else { return false }
        let arrived = waitForAny(
            [
                app.buttons["Go to Listen"],
                app.buttons["Go to Library"],
                app.staticTexts[label],
            ],
            timeout: 5)
        settle()
        return arrived
    }

    @MainActor
    private func openMenuItem(_ label: String, from menuButton: XCUIElement, in app: XCUIApplication)
        -> Bool
    {
        guard tap(menuButton, in: app) else { return false }
        let item = app.buttons[label]
        guard item.waitForExistence(timeout: 5) else { return false }
        item.tap()
        _ = waitForAny([app.staticTexts[label], app.navigationBars[label]], timeout: 5)
        settle()
        return true
    }

    @MainActor
    private func normalizeToListen(in app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["Go to Read & Study"].exists {
                settle()
                return
            }
            if tap(app.buttons["Go to Listen"], in: app) {
                settle()
                continue
            }
            if tap(app.buttons["Go to Library"], in: app) {
                settle()
                continue
            }
            settle()
        }
    }

    @MainActor
    @discardableResult
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return elements.contains(where: { $0.exists })
    }

    @MainActor
    private func dismissBlockingAlerts(in app: XCUIApplication) {
        app.tap()
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        if alert.buttons["Continue Offline"].exists {
            alert.buttons["Continue Offline"].tap()
        } else if alert.buttons["OK"].exists {
            alert.buttons["OK"].tap()
        }
    }

    @MainActor
    private func closePresentedSheet(in app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) {
            done.tap()
            settle()
            return
        }

        app.swipeDown()
        settle()
    }

    @MainActor
    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
