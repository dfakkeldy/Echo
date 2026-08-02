// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

nonisolated struct ArticleInboxReloadResult: Sendable {
    let articles: [ArticleInboxItem]
    let anthologies: [AnthologyRecord]
}

actor ArticleInboxReloadWorker {
    private let operation: @Sendable () async throws -> ArticleInboxReloadResult

    init(operation: @escaping @Sendable () async throws -> ArticleInboxReloadResult) {
        self.operation = operation
    }

    func load() async throws -> ArticleInboxReloadResult {
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
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
    @ObservationIgnored let cleanupContext: ArticleCleanupContext?
    @ObservationIgnored private var reloadGeneration = 0

    init(db: DatabaseService, fileStore: ArticleWorkshopFileStore) {
        let captureDAO = ArticleCaptureDAO(db: db.writer)
        cleanupContext = ArticleCleanupContext(
            captureDAO: captureDAO,
            fileStore: fileStore)
        let service = ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: AnthologyDAO(db: db.writer),
            fileStore: fileStore
        )
        self.service = service
        reloadWorker = ArticleInboxReloadWorker {
            try Task.checkCancellation()
            let stagingRoot = try FileLocations.articleCaptureStagingDirectory()
            try await ArticleInboxIngestionService(
                captureDAO: captureDAO,
                fileStore: fileStore,
                stagingRoot: stagingRoot
            ).drainStagingLocalizingImages()
            try Task.checkCancellation()
            let articles = try service.inboxItems()
            try Task.checkCancellation()
            let anthologies = try service.anthologies()
            try Task.checkCancellation()
            return ArticleInboxReloadResult(articles: articles, anthologies: anthologies)
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
        cleanupContext = nil
        reloadWorker = ArticleInboxReloadWorker {
            try Task.checkCancellation()
            try drainStaging()
            try Task.checkCancellation()
            let articles = try service.inboxItems()
            try Task.checkCancellation()
            let anthologies = try service.anthologies()
            try Task.checkCancellation()
            return ArticleInboxReloadResult(articles: articles, anthologies: anthologies)
        }
    }

    init(
        service: ArticleInboxService,
        reloadWorker: ArticleInboxReloadWorker
    ) {
        self.service = service
        self.reloadWorker = reloadWorker
        cleanupContext = nil
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isImporting = true
        do {
            let result = try await reloadWorker.load()
            guard generation == reloadGeneration else { return }
            guard Task.isCancelled == false else {
                isImporting = false
                return
            }
            articles = result.articles
            anthologies = result.anthologies
            selectedIDs.formIntersection(
                result.articles.lazy.filter(\.isAnthologyEligible).map(\.id))
            errorMessage = nil
            isImporting = false
        } catch is CancellationError {
            guard generation == reloadGeneration else { return }
            isImporting = false
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = error.localizedDescription
            isImporting = false
        }
    }

    func toggleSelection(_ id: String) {
        guard articles.contains(where: { $0.id == id && $0.isAnthologyEligible }) else {
            selectedIDs.remove(id)
            return
        }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAll() {
        let visibleIDs = Set(articles.lazy.filter(\.isAnthologyEligible).map(\.id))
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
            reloadGeneration &+= 1
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
