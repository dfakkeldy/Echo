// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

@MainActor
@Observable
final class ArticleInboxViewModel {
    var articles: [ArticleInboxItem] = []
    var anthologies: [AnthologyRecord] = []
    var selectedIDs: Set<String> = []
    var isImporting = false
    var errorMessage: String?

    @ObservationIgnored private let service: ArticleInboxService
    @ObservationIgnored private let drainStaging: @MainActor () throws -> Void

    init(db: DatabaseService, fileStore: ArticleWorkshopFileStore) {
        let captureDAO = ArticleCaptureDAO(db: db.writer)
        service = ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: AnthologyDAO(db: db.writer),
            fileStore: fileStore
        )
        drainStaging = {
            let stagingRoot = try FileLocations.articleCaptureStagingDirectory()
            try ArticleInboxIngestionService(
                captureDAO: captureDAO,
                fileStore: fileStore,
                stagingRoot: stagingRoot
            ).drainStaging()
        }
    }

    convenience init(db: DatabaseService) {
        self.init(db: db, fileStore: ArticleWorkshopFileStore())
    }

    init(
        service: ArticleInboxService,
        drainStaging: @escaping @MainActor () throws -> Void
    ) {
        self.service = service
        self.drainStaging = drainStaging
    }

    func reload() async {
        isImporting = true
        defer { isImporting = false }
        do {
            try drainStaging()
            let loadedArticles = try service.inboxItems()
            let loadedAnthologies = try service.anthologies()
            articles = loadedArticles
            anthologies = loadedAnthologies
            selectedIDs.formIntersection(loadedArticles.map(\.id))
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
