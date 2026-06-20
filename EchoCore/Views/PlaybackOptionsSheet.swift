// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Live playback tuning surface, presented as a sheet from the speed indicator.
/// Edits the CURRENT playback session: speed, loop, seek durations, smart rewind,
/// and the global volume-boost flag. Distinct from `SettingsManager.defaultPlaybackSpeed`
/// (the Double "default for new books"); this sheet drives `model.speed` (Float) directly.
struct PlaybackOptionsSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Single source of truth for the discrete seek-duration choices, lifted from
    /// the two hardcoded copies in the old SettingsView Playback section.
    static let seekDurationOptions: [Int] = [
        5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300,
    ]

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Speed") {
                    Picker("Playback Speed", selection: speedSelection) {
                        ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { preset in
                            Text(speedLabel(preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Playback speed"))
                }

                Section("Loop") {
                    Picker("Loop Mode", selection: loopSelection) {
                        Text("Off").tag(LoopMode.off)
                        Text("Chapter").tag(LoopMode.chapter)
                        Text("Bookmark").tag(LoopMode.bookmark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Loop mode"))
                }

                Section("Skip") {
                    Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                        ForEach(Self.seekDurationOptions, id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    .onChange(of: settings.seekBackwardDuration) { _, _ in
                        model.syncToWatch()
                    }
                    Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                        ForEach(Self.seekDurationOptions, id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    .onChange(of: settings.seekForwardDuration) { _, _ in
                        model.syncToWatch()
                    }
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }

                Section(footer: Text(volumeBoostFooter)) {
                    Toggle("Volume Boost", isOn: volumeBoostBinding)
                }
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                // BookPlayer-style "More" → the full player-controls surface
                // (skip intervals, smart rewind, quick-action speeds, layout).
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhonePlayerSettingsView()
                    } label: {
                        Text("More")
                    }
                }
            }
        }
    }

    // MARK: - Speed

    /// Live binding to `model.speed` (Float). When the current speed isn't one of the
    /// presets we surface it as 1.0 so the segmented control always has a selection.
    private var speedSelection: Binding<Float> {
        Binding(
            get: {
                let presets = SettingsManager.Defaults.speedPresets
                return presets.contains(model.speed) ? model.speed : 1.0
            },
            set: { model.setSpeed($0) }
        )
    }

    private func speedLabel(_ speed: Float) -> String {
        switch speed {
        case 1.0: return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5: return String(localized: "1.5×")
        case 2.0: return String(localized: "2.0×")
        case 3.0: return String(localized: "3.0×")
        default: return speed.formatted(.number.precision(.fractionLength(2))) + "×"
        }
    }

    // MARK: - Loop

    /// Routes through `model.setLoopMode` and preserves the no-bookmarks demotion:
    /// selecting `.bookmark` with no bookmarks falls back to `.off`.
    private var loopSelection: Binding<LoopMode> {
        Binding(
            get: { model.loopMode },
            set: { newMode in
                if newMode == .bookmark && model.bookmarks.isEmpty {
                    model.setLoopMode(.off)
                } else {
                    model.setLoopMode(newMode)
                }
            }
        )
    }

    // MARK: - Volume Boost

    /// Edits the GLOBAL flag (`model.isVolumeBoostEnabled`). On/off only.
    private var volumeBoostBinding: Binding<Bool> {
        Binding(
            get: { model.isVolumeBoostEnabled },
            set: { model.isVolumeBoostEnabled = $0 }
        )
    }

    /// Reflects the RESOLVED value when a book is loaded.
    private var volumeBoostFooter: String {
        if model.folderURL != nil {
            return model.resolvedVolumeBoostEnabled
                ? String(localized: "Boost is on for this book.")
                : String(localized: "Boost is off for this book.")
        }
        return String(localized: "Raises quiet recordings. Applies to all books unless overridden.")
    }
}

// MARK: - Presenter environment seam

/// Lets deeply-nested transport controls (e.g. the configurable `.speed` slot)
/// request the Playback Options sheet without threading a closure through every
/// intermediate view. `NowPlayingTab` installs the real presenter.
private struct ShowPlaybackOptionsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showPlaybackOptions: () -> Void {
        get { self[ShowPlaybackOptionsKey.self] }
        set { self[ShowPlaybackOptionsKey.self] = newValue }
    }
}
