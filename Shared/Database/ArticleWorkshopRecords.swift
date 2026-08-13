// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

nonisolated struct ArticleCaptureRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord,
    Sendable
{
    var id: String
    var sourceURL: String
    var canonicalURL: String?
    var title: String
    var author: String?
    var siteName: String?
    var language: String?
    var publishedAt: String?
    var capturedAt: String
    var captureMethod: ArticleCaptureMethod
    var packagePath: String
    var contentSHA256: String
    var extractorVersion: String
    var contentState: String
    var warningsJSON: String
    var currentRevisionID: String?
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "article_capture"

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case title
        case author
        case siteName = "site_name"
        case language
        case publishedAt = "published_at"
        case capturedAt = "captured_at"
        case captureMethod = "capture_method"
        case packagePath = "package_path"
        case contentSHA256 = "content_sha256"
        case extractorVersion = "extractor_version"
        case contentState = "content_state"
        case warningsJSON = "warnings_json"
        case currentRevisionID = "current_revision_id"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

nonisolated struct ArticleRevisionRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord,
    Sendable
{
    var id: String
    var captureID: String
    var parentRevisionID: String?
    var metadataOverridesJSON: String
    var recipeJSON: String
    var readableContentSHA256: String
    var createdAt: String
    var deviceName: String?

    static let databaseTableName = "article_revision"

    enum CodingKeys: String, CodingKey {
        case id
        case captureID = "capture_id"
        case parentRevisionID = "parent_revision_id"
        case metadataOverridesJSON = "metadata_overrides_json"
        case recipeJSON = "recipe_json"
        case readableContentSHA256 = "readable_content_sha256"
        case createdAt = "created_at"
        case deviceName = "device_name"
    }
}

nonisolated struct AnthologyRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord,
    Sendable
{
    var id: String
    var title: String
    var subtitle: String?
    var creator: String?
    var coverPath: String?
    var nextStableSlot: Int
    var latestBuildRevision: Int
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "anthology"

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case creator
        case coverPath = "cover_path"
        case nextStableSlot = "next_stable_slot"
        case latestBuildRevision = "latest_build_revision"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

nonisolated struct AnthologyEntryRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord,
    Sendable
{
    var id: String
    var anthologyID: String
    var captureID: String
    var sortOrder: Int
    var stableSlot: Int
    var chapterTitleOverride: String?
    var narrationVoiceID: String?

    static let databaseTableName = "anthology_entry"

    enum CodingKeys: String, CodingKey {
        case id
        case anthologyID = "anthology_id"
        case captureID = "capture_id"
        case sortOrder = "sort_order"
        case stableSlot = "stable_slot"
        case chapterTitleOverride = "chapter_title_override"
        case narrationVoiceID = "narration_voice_id"
    }
}

nonisolated struct AnthologyBuildRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord,
    Sendable
{
    var id: String
    var anthologyID: String
    var revision: Int
    var epubIdentifier: String
    var manifestJSON: String
    var manifestSHA256: String
    var epubPath: String?
    var epubSHA256: String?
    var audiobookID: String?
    var status: String
    var errorCode: String?
    var createdAt: String

    static let databaseTableName = "anthology_build"

    enum CodingKeys: String, CodingKey {
        case id
        case anthologyID = "anthology_id"
        case revision
        case epubIdentifier = "epub_identifier"
        case manifestJSON = "manifest_json"
        case manifestSHA256 = "manifest_sha256"
        case epubPath = "epub_path"
        case epubSHA256 = "epub_sha256"
        case audiobookID = "audiobook_id"
        case status
        case errorCode = "error_code"
        case createdAt = "created_at"
    }
}
