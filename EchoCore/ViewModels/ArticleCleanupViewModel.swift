// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

typealias ArticleRevisionPublisher =
    @Sendable (
        ArticleRevisionRecord,
        String?
    ) throws -> ArticleRevisionPublicationResult

nonisolated struct ArticleCleanupLoadedState: Sendable {
    let source: ArticleSnapshot
    let baselineRecipe: ArticleEditRecipe
    let expectedBaseRevisionID: String?
}

actor ArticleCleanupLoader {
    enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case captureNotFound(String)
        case currentRevisionBelongsToAnotherCapture(String)
        case malformedCurrentRevision(String)
        case inconsistentMetadataOverrides(String)
        case invalidCurrentRecipe(String)

        var errorDescription: String? {
            switch self {
            case .captureNotFound:
                return "This article is no longer available."
            case .currentRevisionBelongsToAnotherCapture:
                return "The saved cleanup does not belong to this article."
            case .malformedCurrentRevision:
                return "The saved cleanup data could not be read safely."
            case .inconsistentMetadataOverrides:
                return "The saved cleanup metadata is inconsistent."
            case .invalidCurrentRecipe:
                return "The saved cleanup references content outside this article."
            }
        }
    }

    private let captureDAO: ArticleCaptureDAO
    private let fileStore: ArticleWorkshopFileStore

    init(captureDAO: ArticleCaptureDAO, fileStore: ArticleWorkshopFileStore) {
        self.captureDAO = captureDAO
        self.fileStore = fileStore
    }

    func load(captureID: String) throws -> ArticleCleanupLoadedState {
        guard let capture = try captureDAO.capture(id: captureID) else {
            throw Error.captureNotFound(captureID)
        }
        let source = try fileStore.loadSnapshot(for: capture)
        guard let current = try captureDAO.currentRevision(captureID: captureID) else {
            return ArticleCleanupLoadedState(
                source: source,
                baselineRecipe: ArticleEditRecipe(),
                expectedBaseRevisionID: nil)
        }
        guard current.captureID == captureID else {
            throw Error.currentRevisionBelongsToAnotherCapture(current.id)
        }

        let recipe: ArticleEditRecipe
        let metadataOverrides: ArticleMetadataOverrides
        do {
            recipe = try JSONDecoder.articleWorkshop.decode(
                ArticleEditRecipe.self,
                from: Data(current.recipeJSON.utf8))
            metadataOverrides = try JSONDecoder.articleWorkshop.decode(
                ArticleMetadataOverrides.self,
                from: Data(current.metadataOverridesJSON.utf8))
        } catch {
            throw Error.malformedCurrentRevision(current.id)
        }
        guard metadataOverrides == recipe.metadataOverrides else {
            throw Error.inconsistentMetadataOverrides(current.id)
        }
        do {
            _ = try ArticleRevisionService().apply(
                snapshot: source,
                recipe: recipe)
        } catch {
            throw Error.invalidCurrentRecipe(current.id)
        }
        return ArticleCleanupLoadedState(
            source: source,
            baselineRecipe: recipe,
            expectedBaseRevisionID: current.id)
    }
}

nonisolated struct ArticleCleanupContext: Sendable {
    let loader: ArticleCleanupLoader
    let publishRevision: ArticleRevisionPublisher

    init(captureDAO: ArticleCaptureDAO, fileStore: ArticleWorkshopFileStore) {
        loader = ArticleCleanupLoader(
            captureDAO: captureDAO,
            fileStore: fileStore)
        publishRevision = { revision, expectedCurrentRevisionID in
            try captureDAO.publishRevision(
                revision,
                expectedCurrentRevisionID: expectedCurrentRevisionID)
        }
    }
}

@MainActor
@Observable
final class ArticleCleanupViewModel {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case revisionConflict(expected: String?, actual: String?)

