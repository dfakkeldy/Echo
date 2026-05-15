//
//  Orbit_AudioBooksApp.swift
//  Orbit Audiobooks
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import SwiftUI

@main
struct Orbit_AudioBooksApp: App {
    @State private var model = PlayerModel()
    @State private var settings = SettingsManager()
    @State private var storeManager = StoreManager()
    @State private var pendingDeepLink: PlayerDeepLink?

    init() {
        #if DEBUG && targetEnvironment(simulator)
        MockMediaProvider.seedSampleAudiobookIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pendingDeepLink: $pendingDeepLink)
                .environment(model)
                .environment(settings)
                .environment(storeManager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        pendingDeepLink = PlayerDeepLink(url: url)
    }
}
