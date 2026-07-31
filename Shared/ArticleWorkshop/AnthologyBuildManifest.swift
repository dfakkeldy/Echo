// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
