// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct EPUBSourceAnchorResolverTests {
    @Test
    func resolvesPortableSuffixToLocalEPUBBlockID() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "s0-b0",
            targetMediaID: "book-a",
            cardReference: "card-1"
        )

        #expect(resolution == .resolved("epub-book-a-s0-b0"))
    }

    @Test
    func stripsLegacyFullBlockIDAndRehomesToTargetBook() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-b", blockIDs: ["epub-book-b-s1-b2"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "epub-original-book-s1-b2",
            targetMediaID: "book-b",
            cardReference: "card-2"
        )

        #expect(resolution == .resolved("epub-book-b-s1-b2"))
    }

    @Test
    func reportsMalformedAnchor() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "chapter-1-paragraph-2",
            targetMediaID: "book-a",
            cardReference: "card-3"
        )

        #expect(
            resolution
                == .unresolved(
                    .sourceAnchorMalformed(
                        cardReference: "card-3", sourceAnchor: "chapter-1-paragraph-2")))
    }

    @Test
    func reportsWrongBookForFullIDThatExistsElsewhere() throws {
        let dbService = try DatabaseService(inMemory: ())
        try seedBook(dbService, audiobookID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        try seedBook(dbService, audiobookID: "book-b", blockIDs: ["epub-book-b-s9-b9"])

        let resolver = EPUBSourceAnchorResolver(dbReader: dbService.writer)
        let resolution = try resolver.resolve(
            sourceAnchor: "epub-book-a-s0-b0",
            targetMediaID: "book-b",
            cardReference: "card-4"
        )

        #expect(
            resolution
                == .unresolved(
                    .sourceAnchorWrongBook(
                        cardReference: "card-4", sourceAnchor: "epub-book-a-s0-b0")))
    }

    private func seedBook(_ dbService: DatabaseService, audiobookID: String, blockIDs: [String])
        throws
    {
        try dbService.write { db in
            var audiobook = AudiobookRecord(
                id: audiobookID,
                title: audiobookID,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)

            for (index, blockID) in blockIDs.enumerated() {
                var block = EPubBlockRecord(
                    id: blockID,
                    audiobookID: audiobookID,
                    spineHref: "Text/chapter.xhtml",
                    spineIndex: index,
                    blockIndex: index,
                    sequenceIndex: index,
                    blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                    text: "Block \(index)",
                    htmlContent: nil,
                    cardColor: nil,
                    chapterThemeColor: nil,
                    imagePath: nil,
                    chapterIndex: index,
                    isHidden: false,
                    hiddenReason: nil,
                    isFrontMatter: false,
                    wordCount: nil,
                    markers: nil,
                    textFormats: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                try block.insert(db)
            }
        }
    }
}
