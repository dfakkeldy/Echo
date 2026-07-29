// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct AnthologyBuilderViewModelTests {
    @Test func metadataEntryVoiceReorderAndRemovePersistBeforePublishingState() async throws {
        let sink = AnthologyBuilderSink()
        let project = builderProject()
        let viewModel = AnthologyBuilderViewModel(
            project: project,
            operations: sink.operations)

        await viewModel.updateProject(
            title: "Edited",
            subtitle: "Subtitle",
            creator: "Creator",
            coverPath: "cover.png")
        await viewModel.updateEntry(
            id: project.entries[0].entry.id,
            chapterTitleOverride: "Opening",
            narrationVoiceID: "af_heart")
        await viewModel.moveDown(entryID: project.entries[0].entry.id)
        await viewModel.remove(entryID: project.entries[0].entry.id)

        #expect(sink.events == ["persist", "persist", "persist", "persist"])
        #expect(viewModel.project.anthology.title == "Edited")
        #expect(viewModel.project.entries.map(\.entry.id) == [project.entries[1].entry.id])
        #expect(viewModel.userMessage == nil)
    }

    @Test func failedImmediateSaveKeepsVisibleDraftAndOffersSafeRetry() async {
        let sink = AnthologyBuilderSink(failPersist: true)
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: sink.operations)

        await viewModel.updateProject(
            title: "Unsaved Draft",
            subtitle: nil,
            creator: nil,
            coverPath: nil)

        #expect(viewModel.project.anthology.title == "Unsaved Draft")
        #expect(viewModel.userMessage == "This anthology could not be saved. Try again.")
        #expect(viewModel.retryActionAvailable)
        #expect(viewModel.status != .saved)
    }

    @Test func buildIsExplicitAndPreparedRevisionIsVisibleWithoutClearingChangesFlag() async {
        let sink = AnthologyBuilderSink()
        var project = builderProject()
        project.changesAvailable = true
        let viewModel = AnthologyBuilderViewModel(project: project, operations: sink.operations)

        #expect(viewModel.preparedManifest == nil)
        #expect(viewModel.status == .changesAvailable)

        await viewModel.prepareBuild()

        #expect(sink.events == ["persist", "build"])
        #expect(viewModel.preparedManifest?.revision == 4)
        #expect(viewModel.status == .prepared(revision: 4, changesAvailable: true))
    }

    @Test func moveAccessibilityActionsHaveDragParityAndStableSlotLabels() async {
        let sink = AnthologyBuilderSink()
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: sink.operations)
        let firstID = viewModel.project.entries[0].entry.id

        #expect(viewModel.policy(for: firstID)?.stableSlotLabel == "Stable slot 3")
        #expect(viewModel.policy(for: firstID)?.canMoveUp == false)
        #expect(viewModel.policy(for: firstID)?.canMoveDown == true)
        #expect(viewModel.policy(for: firstID)?.accessibilityActions == [.moveDown])

        await viewModel.moveDown(entryID: firstID)
        await viewModel.moveUp(entryID: firstID)

        #expect(sink.events == ["persist", "persist"])
    }

    @Test func policyKeepsBuildAndCleanupAsNamedReachableActions() {
        let sink = AnthologyBuilderSink()
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: sink.operations)
        let entryID = viewModel.project.entries[0].entry.id

        #expect(viewModel.buildActionTitle == "Build")
        #expect(
            viewModel.cleanupRoute(for: entryID)?.captureID
                == viewModel.project.entries[0].capture.id)
        #expect(viewModel.policy(for: entryID)?.cleanupActionTitle == "Clean Up")
    }

    @Test func listViewModelLoadsProjectsAndUsesSafeFailureMessage() async {
        let project = builderProject()
        let success = AnthologyListViewModel(load: { [project.anthology] })
        await success.reload()
        #expect(success.projects == [project.anthology])
        #expect(success.userMessage == nil)

        let failure = AnthologyListViewModel(load: { throw BuilderFixtureError.expected })
        await failure.reload()
        #expect(failure.projects.isEmpty)
        #expect(failure.userMessage == "Anthologies could not be loaded. Try again.")
        failure.dismissMessage()
        #expect(failure.userMessage == nil)
    }

    @Test func olderListReloadCannotOverwriteNewerProjectsOrLoadingState() async {
        let gate = ControlledAnthologyListLoad()
        let viewModel = AnthologyListViewModel {
            try await gate.load()
        }
        let old = builderProject().anthology
        var new = old
        new.title = "Newest Title"

        let first = Task { await viewModel.reload() }
        await gate.waitForStartCount(1)
        let second = Task { await viewModel.reload() }
        await gate.waitForStartCount(2)
        await gate.release(index: 1, projects: [new])
        await second.value
        #expect(viewModel.projects == [new])
        #expect(viewModel.isLoading == false)

        await gate.release(index: 0, projects: [old])
        await first.value
        #expect(viewModel.projects == [new])
        #expect(viewModel.isLoading == false)
    }

    @Test func overlappingImmediateSavesRunInOrderAndLatestDraftRemainsAuthoritative() async {
        let gate = ControlledBuilderSave()
        let operations = AnthologyBuilderOperations(
            persistProject: { project in
                await gate.persist(project)
            },
            prepareManifest: { project in
                builderManifest(anthologyID: project.anthology.id)
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)

        let first = Task {
            await viewModel.updateProject(
                title: "First",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await gate.waitForStartCount(1)
        let second = Task {
            await viewModel.updateProject(
                title: "Second",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(await gate.startedTitles == ["First"])
        await gate.release(title: "First")
        await gate.waitForStartCount(2)
        await gate.release(title: "Second")
        _ = await (first.value, second.value)

        #expect(await gate.startedTitles == ["First", "Second"])
        #expect(viewModel.project.anthology.title == "Second")
        #expect(viewModel.userMessage == nil)
    }

    @Test func laterCompositeSavePreservesAnEarlierFailedEdit() async {
        let store = FailingFirstCompositeStore()
        let operations = AnthologyBuilderOperations(
            persistProject: { project in
                try await store.persist(project)
            },
            prepareManifest: { project in
                builderManifest(anthologyID: project.anthology.id)
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)
        let entryID = viewModel.project.entries[0].entry.id

        let metadata = Task {
            await viewModel.updateProject(
                title: "Recovered Metadata",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await store.waitForFirstAttempt()
        let entry = Task {
            await viewModel.updateEntry(
                id: entryID,
                chapterTitleOverride: "Recovered Chapter",
                narrationVoiceID: "af_heart")
        }
        await store.releaseFirstFailure()
        _ = await (metadata.value, entry.value)

        let saved = await store.savedProject
        #expect(saved?.anthology.title == "Recovered Metadata")
        #expect(saved?.entries[0].entry.chapterTitleOverride == "Recovered Chapter")
        #expect(saved?.entries[0].entry.narrationVoiceID == "af_heart")
        #expect(viewModel.userMessage == nil)
    }

    @Test func queuedEditRebasesMembershipAfterLocalRemovalSave() async {
        let store = ControlledMembershipSave()
        let operations = AnthologyBuilderOperations(
            persistProject: { try await store.persist($0) },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            })
        let original = builderProject()
        let removedID = original.entries[0].entry.id
        let remainingID = original.entries[1].entry.id
        let viewModel = AnthologyBuilderViewModel(
            project: original,
            operations: operations)

        let removal = Task {
            await viewModel.remove(entryID: removedID)
        }
        await store.waitForStartCount(1)
        let edit = Task {
            await viewModel.updateProject(
                title: "After Removal",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await store.release(index: 0)
        await store.waitForStartCount(2)
        #expect(await store.expectedEntryIDs(at: 1) == [remainingID])
        await store.release(index: 1)
        _ = await (removal.value, edit.value)

        #expect(viewModel.project.entries.map(\.entry.id) == [remainingID])
        #expect(viewModel.project.anthology.title == "After Removal")
        #expect(viewModel.userMessage == nil)
    }

    @Test func downstreamBuildFailureKeepsSuccessfulPersistenceMembership() async {
        let store = CompoundPersistenceStore()
        let operations = AnthologyBuilderOperations(
            persistProject: { try await store.persist($0) },
            prepareManifest: { _ in throw BuilderFixtureError.expected })
        let original = builderProject()
        let remainingID = original.entries[1].entry.id
        let viewModel = AnthologyBuilderViewModel(
            project: original,
            operations: operations)

        await viewModel.remove(entryID: original.entries[0].entry.id)
        #expect(viewModel.retryActionAvailable)
        await viewModel.prepareBuild()
        #expect(viewModel.retryActionAvailable)
        await viewModel.updateProject(
            title: "Recover After Prepare Failure",
            subtitle: nil,
            creator: nil,
            coverPath: nil)

        #expect(
            await store.expectedMemberships == [
                Set(original.entries.map(\.entry.id)),
                Set(original.entries.map(\.entry.id)),
                [remainingID],
            ])
        #expect(viewModel.userMessage == nil)
    }

    @Test func buildPersistsVisibleDraftAfterFailedSaveBeforePreparing() async {
        let store = FailingFirstCompositeStore()
        let operations = AnthologyBuilderOperations(
            persistProject: { project in
                try await store.persist(project)
            },
            prepareManifest: { project in
                let saved = await store.savedProject
                #expect(saved == project)
                return builderManifest(anthologyID: project.anthology.id)
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)

        let failedSave = Task {
            await viewModel.updateProject(
                title: "Visible Unsaved Draft",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await store.waitForFirstAttempt()
        await store.releaseFirstFailure()
        await failedSave.value
        #expect(viewModel.retryActionAvailable)

        await viewModel.prepareBuild()

        #expect(await store.savedProject?.anthology.title == "Visible Unsaved Draft")
        #expect(viewModel.preparedManifest?.revision == 4)
        #expect(viewModel.userMessage == nil)
    }

    @Test func editQueuedAfterBuildClearsTheNowStalePreparedResult() async {
        let gate = ControlledBuilderSave()
        let operations = AnthologyBuilderOperations(
            persistProject: { project in
                await gate.persist(project)
            },
            prepareManifest: { project in
                builderManifest(anthologyID: project.anthology.id)
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)

        let build = Task { await viewModel.prepareBuild() }
        await gate.waitForStartCount(1)
        let edit = Task {
            await viewModel.updateProject(
                title: "Edited After Build",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await gate.release(title: "Draft")
        await gate.waitForStartCount(2)
        await gate.release(title: "Edited After Build")
        _ = await (build.value, edit.value)

        #expect(viewModel.project.anthology.title == "Edited After Build")
        #expect(viewModel.preparedManifest == nil)
    }

    @Test func existingAnthologyCanLoadAndAddEligibleInboxArticles() async {
        let candidate = builderEntry(
            entryID: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            captureID: "33333333-3333-3333-3333-333333333333",
            anthologyID: builderProject().anthology.id,
            order: 2,
            stableSlot: 9,
            title: "Third")
        let operations = AnthologyBuilderOperations(
            persistProject: { $0 },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            },
            loadProject: { $0 },
            loadAvailableCaptures: { _ in [candidate.capture] },
            addCaptures: { project, captureIDs in
                #expect(captureIDs == [candidate.capture.id])
                var added = project
                added.entries.append(candidate)
                added.anthology.nextStableSlot = 10
                return added
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)

        await viewModel.loadAvailableCaptures()
        #expect(viewModel.availableCaptures == [candidate.capture])

        await viewModel.addCaptures([candidate.capture.id])
        #expect(viewModel.project.entries.last?.capture.id == candidate.capture.id)
        #expect(viewModel.project.entries.last?.entry.stableSlot == 9)
        #expect(viewModel.availableCaptures.isEmpty)
    }

    @Test func openingArticlePickerDoesNotClearPreparedEditionWhenNoEditOccurs() async {
        let operations = AnthologyBuilderOperations(
            persistProject: { $0 },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            },
            loadAvailableCaptures: { _ in [] })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)
        await viewModel.prepareBuild()
        let prepared = viewModel.preparedManifest

        await viewModel.loadAvailableCaptures()

        #expect(viewModel.preparedManifest == prepared)
    }

    @Test func refreshAfterCleanupReloadsLatestArticleRevision() async {
        var refreshed = builderProject()
        refreshed.entries[0].entry.chapterTitleOverride = "Latest Cleanup Revision"
        let operations = AnthologyBuilderOperations(
            persistProject: { $0 },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            },
            loadProject: { _ in refreshed })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)

        await viewModel.refreshFromStorage()

        #expect(
            viewModel.project.entries[0].entry.chapterTitleOverride
                == "Latest Cleanup Revision")
    }

    @Test func addAfterFailedSaveRecoversVisibleDraftBeforeAppending() async {
        let store = FailingFirstCompositeStore()
        let candidate = builderEntry(
            entryID: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            captureID: "33333333-3333-3333-3333-333333333333",
            anthologyID: builderProject().anthology.id,
            order: 2,
            stableSlot: 9,
            title: "Third")
        let operations = AnthologyBuilderOperations(
            persistProject: { try await store.persist($0) },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            },
            addCaptures: { project, _ in
                #expect(
                    await store.savedProject?.anthology.title
                        == "Visible Failed Draft")
                var added = project
                added.entries.append(candidate)
                return added
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)
        let failedSave = Task {
            await viewModel.updateProject(
                title: "Visible Failed Draft",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await store.waitForFirstAttempt()
        await store.releaseFirstFailure()
        await failedSave.value

        await viewModel.addCaptures([candidate.capture.id])

        #expect(viewModel.project.anthology.title == "Visible Failed Draft")
        #expect(viewModel.project.entries.last?.capture.id == candidate.capture.id)
    }

    @Test func refreshAfterFailedSaveRecoversVisibleDraftBeforeReloading() async {
        let store = FailingFirstCompositeStore()
        let operations = AnthologyBuilderOperations(
            persistProject: { try await store.persist($0) },
            prepareManifest: {
                builderManifest(anthologyID: $0.anthology.id)
            },
            loadProject: { project in
                #expect(
                    await store.savedProject?.anthology.title
                        == "Visible Failed Draft")
                return project
            })
        let viewModel = AnthologyBuilderViewModel(
            project: builderProject(),
            operations: operations)
        let failedSave = Task {
            await viewModel.updateProject(
                title: "Visible Failed Draft",
                subtitle: nil,
                creator: nil,
                coverPath: nil)
        }
        await store.waitForFirstAttempt()
        await store.releaseFirstFailure()
        await failedSave.value

        await viewModel.refreshFromStorage()

        #expect(viewModel.project.anthology.title == "Visible Failed Draft")
        #expect(viewModel.userMessage == nil)
    }

    @Test func builderPresentationKeepsDragAddAndStableSlotPreviewReachable() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "EchoCore/Views/ArticleWorkshop/AnthologyBuilderView.swift"),
            encoding: .utf8)

        #expect(source.contains(".onMove"))
        #expect(source.contains("EditButton"))
        #expect(source.contains("Add Articles"))
        #expect(source.contains("Table of Contents Preview"))
        #expect(source.contains("stableSlot"))
        #expect(source.contains("Using Chosen Image"))
        #expect(source.contains("Using \\(filename)") == false)

        let listSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "EchoCore/Views/ArticleWorkshop/AnthologyListView.swift"),
            encoding: .utf8)
        #expect(listSource.contains(".onAppear"))
    }
}

private actor ControlledAnthologyListLoad {
    private var startCount = 0
    private var continuations: [Int: CheckedContinuation<[AnthologyRecord], any Swift.Error>] = [:]

    func load() async throws -> [AnthologyRecord] {
        let index = startCount
        startCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForStartCount(_ count: Int) async {
        while startCount < count {
            await Task.yield()
        }
    }

    func release(index: Int, projects: [AnthologyRecord]) {
        continuations.removeValue(forKey: index)?.resume(returning: projects)
    }
}

private actor ControlledMembershipSave {
    private var projects: [AnthologyProject] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func persist(_ project: AnthologyProject) async throws -> AnthologyProject {
        let index = projects.count
        projects.append(project)
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
        var saved = project
        saved.persistedEntryIDs = Set(saved.entries.map(\.entry.id))
        return saved
    }

    func waitForStartCount(_ count: Int) async {
        while projects.count < count {
            await Task.yield()
        }
    }

    func expectedEntryIDs(at index: Int) -> Set<String>? {
        projects.indices.contains(index) ? projects[index].persistedEntryIDs : nil
    }

    func release(index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }
}

private actor CompoundPersistenceStore {
    private(set) var expectedMemberships: [Set<String>] = []

    func persist(_ project: AnthologyProject) throws -> AnthologyProject {
        expectedMemberships.append(project.persistedEntryIDs)
        if expectedMemberships.count == 1 {
            throw BuilderFixtureError.expected
        }
        var saved = project
        saved.persistedEntryIDs = Set(saved.entries.map(\.entry.id))
        return saved
    }
}

private actor ControlledBuilderSave {
    private var started: [String] = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    var startedTitles: [String] {
        started
    }

    func persist(_ project: AnthologyProject) async -> AnthologyProject {
        let title = project.anthology.title
        started.append(title)
        await withCheckedContinuation { continuation in
            continuations[title] = continuation
        }
        return project
    }

    func waitForStartCount(_ count: Int) async {
        while started.count < count {
            await Task.yield()
        }
    }

    func release(title: String) {
        continuations.removeValue(forKey: title)?.resume()
    }
}

private actor FailingFirstCompositeStore {
    private var attemptCount = 0
    private var firstAttemptStarted = false
    private var firstFailureContinuation: CheckedContinuation<Void, Never>?
    private(set) var savedProject: AnthologyProject?

    func persist(_ project: AnthologyProject) async throws -> AnthologyProject {
        attemptCount += 1
        if attemptCount == 1 {
            firstAttemptStarted = true
            await withCheckedContinuation { continuation in
                firstFailureContinuation = continuation
            }
            throw BuilderFixtureError.expected
        }
        savedProject = project
        return project
    }

    func waitForFirstAttempt() async {
        while firstAttemptStarted == false {
            await Task.yield()
        }
    }

    func releaseFirstFailure() {
        firstFailureContinuation?.resume()
        firstFailureContinuation = nil
    }
}

@MainActor
private final class AnthologyBuilderSink {
    var events: [String] = []
    let failPersist: Bool

    init(failPersist: Bool = false) {
        self.failPersist = failPersist
    }

    var operations: AnthologyBuilderOperations {
        AnthologyBuilderOperations(
            persistProject: { [weak self] project in
                guard let self else { throw BuilderFixtureError.expected }
                try record("persist")
                return project
            },
            prepareManifest: { [weak self] project in
                guard let self else { throw BuilderFixtureError.expected }
                try record("build")
                return builderManifest(anthologyID: project.anthology.id)
            })
    }

    private func record(_ event: String) throws {
        events.append(event)
        if failPersist, event == "persist" {
            throw BuilderFixtureError.expected
        }
    }
}

private enum BuilderFixtureError: Swift.Error {
    case expected
}

private func builderProject() -> AnthologyProject {
    let anthologyID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let first = builderEntry(
        entryID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        captureID: "11111111-1111-1111-1111-111111111111",
        anthologyID: anthologyID,
        order: 0,
        stableSlot: 3,
        title: "First")
    let second = builderEntry(
        entryID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
        captureID: "22222222-2222-2222-2222-222222222222",
        anthologyID: anthologyID,
        order: 1,
        stableSlot: 8,
        title: "Second")
    return AnthologyProject(
        anthology: AnthologyRecord(
            id: anthologyID,
            title: "Draft",
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: 9,
            latestBuildRevision: 3,
            createdAt: "2026-07-29T10:00:00Z",
            modifiedAt: "2026-07-29T10:00:00Z"),
        entries: [first, second],
        persistedEntryIDs: [first.entry.id, second.entry.id],
        latestSuccessfulBuild: nil,
        changesAvailable: false)
}

private func builderEntry(
    entryID: String,
    captureID: String,
    anthologyID: String,
    order: Int,
    stableSlot: Int,
    title: String
) -> AnthologyProjectEntry {
    AnthologyProjectEntry(
        entry: AnthologyEntryRecord(
            id: entryID,
            anthologyID: anthologyID,
            captureID: captureID,
            sortOrder: order,
            stableSlot: stableSlot,
            chapterTitleOverride: nil,
            narrationVoiceID: nil),
        capture: ArticleCaptureRecord(
            id: captureID,
            sourceURL: "https://example.test/\(captureID)",
            canonicalURL: nil,
            title: title,
            author: nil,
            siteName: "Example",
            language: "en",
            publishedAt: nil,
            capturedAt: "2026-07-29T10:00:00Z",
            captureMethod: .urlFetch,
            packagePath: "/managed/\(captureID)",
            contentSHA256: "fixture",
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-29T10:00:00Z",
            modifiedAt: "2026-07-29T10:00:00Z"),
        revision: nil,
        cleanArticle: nil)
}

private func builderManifest(anthologyID: String) -> AnthologyBuildManifest {
    AnthologyBuildManifest(
        schemaVersion: 1,
        anthologyID: UUID(uuidString: anthologyID)!,
        revision: 4,
        epubIdentifier: "urn:uuid:\(anthologyID)",
        title: "Draft",
        subtitle: nil,
        creator: "Various Authors",
        language: "und",
        coverPath: nil,
        modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
        chapters: [])
}
