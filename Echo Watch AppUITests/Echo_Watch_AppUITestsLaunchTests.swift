// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_Watch_AppUITestsLaunchTests.swift
//  Echo Watch AppUITests
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import XCTest

// XCUITest base class. XCTestCase's members are nonisolated; under the target's
// MainActor default isolation the override/init isolation would mismatch, so opt the
// class out. Individual test methods keep their explicit @MainActor.
nonisolated final class Echo_Watch_AppUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
