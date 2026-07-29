// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ArticleCleanupViewModelTests {
    @Test func excludesAndRestoresBlockWithoutChangingSourceOrder() throws {
        let source = cleanupSnapshot()
        let viewModel = try makeViewModel(source: source)

        viewModel.exclude(blockID: source.blocks[1].id)

        #expect(viewModel.recipe.excludedBlockIDs == [source.blocks[1].id])
        #expect(viewModel.preview.blocks.map(\.id) == [source.blocks[0].id, source.blocks[2].id])
        #expect(viewModel.source.blocks.map(\.id) == source.blocks.map(\.id))
        #expect(viewModel.isExcluded(source.blocks[1].id))

        viewModel.restore(blockID: source.blocks[1].id)

        #expect(viewModel.recipe.excludedBlockIDs.isEmpty)
        #expect(viewModel.preview.blocks == source.blocks)
        #expect(viewModel.source.blocks == source.blocks)
    }

    @Test func trimsInclusivelyAndResolvesCrossedBoundsToSelectedBlock() throws {
        let source = cleanupSnapshot()
        let viewModel = try makeViewModel(source: source)

        viewModel.trimBefore(blockID: source.blocks[1].id)
        viewModel.trimAfter(blockID: source.blocks[2].id)

        #expect(viewModel.preview.blocks.map(\.id) == [source.blocks[1].id, source.blocks[2].id])

        viewModel.trimBefore(blockID: source.blocks[2].id)
        viewModel.trimAfter(blockID: source.blocks[0].id)

        #expect(viewModel.recipe.trimBeforeBlockID == source.blocks[0].id)
        #expect(viewModel.recipe.trimAfterBlockID == source.blocks[0].id)
        #expect(viewModel.preview.blocks.map(\.id) == [source.blocks[0].id])
    }

    @Test func correctsMetadataWithoutReplacingArticleText() throws {
        let source = cleanupSnapshot()
        let viewModel = try makeViewModel(source: source)
        let overrides = ArticleMetadataOverrides(
            title: "Corrected title",
            author: "Corrected author",
            siteName: "Corrected site",
            language: "fr",
            publishedTime: "2026-07-29")

        viewModel.updateMetadata(overrides)

        #expect(viewModel.preview.metadata.title == "Corrected title")
        #expect(viewModel.preview.metadata.author == "Corrected author")
        #expect(viewModel.preview.metadata.siteName == "Corrected site")
        #expect(viewModel.preview.metadata.language == "fr")
        #expect(viewModel.preview.metadata.publishedTime == "2026-07-29")
        #expect(viewModel.source.blocks == source.blocks)
    }

    @Test func resetReturnsToImmutableRawSnapshot() throws {
        let source = cleanupSnapshot()
        let baseline = ArticleEditRecipe(
            excludedBlockIDs: [source.blocks[0].id],
            metadataOverrides: .init(title: "Saved title"))
        let viewModel = try makeViewModel(source: source, baselineRecipe: baseline)

        viewModel.reset()

        #expect(viewModel.recipe == ArticleEditRecipe())
        #expect(viewModel.preview.blocks == source.blocks)
        #expect(viewModel.preview.metadata == source.metadata)
        #expect(viewModel.source == source)
        #expect(viewModel.hasUnsavedChanges)
    }

    @Test func saveCreatesCanonicalImmutableChildRevisionAndClearsDirtyState() throws {
        let source = cleanupSnapshot()
        let sink = CleanupRevisionSink()
        let revisionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let viewModel = try makeViewModel(
            source: source,
            expectedBaseRevisionID: "revision-parent",
            revisionID: { revisionID },
            publishRevision: sink.publish)
        viewModel.exclude(blockID: source.blocks[1].id)
        viewModel.updateMetadata(.init(title: "Corrected title"))

        let saved = try viewModel.save(deviceName: "Test iPhone")

        #expect(saved.id == revisionID.uuidString)
        #expect(saved.captureID == source.captureID.uuidString)
        #expect(saved.parentRevisionID == "revision-parent")
        #expect(saved.deviceName == "Test iPhone")
        #expect(saved.metadataOverridesJSON == #"{"title":"Corrected title"}"#)
        #expect(
            saved.recipeJSON
                == #"{"excludedBlockIDs":["article-11111111-1111-1111-1111-111111111111-b1"],"metadataOverrides":{"title":"Corrected title"}}"#
        )
        #expect(saved.readableContentSHA256 == viewModel.preview.readableContentSHA256)
        #expect(sink.expectedRevisionIDs == ["revision-parent"])
        #expect(viewModel.hasUnsavedChanges == false)

        viewModel.restore(blockID: source.blocks[1].id)
        #expect(viewModel.hasUnsavedChanges)
    }

    @Test func conflictPreservesUnsavedRecipeAndDoesNotPublishStaleSibling() throws {
        let source = cleanupSnapshot()
        let sink = CleanupRevisionSink(result: .conflict(actualCurrentRevisionID: "revision-other"))
        let viewModel = try makeViewModel(
            source: source,
            expectedBaseRevisionID: "revision-parent",
            publishRevision: sink.publish)
        viewModel.exclude(blockID: source.blocks[1].id)
        let unsaved = viewModel.recipe

        #expect {
            _ = try viewModel.save(deviceName: nil)
        } throws: { error in
            error as? ArticleCleanupViewModel.Error
                == .revisionConflict(expected: "revision-parent", actual: "revision-other")
        }

        #expect(viewModel.recipe == unsaved)
        #expect(viewModel.hasUnsavedChanges)
        #expect(viewModel.conflict != nil)
        #expect(sink.publishedRecords.isEmpty)

        viewModel.restore(blockID: source.blocks[1].id)
        #expect(
            viewModel.conflict != nil,
            "Editing after a conflict must not hide the still-unresolved database divergence.")
    }

    @Test func excludedRowsRemainAddressableAndUnknownIDsAreIgnored() throws {
        let source = cleanupSnapshot()
        let viewModel = try makeViewModel(source: source)
        viewModel.exclude(blockID: source.blocks[2].id)
        viewModel.exclude(blockID: source.blocks[0].id)
        viewModel.exclude(blockID: source.blocks[2].id)
        viewModel.exclude(blockID: "missing")

        #expect(
            viewModel.recipe.excludedBlockIDs
                == [source.blocks[0].id, source.blocks[2].id])
        #expect(viewModel.source.blocks.map(\.id) == source.blocks.map(\.id))

        viewModel.restore(blockID: source.blocks[2].id)
        #expect(viewModel.recipe.excludedBlockIDs == [source.blocks[0].id])
        #expect(viewModel.isExcluded(source.blocks[2].id) == false)
    }

    @Test func normalizesLoadedExclusionsBeforeMetadataOnlySave() throws {
        let source = cleanupSnapshot()
        let sink = CleanupRevisionSink()
        let baseline = ArticleEditRecipe(
            excludedBlockIDs: [
                source.blocks[2].id,
                source.blocks[0].id,
                source.blocks[2].id,
            ],
            trimBeforeBlockID: source.blocks[0].id,
            trimAfterBlockID: source.blocks[2].id,
            metadataOverrides: .init(title: "Saved title"))
        let viewModel = try makeViewModel(
            source: source,
            baselineRecipe: baseline,
            expectedBaseRevisionID: "revision-parent",
            publishRevision: sink.publish)

        #expect(
            viewModel.recipe.excludedBlockIDs
                == [source.blocks[0].id, source.blocks[2].id])
        #expect(viewModel.recipe.trimBeforeBlockID == source.blocks[0].id)
        #expect(viewModel.recipe.trimAfterBlockID == source.blocks[2].id)
        #expect(viewModel.recipe.metadataOverrides == baseline.metadataOverrides)
        #expect(viewModel.hasUnsavedChanges == false)
        #expect(sink.publishedRecords.isEmpty)

        viewModel.updateMetadata(.init(title: "Updated title"))
        let saved = try viewModel.save(deviceName: "Test iPhone")
        let savedRecipe = try JSONDecoder.articleWorkshop.decode(
            ArticleEditRecipe.self,
            from: Data(saved.recipeJSON.utf8))

        #expect(
            savedRecipe.excludedBlockIDs
                == [source.blocks[0].id, source.blocks[2].id])
        #expect(savedRecipe.trimBeforeBlockID == source.blocks[0].id)
        #expect(savedRecipe.trimAfterBlockID == source.blocks[2].id)
        #expect(savedRecipe.metadataOverrides.title == "Updated title")
        #expect(sink.publishedRecords == [saved])
    }

    @Test func presentsIncludedRemovedAndTrimmedRowsWithBoundaries() throws {
        let source = cleanupSnapshot(blockCount: 7)
        let viewModel = try makeViewModel(source: source)
        viewModel.trimBefore(blockID: source.blocks[1].id)
        viewModel.trimAfter(blockID: source.blocks[5].id)
        viewModel.exclude(blockID: source.blocks[3].id)

        let presentations = source.blocks.compactMap {
            viewModel.presentation(for: $0.id)
        }

        #expect(
            presentations == [
                ArticleCleanupBlockPresentation(
                    state: .trimmedAbove,
                    startsHere: false,
                    endsHere: false),
                ArticleCleanupBlockPresentation(
                    state: .included,
                    startsHere: true,
                    endsHere: false),
                ArticleCleanupBlockPresentation(
                    state: .included,
                    startsHere: false,
                    endsHere: false),
                ArticleCleanupBlockPresentation(
                    state: .explicitlyRemoved,
                    startsHere: false,
                    endsHere: false),
                ArticleCleanupBlockPresentation(
                    state: .included,
                    startsHere: false,
                    endsHere: false),
                ArticleCleanupBlockPresentation(
                    state: .included,
                    startsHere: false,
                    endsHere: true),
                ArticleCleanupBlockPresentation(
                    state: .trimmedBelow,
                    startsHere: false,
                    endsHere: false),
            ])
        #expect(
            presentations.map(\.accessibilityValue) == [
                "Trimmed above",
                "Included, starts here",
                "Included",
                "Removed",
                "Included",
                "Included, ends here",
                "Trimmed below",
            ])
    }

    @Test func mapsLoadAndSaveErrorsWithoutLeakingPrivateDiagnostics() {
        let privatePath = "/Users/reader/Private/article/snapshot.json"
        let sql = "GRDB: SELECT * FROM article_capture"
        let hostile = HostileCleanupError(message: "\(sql) at \(privatePath)")
        let conflict = ArticleCleanupViewModel.Error.revisionConflict(
            expected: "revision-private",
            actual: "revision-other")
        let messages = [
            ArticleCleanupUserMessage.load(
                ArticleCleanupLoader.Error.captureNotFound("capture-private")),
            ArticleCleanupUserMessage.load(
                ArticleCleanupLoader.Error.malformedCurrentRevision("revision-private")),
            ArticleCleanupUserMessage.load(
                ArticleWorkshopFileStore.Error.unsafeFile(
                    URL(fileURLWithPath: privatePath))),
            ArticleCleanupUserMessage.load(hostile),
            ArticleCleanupUserMessage.save(hostile),
            ArticleCleanupUserMessage.save(conflict),
        ]

        #expect(
            messages == [
                "This article is no longer available.",
                "The saved cleanup could not be read safely.",
                "The original capture could not be read safely.",
                "Cleanup could not be loaded right now. Try again.",
                "Cleanup could not be saved. Try again. Your unsaved choices remain.",
                conflict.localizedDescription,
            ])
        for message in messages {
            #expect(message.contains(privatePath) == false)
            #expect(message.contains(sql) == false)
            #expect(message.contains("revision-private") == false)
        }
    }

    @Test func retryStartsNewLoadAfterSafeFailure() async {
        let loader = ControlledCleanupLoader()
        let coordinator = ArticleCleanupLoadingCoordinator(
            loadState: loader.load,
            publishRevision: { revision, _ in .published(revision) })
        coordinator.start(captureID: "capture")
        await loader.waitForAttemptCount(1)
        await loader.fail(
            attempt: 1,
            error: HostileCleanupError(
                message: "GRDB SELECT /Users/reader/Private/snapshot.json"))
        #expect(
            await eventually {
                coordinator.userMessage == "Cleanup could not be loaded right now. Try again."
            })

        coordinator.retry()
        await loader.waitForAttemptCount(2)
        await loader.succeed(
            attempt: 2,
            state: ArticleCleanupLoadedState(
                source: cleanupSnapshot(title: "Retry result"),
                baselineRecipe: ArticleEditRecipe(),
                expectedBaseRevisionID: nil))

        #expect(
            await eventually {
                coordinator.viewModel?.source.metadata.title == "Retry result"
            })
        #expect(await loader.attemptCount == 2)
        #expect(coordinator.userMessage == nil)
    }

    @Test func staleCancelledLoadCannotOverwriteRetryResult() async {
        let loader = ControlledCleanupLoader()
        let coordinator = ArticleCleanupLoadingCoordinator(
            loadState: loader.load,
            publishRevision: { revision, _ in .published(revision) })
        coordinator.start(captureID: "capture")
        await loader.waitForAttemptCount(1)

        coordinator.retry()
        await loader.waitForAttemptCount(2)
        await loader.succeed(
            attempt: 2,
            state: ArticleCleanupLoadedState(
                source: cleanupSnapshot(title: "New result"),
                baselineRecipe: ArticleEditRecipe(),
                expectedBaseRevisionID: nil))
        #expect(
            await eventually {
                coordinator.viewModel?.source.metadata.title == "New result"
            })

        await loader.succeed(
            attempt: 1,
            state: ArticleCleanupLoadedState(
                source: cleanupSnapshot(title: "Stale result"),
                baselineRecipe: ArticleEditRecipe(),
                expectedBaseRevisionID: nil))
        for _ in 0..<200 {
            if await loader.finishedAttemptCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(coordinator.viewModel?.source.metadata.title == "New result")
        #expect(await loader.attemptCount == 2)
        #expect(await loader.finishedAttemptCount == 2)
    }

    @Test func loaderUsesCurrentRecipeAndRejectsMalformedOrForeignRevision() async throws {
        let fixture = try CleanupLoaderFixture()
        defer { fixture.removeFiles() }
        let source = try fixture.installCapture()
        let recipe = ArticleEditRecipe(
            excludedBlockIDs: [source.blocks[1].id],
            metadataOverrides: .init(title: "Saved cleanup"))
        try fixture.saveCurrentRevision(
            id: "revision-current",
            captureID: source.captureID.uuidString,
            recipeJSON: try canonicalJSONString(recipe),
            metadataOverridesJSON: try canonicalJSONString(recipe.metadataOverrides))

        let loaded = try await fixture.loader.load(captureID: source.captureID.uuidString)

        #expect(loaded.source == source)
        #expect(loaded.baselineRecipe == recipe)
        #expect(loaded.expectedBaseRevisionID == "revision-current")

        try fixture.replaceCurrentRevision(
            id: "revision-malformed",
            captureID: source.captureID.uuidString,
            recipeJSON: "{malformed",
            metadataOverridesJSON: "{}")
        await #expect(throws: ArticleCleanupLoader.Error.self) {
            _ = try await fixture.loader.load(captureID: source.captureID.uuidString)
        }

        let foreignCaptureID = UUID().uuidString
        try fixture.installForeignCapture(id: foreignCaptureID)
        try fixture.replaceCurrentRevision(
            id: "revision-foreign",
            captureID: foreignCaptureID,
            recipeJSON: try canonicalJSONString(ArticleEditRecipe()),
            metadataOverridesJSON: "{}")
        await #expect(throws: ArticleCleanupLoader.Error.self) {
            _ = try await fixture.loader.load(captureID: source.captureID.uuidString)
        }
    }

    @Test func cleanupSurfaceHasStructuralAndAccessibleActionsWithoutProseEditor() throws {
        let viewSource = try projectSource(
            "EchoCore/Views/ArticleWorkshop/ArticleCleanupView.swift")
        let modelSource = try projectSource(
            "EchoCore/ViewModels/ArticleCleanupViewModel.swift")

        #expect(viewSource.contains("Trim everything above"))
        #expect(viewSource.contains("Trim everything below"))
        #expect(viewSource.contains(".accessibilityAction"))
        #expect(viewSource.contains("frame(minHeight: 44"))
        #expect(viewSource.contains("TextEditor") == false)
        #expect(viewSource.contains("Newer revision:") == false)
        #expect(modelSource.contains("replaceText") == false)
        #expect(modelSource.contains("updateBlockText") == false)
    }

    private func makeViewModel(
        source: ArticleSnapshot,
        baselineRecipe: ArticleEditRecipe = .init(),
        expectedBaseRevisionID: String? = nil,
        revisionID: @escaping @Sendable () -> UUID = { UUID() },
        publishRevision: @escaping ArticleRevisionPublisher = { revision, _ in
            .published(revision)
        }
    ) throws -> ArticleCleanupViewModel {
        try ArticleCleanupViewModel(
            source: source,
            baselineRecipe: baselineRecipe,
            expectedBaseRevisionID: expectedBaseRevisionID,
            revisionID: revisionID,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            publishRevision: publishRevision)
    }

    private func projectSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private nonisolated final class CleanupRevisionSink: @unchecked Sendable {
    private let lock = NSLock()
    private let result: ArticleRevisionPublicationResult?
    private(set) var expectedRevisionIDs: [String?] = []
    private(set) var publishedRecords: [ArticleRevisionRecord] = []

    init(result: ArticleRevisionPublicationResult? = nil) {
        self.result = result
    }

    func publish(
        _ revision: ArticleRevisionRecord,
        expectedCurrentRevisionID: String?
    ) throws -> ArticleRevisionPublicationResult {
        lock.lock()
        defer { lock.unlock() }
        expectedRevisionIDs.append(expectedCurrentRevisionID)
        if let result { return result }
        publishedRecords.append(revision)
        return .published(revision)
    }
}

