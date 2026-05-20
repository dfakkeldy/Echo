import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

// MARK: - EPUB Container XML Parsing

@MainActor
struct EPUBImportTests {

    /// Creates a minimal EPUB directory structure in a temporary location.
    private func makeMinimalEPUB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // META-INF/container.xml
        let metaInf = tmp.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        // content.opf
        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata><dc:title>Test Book</dc:title></metadata>
          <manifest>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: tmp.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // chapter1.xhtml
        try """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <h1>Chapter One</h1>
          <p>It was a dark and stormy night.</p>
          <p>The rain fell in torrents.</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("chapter1.xhtml"), atomically: true, encoding: .utf8)

        // chapter2.xhtml
        try """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <h1>Chapter Two</h1>
          <p>The morning brought clear skies.</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("chapter2.xhtml"), atomically: true, encoding: .utf8)

        return tmp
    }

    @Test func epubImportParsesSpineAndBlocks() async throws {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeMinimalEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        let assetStorage = EPUBAssetStorage(databaseService: db)
        let service = EPUBImportService(assetStorage: assetStorage)

        // Insert audiobook for FK constraint
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks = try await service.import(
            audiobookID: "book-1",
            epubURL: epubDir,
            chapters: [],
            bookDuration: nil
        )

        #expect(!blocks.isEmpty)

        let dao = EPubBlockDAO(db: db.writer)
        let stored = try dao.blocks(for: "book-1")
        #expect(!stored.isEmpty)

        // Should have heading + paragraphs from both chapters
        #expect(stored.contains(where: { $0.blockKind == "heading" }))
        #expect(stored.contains(where: { $0.blockKind == "paragraph" }))
    }

    @Test func epubImportSequenceIsMonotonic() async throws {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeMinimalEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        let assetStorage = EPUBAssetStorage(databaseService: db)
        let service = EPUBImportService(assetStorage: assetStorage)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks = try await service.import(
            audiobookID: "book-1",
            epubURL: epubDir,
            chapters: [],
            bookDuration: nil
        )

        let sequenceIndices = blocks.map(\.sequenceIndex)
        #expect(sequenceIndices == sequenceIndices.sorted())
        #expect(Set(sequenceIndices).count == sequenceIndices.count) // no duplicates
    }

    @Test func epubImportRejectsInvalidDirectory() async throws {
        let db = try DatabaseService(inMemory: ())
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let assetStorage = EPUBAssetStorage(databaseService: db)
        let service = EPUBImportService(assetStorage: assetStorage)

        do {
            _ = try await service.import(
                audiobookID: "book-1",
                epubURL: tmp,
                chapters: [],
                bookDuration: nil
            )
            #expect(Bool(false), "Expected error not thrown")
        } catch let error as EPUBImportError {
            #expect(error == .notAnEPUB(url: tmp))
        } catch {
            #expect(Bool(false), "Wrong error type: \(error)")
        }
    }

    @Test func epubAssetStorageCreatesDirectory() throws {
        let storage = EPUBAssetStorage()

        let testID = "file:///path/to/test-book-\(UUID().uuidString)"
        let dir = storage.directory(for: testID)

        #expect(!FileManager.default.fileExists(atPath: dir.path))

        try storage.prepare(for: testID)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try storage.removeAll(for: testID)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func epubAssetStorageCopiesImage() throws {
        let storage = EPUBAssetStorage()
        let testID = "test-book-\(UUID().uuidString)"

        // Create a test image file
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceImage = tmpDir.appendingPathComponent("test-image.jpg")
        try Data("fake-image-data".utf8).write(to: sourceImage)

        try storage.prepare(for: testID)
        defer { try? storage.removeAll(for: testID) }

        let localPath = storage.copyImage(from: sourceImage, audiobookID: testID, filename: "test-image.jpg")
        #expect(localPath != nil)
        #expect(FileManager.default.fileExists(atPath: localPath!))
        #expect(storage.imageExists(at: localPath!))
    }
}