        var errorDescription: String? {
            switch self {
            case .revisionConflict:
                return
                    "A newer cleanup was saved on another device. Your changes are still here; reopen the article to review the newer version."
            }
        }
    }

    struct Conflict: Equatable {
        let expectedRevisionID: String?
        let actualRevisionID: String?
    }

    private(set) var source: ArticleSnapshot
    private(set) var recipe: ArticleEditRecipe
    private(set) var preview: CleanArticle
    private(set) var hasUnsavedChanges: Bool
    private(set) var conflict: Conflict?

    @ObservationIgnored private let revisionService = ArticleRevisionService()
    @ObservationIgnored private let revisionID: @Sendable () -> UUID
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let publishRevision: ArticleRevisionPublisher
    @ObservationIgnored private var baselineRecipe: ArticleEditRecipe
    @ObservationIgnored private var expectedBaseRevisionID: String?

    init(
        source: ArticleSnapshot,
        baselineRecipe: ArticleEditRecipe = ArticleEditRecipe(),
        expectedBaseRevisionID: String? = nil,
        revisionID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() },
        publishRevision: @escaping ArticleRevisionPublisher
    ) throws {
        self.source = source
        recipe = baselineRecipe
        preview = try ArticleRevisionService().apply(
            snapshot: source,
            recipe: baselineRecipe)
        hasUnsavedChanges = false
        conflict = nil
        self.baselineRecipe = baselineRecipe
        self.expectedBaseRevisionID = expectedBaseRevisionID
        self.revisionID = revisionID
        self.now = now
        self.publishRevision = publishRevision
    }

    convenience init(
        loadedState: ArticleCleanupLoadedState,
        publishRevision: @escaping ArticleRevisionPublisher
    ) throws {
        try self.init(
            source: loadedState.source,
            baselineRecipe: loadedState.baselineRecipe,
            expectedBaseRevisionID: loadedState.expectedBaseRevisionID,
            publishRevision: publishRevision)
    }

    func isExcluded(_ blockID: String) -> Bool {
        recipe.excludedBlockIDs.contains(blockID)
    }

    func exclude(blockID: String) {
        guard source.blocks.contains(where: { $0.id == blockID }) else { return }
        var next = recipe
        let excluded = Set(next.excludedBlockIDs).union([blockID])
        next.excludedBlockIDs = source.blocks.lazy
            .map(\.id)
            .filter(excluded.contains)
        update(to: next)
    }

    func restore(blockID: String) {
        guard source.blocks.contains(where: { $0.id == blockID }) else { return }
        var next = recipe
        next.excludedBlockIDs.removeAll { $0 == blockID }
        update(to: next)
    }

    func trimBefore(blockID: String) {
        guard let selected = source.blocks.firstIndex(where: { $0.id == blockID }) else {
            return
        }
        var next = recipe
        next.trimBeforeBlockID = blockID
        if let afterID = next.trimAfterBlockID,
            let after = source.blocks.firstIndex(where: { $0.id == afterID }),
            after < selected
        {
            next.trimAfterBlockID = blockID
        }
        update(to: next)
    }

    func trimAfter(blockID: String) {
        guard let selected = source.blocks.firstIndex(where: { $0.id == blockID }) else {
            return
        }
        var next = recipe
        next.trimAfterBlockID = blockID
        if let beforeID = next.trimBeforeBlockID,
            let before = source.blocks.firstIndex(where: { $0.id == beforeID }),
            before > selected
        {
            next.trimBeforeBlockID = blockID
        }
        update(to: next)
    }

    func updateMetadata(_ overrides: ArticleMetadataOverrides) {
        var next = recipe
        next.metadataOverrides = overrides
        update(to: next)
    }

    func reset() {
        update(to: ArticleEditRecipe())
    }

    func save(deviceName: String?) throws -> ArticleRevisionRecord {
        let recipeJSON = try canonicalJSONString(recipe)
        let metadataJSON = try canonicalJSONString(recipe.metadataOverrides)
        let revision = ArticleRevisionRecord(
            id: revisionID().uuidString,
            captureID: source.captureID.uuidString,
            parentRevisionID: expectedBaseRevisionID,
            metadataOverridesJSON: metadataJSON,
            recipeJSON: recipeJSON,
            readableContentSHA256: preview.readableContentSHA256,
            createdAt: Self.timestamp(now()),
            deviceName: normalized(deviceName))

        switch try publishRevision(revision, expectedBaseRevisionID) {
        case .published(let published):
            baselineRecipe = recipe
            expectedBaseRevisionID = published.id
            hasUnsavedChanges = false
            conflict = nil
            return published
        case .conflict(let actualCurrentRevisionID):
            let value = Conflict(
                expectedRevisionID: expectedBaseRevisionID,
                actualRevisionID: actualCurrentRevisionID)
            conflict = value
            throw Error.revisionConflict(
                expected: value.expectedRevisionID,
                actual: value.actualRevisionID)
        }
    }

    private func update(to next: ArticleEditRecipe) {
        guard let revised = try? revisionService.apply(snapshot: source, recipe: next) else {
            return
        }
        recipe = next
        preview = revised
        hasUnsavedChanges = next != baselineRecipe
    }

    private func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func normalized(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false
        else {
            return nil
        }
        return value
    }

    nonisolated private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
