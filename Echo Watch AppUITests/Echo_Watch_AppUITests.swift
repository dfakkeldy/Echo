// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_Watch_AppUITests.swift
//  Echo Watch AppUITests
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import XCTest

// XCUITest base class. XCTestCase's members are nonisolated; under the target's
// MainActor default isolation the override/init isolation would mismatch, so opt the
// class out. Individual test methods keep their explicit @MainActor.
nonisolated final class Echo_Watch_AppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLaunchesWatchApp() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
