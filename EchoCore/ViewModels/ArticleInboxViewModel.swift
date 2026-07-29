// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

nonisolated struct ArticleInboxReloadResult: Sendable {
    let articles: [ArticleInboxItem]
    let anthologies: [AnthologyRecord]
}

nonisolated struct ArticleInboxReloadWorker: Sendable {
    private let operation: @Sendable () throws -> ArticleInboxReloadResult

    init(operation: @escaping @Sendable () throws -> ArticleInboxReloadResult) {
        self.operation = operation
    }

    func load() async throws -> ArticleInboxReloadResult {
        try await Task.detached(priority: .userInitiated) {
            try operation()
        }.value
    }
}

@MainActor
@Observable
final class ArticleInboxViewModel {
    var articles: [ArticleInboxItem] = []
    var anthologies: [AnthologyRecord] = []
    var selectedIDs: Set<String> = []
    var isImporting = false
    var errorMessage: String?

    @ObservationIgnored private let service: ArticleInboxService
    @ObservationIgnored private let reloadWorker: ArticleInboxReloadWorker

    init(db: DatabaseService, fileStore: ArticleWorkshopFileStore) {
        let captureDAO = ArticleCaptureDAO(db: db.writer)
        let service = ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: AnthologyDAO(db: db.writer),
            fileStore: fileStore
        )
        self.service = service
        reloadWorker = ArticleInboxReloadWorker {
            let stagingRoot = try FileLocations.articleCaptureStagingDirectory()
            try ArticleInboxIngestionService(
                captureDAO: captureDAO,
                fileStore: fileStore,
                stagingRoot: stagingRoot
            ).drainStaging()
            return ArticleInboxReloadResult(
                articles: try service.inboxItems(),
                anthologies: try service.anthologies()
            )
        }
    }

    convenience init(db: DatabaseService) {
        self.init(db: db, fileStore: ArticleWorkshopFileStore())
    }

    init(
        service: ArticleInboxService,
        drainStaging: @escaping @Sendable () throws -> Void
    ) {
        self.service = service
        reloadWorker = ArticleInboxReloadWorker {
            try drainStaging()
            return ArticleInboxReloadResult(
                articles: try service.inboxItems(),
                anthologies: try service.anthologies()
            )
        }
    }

    init(
        service: ArticleInboxService,
        reloadWorker: ArticleInboxReloadWorker
    ) {
        self.service = service
        self.reloadWorker = reloadWorker
    }

    func reload() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await reloadWorker.load()
            articles = result.articles
            anthologies = result.anthologies
            selectedIDs.formIntersection(result.articles.map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSelection(_ id: String) {
        guard articles.contains(where: { $0.id == id }) else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAll() {
        let visibleIDs = Set(articles.map(\.id))
        if visibleIDs.isEmpty == false, selectedIDs == visibleIDs {
            selectedIDs.removeAll()
        } else {
            selectedIDs = visibleIDs
        }
    }

    func deletionImpact(for id: String) throws -> ArticleDeletionImpact {
        try service.deletionImpact(for: id)
    }

    func delete(id: String) async {
        do {
            let deletionService = service
            try await Task.detached {
                try deletionService.delete(id: id)
            }.value
            articles.removeAll { $0.id == id }
            selectedIDs.remove(id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createAnthology(title: String = "New Anthology") throws -> AnthologyRecord {
        let orderedIDs = articles.lazy
            .map(\.id)
            .filter(selectedIDs.contains)
        let anthology = try service.createAnthologySeed(
            title: title,
            captureIDs: Array(orderedIDs)
        )
        anthologies = try service.anthologies()
        selectedIDs.removeAll()
        errorMessage = nil
        return anthology
    }
}
