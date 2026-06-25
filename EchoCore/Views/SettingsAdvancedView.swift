// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// App-level advanced preferences that have no per-listen player surface:
/// continuous auto-alignment and bookmark-inline playback. Both keep their
/// custom Binding setters so the model side-effects still fire.
struct SettingsAdvancedView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model
    @State private var contextMemoryStatus: String?

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
            }

            Section {
                Toggle(
                    "Context Memory",
                    isOn: Binding(
                        get: { settings.locationCaptureEnabled },
                        set: { isEnabled in
                            settings.locationCaptureEnabled = isEnabled
                            contextMemoryStatus =
                                isEnabled
                                ? "New bookmarks can receive approximate place names."
                                : "Location capture is off."
                        }
                    ))

                Button(role: .destructive, action: deleteContextMemory) {
                    Label("Delete Context Memory", systemImage: "trash")
                }
                .disabled(model.databaseService == nil)
            } header: {
                Text("Context Memory")
            } footer: {
                Text(
                    contextMemoryStatus
                        ?? "Off by default. When enabled, Echo stores approximate place names for new bookmarks. Delete removes saved bookmark places and session location history from this device."
                )
            }

            Section {
                Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
            } footer: {
                Text(
                    "When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp."
                )
            }
        }
        .navigationTitle("Advanced")
    }

    private func deleteContextMemory() {
        guard let writer = model.databaseService?.writer else {
            contextMemoryStatus = "Open the app database before deleting Context Memory."
            return
        }

        do {
            let summary = try ContextMemoryDAO(db: writer).deleteAll()
            let visibleBookmarkCount = model.bookmarkStore.clearLocationContext()
            let locationCapture = model.locationCapture
            Task { await locationCapture.flushCache() }
            let totalBookmarks = max(summary.bookmarkCount, visibleBookmarkCount)
            contextMemoryStatus =
                "Deleted place data from \(totalBookmarks) bookmark(s) and \(summary.sessionLocationCount) session location(s)."
        } catch {
            contextMemoryStatus = "Could not delete Context Memory: \(error.localizedDescription)"
        }
    }
}
