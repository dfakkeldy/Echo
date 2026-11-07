// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// App-level advanced preferences that have no per-listen player surface.
/// Continuous auto-alignment keeps its custom Binding setter so the model
/// side-effect still fires.
struct SettingsAdvancedView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model
    @State private var contextMemoryStatus: String?
    @State private var deleteStatus: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(
                    "Continuous Auto-Alignment",
                    isOn: Binding(
                        get: { settings.continuousAutoAlignmentEnabled },
                        set: {
                            settings.continuousAutoAlignmentEnabled = $0
                            model.configureContinuousAlignment()
                        }
                    ))
            } header: {
                Text("Auto-Alignment")
            } footer: {
                Text(
                    "When enabled, the app will continuously transcribe audio in the background while playing and attempt to align it with the text."
                )
                .settingsFooterStyle()
            }

            Section {
                Toggle(
                    "Context Memory",
                    isOn: Binding(
                        get: { settings.locationCaptureEnabled },
                        set: { isEnabled in setLocationCaptureEnabled(isEnabled) }
                    ))
            } footer: {
                Text(
                    contextMemoryStatus
                        ?? "Off by default. When on, Echo stores approximate place names for new bookmarks."
                )
                .settingsFooterStyle()
            }

            // The delete sits in its own group, apart from the toggle, so
            // a destructive action is never one row below a switch. Its
            // footer carries the result of the last action.
            Section {
                // Icon and text share one destructive red; the delete is
                // confirmed first because it cannot be undone.
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Context Memory", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .disabled(model.databaseService == nil)
                .confirmationDialog(
                    "Delete Context Memory?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: deleteContextMemory)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes saved bookmark places and session location history from this device. This cannot be undone.")
                }
            } footer: {
                Text(
                    deleteStatus
                        ?? "Removes saved bookmark places and session location history from this device."
                )
                .settingsFooterStyle()
            }

            Section {
                Toggle("Verbose Diagnostic Logging", isOn: $settings.debugLoggingEnabled)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Records extra detail to help fix bugs. Never includes book text.")
                    .settingsFooterStyle()
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteContextMemory() {
        guard let writer = model.databaseService?.writer else {
            deleteStatus = "Open the app database before deleting Context Memory."
            return
        }

        do {
            let summary = try ContextMemoryDAO(db: writer).deleteAll()
            let visibleBookmarkCount = model.bookmarkStore.clearLocationContext()
            let locationCapture = model.locationCapture
            Task { await locationCapture.flushCache() }
            let totalBookmarks = max(summary.bookmarkCount, visibleBookmarkCount)
            deleteStatus =
                "Deleted place data from \(totalBookmarks) bookmark(s) and \(summary.sessionLocationCount) session location(s)."
        } catch {
            deleteStatus = "Could not delete Context Memory: \(error.localizedDescription)"
        }
    }

    private func setLocationCaptureEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            settings.locationCaptureEnabled = false
            contextMemoryStatus = "Location capture is off."
            return
        }

        #if os(iOS)
            switch LocationCaptureAuthorizationService.status() {
            case .authorized:
                settings.locationCaptureEnabled = true
                contextMemoryStatus = "New bookmarks can receive approximate place names."
            case .notDetermined:
                Task { @MainActor in
                    let status = await LocationCaptureAuthorizationService.requestAuthorization()
                    settings.locationCaptureEnabled = status.canCaptureLocation
                    contextMemoryStatus =
                        status.canCaptureLocation
                        ? "New bookmarks can receive approximate place names."
                        : "Location access is required for Context Memory."
                }
            case .denied, .restricted:
                settings.locationCaptureEnabled = false
                contextMemoryStatus =
                    "Location access is denied. Enable location access for Echo in Settings."
            case .unknown:
                settings.locationCaptureEnabled = false
                contextMemoryStatus = "Location access is unavailable."
            }
        #else
            settings.locationCaptureEnabled = false
            contextMemoryStatus = "Location capture is unavailable on this platform."
        #endif
    }
}
