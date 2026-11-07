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

                // Headed like every other group, so the page reads as one
                // rhythm: header, card, header, card.
                Section {
                    NavigationLink("Appearance") {
                        SettingsAppearanceView()
                    }
                } header: {
                    Text("Look & Feel")
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

                Section {
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
                } header: {
                    Text("Study & Notes")
                } footer: {
                    // Limit notes sit under the card, not inside it.
                    SettingsStudyLimitsFooter()
                }

                // Export rows: their status line is this group's footer.
                Section {
                    AutoExportSettingsRows(showsStatus: false)

                    Button {
                        showingAllStudyNotesExport = true
                    } label: {
                        Label("Export All Study Notes", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.databaseService == nil)
                } footer: {
                    AutoExportStatusText()
                        .settingsFooterStyle()
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
                            .settingsFooterStyle()
                        }
                    }
                #endif

                SettingsSupportAboutSection(buildMetadata: buildMetadata)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // System font: no override, so headers and footers keep their
        // own text styles. A custom font sets the body size for rows;
        // footers opt back down with `settingsFooterStyle()`.
        .environment(
            \.font,
            settings.appFont == SettingsManager.systemFontName
                ? nil : Font.custom(settings.appFont, size: 17, relativeTo: .body)
        )
        .fileImporter(
            isPresented: $showingDeckImporter,
            allowedContentTypes: [.folder, .json],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
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
        importAlert = Self.deckImportAlert(for: result, db: model.databaseService)
    }

    /// Runs a deck import the file importer picked and returns the alert to
    /// show. Shared with the Decks screen's empty-state Import Deck button.
    static func deckImportAlert(
        for result: Result<[URL], Error>, db: DatabaseService?
    ) -> (title: String, message: String)? {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let db else { return nil }
            do {
                let result = try DeckImportService().importDeckVNext(from: url, db: db.writer)
                return ("Import Complete", importCompletionMessage(for: result))
            } catch {
                return ("Import Failed", error.localizedDescription)
            }
        case .failure(let error):
            return ("Import Failed", error.localizedDescription)
        }
    }

    private static func importCompletionMessage(for result: ImportDeckResult) -> String {
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
        // used to wrap). The section footer names the limit, so a disabled
        // "+" at the top of the range is not a silent dead end.
        Stepper(value: $settings.studyGlobalNewChapterLimit, in: Self.chapterLimitRange) {
            LabeledContent("New chapters per day") {
                Text("\(settings.studyGlobalNewChapterLimit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }

        Stepper(value: $settings.studyNewCardsPerDayLimit, in: Self.cardLimitRange) {
            LabeledContent("New AI cards per batch") {
                Text("\(settings.studyNewCardsPerDayLimit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }

        NavigationLink("Chapter Checkpoints") {
            CheckpointSettingsView()
        }
    }

    static let chapterLimitRange = 1...12
    static let cardLimitRange = 1...100

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

/// Footer for Study & Notes: names a limit only when its stepper is at it.
private struct SettingsStudyLimitsFooter: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        let chapterCap = settings.studyGlobalNewChapterLimit
            >= SettingsStudyRows.chapterLimitRange.upperBound
        let cardCap = settings.studyNewCardsPerDayLimit
            >= SettingsStudyRows.cardLimitRange.upperBound
        if chapterCap || cardCap {
            VStack(alignment: .leading, spacing: 4) {
                if chapterCap {
                    Text("12 new chapters a day is the most Echo schedules.")
                }
                if cardCap {
                    Text("100 new cards per batch is the most Echo offers.")
                }
            }
            .settingsFooterStyle()
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
                // The timer first, then what happens when it runs out.
                // Menu style keeps each value trailing on its label's line.
                if settings.checkpointTimeoutBehavior != CheckpointTimeoutBehavior.wait.rawValue {
                    Picker("Checkpoint timeout", selection: $settings.checkpointTimeoutSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                    .pickerStyle(.menu)
                }

                Picker("When the timer runs out", selection: $settings.checkpointTimeoutBehavior) {
                    Text("Replay chapter")
                        .tag(CheckpointTimeoutBehavior.replay.rawValue)
                    Text("Move on")
                        .tag(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue)
                    Text("Wait")
                        .tag(CheckpointTimeoutBehavior.wait.rawValue)
                }
                .pickerStyle(.menu)
            } header: {
                Text(
                    "When a due study chapter ends, Echo pauses and asks how well you remember it. Only books with an active study plan have checkpoints."
                )
                .textCase(nil)
                .settingsIntroStyle()
            } footer: {
                Text(timeoutFooter)
                    .settingsFooterStyle()
            }

            Section {
                Toggle("Auto-advance after Good", isOn: $settings.checkpointAutoAdvance)
            } footer: {
                Text("Moves to the next chapter when you grade Good.")
                    .settingsFooterStyle()
            }

            Section {
                Toggle("Lock-screen button grading", isOn: $settings.checkpointRemoteGrading)
            } footer: {
                Text("Skip forward means Good. Skip back means Again.")
                    .settingsFooterStyle()
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
            .settingsFooterStyle()
        }
    }
}

private struct SettingsSupportAboutSection: View {
    let buildMetadata: AppBuildMetadata
    @State private var copiedCommit = false

    var body: some View {
        Section {
            // One icon rule: rows that go somewhere carry an icon in the
            // accent colour with primary-colour text; the Version and
            // Commit facts carry none. Feedback & Support is the one
            // route to email (its page opens Mail with the build filled in).
            NavigationLink {
                FeedbackSupportView()
                    .navigationTitle("Feedback & Support")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Feedback & Support", systemImage: "envelope")
            }
            NavigationLink {
                HelpView()
                    .navigationTitle("Help")
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            // An external page: primary text, accent icon and a trailing
            // arrow.up.right, like the external rows in Feedback & Support.
            // The plain style stops the List from tinting the whole label.
            Link(destination: FeedbackSupport.privacyPolicyURL) {
                HStack {
                    Label {
                        Text("Privacy Policy")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LabeledContent("Version", value: buildMetadata.versionString)
            // A plain row, so the copy control cannot stretch it taller.
            HStack {
                Text("Commit")
                Spacer()
                Text(buildMetadata.commitString)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    copyCommitHash()
                } label: {
                    Image(systemName: copiedCommit ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(buildMetadata.gitCommitHash == nil)
                .accessibilityLabel("Copy commit hash")
            }
        } header: {
            Text("Support & About")
        } footer: {
            Text("Use these details when comparing installs or reporting a bug.")
                .settingsFooterStyle()
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
