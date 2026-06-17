// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

struct SettingsAppearanceView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                // "Color Scheme" — the screen title is already "Appearance"
                // (audit E3: same label twice reads as a bug).
                Picker("Color Scheme", selection: $settings.appAppearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            }
            #if os(iOS)
                Section("App Icon") {
                    NavigationLink {
                        AppIconSelectionView()
                    } label: {
                        HStack {
                            Text("App Icon")
                            Spacer()
                            Text(currentAppIconName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            #endif
            Section("Theme") {
                NavigationLink {
                    ThemeSelectionView()
                } label: {
                    HStack {
                        Text("Accent Color")
                        Spacer()
                        if let color = ThemeColor(rawValue: settings.themeColor)?.color {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color)
                        } else {
                            Text("System")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Typography") {
                NavigationLink {
                    FontSelectionView()
                } label: {
                    HStack {
                        Text("Font")
                        Spacer()
                        Text(
                            settings.appFont == SettingsManager.systemFontName
                                ? "System" : settings.appFont
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(
                    "Truncate Chapter to Ch.",
                    isOn: Binding(
                        get: { settings.truncateChapterNamesEnabled },
                        set: {
                            settings.truncateChapterNamesEnabled = $0
                            model.syncToWatch()
                        }
                    ))
            } header: {
                Text("Display Options")
            } footer: {
                Text(
                    "Shortens \u{201C}Chapter 12\u{201D} to \u{201C}Ch. 12\u{201D} in tight spaces, like the watch and mini-player."
                )
            }
        }
        .navigationTitle("Appearance")
    }

    #if os(iOS)
        private var currentAppIconName: String {
            guard let name = UIApplication.shared.alternateIconName else {
                return "Default"
            }
            switch name {
            case "AppIcon-ComplexWaves": return "Complex Waves"
            case "AppIcon-GoldSilver": return "Gold & Silver"
            case "AppIcon-SilverGold": return "Silver & Gold"
            case "AppIcon-WhiteBolder": return "White Bolder"
            default: return name
            }
        }
    #endif
}
