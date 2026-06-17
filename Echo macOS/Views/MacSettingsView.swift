// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacSettingsView.swift
//  Echo macOS
//
//  Native macOS Preferences window (⌘,). A standard TabView of app-level
//  panes that bind to the shared `SettingsManager` (the same instance injected
//  into the main window in Echo_macOSApp). Pane scope mirrors the iOS
//  app-level Settings (Appearance + Playback defaults). There is no Pro /
//  StoreKit concept on macOS, so the iOS "Pro Transcripts" pane is omitted.
//

import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacAppearanceSettingsPane()
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            MacPlaybackSettingsPane()
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

// MARK: - Appearance Pane

private struct MacAppearanceSettingsPane: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Color Scheme", selection: $settings.appAppearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)

                Picker("Font", selection: $settings.appFont) {
                    Text("Lexend (Default)").tag("Lexend")
                    Text("OpenDyslexic").tag("OpenDyslexic")
                    Text("System").tag(SettingsManager.systemFontName)
                }

                Picker("Theme Color", selection: $settings.themeColor) {
                    ForEach(ThemeColor.allCases) { theme in
                        themeRow(theme).tag(theme.rawValue)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(
                    "Color scheme and font apply across the macOS app window. Theme color tints accents; “Artwork” derives the accent from the current book cover."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func themeRow(_ theme: ThemeColor) -> some View {
        if let color = theme.color {
            Label {
                Text(theme.rawValue)
            } icon: {
                Circle().fill(color).frame(width: 12, height: 12)
            }
        } else {
            Text(theme.rawValue)
        }
    }
}

// MARK: - Playback Pane

private struct MacPlaybackSettingsPane: View {
    @Environment(SettingsManager.self) private var settings
    /// The live player model (the SAME instance injected into the main window —
    /// see `Echo_macOSApp`). Binding Volume Boost directly to it means toggling
    /// here re-applies the audio mix immediately while a book is playing, and
    /// its `didSet` still persists to the shared `global_volumeBoostEnabled`
    /// key (the one the iOS `PlayerModel` reads). Using `@AppStorage` instead
    /// only wrote UserDefaults — the running model reads that key once at init,
    /// so a mid-playback toggle never reached the audio path.
    @Environment(MacPlayerModel.self) private var player

    /// Single source of truth for skip-interval options (mirrors the iOS
    /// hardcoded array in SettingsView's Seek pickers).
    private let skipOptions = [5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]

    var body: some View {
        @Bindable var settings = settings
        @Bindable var player = player
        Form {
            Section {
                Picker("Default Speed", selection: $settings.defaultPlaybackSpeed) {
                    ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { preset in
                        Text(speedLabel(preset)).tag(Double(preset))
                    }
                }

                Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                    ForEach(skipOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }

                Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                    ForEach(skipOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }

                Toggle("Volume Boost", isOn: $player.isVolumeBoostEnabled)
            } header: {
                Text("Playback")
            } footer: {
                Text(
                    "These defaults apply to new playback sessions. Volume Boost amplifies quiet narration."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                // Empty `narrationVoiceID` means "use the catalog default"; map it
                // to the default's raw id so the Picker shows a concrete selection.
                Picker(
                    "Narration Voice",
                    selection: Binding(
                        get: {
                            settings.narrationVoiceID.isEmpty
                                ? VoiceCatalog.default.id.rawValue : settings.narrationVoiceID
                        },
                        set: { settings.narrationVoiceID = $0 })
                ) {
                    ForEach(VoiceCatalog.all) { voice in
                        Text(voice.displayName).tag(voice.id.rawValue)
                    }
                }
            } header: {
                Text("Narration")
            } footer: {
                Text(
                    "Echo synthesizes EPUBs that have no audiobook on-device, using the voice above. Queue them with Batch ▸ “Narrate EPUB(s)…” (⌘⌥N); progress appears in the Batch Queue."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func speedLabel(_ value: Float) -> String {
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }
}

#Preview {
    MacSettingsView()
        .environment(SettingsManager())
        .environment(MacPlayerModel())
}
