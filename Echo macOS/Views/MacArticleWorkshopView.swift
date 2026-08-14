// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A small macOS adapter around Echo's shared Article Workshop services.
///
/// The iPhone/iPad workshop uses UIKit-backed navigation, so the Mac target
/// needs its own presentation while continuing to share ingestion, anthology,
/// EPUB-build, and library-import behavior.
struct MacArticleWorkshopView: View {
    @State private var inbox: ArticleInboxViewModel
    @State private var websiteCapture: ArticleWebsiteCaptureCoordinator
    @State private var linkBatch: ArticleLinkBatchCoordinator
    @State private var showsLinkBatch = false
    @State private var mode: LibraryMode = .inbox
    @State private var anthologyTitle = ""
    @State private var knownCaptureIDs: Set<String> = []
    @State private var buildCoordinator: MacArticleWorkshopBuildCoordinator
    @State private var didLoad = false
    @State private var loadingVoiceEditorID: String?
    @State private var voiceEditor: VoiceEditorPresentation?
    @State private var voiceEditorLoadMessage: String?
    @AccessibilityFocusState private var voiceEditorLoadErrorIsFocused: Bool
    @State private var websiteSubmissionID = 0

    private let anthologyService: AnthologyService
    /// Injected rather than read from `@Environment`: this view is presented as a
    /// sheet from `Echo_macOSApp`, and a sheet only inherits the environment that
    /// exists where its `.sheet` modifier is attached — which is *outside* the
    /// `.environment(...)` writes applied to the window's root view. Reading
    /// `SettingsManager` from the environment therefore trapped on open. A stored
    /// dependency makes the requirement a compile-time one instead.
    private let settings: SettingsManager

