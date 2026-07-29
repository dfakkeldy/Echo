// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyLibraryIntegrationTests {
    @Test func generatedAnthologyImportsThroughEchoCoordinatorWithStableIdentity() async throws {
        let fixture = try AnthologyLibraryIntegrationFixture()
        defer { fixture.removeFiles() }
        let networkRequests = LockedNetworkRequestCounter()
        try fixture.seedDatalessSidecarPlaceholder()

        let receipt = try await fixture.service(
            networkRequests: networkRequests
        ).build(
            anthologyID: fixture.anthologyID.uuidString)

        #expect(receipt.audiobookID == fixture.audiobookID)
        #expect(receipt.epubPath == fixture.finalURL.path)
        #expect(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        let audiobook = try #require(try fixture.audiobookDAO.get(fixture.audiobookID))
        #expect(audiobook.title == fixture.manifest.title)
        #expect(audiobook.author == fixture.manifest.creator)
        #expect(audiobook.coverArtPath == fixture.managedCoverURL.path)
        #expect(audiobook.textOrigin == "epub")
        #expect(try fixture.importedBlockCount() > 0)
        #expect(
            try EPubTOCEntryDAO(db: fixture.database.writer)
                .entries(for: fixture.audiobookID)
                .contains { $0.title == "A Coordinator Chapter" })
        #expect(networkRequests.count == 0)
    }

    @Test func lateRealCoordinatorFailureRestoresPriorEditionAndImport() async throws {
        let fixture = try AnthologyLibraryIntegrationFixture()
        defer { fixture.removeFiles() }
        let networkRequests = LockedNetworkRequestCounter()
        let first = try await fixture.service(
            networkRequests: networkRequests
        ).build(
            anthologyID: fixture.anthologyID.uuidString)
        let priorBytes = try Data(contentsOf: fixture.finalURL)
        let priorAudiobook = try #require(
            try fixture.audiobookDAO.get(fixture.audiobookID))
        let priorBlocks = try fixture.importedBlockEvidence()

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(
                manifest: fixture.revisedManifest(),
                failSuccessfulReceipt: true,
                networkRequests: networkRequests
            ).build(anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: fixture.finalURL) == priorBytes)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == first)
        let restoredAudiobook = try #require(
            try fixture.audiobookDAO.get(fixture.audiobookID))
        #expect(restoredAudiobook.title == priorAudiobook.title)
        #expect(restoredAudiobook.author == priorAudiobook.author)
        #expect(restoredAudiobook.coverArtPath == priorAudiobook.coverArtPath)
        let restoredBlocks = try fixture.importedBlockEvidence()
        #expect(restoredBlocks.count == priorBlocks.count)
        for (restored, prior) in zip(restoredBlocks, priorBlocks) {
            #expect(restored.id == prior.id)
            #expect(restored.audiobookID == prior.audiobookID)
            #expect(restored.spineHref == prior.spineHref)
            #expect(restored.spineIndex == prior.spineIndex)
            #expect(restored.blockIndex == prior.blockIndex)
            #expect(restored.sequenceIndex == prior.sequenceIndex)
            #expect(restored.blockKind == prior.blockKind)
            #expect(restored.text == prior.text)
            #expect(restored.htmlContent == prior.htmlContent)
            #expect(restored.cardColor == prior.cardColor)
            #expect(restored.chapterThemeColor == prior.chapterThemeColor)
            #expect(restored.imagePath == prior.imagePath)
            #expect(restored.chapterIndex == prior.chapterIndex)
            #expect(restored.isHidden == prior.isHidden)
            #expect(restored.hiddenReason == prior.hiddenReason)
            #expect(restored.isFrontMatter == prior.isFrontMatter)
            #expect(restored.wordCount == prior.wordCount)
            #expect(restored.markers == prior.markers)
            #expect(restored.textFormats == prior.textFormats)
            #expect(restored.narrationText == prior.narrationText)
            #expect(restored.codeLanguage == prior.codeLanguage)
        }
        let toc = try EPubTOCEntryDAO(db: fixture.database.writer)
            .entries(for: fixture.audiobookID)
        #expect(toc.contains { $0.title == "A Coordinator Chapter" })
        #expect(toc.contains { $0.title == "Replacement Chapter" } == false)
        #expect(try fixture.taskResidue().isEmpty)
        #expect(networkRequests.count == 0)
    }
}

@MainActor
private struct AnthologyLibraryIntegrationFixture {
    let root: URL
    let workshopRoot: URL
    let database: DatabaseService
    let audiobookDAO: AudiobookDAO
    let anthologyDAO: AnthologyDAO
    let anthologyID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
    let coverName: String
    let manifest: AnthologyBuildManifest

