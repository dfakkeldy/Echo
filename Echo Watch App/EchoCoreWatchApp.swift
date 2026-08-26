// SPDX-License-Identifier: GPL-3.0-or-later
//
//  EchoCoreWatchApp.swift
//  Echo Watch App
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import SwiftUI

@main
struct Echo_WatchApp: App {
    // Owned at App level (not ContentView) so the view model — and the
    // WCSession it activates — exists during background launches, where no
    // window content is ever built.
    @State private var viewModel = WatchViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        // The system delivers phone-side pushes (application context, queued
        // userInfo) to a suspended watch app only through this background
        // task. Without it, synced state lands exclusively while the UI is
        // foreground, so the app-group snapshot — and the Smart Stack widget
        // reading it — froze at the last foreground moment.
        .backgroundTask(.watchConnectivity) { @MainActor in
            await viewModel.drainBackgroundConnectivity()
        }
    }
}
