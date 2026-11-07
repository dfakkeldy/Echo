// SPDX-License-Identifier: GPL-3.0-or-later
//
//  EchoDesignCouncilShots.swift
//  EchoUITests
//
//  Walks every reachable iPhone screen and attaches one named screenshot per
//  screen, for design reviews. It is NOT the App Store shoot (that is
//  EchoScreenshots, whose names are release tooling). Run it with:
//
//      xcodebuild test -scheme "Echo Screenshots" \
//        -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
//        -only-testing:EchoUITests/EchoDesignCouncilShots \
//        -resultBundlePath /tmp/council.xcresult
//      xcrun xcresulttool export attachments --path /tmp/council.xcresult \
//        --output-path <dir>
//
//  Two fixtures:
//  - `--echo-screenshot-fixture-gatsby`: the bundled Standard Ebooks EPUB
//    (reader, library, settings, study).
//  - `--echo-screenshot-fixture-audio`: a local `EchoScreenshotSample.m4b`
//    placed in the app's Documents folder before the run (player screens).
//    Without it, the audio pass captures whatever the app restores.
//
//  Every step is guarded: a missing screen is skipped, never fatal.
//

import XCTest

nonisolated final class EchoDesignCouncilShots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Player (audio fixture)

    @MainActor
    func test1PlayerScreens() throws {
        let app = launch(fixture: "--echo-screenshot-fixture-audio")
        normalizeToListen(in: app)
        shot("P01_Player", app)

        if openMenu(app.buttons["More options"], in: app) {
            shot("P02_MoreMenu", app)
            dismissMenu(in: app)
        }
        if openMenu(app.buttons["Playback speed"].firstMatch, in: app) {
            shot("P03_SpeedMenu", app)
            dismissMenu(in: app)
        }
        if openMenu(app.buttons["Bookmark, note, or memo"], in: app) {
            shot("P04_CaptureMenu", app)
            let add = app.buttons["Add bookmark"].firstMatch
            if add.waitForExistence(timeout: 2), add.isHittable {
                add.tap()
                settle(1.5)
                shot("P05_BookmarkDraft", app)
                closePresentedSheet(in: app, preferCancel: true)
            } else {
                dismissMenu(in: app)
            }
        }
        if openMenu(app.buttons["Playback speed"].firstMatch, in: app) {
            let options = app.buttons["Playback Options"].firstMatch
            if options.waitForExistence(timeout: 2) {
                options.tap()
                settle(1.5)
                shot("P06_PlaybackOptions", app)
                closePresentedSheet(in: app)
            } else {
                dismissMenu(in: app)
            }
        }
        if openMenuItem("Chapters", in: app) {
            shot("P07_Chapters", app)
            closePresentedSheet(in: app)
        }
        if tap(app.buttons["Book info"].firstMatch, in: app) {
            settle(1.5)
            shot("P08_BookSettings", app)
            closePresentedSheet(in: app)
        }
        if tap(app.buttons["Sleep Timer"].firstMatch, in: app) {
            settle()
            shot("P09_SleepTimer", app)
            dismissMenu(in: app)
        }
        if openMenuItem("Bookmarks", in: app) {
            shot("P10_MoreBookmarks", app)
        }
    }

    // MARK: - Reader, library and app-level screens (EPUB fixture)

    @MainActor
    func test2ReaderAndLibraryScreens() throws {
        let app = launch(fixture: "--echo-screenshot-fixture-gatsby")
        normalizeToListen(in: app)
        shot("R00_PlayerEPUBOnly", app)

        if navigate(to: "Read & Study", in: app) {
            settle(2)
            shot("R01_Reader", app)
            app.swipeUp()
            settle()
            shot("R02_ReaderScrolled", app)
            if tap(app.buttons["Table of Contents"].firstMatch, in: app) {
                settle(1.5)
                shot("R03_TableOfContents", app)
                closePresentedSheet(in: app)
            }
            if tap(app.buttons["Reader settings"].firstMatch, in: app) {
                settle(1.5)
                shot("R04_ReaderSettings", app)
                closePresentedSheet(in: app)
            }
            if tap(app.buttons["Listening sessions"].firstMatch, in: app) {
                settle(1.5)
                shot("R05_ListeningSessions", app)
                closePresentedSheet(in: app)
            }
        }

        if navigate(to: "Library", in: app) {
            settle(2)
            shot("L01_Library", app)
            let browse = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Browse by'")
            ).firstMatch
            if openMenu(browse, in: app) {
                shot("L02_LibraryBrowseBy", app)
                dismissMenu(in: app)
            }
        }
    }

    @MainActor
    func test3AppLevelScreens() throws {
        let app = launch(fixture: "--echo-screenshot-fixture-gatsby")
        normalizeToListen(in: app)

        if openMenuItem("Help", in: app) {
            shot("A06_Help", app)
            closePresentedSheet(in: app)
        }
        if openMenuItem("Fidget", in: app) {
            settle(1.5)
            shot("A07_Fidget", app)
            closePresentedSheet(in: app)
        }
        if openMenuItem("Stats", in: app) {
            settle(2)
            shot("A01_Stats", app)
            app.swipeUp(velocity: .slow)
            app.swipeUp(velocity: .slow)
            settle()
            shot("A02_StatsScrolled", app)
            closePresentedSheet(in: app)
        }
        // Each study link replaces the Stats sheet, so reopen Stats per link.
        for (label, name) in [
            ("Review Queue", "A03_Review"), ("Card Inbox", "A04_CardInbox"), ("Decks", "A05_Decks"),
        ] {
            guard openMenuItem("Stats", in: app) else { break }
            settle(1.5)
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if link.waitForExistence(timeout: 3), link.isHittable {
                link.tap()
                settle(1.5)
                shot(name, app)
            }
            closePresentedSheet(in: app)
            closePresentedSheet(in: app)
        }
    }

    @MainActor
    func test4SettingsScreens() throws {
        let app = launch(fixture: "--echo-screenshot-fixture-gatsby")
        normalizeToListen(in: app)
        guard openMenuItem("Settings", in: app) else { return }
        shot("S00_Settings", app)
        app.swipeUp()
        settle()
        shot("S00b_SettingsScrolled", app)
        app.swipeUp()
        settle()
        shot("S00c_SettingsBottom", app)

        let pages: [(String, String)] = [
            ("Playback Defaults", "S01_PlaybackDefaults"),
            ("Appearance", "S02_Appearance"),
            ("Phone Player Settings", "S03_PhonePlayer"),
            ("Watch App Settings", "S04_WatchApp"),
            ("Connections", "S05_Connections"),
            ("Echo Pro", "S06_EchoPro"),
            ("AI Card Generation", "S07_AICardGeneration"),
            ("Chapter Checkpoints", "S08_ChapterCheckpoints"),
            ("Pronunciation", "S09_Pronunciation"),
            ("Advanced", "S10_Advanced"),
            ("Feedback & Support", "S11_FeedbackSupport"),
        ]
        for (label, name) in pages {
            let link = findRow(label, in: app)
            guard let link else { continue }
            link.tap()
            settle(1.5)
            shot(name, app)
            goBack(in: app)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [fixture, "--echo-screenshot-appearance-dark"]
        addUIInterruptionMonitor(withDescription: "Bootstrap alerts") { alert in
            for title in ["Continue Offline", "Allow", "OK", "Not Now"]
            where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissBlockingAlerts(in: app)
        waitForAny(
            [
                app.buttons["Go to Read & Study"], app.buttons["Go to Listen"],
                app.buttons["More options"],
            ],
            timeout: 12)
        settle(2)
        return app
    }

    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap()
        return true
    }

    @MainActor
    private func openMenu(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard tap(element, in: app) else { return false }
        settle()
        return true
    }

    @MainActor
    private func dismissMenu(in app: XCUIApplication) {
        // Tap the top-left status area, outside any menu or sheet content.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.06)).tap()
        settle()
    }

    @MainActor
    private func openMenuItem(_ label: String, in app: XCUIApplication) -> Bool {
        guard tap(app.buttons["More options"], in: app) else { return false }
        let item = app.buttons[label].firstMatch
        guard item.waitForExistence(timeout: 3), item.isEnabled else {
            dismissMenu(in: app)
            return false
        }
        item.tap()
        settle(1.5)
        return true
    }

    @MainActor
    private func findRow(_ label: String, in app: XCUIApplication) -> XCUIElement? {
        for _ in 0..<6 {
            let candidates = [app.buttons[label].firstMatch, app.staticTexts[label].firstMatch]
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                return hit
            }
            app.swipeUp()
            settle(0.6)
        }
        for _ in 0..<6 {
            app.swipeDown()
            settle(0.4)
            let candidates = [app.buttons[label].firstMatch, app.staticTexts[label].firstMatch]
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                return hit
            }
        }
        return nil
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable {
            back.tap()
        } else {
            app.swipeRight()
        }
        settle()
    }

    @MainActor
    @discardableResult
    private func navigate(to label: String, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            if tap(app.buttons["Go to \(label)"], in: app) {
                settle(1.5)
                return true
            }
            // The dock cycles tabs; step once and retry.
            let cycle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to '"))
                .firstMatch
            guard tap(cycle, in: app) else { return false }
            settle()
        }
        return false
    }

    @MainActor
    private func normalizeToListen(in app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["Go to Read & Study"].exists { return }
            let cycle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to '"))
                .firstMatch
            guard tap(cycle, in: app) else { return }
            settle()
        }
    }

    @MainActor
    @discardableResult
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func dismissBlockingAlerts(in app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for title in ["Continue Offline", "OK", "Not Now"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
    }

    @MainActor
    private func closePresentedSheet(in app: XCUIApplication, preferCancel: Bool = false) {
        let titles = preferCancel ? ["Cancel", "Done", "Close"] : ["Done", "Close", "Cancel"]
        for title in titles {
            let button = app.buttons[title].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                settle()
                return
            }
        }
        app.swipeDown(velocity: .fast)
        settle()
    }

    @MainActor
    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
