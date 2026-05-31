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
    @State private var databaseError: Error?

    /// Static reference for CarPlay scene delegate and other non-SwiftUI contexts
    /// that need access to the shared PlayerModel instance.
    ///
    /// REFACTOR-TODO (§3.13): This is a backdoor for CarPlaySceneDelegate (line 35).
    /// CarPlay should receive PlayerModel via dependency injection rather than a
    /// static weak singleton. A shared container service (e.g. a registry keyed by
    /// scene identifier) would eliminate the global and avoid concurrency ordering
    /// hazards without changing the CarPlay code paths.
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
            databaseError = error
            // Attempt in-memory fallback so the app remains functional.
            // The error is presented to the user in the view hierarchy.
        }
        Self.playerModel = model
        ReviewNotificationService.requestAuthorization()
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
                .tint(ThemeColor(rawValue: settings.themeColor)?.color)
                .accentColor(ThemeColor(rawValue: settings.themeColor)?.color)
                .alert("Database Error", isPresented: Binding(
                    get: { databaseError != nil },
                    set: { if !$0 { databaseError = nil } }
                )) {
                    Button("Retry") {
                        do {
                            let db = try DatabaseService()
                            model.databaseService = db
                            databaseError = nil
                        } catch {
                            databaseError = error
                        }
                    }
                    Button("Continue Offline", role: .cancel) {
                        databaseError = nil
                    }
                } message: {
                    Text(databaseError?.localizedDescription ?? "An unknown database error occurred.")
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        pendingDeepLink = PlayerDeepLink(url: url)
    }
}
