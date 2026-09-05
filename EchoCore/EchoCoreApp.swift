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
    @State private var storeManager: StoreManager
    @State private var freeTierGate: FreeTierGate!
    @State private var autoExport: AutoExportService?
    @State private var isOpeningDatabase = false
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
            MockMediaProvider.seedSampleMediaIfNeeded()
        #endif

        let initialSettings = SettingsManager()
        #if DEBUG && targetEnvironment(simulator)
            if MockMediaProvider.prefersDarkAppearance() {
                initialSettings.appAppearance = "Dark"
            }
        #endif

        let initialModel = PlayerModel()
        let initialStoreManager = StoreManager()
        initialModel.setSettingsManager(initialSettings)
        let initialFreeTierGate = FreeTierGate(entitlement: initialStoreManager)
        initialModel.setFreeTierGate(initialFreeTierGate)

        _model = State(wrappedValue: initialModel)
        _settings = State(wrappedValue: initialSettings)
        _storeManager = State(wrappedValue: initialStoreManager)
        _freeTierGate = State(wrappedValue: initialFreeTierGate)
        Self.playerModel = initialModel

        MetricKitDiagnosticsController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let autoExport {
                    RootTabView(pendingDeepLink: $pendingDeepLink)
                        .environment(model)
                        .environment(settings)
                        .environment(storeManager)
                        .environment(freeTierGate)
                        .environment(autoExport)
                } else {
                    ProgressView("Opening Library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task { await openDatabaseIfNeeded() }
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
                    Task { await openDatabaseIfNeeded() }
                }
                Button("Continue Offline", role: .cancel) {
                    do {
                        installDatabase(try DatabaseService(inMemory: ()))
                        databaseError = nil
                    } catch {
                        databaseError = error
                    }
                }
            } message: {
                Text(
                    databaseError?.localizedDescription ?? "An unknown database error occurred."
                )
            }
        }
    }

    private func openDatabaseIfNeeded() async {
        guard autoExport == nil, !isOpeningDatabase else { return }
        isOpeningDatabase = true
        defer { isOpeningDatabase = false }
        do {
            let database = try await DatabaseService.openForLaunch()
            installDatabase(database)
            databaseError = nil
        } catch is CancellationError {
            // A later appearance can resume startup after this task disappears.
        } catch {
            databaseError = error
        }
    }

    private func installDatabase(_ database: DatabaseService) {
        model.databaseService = database
        freeTierGate.wireCounts(
            flashcardCount: {
                (try? FlashcardDAO(db: database.writer).count()) ?? 0
            },
            narratedChapters: { audiobookID in
                let tracks = (try? TrackDAO(db: database.writer).tracks(for: audiobookID)) ?? []
                return NarrationEntitlementCounter.renderedChapterCount(in: tracks)
            }
        )
        let service = AutoExportService(
            database: database,
            isEnabled: { settings.studyAutoExportEnabled && storeManager.isPro })
        service.start()
        autoExport = service
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
