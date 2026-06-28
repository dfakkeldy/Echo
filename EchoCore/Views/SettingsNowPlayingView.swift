// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsNowPlayingView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Default Speed", selection: defaultSpeedSelection) {
                    ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { speed in
                        Text(speedLabel(Double(speed))).tag(Double(speed))
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Playback Defaults")
            } footer: {
                Text(
                    "Used for new books. Existing books keep the last speed you selected for that book."
                )
            }

            Section("Skip Durations") {
                Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                    ForEach(PlaybackOptionsSheet.seekDurationOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }
                .onChange(of: settings.seekBackwardDuration) { _, _ in
                    model.syncToWatch()
                }

                Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                    ForEach(PlaybackOptionsSheet.seekDurationOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }
                .onChange(of: settings.seekForwardDuration) { _, _ in
                    model.syncToWatch()
                }
            }

            Section {
                NavigationLink("Smart Rewind") {
                    SmartRewindSettingsView()
                }
            } footer: {
                Text("Automatically rewinds after pauses so you can regain context.")
            }

            Section {
                Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
            } footer: {
                Text(
                    "When enabled, voice memos attached to bookmarks play automatically when the audiobook reaches that timestamp."
                )
            }
        }
        .navigationTitle("Now Playing")
    }

    private var defaultSpeedSelection: Binding<Double> {
        Binding(
            get: { settings.defaultPlaybackSpeed },
            set: { settings.defaultPlaybackSpeed = $0 }
        )
    }

    private func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}
