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

                Section("Now Playing") {
                    NavigationLink("Playback Defaults") {
                        SettingsNowPlayingView()
                    }
                }

                Section("Appearance") {
                    NavigationLink("Appearance") {
                        SettingsAppearanceView()
                    }
                }

                Section("Controls") {
                    NavigationLink("Phone Player Settings") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                }

                Section("Library & Accounts") {
                    NavigationLink("Connections") {
                        ABSConnectionsSettingsView()
                    }
                    NavigationLink("Echo Pro") {
                        ProTranscriptsSettingsView()
                    }
                }

                Section("Study & Notes") {
                    NavigationLink("AI Card Generation") {
                        AICardGenerationSettingsView()
                            .navigationTitle("AI Card Generation")
                    }

                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }

                    SettingsStudyRows()

                    Button {
                        showingAllStudyNotesExport = true
                    } label: {
                        Label("Export All Study Notes", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.databaseService == nil)
                }

                Section("Advanced & Privacy") {
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

                SettingsSupportAboutSection(
                    buildMetadata: buildMetadata,
                    showingFeedback: $showingFeedback
                )
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

private struct SettingsStudyRows: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @State private var reviewReminderStatus: String?

    var body: some View {
        @Bindable var settings = settings

        Toggle(
            "Daily Review Reminder",
            isOn: Binding(
                get: { settings.reviewNotificationsEnabled },
                set: { isEnabled in setReviewNotificationsEnabled(isEnabled) }
            )
        )

        if let reviewReminderStatus {
            Text(reviewReminderStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Stepper(value: $settings.studyGlobalNewChapterLimit, in: 1...12) {
            LabeledContent("Global New Chapters") {
                Text(chapterLimitText)
                    .foregroundStyle(.secondary)
            }
        }

        Stepper(value: $settings.studyNewCardsPerDayLimit, in: 1...100) {
            LabeledContent("New AI Card Offer Cap") {
                Text(cardLimitText)
                    .foregroundStyle(.secondary)
            }
        }

        NavigationLink("Chapter Checkpoints") {
            CheckpointSettingsView()
        }
    }

    private var chapterLimitText: String {
        let limit = settings.studyGlobalNewChapterLimit
        let unit = limit == 1 ? "chapter" : "chapters"
        return "\(limit) \(unit) per day"
    }

    private var cardLimitText: String {
        let limit = settings.studyNewCardsPerDayLimit
        let unit = limit == 1 ? "card" : "cards"
        return "\(limit) \(unit) per build"
    }

    private func setReviewNotificationsEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            settings.reviewNotificationsEnabled = false
            ReviewNotificationService.removeScheduledNotification()
            reviewReminderStatus = "Daily review reminders are off."
            return
        }

        Task { @MainActor in
            let status = await ReviewNotificationService.requestAuthorization()
            guard status.canScheduleNotifications else {
                settings.reviewNotificationsEnabled = false
                ReviewNotificationService.removeScheduledNotification()
                reviewReminderStatus =
                    "Notifications are not allowed. Enable notifications for Echo in Settings."
                return
            }

            settings.reviewNotificationsEnabled = true
            reviewReminderStatus = "Daily review reminders are on."
            updateDailyReviewReminder()
        }
    }

    private func updateDailyReviewReminder() {
        guard let db = model.databaseService else {
            ReviewNotificationService.updateNotification(dueCount: 0, isEnabled: true)
            return
        }

        do {
            let queue = try StudyQueueBuilder(db: db.writer).build(
                globalNewChapterLimit: settings.studyGlobalNewChapterLimit,
                globalNewCardLimit: settings.studyNewCardsPerDayLimit
            )
            ReviewNotificationService.updateNotification(
                dueCount: queue.dueReviewCount + queue.inProgressAssignmentCount,
                isEnabled: settings.reviewNotificationsEnabled
            )
        } catch {
            ReviewNotificationService.updateNotification(dueCount: 0, isEnabled: true)
        }
    }
}

private struct CheckpointSettingsView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("When the timer runs out", selection: $settings.checkpointTimeoutBehavior) {
                    Text("Replay the chapter")
                        .tag(CheckpointTimeoutBehavior.replay.rawValue)
                    Text("Grade Again and move on")
                        .tag(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue)
                    Text("Wait - no grade, re-queue today")
                        .tag(CheckpointTimeoutBehavior.wait.rawValue)
                }

                if settings.checkpointTimeoutBehavior != CheckpointTimeoutBehavior.wait.rawValue {
                    Picker("Checkpoint timeout", selection: $settings.checkpointTimeoutSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                }

                Toggle("Auto-advance after Good", isOn: $settings.checkpointAutoAdvance)
                Toggle("Lock-screen button grading", isOn: $settings.checkpointRemoteGrading)
            } header: {
                Text("Chapter Checkpoints")
            } footer: {
                Text(
                    "When a due study chapter finishes playing, Echo pauses and asks for a retention grade. While the window is open, lock-screen skip-forward means Good and skip-back means Again. Checkpoints only exist for books with an active study plan; pause the plan to silence them."
                )
            }
        }
        .navigationTitle("Chapter Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
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

private struct SettingsSupportAboutSection: View {
    let buildMetadata: AppBuildMetadata
    @Binding var showingFeedback: Bool
    @State private var copiedCommit = false

    var body: some View {
        Section {
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
            Link(destination: FeedbackSupport.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }

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
            Text("Support & About")
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
