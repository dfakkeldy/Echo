// SPDX-License-Identifier: GPL-3.0-or-later
//
//  EchoCoreApp.swift
//  Echo
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import GRDB
import SwiftUI

@main
struct EchoCoreApp: App {
    @State private var model: PlayerModel
    @State private var settings: SettingsManager
    @State private var storeManager = StoreManager()
    @State private var freeTierGate: FreeTierGate!
    @State private var pendingDeepLink: PlayerDeepLink?
    @State private var databaseError: Error?

    /// Shared `PlayerModel` reference for non-SwiftUI contexts. `CarPlaySceneDelegate`
    /// is instantiated by UIKit from Info.plist, so it lives outside the SwiftUI
    /// environment and cannot receive `PlayerModel` via injection; `CarPlayManager`'s
    /// library/chapters/bookmarks refreshes read it here (3 sites).
    ///
    /// REFACTOR-TODO (audit §3.7): replace this static with a `@MainActor` registry
    /// keyed by scene identifier. Kept as a deliberate backdoor for now — the capture
    /// buttons already push the other way via `NotificationCenter`.
    @MainActor static weak var playerModel: PlayerModel?

    init() {
        #if DEBUG && targetEnvironment(simulator)
            MockMediaProvider.seedSampleAudiobookIfNeeded()
        #endif

        let initialSettings = SettingsManager()
        let initialModel = PlayerModel()
        let initialStoreManager = StoreManager()
        initialModel.setSettingsManager(initialSettings)
        var initialError: Error? = nil

        do {
            let db = try DatabaseService()
            initialModel.databaseService = db
        } catch {
            initialError = error
            // Attempt in-memory fallback so the app remains functional.
            // The error is presented to the user in the view hierarchy.
        }

        let initialFreeTierGate = FreeTierGate(entitlement: initialStoreManager)
        initialModel.setFreeTierGate(initialFreeTierGate)

        _model = State(wrappedValue: initialModel)
        _settings = State(wrappedValue: initialSettings)
        _storeManager = State(wrappedValue: initialStoreManager)
        _databaseError = State(wrappedValue: initialError)
        _freeTierGate = State(wrappedValue: initialFreeTierGate)
        Self.playerModel = initialModel

        // Wire the live DB counts into the free-tier gate so cap enforcement
        // reflects real user data after database init.
        if let db = initialModel.databaseService {
            initialFreeTierGate.wireCounts(
                flashcardCount: {
                    (try? FlashcardDAO(db: db.writer).count()) ?? 0
                },
                narratedChapters: { audiobookID in
                    let tracks = (try? TrackDAO(db: db.writer).tracks(for: audiobookID)) ?? []
                    return NarrationEntitlementCounter.renderedChapterCount(in: tracks)
                }
            )
        }

        MetricKitDiagnosticsController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(pendingDeepLink: $pendingDeepLink)
                .environment(model)
                .environment(settings)
                .environment(storeManager)
                .environment(freeTierGate)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .tint(resolvedAccentColor)
                .accentColor(resolvedAccentColor)
                .alert(
                    "Database Error",
                    isPresented: Binding(
                        get: { databaseError != nil },
                        set: { if !$0 { databaseError = nil } }
                    )
                ) {
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
                    Text(
                        databaseError?.localizedDescription ?? "An unknown database error occurred."
                    )
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
