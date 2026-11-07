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
    /// Debug-menu mirror of the reader's alignment-timestamp overlay toggle.
    @State private var showAlignmentTimestamps = UserDefaults.standard.bool(
        forKey: "reader.showAlignmentTimestamps")

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

                // No header: a one-row group named after its only row
                // just says the same word twice.
                Section {
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
                            .navigationBarTitleDisplayMode(.inline)
                    }

                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }

                    SettingsStudyRows()

                    AutoExportSettingsRows()

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
                // and must not ship in release builds. Screenshot runs hide it
                // too, so design-review captures show what users see.
                #if DEBUG
                    if !MockMediaProvider.isScreenshotRun {
                        SettingsSilenceDetectionSection()
                    }
                #endif

                #if DEBUG
                    if !MockMediaProvider.isScreenshotRun {
                        Section {
                            Button("Load Development Assets") {
                                model.loadFolder(Bundle.main.bundleURL)
                                dismiss()
                            }
                            Button("🔊 Narrate Ch. 1 (Kokoro test)") {
                                runNarrationTest()
                            }
                            // Alignment QA aid: per-block timestamps in the reader
                            // (red = locked anchor, grey = interpolated). Off by
                            // default so the overlay never collides with body text
                            // during normal reading; ReaderFeedCollectionView reads
                            // the same key.
                            Toggle(
                                "Show Alignment Timestamps",
                                isOn: $showAlignmentTimestamps
                            )
                            .onChange(of: showAlignmentTimestamps) { _, newValue in
                                UserDefaults.standard.set(
                                    newValue, forKey: "reader.showAlignmentTimestamps")
                            }
                        } header: {
                            Text("Debug Menu")
                        } footer: {
                            Text(
                                "Loads audio files from Development Assets into the player and renders chapter 1 through the on-device ONNX narration engine."
                            )
                        }
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
            allowedContentTypes: [.folder, .json],
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
        // Display title, never the raw folder slug (audit 2026-07:
        // "system-that-does-the-reviewing — overrides global").
        let title = model.bookDisplayTitle
        return title.isEmpty
            ? String(localized: "This Book — overrides global")
            : String(localized: "\(title) — overrides global")
    }

    // MARK: - Helpers

    private func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "Light": return .light
        case "Dark": return .dark
        case "Cover": return model.coverPreferredScheme
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
                        let audiobookID = model.bookIdentityURL?.absoluteString
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

        // Short label, value trailing, one line each (Global New Chapters
        // used to wrap). The footnote below names the limit, so a disabled
        // "+" at the top of the range is not a silent dead end.
        Stepper(value: $settings.studyGlobalNewChapterLimit, in: Self.chapterLimitRange) {
            LabeledContent("New chapters per day") {
                Text("\(settings.studyGlobalNewChapterLimit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        if settings.studyGlobalNewChapterLimit >= Self.chapterLimitRange.upperBound {
            Text("12 new chapters a day is the most Echo schedules.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Stepper(value: $settings.studyNewCardsPerDayLimit, in: Self.cardLimitRange) {
            LabeledContent("New AI cards per build") {
                Text("\(settings.studyNewCardsPerDayLimit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        if settings.studyNewCardsPerDayLimit >= Self.cardLimitRange.upperBound {
            Text("100 new cards per build is the most Echo offers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        NavigationLink("Chapter Checkpoints") {
            CheckpointSettingsView()
        }
    }

    private static let chapterLimitRange = 1...12
    private static let cardLimitRange = 1...100

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
            // No header: the page title already says "Chapter Checkpoints".
            // The explanation comes first, then each control with its own
            // one-line footer.
            Section {
                // Menu style keeps the value trailing on the label's line,
                // like "Checkpoint timeout" below.
                Picker("When the timer runs out", selection: $settings.checkpointTimeoutBehavior) {
                    Text("Replay chapter")
                        .tag(CheckpointTimeoutBehavior.replay.rawValue)
                    Text("Move on")
                        .tag(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue)
                    Text("Wait")
                        .tag(CheckpointTimeoutBehavior.wait.rawValue)
                }
                .pickerStyle(.menu)

                if settings.checkpointTimeoutBehavior != CheckpointTimeoutBehavior.wait.rawValue {
                    Picker("Checkpoint timeout", selection: $settings.checkpointTimeoutSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text(
                    "When a due study chapter ends, Echo pauses and asks how well you remember it. Only books with an active study plan have checkpoints."
                )
                .textCase(nil)
            } footer: {
                Text(timeoutFooter)
            }

            Section {
                Toggle("Auto-advance after Good", isOn: $settings.checkpointAutoAdvance)
            } footer: {
                Text("Moves to the next chapter when you grade Good.")
            }

            Section {
                Toggle("Lock-screen button grading", isOn: $settings.checkpointRemoteGrading)
            } footer: {
                Text("Skip forward means Good. Skip back means Again.")
            }
        }
        .navigationTitle("Chapter Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timeoutFooter: String {
        switch CheckpointTimeoutBehavior(rawValue: settings.checkpointTimeoutBehavior) {
        case .replay?:
            String(localized: "No answer in time grades Again and replays the chapter.")
        case .gradeAndAdvance?:
            String(localized: "No answer in time grades Again and moves on.")
        case .wait?:
            String(localized: "Echo waits with no grade and asks again later today.")
        default:
            String(localized: "To silence checkpoints, pause the book's study plan.")
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

private struct SettingsSupportAboutSection: View {
    let buildMetadata: AppBuildMetadata
    @Binding var showingFeedback: Bool
    @State private var copiedCommit = false

    var body: some View {
        Section {
            NavigationLink("Feedback & Support") {
                FeedbackSupportView()
                    .navigationTitle("Feedback & Support")
                    .navigationBarTitleDisplayMode(.inline)
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
