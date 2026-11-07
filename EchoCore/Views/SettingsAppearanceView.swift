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
                    Text("Cover").tag("Cover")
                }
                // The App Icon row joins this group: a one-row section headed
                // "App Icon" just repeated its row.
                #if os(iOS)
                    NavigationLink {
                        AppIconSelectionView()
                    } label: {
                        LabeledContent("App Icon", value: currentAppIconName)
                    }
                #endif
            } footer: {
                Text(colorSchemeFooter)
                    .settingsFooterStyle()
            }
            Section {
                NavigationLink {
                    ThemeSelectionView()
                } label: {
                    let selectedTheme =
                        ThemeColor(rawValue: settings.themeColor) ?? .artwork
                    HStack {
                        Text("Accent Color")
                        Spacer()
                        if let color = summarySwatchColor(for: selectedTheme) {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color)
                        }
                        Text(selectedTheme.settingsSummaryTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    "Vivid Cover Accent",
                    isOn: Binding(
                        get: { settings.vividCoverAccent },
                        set: {
                            settings.vividCoverAccent = $0
                            model.syncToWatch()
                        }
                    ))
            } header: {
                Text("Theme")
            } footer: {
                Text(
                    "Vivid Cover Accent picks the cover's brightest color, even a small one. Off blends the cover's colors."
                )
                .settingsFooterStyle()
            }
            // Text settings in one group; no "Typography" header over two
            // rows that already say Font and Reader Defaults.
            Section {
                NavigationLink {
                    FontSelectionView()
                } label: {
                    LabeledContent(
                        "Font",
                        value: settings.appFont == SettingsManager.systemFontName
                            ? String(localized: "System") : settings.appFont
                    )
                }
                NavigationLink {
                    ReaderDefaultsSettingsView()
                } label: {
                    LabeledContent("Reader Defaults", value: "\(Int(settings.readerFontSize)) pt")
                }
                Toggle(
                    "Short chapter names",
                    isOn: Binding(
                        get: { settings.truncateChapterNamesEnabled },
                        set: {
                            settings.truncateChapterNamesEnabled = $0
                            model.syncToWatch()
                        }
                    ))
            } footer: {
                Text(
                    "Short chapter names shows \u{201C}Ch. 12\u{201D} instead of \u{201C}Chapter 12\u{201D} on the watch and mini-player."
                )
                .settingsFooterStyle()
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Names the selected option first, so the footer reads as a
    /// description of the current choice, not a list of all four.
    private var colorSchemeFooter: String {
        switch settings.appAppearance {
        case "Light":
            String(localized: "Light: Echo stays light, whatever the system setting.")
        case "Dark":
            String(localized: "Dark: Echo stays dark, whatever the system setting.")
        case "Cover":
            String(
                localized:
                    "Cover: light for pale covers, dark for deep ones. Books with no preference follow the system."
            )
        default:
            String(localized: "System: Echo matches your device's light or dark setting.")
        }
    }

    private func summarySwatchColor(for theme: ThemeColor) -> Color? {
        switch theme {
        case .artwork:
            return model.resolvedTint(for: .artwork)
        case .system:
            return nil
        default:
            return theme.color
        }
    }

    #if os(iOS)
        private var currentAppIconName: String {
            guard let name = UIApplication.shared.alternateIconName else {
                return "Default"
            }
            switch name {
            case "AppIcon-CircuitBrain": return "Circuit Brain"
            case "AppIcon-ComplexWaves": return "Complex Waves"
            case "AppIcon-GoldSilver": return "Gold & Silver"
            case "AppIcon-SilverGold": return "Silver & Gold"
            case "AppIcon-WhiteBolder": return "White Bolder"
            default: return name
            }
        }
    #endif
}
