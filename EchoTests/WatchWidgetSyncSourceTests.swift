// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// Wiring guards for the watch-side sync fixes. `make test` (iPhone scheme)
/// cannot compile the watchOS app or widget targets, so — like
/// `WatchWidgetPresentationSourceTests` — the cross-target wiring is pinned
/// by source scan while the policy logic itself is unit-tested in
/// `WatchWidgetProgressProjectionTests` / `WidgetPlaybackToggleRequestTests`.
struct WatchWidgetSyncSourceTests {

    // MARK: Background delivery

    @Test("the watch app registers for background WatchConnectivity wakes")
    func appRegistersBackgroundTask() {
        let source = Self.sourceIfPresent(at: "Echo Watch App/EchoCoreWatchApp.swift")

        // Without this scene modifier, phone pushes only land while the watch
        // app is foreground — the app-group snapshot (and the Smart Stack
        // widget reading it) freezes the moment the app sleeps.
        #expect(source.contains(".backgroundTask(.watchConnectivity)"))
        #expect(source.contains("drainBackgroundConnectivity()"))
        // The view model must be owned by the App: a background launch never
        // builds ContentView, so view-owned state would leave WCSession
        // without a delegate during the wake.
        #expect(source.contains("@State private var viewModel = WatchViewModel()"))
    }

    @Test("ContentView no longer owns the view model")
    func contentViewReceivesViewModel() {
        let source = Self.sourceIfPresent(at: "Echo Watch App/Views/ContentView.swift")
        #expect(source.contains("let viewModel: WatchViewModel"))
        #expect(!source.contains("@State private var viewModel = WatchViewModel()"))
    }

    @Test("the background drain waits out pending deliveries before applying")
    func drainWaitsForPendingContent() {
        let source = Self.sourceIfPresent(at: "Echo Watch App/Services/WatchViewModel.swift")
        #expect(source.contains("func drainBackgroundConnectivity() async"))
        #expect(source.contains("hasContentPending"))
    }

    // MARK: Progress projection

    @Test("applying authoritative state re-anchors the widget projection")
    func applyStateWritesAnchor() {
        let source = Self.sourceIfPresent(at: "Echo Watch App/Services/WatchViewModel.swift")
        #expect(source.contains("forKey: \"totalProgressFraction\")"))
        #expect(source.contains("WatchWidgetProgressProjection.writeAnchor("))
    }

    @Test("the widget provider schedules projected entries, not one static one")
    func providerProjectsTimeline() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")
        #expect(source.contains("WatchWidgetProgressProjection.read(from:"))
        #expect(source.contains("timelineDates(startingAt:"))
        #expect(source.contains("projection.fraction(at: date)"))
        // Playing timelines re-run when their projected entries run out;
        // a fixed 60 s .after ask was over WidgetKit's refresh budget.
        #expect(source.contains(".atEnd"))
    }

    // MARK: Play/pause handshake

    @Test("the toggle intent records a request instead of only flipping the flag")
    func intentWritesHandshake() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Models/AppIntent.swift")
        #expect(source.contains("WidgetPlaybackToggleRequest.write("))
        // Starting the projection from a stale anchor on the optimistic
        // paused→playing flip would jump the bar forward.
        #expect(source.contains("WatchWidgetProgressProjection.writeAnchor("))
    }

    @Test("the watch app consumes the request and sends an absolute command")
    func viewModelConsumesHandshake() {
        let source = Self.sourceIfPresent(at: "Echo Watch App/Services/WatchViewModel.swift")
        #expect(source.contains("WidgetPlaybackToggleRequest.consume(from:"))
        #expect(source.contains("consumePendingWidgetToggle()"))
        #expect(source.contains("sendCommand(desired ? \"play\" : \"pause\")"))
    }

    static func sourceIfPresent(at relativePath: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return
            (try? String(
                contentsOf: repositoryRoot.appending(path: relativePath),
                encoding: .utf8
            )) ?? ""
    }
}
