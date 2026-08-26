// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

struct AnthologyBuilderOperations {
    let persistProject: (_ project: AnthologyProject) async throws -> AnthologyProject
    let prepareManifest: (_ project: AnthologyProject) async throws -> AnthologyBuildManifest
    let loadProject: (_ project: AnthologyProject) async throws -> AnthologyProject
    let loadAvailableCaptures: (_ project: AnthologyProject) async throws -> [ArticleCaptureRecord]
    let addCaptures:
        (
            _ project: AnthologyProject,
            _ captureIDs: [String]
        ) async throws -> AnthologyProject

    init(
        persistProject:
            @escaping (
                _ project: AnthologyProject
            ) async throws -> AnthologyProject,
        prepareManifest:
            @escaping (
                _ project: AnthologyProject
            ) async throws -> AnthologyBuildManifest,
        loadProject:
            @escaping (
                _ project: AnthologyProject
            ) async throws -> AnthologyProject = { $0 },
        loadAvailableCaptures:
            @escaping (
                _ project: AnthologyProject
            ) async throws -> [ArticleCaptureRecord] = { _ in [] },
        addCaptures:
            @escaping (
                _ project: AnthologyProject,
                _ captureIDs: [String]
            ) async throws -> AnthologyProject = { project, _ in project }
    ) {
        self.persistProject = persistProject
        self.prepareManifest = prepareManifest
        self.loadProject = loadProject
        self.loadAvailableCaptures = loadAvailableCaptures
        self.addCaptures = addCaptures
    }

    init(service: AnthologyService) {
        persistProject = { project in
            try await Task.detached {
                try service.saveDraft(project)
            }.value
        }
        prepareManifest = { project in
            try await Task.detached {
                try service.prepareManifest(anthologyID: project.anthology.id)
            }.value
        }
        loadProject = { project in
            try await Task.detached {
                try service.loadProject(id: project.anthology.id)
            }.value
        }
        loadAvailableCaptures = { project in
            try await Task.detached {
                try service.availableCaptures(anthologyID: project.anthology.id)
            }.value
        }
        addCaptures = { project, captureIDs in
            try await Task.detached {
                try service.addCaptures(captureIDs, to: project.anthology.id)
            }.value
        }
    }
}

nonisolated enum AnthologyBuilderAccessibilityAction: Equatable, Sendable {
    case moveUp
    case moveDown
}

nonisolated struct AnthologyEntryPolicy: Equatable, Sendable {
    let stableSlotLabel: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let accessibilityActions: [AnthologyBuilderAccessibilityAction]
    let cleanupActionTitle = "Clean Up"
}

nonisolated struct AnthologyCleanupRoute: Hashable, Sendable {
    let captureID: String
}

@MainActor
@Observable
final class AnthologyBuilderViewModel {
    enum Status: Equatable {
        case saved
        case unsaved
        case changesAvailable
        case prepared(revision: Int, changesAvailable: Bool)
    }

    var project: AnthologyProject
    private(set) var preparedManifest: AnthologyBuildManifest?
    private(set) var userMessage: String?
    private(set) var retryActionAvailable = false
    private(set) var isSaving = false
    private(set) var availableCaptures: [ArticleCaptureRecord] = []
    private(set) var isLoadingAvailableCaptures = false

    let buildActionTitle = "Build"

    @ObservationIgnored private let operations: AnthologyBuilderOperations
    @ObservationIgnored private var retryAction: (() async -> Void)?
    @ObservationIgnored private var persistenceTail: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var persistedEntryIDs: Set<String>

    init(project: AnthologyProject, operations: AnthologyBuilderOperations) {
        self.project = project
        self.operations = operations
        persistedEntryIDs = project.persistedEntryIDs
    }

    convenience init(project: AnthologyProject, service: AnthologyService) {
        self.init(
            project: project,
            operations: AnthologyBuilderOperations(service: service))
    }

    var status: Status {
        if retryActionAvailable {
            return .unsaved
        }
        if let preparedManifest {
            return .prepared(
                revision: preparedManifest.revision,
                changesAvailable: project.changesAvailable)
        }
        return project.changesAvailable ? .changesAvailable : .saved
    }

    func updateProject(
        title: String,
        subtitle: String?,
        creator: String?,
        coverPath: String?
    ) async {
        var draft = project
        draft.anthology.title = title
        draft.anthology.subtitle = subtitle
        draft.anthology.creator = creator
        draft.anthology.coverPath = coverPath
        project = draft
        preparedManifest = nil
        await save(draft)
    }

    func updateEntry(
        id: String,
        chapterTitleOverride: String?,
        narrationVoiceID: String?
    ) async {
        let draft = project.updatingEntry(
            id: id,
            chapterTitleOverride: chapterTitleOverride,
            narrationVoiceID: narrationVoiceID)
        project = draft
        preparedManifest = nil
        await save(draft)
    }

    func reorder(entryIDs: [String]) async {
        let draft = project.reordering(entryIDs: entryIDs)
        project = draft
        preparedManifest = nil
        await save(draft)
    }

    func moveUp(entryID: String) async {
        guard let index = project.entries.firstIndex(where: { $0.entry.id == entryID }),
            index > 0
        else {
            return
        }
        var ids = project.entries.map(\.entry.id)
        ids.swapAt(index, index - 1)
        await reorder(entryIDs: ids)
    }

    func moveDown(entryID: String) async {
        guard let index = project.entries.firstIndex(where: { $0.entry.id == entryID }),
            index + 1 < project.entries.count
        else {
            return
        }
        var ids = project.entries.map(\.entry.id)
        ids.swapAt(index, index + 1)
        await reorder(entryIDs: ids)
    }