    var editionDirectory: URL {
        workshopRoot
            .appending(path: "Editions", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
    }

    var finalURL: URL {
        editionDirectory.appending(path: "book.epub")
    }

    var audiobookID: String {
        editionDirectory.standardizedFileURL.absoluteString
    }

    var managedCoverURL: URL {
        workshopRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
            .appending(path: coverName)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AnthologyLibraryIntegration-\(UUID().uuidString)")
        workshopRoot = root.appending(path: "ArticleWorkshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
        database = try DatabaseService(inMemory: ())
        audiobookDAO = AudiobookDAO(db: database.writer)
        anthologyDAO = AnthologyDAO(db: database.writer)

        let coverData = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        coverName = "cover-\(Self.sha256(coverData)).png"
        let coverDirectory =
            workshopRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: coverDirectory,
            withIntermediateDirectories: true)
        try coverData.write(to: coverDirectory.appending(path: coverName))
        manifest = Self.makeManifest(
            anthologyID: anthologyID,
            coverName: coverName)

        try anthologyDAO.save(
            AnthologyRecord(
                id: anthologyID.uuidString,
                title: manifest.title,
                subtitle: manifest.subtitle,
                creator: manifest.creator,
                coverPath: coverName,
                nextStableSlot: 1,
                latestBuildRevision: 0,
                createdAt: "2026-07-29T12:00:00Z",
                modifiedAt: "2026-07-29T12:00:00Z"))

    }

    func service(
        manifest requestedManifest: AnthologyBuildManifest? = nil,
        failSuccessfulReceipt: Bool = false,
        networkRequests: LockedNetworkRequestCounter? = nil
    ) -> AnthologyBuildService {
        let requestedManifest = requestedManifest ?? manifest
        let builder = AnthologyEPUBBuilder(workshopRoot: workshopRoot)
        let preflight = AnthologyEPUBPreflight()
        let database = database
        let writer = database.writer
        return AnthologyBuildService(
            workshopRoot: workshopRoot,
            databaseService: database,
            dependencies: .init(
                freezeManifest: { _ in requestedManifest },
                buildEPUB: { manifest, destination in
                    try builder.build(manifest: manifest, to: destination)
                },
                preflight: { result, manifest in
                    try preflight.validate(result: result, against: manifest)
                },
                importEPUB: { finalURL, editionDirectory, audiobookID in
                    _ = try await EPUBImportCoordinator.importEPUB(
                        from: finalURL,
                        to: editionDirectory,
                        databaseService: database,
                        chapters: [],
                        duration: nil,
                        audiobookID: audiobookID,
                        networkPolicy: .localOnly,
                        networkRequestObserver: { request in
                            networkRequests?.record(request)
                        })
                    return AnthologyLibraryImportReceipt(
                        audiobookID: audiobookID)
                },
                saveBuild: { build in
                    if failSuccessfulReceipt, build.status == "succeeded" {
                        throw AnthologyLibraryIntegrationError.injected
                    }
                    try AnthologyDAO(db: writer).saveBuild(build)
                },
                restoreImport: { finalURL, editionDirectory, audiobookID in
                    _ = try await EPUBImportCoordinator.importEPUB(
                        from: finalURL,
                        to: editionDirectory,
                        databaseService: database,
                        chapters: [],
                        duration: nil,
                        audiobookID: audiobookID,
                        networkPolicy: .localOnly,
                        networkRequestObserver: { request in
                            networkRequests?.record(request)
                        })
                }),
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: UUID.init)
    }

    func revisedManifest() -> AnthologyBuildManifest {
        let replacementBlocks = [
            ArticleBlock(
                id: "replacement-paragraph",
                stableOrdinal: 0,
                kind: .paragraph,
                text: "This replacement must roll back after the late failure.",
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil)
        ]
        let prior = manifest.chapters[0]
        let replacementChapter = AnthologyChapterManifest(
            entryID: prior.entryID,
            captureID: prior.captureID,
            articleRevisionID: prior.articleRevisionID,
            stableSlot: prior.stableSlot,
            order: prior.order,
            title: "Replacement Chapter",
            author: prior.author,
            siteName: prior.siteName,
            sourceURL: prior.sourceURL,
            capturedAt: prior.capturedAt,
            voiceID: prior.voiceID,
            blocks: replacementBlocks,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(
                blocks: replacementBlocks))
        return AnthologyBuildManifest(
            schemaVersion: manifest.schemaVersion,
            anthologyID: manifest.anthologyID,
            revision: 2,
            epubIdentifier: manifest.epubIdentifier,
            title: "Replacement Anthology",
            subtitle: manifest.subtitle,
            creator: "Replacement Editor",
            language: manifest.language,
            coverPath: manifest.coverPath,
            modifiedAt: manifest.modifiedAt.addingTimeInterval(1),
            chapters: [replacementChapter])
    }

    func importedBlockCount() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM epub_block WHERE audiobook_id = ?",
                arguments: [audiobookID]) ?? 0
        }
    }

    func importedBlockEvidence() throws -> [ImportedBlockEvidence] {
        try EPubBlockDAO(db: database.writer)
            .allBlocks(for: audiobookID)
            .map(ImportedBlockEvidence.init)
    }

    func taskResidue() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: editionDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(".book-") }
    }

    func seedDatalessSidecarPlaceholder() throws {
        try FileManager.default.createDirectory(
            at: editionDirectory,
            withIntermediateDirectories: true)
        try Data().write(
            to: editionDirectory.appending(path: ".book.alignment.json.icloud"))
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static func makeManifest(
        anthologyID: UUID,
        coverName: String
    ) -> AnthologyBuildManifest {
        let blocks = [
            ArticleBlock(
                id: "coordinator-heading",
                stableOrdinal: 0,
                kind: .heading,
                text: "A coordinator heading",
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil),
            ArticleBlock(
                id: "coordinator-paragraph",
                stableOrdinal: 1,
                kind: .paragraph,
                text: "This frozen paragraph is imported through Echo’s real EPUB coordinator.",
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil),
        ]
        return AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: anthologyID,
            revision: 1,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
            title: "Coordinator Anthology",
            subtitle: "A generated integration fixture",
            creator: "Echo Integration",
            language: "en",
            coverPath: coverName,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: [
                AnthologyChapterManifest(
                    entryID: UUID(uuidString: "11111111-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    captureID: UUID(uuidString: "22222222-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    articleRevisionID: UUID(
                        uuidString: "33333333-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                    stableSlot: 0,
                    order: 0,
                    title: "A Coordinator Chapter",
                    author: "Fixture Writer",
                    siteName: "Fixture Site",
                    sourceURL: URL(string: "https://example.test/coordinator")!,
                    capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
                    voiceID: nil,
                    blocks: blocks,
                    readableContentSHA256: ArticleWorkshopDigest.readableContent(
                        blocks: blocks))
            ])
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ImportedBlockEvidence: Equatable, Sendable {
    let id: String
    let audiobookID: String
    let spineHref: String
    let spineIndex: Int
    let blockIndex: Int
    let sequenceIndex: Int
    let blockKind: String
    let text: String?
    let htmlContent: String?
    let cardColor: String?
    let chapterThemeColor: String?
    let imagePath: String?
    let chapterIndex: Int?
    let isHidden: Bool
    let hiddenReason: String?
    let isFrontMatter: Bool
    let wordCount: Int?
    let markers: String?
    let textFormats: String?
    let narrationText: String?
    let codeLanguage: String?

    init(_ block: EPubBlockRecord) {
        id = block.id
        audiobookID = block.audiobookID
        spineHref = block.spineHref
        spineIndex = block.spineIndex
        blockIndex = block.blockIndex
        sequenceIndex = block.sequenceIndex
        blockKind = block.blockKind
        text = block.text
        htmlContent = block.htmlContent
        cardColor = block.cardColor
        chapterThemeColor = block.chapterThemeColor
        imagePath = block.imagePath
        chapterIndex = block.chapterIndex
        isHidden = block.isHidden
        hiddenReason = block.hiddenReason
        isFrontMatter = block.isFrontMatter
        wordCount = block.wordCount
        markers = Self.canonicalJSON(block.markers)
        textFormats = Self.canonicalJSON(block.textFormats)
        narrationText = block.narrationText
        codeLanguage = block.codeLanguage
    }

    private static func canonicalJSON(_ value: String?) -> String? {
        guard let value,
            let source = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: source),
            let canonical = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys])
        else {
            return value
        }
        return String(data: canonical, encoding: .utf8) ?? value
    }
}

private enum AnthologyLibraryIntegrationError: Swift.Error {
    case injected
}

private nonisolated final class LockedNetworkRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [DocumentImportNetworkRequest] = []

    var count: Int {
        lock.withLock { requests.count }
    }

    func record(_ request: DocumentImportNetworkRequest) {
        lock.withLock {
            requests.append(request)
        }
    }
}
