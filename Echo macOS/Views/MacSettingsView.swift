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

import AppKit
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

            AICardGenerationSettingsView()
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            MacSupportSettingsPane()
                .tabItem {
                    Label("Support", systemImage: "questionmark.circle")
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
                    "Color scheme and font apply across the macOS app window. Theme color tints accents throughout the app."
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

    /// Output-boost amounts in dB offered when Volume Boost is on (matches the
    /// iOS Volume Boost picker).
    private let boostGainOptions: [Float] = [3, 6, 9, 12, 15]

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

                if player.isVolumeBoostEnabled {
                    Picker(
                        "Boost Amount",
                        selection: Binding(
                            // Persist to settings AND push to the live player so the
                            // change takes effect mid-playback — the player otherwise
                            // reads settings.volumeBoostGain only at injection time.
                            get: { settings.volumeBoostGain },
                            set: { newGain in
                                settings.volumeBoostGain = newGain
                                player.volumeBoostGain = newGain
                            })
                    ) {
                        ForEach(boostGainOptions, id: \.self) { db in
                            Text("+\(Int(db)) dB").tag(db)
                        }
                    }
                }
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
                Toggle("Smart Rewind", isOn: $settings.isRewindEnabled)

                if settings.isRewindEnabled {
                    Stepper(value: $settings.rewindPauseSecondsThreshold, in: 5...300, step: 5) {
                        Text("Short pause after \(settings.rewindPauseSecondsThreshold)s")
                    }
                    Stepper(value: $settings.rewindAmountAfterSeconds, in: 5...180, step: 5) {
                        Text("…then rewind \(settings.rewindAmountAfterSeconds)s")
                    }
                    Stepper(value: $settings.rewindPauseMinutesThreshold, in: 1...120, step: 1) {
                        Text("Medium pause after \(settings.rewindPauseMinutesThreshold) min")
                    }
                    Stepper(value: $settings.rewindAmountAfterMinutes, in: 10...600, step: 5) {
                        Text("…then rewind \(settings.rewindAmountAfterMinutes)s")
                    }
                    Stepper(value: $settings.rewindPauseHoursThreshold, in: 1...24, step: 1) {
                        Text("Long pause after \(settings.rewindPauseHoursThreshold)h")
                    }
                    Toggle("…then jump to chapter start", isOn: $settings.rewindHoursToChapterStart)
                    if !settings.rewindHoursToChapterStart {
                        Stepper(value: $settings.rewindAmountAfterHours, in: 15...3600, step: 15) {
                            Text("…then rewind \(settings.rewindAmountAfterHours)s")
                        }
                    }
                }
            } header: {
                Text("Smart Rewind")
            } footer: {
                Text(smartRewindFooter)
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
                    ForEach(VoiceCatalog.sections) { section in
                        Section(section.title) {
                            ForEach(section.voices) { voice in
                                Text(voice.displayName).tag(voice.id.rawValue)
                            }
                        }
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

    /// Explains Smart Rewind with a worked example from the current thresholds
    /// (teach-by-example, mirroring the iOS settings footer). Thresholds default
    /// to the shared values; the gate toggle above drives whether playback rewinds.
    private var smartRewindFooter: String {
        let policy = SmartRewindPolicy(
            secondsThreshold: settings.rewindPauseSecondsThreshold,
            secondsAmount: settings.rewindAmountAfterSeconds,
            minutesThreshold: settings.rewindPauseMinutesThreshold,
            minutesAmount: settings.rewindAmountAfterMinutes,
            hoursThreshold: settings.rewindPauseHoursThreshold,
            hoursAmount: settings.rewindAmountAfterHours)
        return
            "On resume after a pause, Echo rewinds a few seconds so you can re-orient. "
            + "Example — \(policy.exampleText(forPausedMinutes: 10))."
    }
}

// MARK: - Support Pane

private struct MacSupportSettingsPane: View {
    private let buildMetadata = AppBuildMetadata()

    var body: some View {
        Form {
            Section {
                Link(destination: FeedbackSupport.emailURL(buildMetadata: buildMetadata)) {
                    Label("Email Support", systemImage: "envelope")
                }

                Link(destination: FeedbackSupport.githubIssuesURL) {
                    Label("Open GitHub Issues", systemImage: "ladybug")
                }

                Link(destination: FeedbackSupport.manualURL) {
                    Label("Open Manual", systemImage: "book")
                }
            } header: {
                Text("Feedback & Support")
            } footer: {
                Text(
                    "Email opens with Echo's version and commit already filled in. No logs, book paths, or listening data are attached."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: buildMetadata.versionString)
                LabeledContent("Commit") {
                    HStack(spacing: 8) {
                        Text(buildMetadata.commitString)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                buildMetadata.commitString, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy commit hash")
                    }
                }
            } header: {
                Text("About")
            } footer: {
                Text(
                    "Use these details when comparing installs or reporting a bug. The commit hash is stamped in at build time."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    MacSettingsView()
        .environment(SettingsManager())
        .environment(MacPlayerModel())
}
