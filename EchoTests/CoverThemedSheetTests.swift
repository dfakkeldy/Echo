// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Echo

/// Guards the two halves of the player-sheet wash.
///
/// 1. `ChapterPickerSheet` gained an `@Environment(PlayerModel.self)`
///    dependency to read the cover theme. A non-optional `@Environment`
///    that no host injects traps on first appearance (J-Space device QA
///    2026-07-17, issue 1), so the sheet is rendered in a live window here
///    rather than discovered on device.
/// 2. The wash must sit INSIDE the `NavigationStack` — a stack paints an
///    opaque systemBackground over anything behind it, which is what left the
///    player looking untinted before PR #420. `CoverThemedSheet` owns the
///    stack so call sites cannot get the layering wrong; these checks fail if
///    a future edit hands the stack back to the call site.
@MainActor
@Suite struct CoverThemedSheetTests {

    @Test func chapterPickerSheetRendersInMinimalHost() async throws {
        let model = PlayerModel()
        let suiteName = "CoverThemedSheetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)

        await renderInLiveWindow(
            ChapterPickerSheet(chapters: Self.chapters, onSelect: { _ in })
                .environment(model)
                .environment(settings))
    }

    @Test func washDefeatsBothOpaqueLayersOfASheet() throws {
        let scaffold = try Self.source("EchoCore/Views/Components/CoverThemedSheet.swift")

        // Layer 1 — the navigation stack's own systemBackground. The ramp has
        // to be a sibling INSIDE the stack; behind it, it is invisible (#420).
        let stack = try #require(scaffold.range(of: "NavigationStack {"))
        let layered = try #require(scaffold.range(of: "ZStack {"))
        #expect(
            stack.lowerBound < layered.lowerBound,
            "the ramp must be layered inside the stack, never behind it")
        #expect(scaffold.contains(".scrollContentBackground(.hidden)"))
        #expect(scaffold.contains(".toolbarBackground(.hidden, for: .navigationBar)"))

        // Layer 2 — the sheet's presentation backdrop. With only layer 1 in
        // place the sheet still measured #1C1C1E (systemBackground exactly) on
        // the simulator, so both are required.
        #expect(scaffold.contains(".presentationBackground { ramp }"))
    }

    @Test func playerSheetsGoThroughTheScaffold() throws {
        for path in [
            "EchoCore/Views/BookSettingsView.swift",
            "EchoCore/Views/ChapterPickerSheet.swift",
        ] {
            let source = try Self.source(path)
            #expect(
                source.contains("CoverThemedSheet(theme: model.coverTheme)"),
                "\(path) should take its wash from the scaffold")
            #expect(
                !source.contains("NavigationStack {"),
                "\(path) must not own a bare stack — it would paint over the wash")
        }
    }

    // MARK: - Helpers

    private static let chapters = [
        Chapter(index: 0, title: "Opening", startSeconds: 0, endSeconds: 3725),
        Chapter(index: 1, title: "The Long Middle", startSeconds: 3725, endSeconds: 7200),
    ]

    /// Hosts `view` in a key window, forces layout, then suspends so the main
    /// run loop drains the first render pass and its `.onAppear`/`.task`
    /// closures — the exact place a missing environment dependency traps.
    private func renderInLiveWindow(_ view: some View) async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
