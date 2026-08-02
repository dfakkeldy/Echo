// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated enum GeneratedAnthologyImportError: Swift.Error, Equatable, Sendable {
    case invalidManifest
    case packageEvidenceMismatch
    case unexpectedChapter
    case invalidStableBlock
    case incompleteStableBlockSet
    case duplicateStableBlock
    case crossBookCollision
    case rollbackSnapshotLimitExceeded
    case invalidRollbackSnapshot
    case injectedFailure
}

nonisolated struct GeneratedChapterIdentity: Equatable, Sendable {
    struct ExpectedBlock: Equatable, Sendable {
        let stableBlockIndex: Int
        let kind: EPubBlockRecord.Kind
        let text: String?
        let imagePath: String?
        let rawTag: String
        let rawClasses: Set<String>
        let codeLanguage: String?
        let narrationCue: String?
        let sourceURL: URL?
        let narrationSkipped: Bool
    }

    let sourceChapterKey: String
    let href: String
    let stableSlot: Int
    let expectedBlocksByIndex: [Int: ExpectedBlock]
}

/// Capability data built only from a frozen, in-memory anthology manifest.
/// XHTML attributes can corroborate this map but can never create it.
nonisolated struct GeneratedAnthologyImportIdentity: Equatable, Sendable {
    let anthologyID: UUID
    let expectedPackageIdentifier: String
    let expectedManifestSHA256: String
    let chaptersByHref: [String: GeneratedChapterIdentity]

    init(manifest: AnthologyBuildManifest) throws {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let digest = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }.joined()

        guard [1, 2].contains(manifest.schemaVersion),
            manifest.revision > 0,
            manifest.epubIdentifier == "urn:uuid:\(manifest.anthologyID.uuidString)",
            manifest.chapters.isEmpty == false
        else {
            throw GeneratedAnthologyImportError.invalidManifest
        }

        var chapters: [String: GeneratedChapterIdentity] = [:]
        var slots = Set<Int>()
        var chapterKeys = Set<String>()
        for chapter in manifest.chapters {
            guard chapter.stableSlot >= 0,
                slots.insert(chapter.stableSlot).inserted,
                chapterKeys.insert(chapter.entryID.uuidString).inserted
            else {
                throw GeneratedAnthologyImportError.invalidManifest
            }
            let href = "articles/article-s\(chapter.stableSlot).xhtml"
            guard chapters[href] == nil else {
                throw GeneratedAnthologyImportError.invalidManifest
            }
            let expected = try Self.expectedBlocks(
                for: chapter,
                imageAssets: manifest.imageAssets ?? [])
            chapters[href] = GeneratedChapterIdentity(
                sourceChapterKey: chapter.entryID.uuidString,
                href: href,
                stableSlot: chapter.stableSlot,
                expectedBlocksByIndex: expected)
        }

        anthologyID = manifest.anthologyID
        expectedPackageIdentifier = manifest.epubIdentifier
        expectedManifestSHA256 = digest
        chaptersByHref = chapters
    }

    func chapter(for href: String) -> GeneratedChapterIdentity? {
        let decoded = href.removingPercentEncoding ?? href
        let withoutFragment = String(decoded.split(separator: "#", maxSplits: 1)[0])
        return chaptersByHref[withoutFragment]
    }

    func validatePackage(identifier: String?, manifestSHA256: String?) throws {
        guard identifier == expectedPackageIdentifier,
            manifestSHA256 == expectedManifestSHA256
        else {
            throw GeneratedAnthologyImportError.packageEvidenceMismatch
        }
    }

    func validate(
        descriptors: [TextBlockDescriptor],
        chapter: GeneratedChapterIdentity
    ) throws -> [Int] {
        var accepted: [Int] = []
        var seen = Set<Int>()
        for descriptor in descriptors {
            guard descriptor.echoMetadataPresent,
                descriptor.echoStableSlot == chapter.stableSlot,
                let blockIndex = descriptor.echoBlockIndex,
                let expected = chapter.expectedBlocksByIndex[blockIndex],
                seen.insert(blockIndex).inserted,
                descriptor.kind == expected.kind,
                descriptor.text == expected.text,
                descriptor.imagePath == expected.imagePath,
                descriptor.rawTags == expected.rawTag,
                Set(descriptor.rawClasses) == expected.rawClasses,
                descriptor.codeLanguage == expected.codeLanguage,
                descriptor.narrationCue == expected.narrationCue
            else {
                throw GeneratedAnthologyImportError.invalidStableBlock
            }
            if let sourceURL = expected.sourceURL {
                guard
                    descriptor.markers.filter({ $0.type == .hyperlink }).map(\.payload)
                        == [sourceURL.absoluteString],
                    descriptor.echoNarration == "skip",
                    descriptor.echoLinkNarrationValues == ["skip"]
                else {
                    throw GeneratedAnthologyImportError.invalidStableBlock
                }
            } else if expected.narrationSkipped {
                guard descriptor.echoNarration == "skip" else {
                    throw GeneratedAnthologyImportError.invalidStableBlock
                }
            } else {
                guard descriptor.echoNarration == nil,
                    descriptor.echoLinkNarrationValues.isEmpty
                else {
                    throw GeneratedAnthologyImportError.invalidStableBlock
                }
            }
            accepted.append(blockIndex)
        }
        guard seen == Set(chapter.expectedBlocksByIndex.keys) else {
            throw GeneratedAnthologyImportError.incompleteStableBlockSet
        }
        return accepted
    }

    private static func expectedBlocks(
        for chapter: AnthologyChapterManifest,
        imageAssets: [ArticleImageAssetDescriptor]
    ) throws -> [Int: GeneratedChapterIdentity.ExpectedBlock] {
        var expected: [Int: GeneratedChapterIdentity.ExpectedBlock] = [:]
        try insert(
            .init(
                stableBlockIndex: 0,
                kind: .heading,
                text: chapter.title,
                imagePath: nil,
                rawTag: "h1",
                rawClasses: [],
                codeLanguage: nil,
                narrationCue: nil,
                sourceURL: nil,
                narrationSkipped: false),
            into: &expected)
        if let author = chapter.author {
            try insert(
                .init(
                    stableBlockIndex: 1,
                    kind: .paragraph,
                    text: author,
                    imagePath: nil,
                    rawTag: "p",
                    rawClasses: ["byline"],
                    codeLanguage: nil,
                    narrationCue: nil,
                    sourceURL: nil,
                    narrationSkipped: false),
                into: &expected)
        }
        let publication = [chapter.siteName, date(chapter.capturedAt)]
            .compactMap { $0 }.joined(separator: " — ")
        try insert(
            .init(
                stableBlockIndex: 2,
                kind: .paragraph,
                text: publication,
                imagePath: nil,
                rawTag: "p",
                rawClasses: ["publication"],
                codeLanguage: nil,
                narrationCue: nil,
                sourceURL: nil,
                narrationSkipped: false),
            into: &expected)
        for block in chapter.blocks {
            guard block.stableOrdinal >= 0, block.stableOrdinal < 899_000 else {
                throw GeneratedAnthologyImportError.invalidManifest
            }
            let index = 1_000 + block.stableOrdinal
            let attributes = expectedAttributes(for: block)
            let image = imageAssets.first(where: { $0.owningBlockID == block.id })
            if block.kind == .image, image == nil {
                throw GeneratedAnthologyImportError.invalidManifest
            }
            try insert(
                .init(
                    stableBlockIndex: index,
                    kind: attributes.kind,
                    // XML parsing canonicalizes presentation-only whitespace at
                    // element boundaries. Apply the same rule to legacy capture
                    // snapshots before performing the strict identity check.
                    text: block.kind == .image
                        ? (image?.caption ?? image?.altText)
                        : block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    imagePath: image.map {
                        "../" + String($0.archivePath.dropFirst("EPUB/".count))
                    },
                    rawTag: attributes.tag,
                    rawClasses: attributes.classes,
                    codeLanguage: block.kind == .code ? block.codeLanguage : nil,
                    narrationCue: block.kind == .code ? "Code listing." : nil,
                    sourceURL: nil,
                    narrationSkipped: false),
                into: &expected)
        }
        try insert(
            .init(
                stableBlockIndex: 900_000,
                kind: .paragraph,
                text: "Source: \(chapter.sourceURL.absoluteString)",
                imagePath: nil,
                rawTag: "p",
                rawClasses: ["source"],
                codeLanguage: nil,
                narrationCue: nil,
                sourceURL: chapter.sourceURL,
                narrationSkipped: true),
            into: &expected)
        return expected
    }

    private static func insert(
        _ block: GeneratedChapterIdentity.ExpectedBlock,
        into expected: inout [Int: GeneratedChapterIdentity.ExpectedBlock]
    ) throws {
        guard expected[block.stableBlockIndex] == nil else {
            throw GeneratedAnthologyImportError.invalidManifest
        }
        expected[block.stableBlockIndex] = block
    }

    private static func expectedAttributes(
        for block: ArticleBlock
    ) -> (kind: EPubBlockRecord.Kind, tag: String, classes: Set<String>) {
        switch block.kind {
        case .heading:
            return (.heading, "h2", [])
        case .paragraph:
            return (.paragraph, "p", [])
        case .listItem:
            return (.paragraph, "p", ["list-item"])
        case .quote:
            return (.paragraph, "blockquote", [])
        case .code:
            return (.code, "pre", [])
        case .separator:
            return (.paragraph, "hr", [])
        case .image:
            return (.image, "img", [])
        }
    }

    private static func date(_ value: Date) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
