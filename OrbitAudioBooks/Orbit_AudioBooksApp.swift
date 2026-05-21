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

    /// Static reference for CarPlay scene delegate and other non-SwiftUI contexts
    /// that need access to the shared PlayerModel instance.
    static weak var playerModel: PlayerModel?

    init() {
        #if DEBUG && targetEnvironment(simulator)
        MockMediaProvider.seedSampleAudiobookIfNeeded()
        #endif
        do {
            let db = try DatabaseService()
            model.databaseService = db
            #if os(iOS)
            MigrationService.migrateIfNeeded(database: db)
            #endif
        } catch {
            fatalError("DatabaseService initialization failed: \(error)")
        }
        Self.playerModel = model
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(pendingDeepLink: $pendingDeepLink)
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
