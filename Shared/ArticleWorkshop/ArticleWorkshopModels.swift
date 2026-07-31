// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated enum ArticleBlockKind: String, Codable, Sendable {
    case heading
    case paragraph
    case listItem
    case quote
    case code
    case image
    case separator
}

nonisolated enum ArticleContentState: String, Codable, Sendable {
    case ready
    case reviewSuggested
    case captureFailed
}

nonisolated enum ArticleSanitizationWarning: String, Codable, Sendable {
    case contentXHTMLTooLarge
    case elementLimitReached
    case blockLimitReached
    case imageCandidateLimitReached
    case rejectedURLScheme
    case parserFailure
    case noUsableText
}

nonisolated struct ArticleBlock: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let stableOrdinal: Int
    let kind: ArticleBlockKind
    let text: String?
    let sourceURL: URL?
    let imageCandidateURL: URL?
    let caption: String?
    let codeLanguage: String?

    func withCaption(_ caption: String?) -> ArticleBlock {
        ArticleBlock(
            id: id,
            stableOrdinal: stableOrdinal,
            kind: kind,
            text: text,
            sourceURL: sourceURL,
            imageCandidateURL: imageCandidateURL,
            caption: caption,
            codeLanguage: codeLanguage)
    }
}

nonisolated struct ArticleMetadata: Codable, Equatable, Sendable {
    let title: String
    let author: String?
    let siteName: String?
    let language: String?
    let publishedTime: String?

    init(
        title: String,
        author: String? = nil,
        siteName: String? = nil,
        language: String? = nil,
        publishedTime: String? = nil
    ) {
        self.title = title
        self.author = author
        self.siteName = siteName
        self.language = language
        self.publishedTime = publishedTime
    }
}

nonisolated struct ArticleMetadataOverrides: Codable, Equatable, Sendable {
    var title: String?
    var author: String?
    var siteName: String?
    var language: String?
    var publishedTime: String?

    init(
        title: String? = nil,
        author: String? = nil,
        siteName: String? = nil,
        language: String? = nil,
        publishedTime: String? = nil
    ) {
        self.title = title
        self.author = author
        self.siteName = siteName
        self.language = language
        self.publishedTime = publishedTime
    }

    func applying(to metadata: ArticleMetadata) -> ArticleMetadata {
        ArticleMetadata(
            title: title ?? metadata.title,
            author: author ?? metadata.author,
            siteName: siteName ?? metadata.siteName,
            language: language ?? metadata.language,
            publishedTime: publishedTime ?? metadata.publishedTime)
    }
}

nonisolated struct ArticleEditRecipe: Codable, Equatable, Sendable {
    var excludedBlockIDs: [String]
    var trimBeforeBlockID: String?
    var trimAfterBlockID: String?
    var metadataOverrides: ArticleMetadataOverrides

    init(
        excludedBlockIDs: [String] = [],
        trimBeforeBlockID: String? = nil,
        trimAfterBlockID: String? = nil,
        metadataOverrides: ArticleMetadataOverrides = .init()
    ) {
        self.excludedBlockIDs = excludedBlockIDs
        self.trimBeforeBlockID = trimBeforeBlockID
        self.trimAfterBlockID = trimAfterBlockID
        self.metadataOverrides = metadataOverrides
    }
}

nonisolated struct ArticleSnapshot: Codable, Equatable, Sendable {
    let captureID: UUID
    let metadata: ArticleMetadata
    let blocks: [ArticleBlock]
    let warnings: [ArticleSanitizationWarning]
    let contentState: ArticleContentState
    let snapshotSHA256: String
}

nonisolated struct CleanArticle: Codable, Equatable, Sendable {
    let captureID: UUID
    let metadata: ArticleMetadata
    let blocks: [ArticleBlock]
    let recipe: ArticleEditRecipe
    let readableContentSHA256: String
}

nonisolated enum ArticleWorkshopDigest {
    static func snapshot(
        captureID: UUID,
        metadata: ArticleMetadata,
        blocks: [ArticleBlock],
        warnings: [ArticleSanitizationWarning],
        contentState: ArticleContentState
    ) throws -> String {
        let value = SnapshotDigestInput(
            captureID: captureID,
            metadata: metadata,
            blocks: blocks,
            warnings: warnings,
            contentState: contentState)
        return sha256(try canonicalJSON(value))
    }

    static func readableContent(blocks: [ArticleBlock]) -> String {
        var data = Data("echo.article.clean.v1\u{0}".utf8)
        for block in blocks {
            append(block.kind.rawValue, to: &data)
            append(block.text ?? "", to: &data)
            append(block.caption ?? "", to: &data)
            append(block.codeLanguage ?? "", to: &data)
        }
        return sha256(data)
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct SnapshotDigestInput: Codable {
        let captureID: UUID
        let metadata: ArticleMetadata
        let blocks: [ArticleBlock]
        let warnings: [ArticleSanitizationWarning]
        let contentState: ArticleContentState
    }
}
