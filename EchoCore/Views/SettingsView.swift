// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    private let buildMetadata = AppBuildMetadata()
    @State private var showingDeckImporter = false
    @State private var showingAllStudyNotesExport = false
    @State private var showingFeedback = false
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

                Section("Library Sources") {
                    NavigationLink("Connections") {
                        ABSConnectionsSettingsView()
                    }
                }

                Section("Customization") {
                    NavigationLink("Phone Player Designer") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                    NavigationLink("Pronunciation") {
                        PronunciationDictionaryView(store: .shared)
                    }
                    NavigationLink("Advanced") {
                        SettingsAdvancedView()
                    }
                }

                // Audit E4: the "for testing" lookback slider is debug tooling
                // and must not ship in release builds.
                #if DEBUG
                    SettingsSilenceDetectionSection()
                #endif

                Section("Flashcards") {
                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }
                }

                SettingsStudySection()

                Section("Data") {
                    Button {
                        showingAllStudyNotesExport = true
                    } label: {
                        Label("Export All Study Notes", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.databaseService == nil)
                }

                #if DEBUG
                    Section {
                        Button("Load Development Assets") {
                            model.loadFolder(Bundle.main.bundleURL)
                            dismiss()
                        }
                        Button("🔊 Narrate Ch. 1 (Kokoro test)") {
                            runNarrationTest()
                        }
                    } header: {
                        Text("Debug Menu")
                    } footer: {
                        Text(
                            "Loads audio files from Development Assets into the player and renders chapter 1 through the on-device ONNX narration engine."
                        )
                    }
                #endif

                Section("Support") {
                    NavigationLink("Feedback & Support") {
                        FeedbackSupportView()
                            .navigationTitle("Feedback & Support")
                    }
                    NavigationLink {
                        HelpView()
                            .navigationTitle("Help")
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }

                    Button {
                        showingFeedback = true
                    } label: {
                        Label("Send Feedback", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }

                BuildMetadataSection(buildMetadata: buildMetadata)
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
        .sheet(isPresented: $showingFeedback) {
            FeedbackFormView()
        }
        .sheet(isPresented: $showingAllStudyNotesExport) {
            if let writer = model.databaseService?.writer {
                AllStudyNotesExportView(databaseWriter: writer)
            }
        }
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
                let result = try importer.importDeckVNext(from: url, db: db.writer)
                importAlert = ("Import Complete", importCompletionMessage(for: result))
            } catch {
                importAlert = ("Import Failed", error.localizedDescription)
            }
        case .failure(let error):
            importAlert = ("Import Failed", error.localizedDescription)
        }
    }

    private func importCompletionMessage(for result: ImportDeckResult) -> String {
        if result.warningCount == 0 {
            return
                "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text."
        }
        return
            "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text. \(result.warningCount) warnings."
    }

    #if DEBUG
        private func runNarrationTest() {
            Task {
                do {
                    guard let writer = model.databaseService?.writer,
                        let audiobookID = model.folderURL?.absoluteString
                    else { return }
                    let player =
                        try await NarrationService.testRenderAndPlayChapterOne(
                            databaseWriter: writer, audiobookID: audiobookID)
                    self.debugNarrationPlayer = player
                } catch {
                    logNarrationTestFailure(error)
                }
            }
        }

        private func logNarrationTestFailure(_ error: Error) {
            let logger = Logger(category: "NarrationTest")
            logger.error("Narration test failed.")
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
    #endif
}

private struct SettingsStudySection: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section("Study") {
            Stepper(value: $settings.studyGlobalNewChapterLimit, in: 1...12) {
                LabeledContent("Global New Chapters") {
                    Text(limitText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var limitText: String {
        let limit = settings.studyGlobalNewChapterLimit
        let unit = limit == 1 ? "chapter" : "chapters"
        return "\(limit) \(unit) per day"
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

private struct BuildMetadataSection: View {
    let buildMetadata: AppBuildMetadata
    @State private var copiedCommit = false

    var body: some View {
        Section {
            LabeledContent("Version", value: buildMetadata.versionString)
            LabeledContent {
                HStack {
                    Text(buildMetadata.commitString)
                        .textSelection(.enabled)
                    Button("Copy", systemImage: copiedCommit ? "checkmark" : "doc.on.doc") {
                        copyCommitHash()
                    }
                    .disabled(buildMetadata.gitCommitHash == nil)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy commit hash")
                }
            } label: {
                Text("Commit")
            }
        } header: {
            Text("Build")
        } footer: {
            Text(
                "Use these details when comparing installs or reporting a bug. The commit hash is stamped into the app at build time."
            )
        }
    }

    private func copyCommitHash() {
        guard let gitCommitHash = buildMetadata.gitCommitHash else { return }

        #if canImport(UIKit)
            UIPasteboard.general.string = gitCommitHash
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(gitCommitHash, forType: .string)
        #endif

        copiedCommit = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedCommit = false
        }
    }
}
