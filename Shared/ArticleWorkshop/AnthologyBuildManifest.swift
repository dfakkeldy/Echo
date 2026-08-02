// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum ArticleImageLocalizationWarning: String, Codable, Equatable, Sendable {
    case invalidURL
    case downloadFailed
    case invalidContentType
    case responseTooLarge
    case invalidImage
    case totalByteLimitReached
    case unsafeDestination
}

nonisolated struct ArticleImageLocalization: Sendable {
    let localURLs: [URL]
    let warnings: [ArticleImageLocalizationWarning]
    let assets: [ArticleImageAssetDescriptor]
    let failures: [ArticleImageFailureDescriptor]

    init(
        localURLs: [URL],
        warnings: [ArticleImageLocalizationWarning],
        assets: [ArticleImageAssetDescriptor] = [],
        failures: [ArticleImageFailureDescriptor] = []
    ) {
        self.localURLs = localURLs
        self.warnings = warnings
        self.assets = assets
        self.failures = failures
    }
}

nonisolated struct ArticleImageCandidate: Equatable, Sendable {
    let owningBlockID: String
    let sourceURL: URL
    let altText: String?
    let caption: String?
}

nonisolated struct AnthologyBuildManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let anthologyID: UUID
    let revision: Int
    let epubIdentifier: String
    let title: String
    let subtitle: String?
    let creator: String
    let language: String
    let coverPath: String?
    let modifiedAt: Date
    let chapters: [AnthologyChapterManifest]
    let imageAssets: [ArticleImageAssetDescriptor]?
    let imageFailures: [ArticleImageFailureDescriptor]?

    init(
        schemaVersion: Int,
        anthologyID: UUID,
        revision: Int,
        epubIdentifier: String,
        title: String,
        subtitle: String?,
        creator: String,
        language: String,
        coverPath: String?,
        modifiedAt: Date,
        chapters: [AnthologyChapterManifest],
        imageAssets: [ArticleImageAssetDescriptor]? = nil,
        imageFailures: [ArticleImageFailureDescriptor]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.anthologyID = anthologyID
        self.revision = revision
        self.epubIdentifier = epubIdentifier
        self.title = title
        self.subtitle = subtitle
        self.creator = creator
        self.language = language
        self.coverPath = coverPath
        self.modifiedAt = modifiedAt
        self.chapters = chapters
        self.imageAssets = imageAssets
        self.imageFailures = imageFailures
    }

    var includedImageCount: Int { imageAssets?.count ?? 0 }
    var candidateImageCount: Int { includedImageCount + (imageFailures?.count ?? 0) }

    var imageInclusionSummary: String? {
        guard candidateImageCount > 0 else { return nil }
        return "\(includedImageCount) of \(candidateImageCount) pictures included."
    }
}

/// Immutable per-block evidence for one accepted managed image. Identical bytes
/// may deliberately share `managedPath` and `archivePath`; ownership and
/// accessibility metadata remain block-specific.
nonisolated struct ArticleImageAssetDescriptor: Codable, Equatable, Sendable {
    let owningBlockID: String
    let managedPath: String
    let archivePath: String
    let mediaType: String
    let sha256: String
    let byteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let sourceURL: URL
    let altText: String?
    let caption: String?
}

nonisolated struct ArticleImageFailureDescriptor: Codable, Equatable, Sendable {
    let owningBlockID: String
    let sourceURL: URL
    let reason: ArticleImageLocalizationWarning
}

nonisolated struct ArticleImageAssetManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let captureID: UUID
    let assets: [ArticleImageAssetDescriptor]
    let failures: [ArticleImageFailureDescriptor]
}

nonisolated struct AnthologyChapterManifest: Codable, Equatable, Sendable {
    let entryID: UUID
    let captureID: UUID
    let articleRevisionID: UUID
    let stableSlot: Int
    let order: Int
    let title: String
    let author: String?
    let siteName: String?
    let sourceURL: URL
    let capturedAt: Date
    let voiceID: String?
    let blocks: [ArticleBlock]
    let readableContentSHA256: String
}

nonisolated struct AnthologyProjectEntry: Equatable, Sendable {
    var entry: AnthologyEntryRecord
    let capture: ArticleCaptureRecord
    let revision: ArticleRevisionRecord?
    let cleanArticle: CleanArticle?
}

nonisolated struct AnthologyProject: Equatable, Sendable {
    var anthology: AnthologyRecord
    var entries: [AnthologyProjectEntry]
    var persistedEntryIDs: Set<String>
    let latestSuccessfulBuild: AnthologyBuildRecord?
    var changesAvailable: Bool

    func replacing(anthology: AnthologyRecord) -> AnthologyProject {
        var copy = self
        copy.anthology = anthology
        return copy
    }

    func updatingEntry(
        id: String,
        chapterTitleOverride: String?,
        narrationVoiceID: String?
    ) -> AnthologyProject {
        var copy = self
        guard let index = copy.entries.firstIndex(where: { $0.entry.id == id }) else {
            return copy
        }
        copy.entries[index].entry.chapterTitleOverride = chapterTitleOverride
        copy.entries[index].entry.narrationVoiceID = narrationVoiceID
        return copy
    }

    func reordering(entryIDs: [String]) -> AnthologyProject {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.entry.id, $0) })
        guard entryIDs.count == entries.count, Set(entryIDs) == Set(byID.keys) else {
            return self
        }
        var copy = self
        copy.entries = entryIDs.enumerated().compactMap { order, id in
            guard var value = byID[id] else { return nil }
            value.entry.sortOrder = order
            return value
        }
        return copy
    }

    func removing(entryID: String) -> AnthologyProject {
        var copy = self
        copy.entries.removeAll { $0.entry.id == entryID }
        for index in copy.entries.indices {
            copy.entries[index].entry.sortOrder = index
        }
        return copy
    }
}
