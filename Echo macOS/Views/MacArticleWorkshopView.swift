// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A small macOS adapter around Echo's shared Article Workshop services.
///
/// The iPhone/iPad workshop uses UIKit-backed navigation, so the Mac target
/// needs its own presentation while continuing to share ingestion, anthology,
/// EPUB-build, and library-import behavior.
struct MacArticleWorkshopView: View {
    @State private var inbox: ArticleInboxViewModel
    @State private var mode: LibraryMode = .inbox
    @State private var anthologyTitle = ""
    @State private var knownCaptureIDs: Set<String> = []
    @State private var buildCoordinator: MacArticleWorkshopBuildCoordinator
    @State private var didLoad = false

    @MainActor
    init(db: DatabaseService) {
        let fileStore = ArticleWorkshopFileStore()
        let anthologyService = AnthologyService(db: db, fileStore: fileStore)
        let inbox = ArticleInboxViewModel(db: db, fileStore: fileStore)
        _inbox = State(initialValue: inbox)
        _buildCoordinator = State(initialValue: MacArticleWorkshopBuildCoordinator(
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
            HStack {
                Button("Refresh & Select New") {
                    Task { await refreshAndSelectNew() }
                }
                .accessibilityIdentifier("articleWorkshop.refreshAndSelectNew")
                .disabled(inbox.isImporting)

                Button(inbox.selectedIDs.isEmpty ? "Select All" : "Clear Selection") {
                    inbox.selectAll()
                }
                .disabled(inbox.articles.isEmpty)

                Toggle(
                    "Show Used Captures",
                    isOn: Binding(
                        get: { inbox.showsUsedCaptures },
                        set: { inbox.setShowsUsedCaptures($0) }))
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
                    description: Text("Place capture packages in Echo’s staging folder, then refresh."))
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

    private func articleRow(_ article: ArticleInboxItem) -> some View {
        Button {
            inbox.toggleSelection(article.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: inbox.selectedIDs.contains(article.id)
                    ? "checkmark.circle.fill" : "circle")
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

            Divider()

            if inbox.anthologies.isEmpty {
                ContentUnavailableView(
                    "No Anthologies",
                    systemImage: "text.book.closed",
                    description: Text("Select captures in the Inbox to create one."))
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
