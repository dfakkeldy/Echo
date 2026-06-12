//
//  EchoCoreApp.swift
//  Echo
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import SwiftUI

@main
struct EchoCoreApp: App {
    @State private var model: PlayerModel
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
        
        let initialModel = PlayerModel()
        var initialError: Error? = nil
        
        do {
            let db = try DatabaseService()
            initialModel.databaseService = db
            #if os(iOS)
            MigrationService.migrateIfNeeded(database: db)
            #endif
        } catch {
            initialError = error
            // Attempt in-memory fallback so the app remains functional.
            // The error is presented to the user in the view hierarchy.
        }
        
        _model = State(wrappedValue: initialModel)
        _databaseError = State(wrappedValue: initialError)
        Self.playerModel = initialModel
        
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
                .tint(resolvedAccentColor)
                .accentColor(resolvedAccentColor)
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

    /// Resolves the active accent colour (audit E2): the single source of
    /// truth lives on PlayerModel so settings sheets resolve identically.
    /// When both the theme and artwork colour are unavailable, SwiftUI uses the
    /// system default (blue) automatically via `nil` coalescing in the modifier chain.
    private var resolvedAccentColor: Color? {
        model.resolvedThemeTint
    }

    private func handleDeepLink(_ url: URL) {
        pendingDeepLink = PlayerDeepLink(url: url)
    }
}