private nonisolated struct HostileCleanupError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private actor ControlledCleanupLoader {
    private var nextAttempt = 0
    private var pending: [Int: CheckedContinuation<ArticleCleanupLoadedState, any Error>] = [:]
    private var attemptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var finishedAttemptCount = 0

    var attemptCount: Int { nextAttempt }

    func load(_ captureID: String) async throws -> ArticleCleanupLoadedState {
        nextAttempt += 1
        let attempt = nextAttempt
        let state = try await withCheckedThrowingContinuation { continuation in
            pending[attempt] = continuation
            releaseAttemptWaiters()
        }
        finishedAttemptCount += 1
        return state
    }

    func waitForAttemptCount(_ count: Int) async {
        guard nextAttempt < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append((count, continuation))
        }
    }

    func succeed(attempt: Int, state: ArticleCleanupLoadedState) {
        pending.removeValue(forKey: attempt)?.resume(returning: state)
    }

    func fail(attempt: Int, error: any Error) {
        pending.removeValue(forKey: attempt)?.resume(throwing: error)
    }

    private func releaseAttemptWaiters() {
        let ready = attemptWaiters.filter { $0.count <= nextAttempt }
        attemptWaiters.removeAll { $0.count <= nextAttempt }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private struct CleanupLoaderFixture {
    let root: URL
    let database: DatabaseService
    let captureDAO: ArticleCaptureDAO
    let fileStore: ArticleWorkshopFileStore
    let loader: ArticleCleanupLoader

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "ArticleCleanupLoaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseService(inMemory: ())
        captureDAO = ArticleCaptureDAO(db: database.writer)
        fileStore = ArticleWorkshopFileStore(
            root: root.appending(path: "Workshop", directoryHint: .isDirectory))
        loader = ArticleCleanupLoader(captureDAO: captureDAO, fileStore: fileStore)
    }

    func installCapture() throws -> ArticleSnapshot {
        let captureID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let envelope = articleWorkshopFixtureEnvelope(
            captureID: captureID,
            title: "Original title",
            contentXHTML: "<article><p>First</p><p>Second</p><p>Third</p></article>")
        let staging = root.appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let package = try ArticleCaptureStagingWriter(root: staging).stage(envelope)
        let imported = try fileStore.importEnvelope(at: package)
        try captureDAO.saveCapture(
            ArticleCaptureRecord(
                id: captureID.uuidString,
                sourceURL: envelope.payload.sourceURL,
                canonicalURL: envelope.payload.canonicalURL,
                title: "Original title",
                author: envelope.payload.byline,
                siteName: envelope.payload.siteName,
                language: envelope.payload.language,
                publishedAt: envelope.payload.publishedTime,
                capturedAt: "2026-07-29T00:00:00Z",
                captureMethod: envelope.method,
                packagePath: "/untrusted/database/path",
                contentSHA256: imported.sha256,
                extractorVersion: "1",
                contentState: "ready",
                warningsJSON: "[]",
                currentRevisionID: nil,
                createdAt: "2026-07-29T00:00:00Z",
                modifiedAt: "2026-07-29T00:00:00Z"))
        return try ArticleBlockSanitizer().sanitize(envelope: envelope)
    }

    func saveCurrentRevision(
        id: String,
        captureID: String,
        recipeJSON: String,
        metadataOverridesJSON: String
    ) throws {
        try captureDAO.saveRevision(
            ArticleRevisionRecord(
                id: id,
                captureID: captureID,
                parentRevisionID: nil,
                metadataOverridesJSON: metadataOverridesJSON,
                recipeJSON: recipeJSON,
                readableContentSHA256: "fixture",
                createdAt: "2026-07-29T00:00:00Z",
                deviceName: "Test"),
            makeCurrent: true)
    }

    func installForeignCapture(id: String) throws {
        try captureDAO.saveCapture(
            ArticleCaptureRecord(
                id: id,
                sourceURL: "https://example.test/foreign",
                canonicalURL: "https://example.test/foreign",
                title: "Foreign",
                author: nil,
                siteName: nil,
                language: "en",
                publishedAt: nil,
                capturedAt: "2026-07-29T00:00:00Z",
                captureMethod: .urlFetch,
                packagePath: "/foreign",
                contentSHA256: "foreign",
                extractorVersion: "1",
                contentState: "ready",
                warningsJSON: "[]",
                currentRevisionID: nil,
                createdAt: "2026-07-29T00:00:00Z",
                modifiedAt: "2026-07-29T00:00:00Z"))
    }

    func replaceCurrentRevision(
        id: String,
        captureID: String,
        recipeJSON: String,
        metadataOverridesJSON: String
    ) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM article_revision")
            try db.execute(
                sql: """
                    INSERT INTO article_revision
                        (id, capture_id, parent_revision_id, metadata_overrides_json, recipe_json,
                         readable_content_sha256, created_at, device_name)
                    VALUES (?, ?, NULL, ?, ?, 'fixture', '2026-07-29T00:00:00Z', 'Test')
                    """,
                arguments: [id, captureID, metadataOverridesJSON, recipeJSON])
            try db.execute(
                sql: "UPDATE article_capture SET current_revision_id = ?",
                arguments: [id])
        }
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func cleanupSnapshot(
    title: String = "Original title",
    blockCount: Int = 3
) -> ArticleSnapshot {
    let captureID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let blocks = (0..<blockCount).map { ordinal in
        let text: String
        switch ordinal {
        case 0: text = "Heading"
        case 1: text = "First"
        case 2: text = "Second"
        default: text = "Block \(ordinal)"
        }
        return cleanupBlock(
            captureID: captureID,
            ordinal: ordinal,
            kind: ordinal == 0 ? .heading : .paragraph,
            text: text)
    }
    return ArticleSnapshot(
        captureID: captureID,
        metadata: ArticleMetadata(
            title: title,
            author: "Original author",
            siteName: "Original site",
            language: "en",
            publishedTime: "2026-07-28"),
        blocks: blocks,
        warnings: [],
        contentState: .ready,
        snapshotSHA256: "fixture")
}

private func cleanupBlock(
    captureID: UUID,
    ordinal: Int,
    kind: ArticleBlockKind,
    text: String
) -> ArticleBlock {
    ArticleBlock(
        id: "article-\(captureID.uuidString.lowercased())-b\(ordinal)",
        stableOrdinal: ordinal,
        kind: kind,
        text: text,
        sourceURL: nil,
        imageCandidateURL: nil,
        caption: nil,
        codeLanguage: nil)
}

private func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder.articleWorkshop
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