    func remove(entryID: String) async {
        let draft = project.removing(entryID: entryID)
        project = draft
        preparedManifest = nil
        await save(draft)
    }

    func prepareBuild() async {
        let draft = project
        await run(
            failureMessage: "This anthology could not be prepared. Try again."
        ) { [operations] expectedEntryIDs, didPersist in
            var rebased = draft
            rebased.persistedEntryIDs = expectedEntryIDs
            let saved = try await operations.persistProject(rebased)
            didPersist(saved.persistedEntryIDs)
            let manifest = try await operations.prepareManifest(saved)
            return .prepared(saved, manifest)
        }
    }

    func loadAvailableCaptures() async {
        guard isLoadingAvailableCaptures == false else { return }
        isLoadingAvailableCaptures = true
        defer { isLoadingAvailableCaptures = false }
        let draft = project
        await run(
            failureMessage: "This anthology could not be saved. Try again."
        ) { [operations] expectedEntryIDs, didPersist in
            var rebased = draft
            rebased.persistedEntryIDs = expectedEntryIDs
            let saved = try await operations.persistProject(rebased)
            didPersist(saved.persistedEntryIDs)
            return .refreshed(saved)
        }
        guard userMessage == nil else { return }
        do {
            let captures = try await operations.loadAvailableCaptures(project)
            guard Task.isCancelled == false else { return }
            let existing = Set(project.entries.map(\.capture.id))
            availableCaptures = captures.filter { existing.contains($0.id) == false }
            userMessage = nil
        } catch is CancellationError {
            return
        } catch {
            userMessage = "Available articles could not be loaded. Try again."
        }
    }

    func addCaptures(_ captureIDs: [String]) async {
        guard captureIDs.isEmpty == false else { return }
        let draft = project
        await run(
            failureMessage: "These articles could not be added. Try again."
        ) { [operations] expectedEntryIDs, didPersist in
            var rebased = draft
            rebased.persistedEntryIDs = expectedEntryIDs
            let saved = try await operations.persistProject(rebased)
            didPersist(saved.persistedEntryIDs)
            return .saved(try await operations.addCaptures(saved, captureIDs))
        }
        let existing = Set(project.entries.map(\.capture.id))
        availableCaptures.removeAll { existing.contains($0.id) }
    }

    func refreshFromStorage() async {
        let current = project
        await run(
            failureMessage: "This anthology could not be refreshed. Try again."
        ) { [operations] expectedEntryIDs, didPersist in
            var rebased = current
            rebased.persistedEntryIDs = expectedEntryIDs
            let saved = try await operations.persistProject(rebased)
            didPersist(saved.persistedEntryIDs)
            return .saved(try await operations.loadProject(saved))
        }
    }

    func retry() async {
        await retryAction?()
    }

    func policy(for entryID: String) -> AnthologyEntryPolicy? {
        guard let index = project.entries.firstIndex(where: { $0.entry.id == entryID }) else {
            return nil
        }
        let canMoveUp = index > 0
        let canMoveDown = index + 1 < project.entries.count
        var actions: [AnthologyBuilderAccessibilityAction] = []
        if canMoveUp { actions.append(.moveUp) }
        if canMoveDown { actions.append(.moveDown) }
        return AnthologyEntryPolicy(
            stableSlotLabel: "Stable slot \(project.entries[index].entry.stableSlot)",
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            accessibilityActions: actions)
    }

    func cleanupRoute(for entryID: String) -> AnthologyCleanupRoute? {
        project.entries.first(where: { $0.entry.id == entryID }).map {
            AnthologyCleanupRoute(captureID: $0.capture.id)
        }
    }

    private enum OperationResult {
        case saved(AnthologyProject)
        case refreshed(AnthologyProject)
        case prepared(AnthologyProject, AnthologyBuildManifest)

        var project: AnthologyProject {
            switch self {
            case .saved(let project), .refreshed(let project):
                return project
            case .prepared(let project, _):
                return project
            }
        }
    }

    private func save(_ draft: AnthologyProject) async {
        await run(
            failureMessage: "This anthology could not be saved. Try again."
        ) { [operations] expectedEntryIDs, didPersist in
            var rebased = draft
            rebased.persistedEntryIDs = expectedEntryIDs
            let saved = try await operations.persistProject(rebased)
            didPersist(saved.persistedEntryIDs)
            return .saved(saved)
        }
    }

    private func run(
        failureMessage: String,
        operation:
            @escaping (
                Set<String>,
                @escaping (Set<String>) -> Void
            ) async throws -> OperationResult
    ) async {
        operationGeneration &+= 1
        let generation = operationGeneration
        let previous = persistenceTail
        retryAction = { [weak self] in
            await self?.run(
                failureMessage: failureMessage,
                operation: operation)
        }
        retryActionAvailable = false
        isSaving = true
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await operation(persistedEntryIDs) {
                    self.persistedEntryIDs = $0
                }
                persistedEntryIDs = result.project.persistedEntryIDs
                guard generation == operationGeneration else { return }
                switch result {
                case .saved(let saved):
                    project = saved
                    preparedManifest = nil
                case .refreshed(let saved):
                    project = saved
                case .prepared(let saved, let manifest):
                    project = saved
                    preparedManifest = manifest
                }
                userMessage = nil
                retryAction = nil
                retryActionAvailable = false
            } catch {
                guard generation == operationGeneration else { return }
                userMessage = failureMessage
                retryActionAvailable = true
            }
            if generation == operationGeneration {
                isSaving = false
            }
        }
        persistenceTail = task
        await task.value
    }
}
