// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Testing
import UIKit

@testable import Echo

/// Regression tests for the Sessions sheet crash (J-Space device QA 2026-07-17,
/// issue 1): `SessionsListView`/`SessionDetailFeedView` declared
/// `@Environment(DatabaseService.self)`, which no iOS root ever injected, so
/// presenting the sheet trapped in `SessionsListView.load()` on first appearance.
///
/// Both views are now constructor-injected. These tests render each one inside
/// a minimal live host (`UIWindow` + `UIHostingController`) and let the run
/// loop turn so `.task`/`.onAppear` execute — the exact places the old trap
/// fired, which a body-only render would miss. If a future change reintroduces
/// a non-optional `@Environment` dependency that no host injects, these tests
/// crash in CI instead of on-device.
@MainActor
@Suite struct SessionViewsHostingTests {

    @Test func sessionsListViewRendersInMinimalHost() async throws {
        let dbService = try DatabaseService(inMemory: ())
        await renderInLiveWindow(
            SessionsListView(audiobookID: "host-test-book", dbService: dbService))
    }

    @Test func sessionDetailFeedViewRendersInMinimalHost() async throws {
        let dbService = try DatabaseService(inMemory: ())
        await renderInLiveWindow(
            SessionDetailFeedView(
                audiobookID: "host-test-book",
                session: Self.routelessSession,
                dbService: dbService))
    }

    // MARK: - Minimal live host

    /// Hosts `view` in a key window, forces layout, then suspends so the main
    /// run loop drains the first render pass and its `.onAppear`/`.task`
    /// closures. A missing environment dependency traps here rather than
    /// on-device.
    private func renderInLiveWindow(_ view: some View) async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: NavigationStack { view })
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        // Detach the hierarchy so SwiftUI cancels the view's `.task` work
        // before the test returns.
        window.isHidden = true
        window.rootViewController = nil
    }

    /// A route-less session so the detail view skips its MapKit header —
    /// map rendering adds flakiness without exercising the injection seam.
    private static let routelessSession = SessionSummary(
        id: "host-test-book#2026-07-17T12:00:00Z",
        audiobookID: "host-test-book",
        startedAt: Date(timeIntervalSince1970: 1_752_753_600),
        endedAt: Date(timeIntervalSince1970: 1_752_755_400),
        startPosition: 0,
        endPosition: 1800,
        minutesListened: 30,
        firstChapterTitle: "Chapter 1",
        lastChapterTitle: "Chapter 2",
        firstChapterSortOrder: 0,
        lastChapterSortOrder: 1,
        bookmarkCount: 0,
        cardCount: 0,
        noteCount: 0,
        imageCount: 0,
        route: [],
        routeMiles: 0)
}
