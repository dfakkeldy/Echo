// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// App-level advanced preferences that have no per-listen player surface:
/// continuous auto-alignment and bookmark-inline playback. Both keep their
/// custom Binding setters so the model side-effects still fire.
struct SettingsAdvancedView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

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
                Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
            } footer: {
                Text(
                    "When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp."
                )
            }
        }
        .navigationTitle("Advanced")
    }
}
