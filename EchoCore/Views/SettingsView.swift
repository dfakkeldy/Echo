// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeckImporter = false
    @State private var importAlert: (title: String, message: String)?

    #if DEBUG
        @State private var debugNarrationPlayer: AVAudioPlayer?
    #endif

    var body: some View {
        @Bindable var settings = settings
        @Bindable var model = model

        NavigationStack {
            Form {
                // Audit E1: one settings surface — the loaded book's overrides
                // live in a clearly-labeled section at the top.
                if model.folderURL != nil {
                    BookOverridesSections(
                        model: model,
                        headerTitle: bookOverridesHeader
                    )
                }

                Section("Display") {
                    NavigationLink("Appearance") {
                        SettingsAppearanceView()
                    }
                }

                Section("Store") {
                    NavigationLink("Pro Transcripts") {
                        ProTranscriptsSettingsView()
                    }
                }

                Section("Customization") {
                    NavigationLink("Phone Player Designer") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                }

                Section("Playback") {
                    Toggle("Volume Boost", isOn: $model.isVolumeBoostEnabled)
                    Picker("Default Speed", selection: $settings.defaultPlaybackSpeed) {
                        Text("1.0×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2.0×").tag(2.0)
                        Text("3.0×").tag(3.0)
                    }
                    Picker("Seek Backward", selection: $settings.seekBackwardDuration) {
                        ForEach(
                            [5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300], id: \.self
                        ) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    .onChange(of: settings.seekBackwardDuration) { _, _ in
                        model.syncToWatch()
                    }
                    Picker("Seek Forward", selection: $settings.seekForwardDuration) {
                        ForEach(
                            [5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300], id: \.self
                        ) { duration in
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

                // Audit E4: the "for testing" lookback slider is debug tooling
                // and must not ship in release builds.
                #if DEBUG
                    SettingsSilenceDetectionSection()
                #endif

                SettingsAutoAlignmentSection()

                SettingsBookmarksInlineSection()

                Section("Flashcards") {
                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }
                }

                #if DEBUG
                    Section {
                        Button("Load Development Assets") {
                            model.loadFolder(Bundle.main.bundleURL)
                            dismiss()
                        }
                        Button("🔊 Narrate Ch. 1 (Kokoro test)") {
                            Task {
                                do {
                                    guard let writer = model.databaseService?.writer,
                                        let audiobookID = model.folderURL?.absoluteString
                                    else { return }
                                    let player =
                                        try await NarrationService
                                        .testRenderAndPlayChapterOne(
                                            databaseWriter: writer, audiobookID: audiobookID)
                                    self.debugNarrationPlayer = player
                                } catch {
                                    Logger(category: "NarrationTest").error(
                                        "Narration test failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    } header: {
                        Text("Debug Menu")
                    } footer: {
                        Text("Loads audio files from Development Assets into the player.")
                    }
                #endif

                Section {
                    NavigationLink("Help") {
                        HelpView()
                            .navigationTitle("Help")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(
            \.font,
            settings.appFont == SettingsManager.systemFontName
                ? .body : .custom(settings.appFont, size: 17, relativeTo: .body)
        )
        .fileImporter(
            isPresented: $showingDeckImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .alert(importAlert?.title ?? "", isPresented: isShowingAlert) {
            Button("OK") { importAlert = nil }
        } message: {
            if let message = importAlert?.message {
                Text(message)
            }
        }
        .preferredColorScheme(colorScheme(for: settings.appAppearance))
        // Audit E2: resolved tint includes the artwork accent — the
        // static-only lookup nil'd it out and toggles fell back to green.
        .tint(model.resolvedThemeTint)
    }

    private var bookOverridesHeader: String {
        let title = model.currentTitle
        return title.isEmpty
            ? String(localized: "This Book — overrides global")
            : String(localized: "\(title) — overrides global")
    }

    // MARK: - Helpers

    private func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { importAlert != nil },
            set: { if !$0 { importAlert = nil } }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let db = model.databaseService else { return }
            let importer = DeckImportService()
            do {
                let count = try importer.importDeck(from: url, db: db.writer)
                importAlert = ("Import Complete", "Imported \(count) cards successfully.")
            } catch {
                importAlert = ("Import Failed", error.localizedDescription)
            }
        case .failure(let error):
            importAlert = ("Import Failed", error.localizedDescription)
        }
    }
}

private struct SettingsSilenceDetectionSection: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lookback Duration")
                    Spacer()
                    Text(String(format: "%.1fs", settings.silenceDetectionLookbackSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.silenceDetectionLookbackSeconds, in: 1...30, step: 0.5)
            }
        } header: {
            Text("Silence Detection")
        } footer: {
            Text(
                "How far back to scan for silence when locating playback position during reverse playback. For testing."
            )
        }
    }
}

private struct SettingsAutoAlignmentSection: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
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
    }
}

private struct SettingsBookmarksInlineSection: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
        } footer: {
            Text(
                "When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp."
            )
        }
    }
}