    @MainActor
    init(db: DatabaseService, settings: SettingsManager) {
        self.settings = settings
        let fileStore = ArticleWorkshopFileStore()
        let anthologyService = AnthologyService(db: db, fileStore: fileStore)
        self.anthologyService = anthologyService
        let inbox = ArticleInboxViewModel(db: db, fileStore: fileStore)
        _inbox = State(initialValue: inbox)
        _websiteCapture = State(initialValue: ArticleWebsiteCaptureCoordinator(inbox: inbox))
        _linkBatch = State(initialValue: ArticleLinkBatchCoordinator(inbox: inbox))
        _buildCoordinator = State(
            initialValue: MacArticleWorkshopBuildCoordinator(
                service: AnthologyBuildService(
                    anthologyService: anthologyService,
                    databaseService: db),
                onSuccessfulBuild: {
                    await inbox.reload()
                }))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch mode {
                case .inbox:
                    inboxContent
                case .anthologies:
                    anthologyContent
                case .books:
                    EmptyView()
                }
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .task {
            guard didLoad == false else { return }
            didLoad = true
            await inbox.reload()
            knownCaptureIDs = inbox.allCaptureIDs
        }
        .task(id: websiteSubmissionID) {
            guard websiteSubmissionID > 0 else { return }
            if websiteCapture.retryAvailable {
                await websiteCapture.retry()
            } else {
                await websiteCapture.submit()
            }
            knownCaptureIDs = inbox.allCaptureIDs
        }
        .sheet(item: $voiceEditor) { presentation in
            MacAnthologyVoiceEditor(
                viewModel: presentation.viewModel,
                preferredVoice: preferredVoice)
        }
        .sheet(isPresented: $showsLinkBatch) {
            MacArticleLinkBatchSheet(coordinator: linkBatch) { anthology in
                knownCaptureIDs = inbox.allCaptureIDs
                mode = .anthologies
                showsLinkBatch = false
            }
        }
        .onChange(of: voiceEditorLoadMessage) { _, message in
            guard message != nil else {
                voiceEditorLoadErrorIsFocused = false
                return
            }
            voiceEditorLoadErrorIsFocused = true
            AccessibilityNotification.LayoutChanged().post()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Article Workshop")
                    .font(.title2.bold())
                Text("Import captures, assemble anthologies, and build EPUB editions.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Workspace", selection: $mode) {
                Label("Inbox", systemImage: "tray")
                    .tag(LibraryMode.inbox)
                Label("Anthologies", systemImage: "text.book.closed")
                    .tag(LibraryMode.anthologies)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding()
    }

    private var inboxContent: some View {
        VStack(spacing: 0) {
            websiteCaptureForm

            Divider()

            HStack {
                Button("Refresh & Select New") {
                    Task { await refreshAndSelectNew() }
                }
                .accessibilityIdentifier("articleWorkshop.refreshAndSelectNew")
                .disabled(inbox.isImporting || websiteCapture.isBusy)

                Button(inbox.selectedIDs.isEmpty ? "Select All" : "Clear Selection") {
                    inbox.selectAll()
                }
                .disabled(inbox.articles.isEmpty)

                Toggle(
                    "Show Used Captures",
                    isOn: Binding(
                        get: { inbox.showsUsedCaptures },
                        set: { inbox.setShowsUsedCaptures($0) })
                )
                .toggleStyle(.checkbox)

                if inbox.isImporting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
                Text("\(inbox.selectedIDs.count) selected · \(inbox.articles.count) captures")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if inbox.articles.isEmpty, inbox.isImporting == false {
                ContentUnavailableView(
                    "No Article Captures",
                    systemImage: "tray",
                    description: Text(
                        "Place capture packages in Echo’s staging folder, then refresh.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(inbox.articles) { article in
                    articleRow(article)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                TextField("Anthology title", text: $anthologyTitle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("articleWorkshop.anthologyTitle")
                Button("Create Anthology") {
                    createAnthology()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("articleWorkshop.createAnthology")
                .disabled(
                    inbox.selectedIDs.isEmpty
                        || anthologyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            if let error = inbox.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
        }
    }

    private var websiteCaptureForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add Website")
                    .font(.headline)
                Spacer()
                Button("New Anthology from Links…", systemImage: "list.bullet.clipboard") {
                    linkBatch = ArticleLinkBatchCoordinator(inbox: inbox)
                    showsLinkBatch = true
                }
                .accessibilityIdentifier("articleWorkshop.newAnthologyFromLinks")
                .disabled(inbox.isImporting || websiteCapture.isBusy)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(
                    "Website URL",
                    text: $websiteCapture.urlText,
                    prompt: Text("https://example.com/article")
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(requestWebsiteCapture)
                .accessibilityIdentifier("articleWorkshop.websiteURL")
                .accessibilityHint("Enter a public HTTP or HTTPS article URL.")
                .disabled(websiteCapture.isBusy || inbox.isImporting)

                Button("Add Website", action: requestWebsiteCapture)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("articleWorkshop.addWebsite")
                    .accessibilityHint(
                        "Captures the website and adds it through the Article Inbox."
                    )
                    .disabled(websiteCapture.canSubmit == false || inbox.isImporting)
            }

            if let validationMessage = websiteCapture.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("articleWorkshop.websiteValidation")
            } else {
                Text("Add a public HTTP(S) article. Signed-in pages are not supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            websiteCaptureStatus
        }
        .padding()
    }

    @ViewBuilder
    private var websiteCaptureStatus: some View {
        switch websiteCapture.phase {
        case .idle:
            EmptyView()
        case .capturing:
            ProgressView("Capturing website…")
                .accessibilityIdentifier("articleWorkshop.websiteCapturing")
        case .loading:
            ProgressView("Adding capture to Inbox…")
                .accessibilityIdentifier("articleWorkshop.websiteLoading")
        case .success:
            Label("Website added and selected.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("articleWorkshop.websiteSuccess")
        case .failure(_, let message):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("articleWorkshop.websiteFailure")
                Spacer()
                Button("Retry", action: requestWebsiteCapture)
                    .accessibilityIdentifier("articleWorkshop.websiteRetry")
                    .accessibilityHint(
                        "Retries from the failed step without duplicating completed work.")
            }
        }
    }

    private func articleRow(_ article: ArticleInboxItem) -> some View {
        Button {
            inbox.toggleSelection(article.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: inbox.selectedIDs.contains(article.id)
                        ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(
                    inbox.selectedIDs.contains(article.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let site = article.siteName, site.isEmpty == false {
                            Text(site)
                        }
                        Label(article.state.title, systemImage: article.state.systemImage)
                        if article.isUsed {
                            Label("Used in EPUB", systemImage: "archivebox")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if article.warnings.isEmpty == false {
                        Text(article.warnings.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(article.isAnthologyEligible == false)
        .accessibilityIdentifier("articleWorkshop.capture.\(article.id)")
    }

    private var anthologyContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Refresh") {
                    Task { await inbox.reload() }
                }
                .disabled(inbox.isImporting)

                Button("Build All EPUBs") {
                    buildCoordinator.buildAll(inbox.anthologies)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("articleWorkshop.buildAll")
                .disabled(inbox.anthologies.isEmpty || buildCoordinator.isBuilding)

                Spacer()
                Text("\(inbox.anthologies.count) anthologies")
                    .foregroundStyle(.secondary)
            }
            .padding()

            if let voiceEditorLoadMessage {
                Label(voiceEditorLoadMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityFocused($voiceEditorLoadErrorIsFocused)
                    .accessibilityIdentifier("articleWorkshop.editVoices.error")
            }

            Divider()

            if inbox.anthologies.isEmpty {
                ContentUnavailableView(
                    "No Anthologies",
                    systemImage: "text.book.closed",
                    description: Text("Select captures in the Inbox to create one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(inbox.anthologies, id: \.id) { anthology in
                    HStack(spacing: 12) {
                        Image(systemName: "text.book.closed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(anthology.title)
                                .font(.headline)
                            Text("Revision \(anthology.latestBuildRevision)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let message = buildCoordinator.messages[anthology.id] {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(message.hasPrefix("Built") ? .green : .red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if buildCoordinator.buildingIDs.contains(anthology.id) {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if loadingVoiceEditorID == anthology.id {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Edit Voices") {
                            Task { await loadVoiceEditor(for: anthology) }
                        }
                        .disabled(loadingVoiceEditorID == anthology.id)
                        .accessibilityIdentifier("articleWorkshop.editVoices.\(anthology.id)")
                        Button("Build EPUB") {
                            buildCoordinator.build(anthology)
                        }
                        .disabled(buildCoordinator.buildingIDs.contains(anthology.id))
                        .accessibilityIdentifier("articleWorkshop.build.\(anthology.id)")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private var preferredVoice: VoiceID {
        guard settings.narrationVoiceID.isEmpty == false,
            let voice = VoiceCatalog.voice(for: VoiceID(settings.narrationVoiceID))
        else { return VoiceCatalog.default.id }
        return voice.id
    }

    @MainActor
    private func loadVoiceEditor(for anthology: AnthologyRecord) async {
        guard loadingVoiceEditorID == nil else { return }
        loadingVoiceEditorID = anthology.id
        voiceEditorLoadMessage = nil
        defer { loadingVoiceEditorID = nil }
        do {
            let service = anthologyService
            let project = try await Task.detached {
                try service.loadProject(id: anthology.id)
            }.value
            voiceEditor = VoiceEditorPresentation(
                id: anthology.id,
                viewModel: AnthologyBuilderViewModel(
                    project: project,
                    service: anthologyService))
        } catch {
            voiceEditorLoadMessage = String(
                localized: "This anthology's voices could not be loaded. Try again."
            )
        }
    }

    @MainActor
    private func refreshAndSelectNew() async {
        let before = knownCaptureIDs
        await inbox.reload()
        let eligible = inbox.articles.filter(\.isAnthologyEligible)
        let newlyImported = eligible.filter { before.contains($0.id) == false }
        for article in newlyImported where inbox.selectedIDs.contains(article.id) == false {
            inbox.toggleSelection(article.id)
        }
        knownCaptureIDs = inbox.allCaptureIDs
    }

    private func requestWebsiteCapture() {
        guard websiteCapture.canSubmit, inbox.isImporting == false else { return }
        websiteSubmissionID &+= 1
    }

    @MainActor
    private func createAnthology() {
        do {
            _ = try inbox.createAnthology(title: anthologyTitle)
            anthologyTitle = ""
            mode = .anthologies
        } catch {
            inbox.errorMessage = error.localizedDescription
        }
    }

}

@MainActor
private struct MacArticleLinkBatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: ArticleLinkBatchCoordinator
    let onCreated: (AnthologyRecord) -> Void

    @State private var workTask: Task<Void, Never>?

    private var uniqueLinkCount: Int {
        coordinator.rows.count { row in
            switch row.status {
            case .queued, .capturing, .succeeded, .failed:
                true
            case .duplicate, .invalid:
                false
            }
        }
    }

    private var successCount: Int {
        coordinator.rows.count { row in
            if case .succeeded = row.status { return true }
            return false
        }
    }

    private var failureCount: Int {
        coordinator.rows.count { row in
            if case .failed = row.status { return true }
            return false
        }
    }

    private var invalidCount: Int {
        coordinator.rows.count { $0.status == .invalid }
    }

    private var duplicateCount: Int {
        coordinator.rows.count { row in
            if case .duplicate = row.status { return true }
            return false
        }
    }

    private var hasStarted: Bool {
        coordinator.rows.contains { row in
            switch row.status {
            case .capturing, .succeeded, .failed:
                true
            case .queued, .duplicate, .invalid:
                false
            }
        }
    }

    private var primaryTitle: String {
        if failureCount > 0 { return "Retry Failed" }
        if coordinator.creationError != nil, successCount > 0 { return "Retry Create" }
        return "Capture & Create Anthology"
    }

    private var primaryDisabled: Bool {
        if coordinator.isRunning || workTask != nil { return true }
        if failureCount > 0 { return false }
        if coordinator.creationError != nil, successCount > 0 { return false }
        return coordinator.canStart == false
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anthology Title")
                        .font(.headline)
                    TextField("Anthology title", text: $coordinator.title)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.isRunning || hasStarted)
                        .accessibilityIdentifier("articleWorkshop.linkBatch.title")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Article Links")
                        .font(.headline)
                    Text("Paste one public HTTP(S) link per line. Blank lines are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $coordinator.linkText)
                        .font(.body.monospaced())
                        .frame(minHeight: 150)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .disabled(coordinator.isRunning || hasStarted)
                        .accessibilityIdentifier("articleWorkshop.linkBatch.links")
                }

                validationSummary

                if coordinator.rows.isEmpty == false {
                    linkRows
                }

                if let creationError = coordinator.creationError {
                    Label(creationError, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("articleWorkshop.linkBatch.creationError")
                }

                if failureCount > 0, successCount > 0 {
                    HStack {
                        Text(
                            "You can retry the failures or create an anthology from the captured links."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Create with \(successCount) of \(uniqueLinkCount)") {
                            coordinator.createWithSuccesses()
                            finishIfCreated()
                        }
                        .accessibilityIdentifier("articleWorkshop.linkBatch.createWithSuccesses")
                    }
                }
            }
            .padding(20)
            .navigationTitle("New Anthology from Links")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryTitle, action: performPrimaryAction)
                        .disabled(primaryDisabled)
                        .accessibilityIdentifier("articleWorkshop.linkBatch.primaryAction")
                }
            }
        }
        .frame(minWidth: 680, minHeight: 620)
        .interactiveDismissDisabled(coordinator.isRunning)
        .onDisappear {
            workTask?.cancel()
        }
    }

    @ViewBuilder
    private var validationSummary: some View {
        if invalidCount > 0 {
            Label(
                "Correct \(invalidCount) invalid link\(invalidCount == 1 ? "" : "s") before starting.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        } else if uniqueLinkCount > 0 {
            HStack(spacing: 12) {
                Label(
                    "\(uniqueLinkCount) link\(uniqueLinkCount == 1 ? "" : "s") ready",
                    systemImage: "link")
                if duplicateCount > 0 {
                    Label(
                        "\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") skipped",
                        systemImage: "doc.on.doc"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var linkRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(coordinator.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(row.lineNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        rowStatus(row)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.originalText)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(statusDescription(row.status))
                                .font(.caption)
                                .foregroundStyle(statusColor(row.status))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    if row.id != coordinator.rows.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(minHeight: 160, maxHeight: 240)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("articleWorkshop.linkBatch.rows")
    }

    @ViewBuilder
    private func rowStatus(_ row: ArticleLinkBatchCoordinator.Row) -> some View {
        if row.status == .capturing {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: statusSymbol(row.status))
                .foregroundStyle(statusColor(row.status))
        }
    }

    private func statusSymbol(_ status: ArticleLinkBatchCoordinator.Status) -> String {
        switch status {
        case .queued: "circle"
        case .capturing: "arrow.down.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .duplicate: "doc.on.doc"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }

    private func statusDescription(_ status: ArticleLinkBatchCoordinator.Status) -> String {
        switch status {
        case .queued: "Ready"
        case .capturing: "Capturing…"
        case .succeeded: "Captured"
        case .failed(let message): message
        case .duplicate(let firstLineNumber): "Duplicate of line \(firstLineNumber); skipped"
        case .invalid: "Enter a valid public HTTP(S) URL"
        }
    }

    private func statusColor(_ status: ArticleLinkBatchCoordinator.Status) -> Color {
        switch status {
        case .succeeded: .green
        case .failed, .invalid: .red
        case .duplicate: .orange
        case .queued, .capturing: .secondary
        }
    }

    private func performPrimaryAction() {
        if failureCount > 0 {
            startWork { await coordinator.retryFailures() }
        } else if coordinator.creationError != nil, successCount > 0 {
            coordinator.createWithSuccesses()
            finishIfCreated()
        } else {
            startWork { await coordinator.captureAndCreate() }
        }
    }

    private func startWork(_ operation: @escaping @MainActor () async -> Void) {
        guard workTask == nil else { return }
        workTask = Task { @MainActor in
            await operation()
            guard Task.isCancelled == false else { return }
            workTask = nil
            finishIfCreated()
        }
    }

    private func finishIfCreated() {
        guard let anthology = coordinator.createdAnthology else { return }
        onCreated(anthology)
        dismiss()
    }

    private func cancel() {
        workTask?.cancel()
        dismiss()
    }
}

@MainActor
private struct VoiceEditorPresentation: Identifiable {
    let id: String
    let viewModel: AnthologyBuilderViewModel
}

/// Owns workshop build tasks independently of the sheet's presentation
/// lifetime. A library refresh can temporarily replace the SwiftUI sheet, but
/// an in-flight publication must still reach commit or rollback.
@MainActor
@Observable
private final class MacArticleWorkshopBuildCoordinator {
    private let service: AnthologyBuildService
    private let onSuccessfulBuild: @MainActor @Sendable () async -> Void
    private var tasks: [String: Task<Void, Never>] = [:]
    private var buildAllTask: Task<Void, Never>?

    private(set) var buildingIDs: Set<String> = []
    private(set) var messages: [String: String] = [:]

    var isBuilding: Bool {
        buildAllTask != nil || buildingIDs.isEmpty == false
    }

    init(
        service: AnthologyBuildService,
        onSuccessfulBuild: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.service = service
        self.onSuccessfulBuild = onSuccessfulBuild
    }

    func build(_ anthology: AnthologyRecord) {
        guard tasks[anthology.id] == nil, buildAllTask == nil else { return }
        buildingIDs.insert(anthology.id)
        messages[anthology.id] = nil
        let service = service
        tasks[anthology.id] = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Self.result(anthology, using: service)
            await self?.finish(anthology, with: result)
        }
    }

    func buildAll(_ anthologies: [AnthologyRecord]) {
        guard buildAllTask == nil, tasks.isEmpty else { return }
        buildingIDs.formUnion(anthologies.map(\.id))
        for anthology in anthologies { messages[anthology.id] = nil }
        let service = service
        buildAllTask = Task.detached(priority: .userInitiated) { [weak self] in
            for anthology in anthologies {
                let result = await Self.result(anthology, using: service)
                await self?.finish(anthology, with: result)
            }
            await self?.finishBuildAll()
        }
    }

    private nonisolated static func result(
        _ anthology: AnthologyRecord,
        using service: AnthologyBuildService
    ) async -> Result<AnthologyBuildRecord, Swift.Error> {
        do {
            let record = try await service.build(anthologyID: anthology.id)
            return .success(record)
        } catch {
            return .failure(error)
        }
    }

    private func finish(
        _ anthology: AnthologyRecord,
        with result: Result<AnthologyBuildRecord, Swift.Error>
    ) async {
        buildingIDs.remove(anthology.id)
        tasks[anthology.id] = nil
        switch result {
        case .success(let record):
            messages[anthology.id] = "Built revision \(record.revision) and added it to Echo."
            await onSuccessfulBuild()
        case .failure(let error):
            messages[anthology.id] = error.localizedDescription
        }
    }

    private func finishBuildAll() {
        buildAllTask = nil
    }
}
