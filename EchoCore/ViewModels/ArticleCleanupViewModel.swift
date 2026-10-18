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
        case originalCaptureUnreadable

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
            case .originalCaptureUnreadable:
                return "The original capture could not be read safely."
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
        let source: ArticleSnapshot
        do {
            source = try fileStore.loadSnapshot(for: capture)
        } catch {
            throw Error.originalCaptureUnreadable
        }
        guard let current = try captureDAO.currentRevision(captureID: captureID) else {
            return ArticleCleanupLoadedState(
                source: source,
                baselineRecipe: ArticleEditRecipe(),
                expectedBaseRevisionID: nil)
        }
        guard current.captureID == captureID else {
            throw Error.currentRevisionBelongsToAnotherCapture(current.id)
        }

        let clean: CleanArticle
        do {
            clean = try ArticleRevisionMaterializer().materialize(
                capture: capture,
                revision: current,
                source: source)
        } catch ArticleRevisionMaterializer.Error.malformedRevision {
            throw Error.malformedCurrentRevision(current.id)
        } catch ArticleRevisionMaterializer.Error.inconsistentMetadataOverrides {
            throw Error.inconsistentMetadataOverrides(current.id)
        } catch ArticleRevisionMaterializer.Error.revisionBelongsToAnotherCapture {
            throw Error.currentRevisionBelongsToAnotherCapture(current.id)
        } catch ArticleRevisionMaterializer.Error.invalidRecipe,
            ArticleRevisionMaterializer.Error.readableContentDigestMismatch
        {
            throw Error.invalidCurrentRecipe(current.id)
        }
        return ArticleCleanupLoadedState(
            source: source,
            baselineRecipe: clean.recipe,
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

nonisolated enum ArticleCleanupUserMessage {
    static func load(_ error: any Swift.Error) -> String {
        if let loaderError = error as? ArticleCleanupLoader.Error {
            switch loaderError {
            case .captureNotFound:
                return "This article is no longer available."
            case .originalCaptureUnreadable:
                return "The original capture could not be read safely."
            case .currentRevisionBelongsToAnotherCapture,
                .malformedCurrentRevision,
                .inconsistentMetadataOverrides,
                .invalidCurrentRecipe:
                return "The saved cleanup could not be read safely."
            }
        }
        if error is ArticleWorkshopFileStore.Error {
            return "The original capture could not be read safely."
        }
        if error is ArticleRevisionService.Error {
            return "The saved cleanup could not be read safely."
        }
        return "Cleanup could not be loaded right now. Try again."
    }

    static func save(_ error: any Swift.Error) -> String {
        if let conflict = error as? ArticleCleanupViewModel.Error {
            return conflict.localizedDescription
        }
        return "Cleanup could not be saved. Try again. Your unsaved choices remain."
    }
}

typealias ArticleCleanupStateLoader =
    @Sendable (String) async throws -> ArticleCleanupLoadedState

@MainActor
@Observable
final class ArticleCleanupLoadingCoordinator {
    private(set) var viewModel: ArticleCleanupViewModel?
    private(set) var userMessage: String?
    private(set) var isLoading = false

    @ObservationIgnored private let loadState: ArticleCleanupStateLoader
    @ObservationIgnored private let publishRevision: ArticleRevisionPublisher
    @ObservationIgnored private var captureID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        loadState: @escaping ArticleCleanupStateLoader,
        publishRevision: @escaping ArticleRevisionPublisher
    ) {
        self.loadState = loadState
        self.publishRevision = publishRevision
    }

    func start(captureID: String) {
        self.captureID = captureID
        startLoad(captureID: captureID)
    }

    func retry() {
        guard let captureID else { return }
        startLoad(captureID: captureID)
    }

    func cancel() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func startLoad(captureID: String) {
        loadTask?.cancel()
        generation += 1
        let loadGeneration = generation
        let loadState = loadState
        let publishRevision = publishRevision
        viewModel = nil
        userMessage = nil
        isLoading = true

        loadTask = Task { [weak self] in
            do {
                let loaded = try await loadState(captureID)
                try Task.checkCancellation()
                let viewModel = try ArticleCleanupViewModel(
                    loadedState: loaded,
                    publishRevision: publishRevision)
                guard let self, generation == loadGeneration else { return }
                self.viewModel = viewModel
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == loadGeneration else { return }
                userMessage = ArticleCleanupUserMessage.load(error)
            }
            guard let self, generation == loadGeneration else { return }
            isLoading = false
            loadTask = nil
        }
    }
}

nonisolated struct ArticleCleanupBlockPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case included
        case explicitlyRemoved
        case trimmedAbove
        case trimmedBelow
    }

    let state: State
    let startsHere: Bool
    let endsHere: Bool

    var accessibilityValue: String {
        let stateValue: String
        switch state {
        case .included: stateValue = "Included"
        case .explicitlyRemoved: stateValue = "Removed"
        case .trimmedAbove: stateValue = "Trimmed above"
        case .trimmedBelow: stateValue = "Trimmed below"
        }
        var values = [stateValue]
        if startsHere {
            values.append("starts here")
        }
        if endsHere {
            values.append("ends here")
        }
        return values.joined(separator: ", ")
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
        let baselineRecipe = try Self.normalized(
            baselineRecipe,
            for: source)
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

    func presentation(for blockID: String) -> ArticleCleanupBlockPresentation? {
        guard let index = source.blocks.firstIndex(where: { $0.id == blockID }) else {
            return nil
        }
        let startIndex = recipe.trimBeforeBlockID.flatMap { boundary in
            source.blocks.firstIndex(where: { $0.id == boundary })
        }
        let endIndex = recipe.trimAfterBlockID.flatMap { boundary in
            source.blocks.firstIndex(where: { $0.id == boundary })
        }
        if let startIndex, index < startIndex {
            return ArticleCleanupBlockPresentation(
                state: .trimmedAbove,
                startsHere: false,
                endsHere: false)
        }
        if let endIndex, index > endIndex {
            return ArticleCleanupBlockPresentation(
                state: .trimmedBelow,
                startsHere: false,
                endsHere: false)
        }
        return ArticleCleanupBlockPresentation(
            state: isExcluded(blockID) ? .explicitlyRemoved : .included,
            startsHere: index == startIndex,
            endsHere: index == endIndex)
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
        guard
            let next = try? Self.normalized(next, for: source),
            let revised = try? revisionService.apply(snapshot: source, recipe: next)
        else {
            return
        }
        recipe = next
        preview = revised
        hasUnsavedChanges = next != baselineRecipe
    }

    nonisolated private static func normalized(
        _ recipe: ArticleEditRecipe,
        for source: ArticleSnapshot
    ) throws -> ArticleEditRecipe {
        _ = try ArticleRevisionService().apply(
            snapshot: source,
            recipe: recipe)
        var recipe = recipe
        let excluded = Set(recipe.excludedBlockIDs)
        recipe.excludedBlockIDs = source.blocks.lazy
            .map(\.id)
            .filter(excluded.contains)
        return recipe
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
