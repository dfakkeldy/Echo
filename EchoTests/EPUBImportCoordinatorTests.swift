// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

private final class EPUBCoordinatorFixtureLocator {}

@MainActor
struct EPUBImportCoordinatorTests {
    private var fixtureChapters: [Chapter] {
        [
            Chapter(
                index: 0, title: "Chapter One", startSeconds: 0, endSeconds: 1800, isEnabled: true
            ),
            Chapter(
                index: 1, title: "Chapter Two", startSeconds: 1800, endSeconds: 3600,
                isEnabled: true
            ),
        ]
    }

    @Test("Same-folder import preserves the source EPUB file")
    func preservesSourceWhenSameFolder() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        do {
            _ = try await EPUBImportCoordinator.importEPUB(
                from: epubURL,
                to: tmpDir,
                databaseService: db,
                chapters: [],
                duration: nil
            )
            Issue.record("Expected fake EPUB payload to report scanner failure.")
        } catch EPUBImportCoordinator.ImportError.scannerFailed(let url, let underlying) {
            #expect(url == epubURL)
            #expect(underlying != nil)
        } catch {
            Issue.record("Expected scanner failure, got \(error).")
        }

        // Source must still exist — same-folder imports skip the copy.
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test("Failed outside-folder EPUB import preserves existing document and source")
    func failedOutsideFolderImportPreservesExistingDocumentAndSource() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-existing EPUB in the folder should survive.
        let oldURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old".utf8).write(to: oldURL)

        // Source EPUB outside the folder.
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("new.epub")
        try Data("new".utf8).write(to: sourceURL)

        do {
            _ = try await EPUBImportCoordinator.importEPUB(
                from: sourceURL,
                to: tmpDir,
                databaseService: db,
                chapters: [],
                duration: nil
            )
            Issue.record("Expected fake EPUB payload to report scanner failure.")
        } catch EPUBImportCoordinator.ImportError.scannerFailed(let url, let underlying) {
            #expect(url.deletingLastPathComponent() == tmpDir)
            #expect(url.pathExtension == "epub")
            #expect(url.lastPathComponent.hasPrefix("new.echo-import-"))
            #expect(underlying != nil)
        } catch {
            Issue.record("Expected scanner failure, got \(error).")
        }

        // Failed imports must not clean up the existing companion document.
        #expect(FileManager.default.fileExists(atPath: oldURL.path))

        let destURL = tmpDir.appendingPathComponent("new.epub")
        // The failed staged copy is removed and never promoted to the final file.
        #expect(!FileManager.default.fileExists(atPath: destURL.path))

        // Source at original location is preserved.
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("Failed same-name EPUB import preserves existing destination")
    func failedSameNameImportPreservesExistingDestination() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-existing file at destination with same name.
        let existingURL = tmpDir.appendingPathComponent("book.epub")
        try Data("old content".utf8).write(to: existingURL)

        // Source outside folder with same filename.
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("book.epub")
        try Data("new content".utf8).write(to: sourceURL)

        do {
            _ = try await EPUBImportCoordinator.importEPUB(
                from: sourceURL,
                to: tmpDir,
                databaseService: db,
                chapters: [],
                duration: nil
            )
            Issue.record("Expected fake EPUB payload to report scanner failure.")
        } catch EPUBImportCoordinator.ImportError.scannerFailed(let url, let underlying) {
            #expect(url.deletingLastPathComponent() == tmpDir)
            #expect(url.pathExtension == "epub")
            #expect(url.lastPathComponent.hasPrefix("book.echo-import-"))
            #expect(underlying != nil)
        } catch {
            Issue.record("Expected scanner failure, got \(error).")
        }

        // Destination still holds the old content because the staged import failed.
        #expect(FileManager.default.fileExists(atPath: existingURL.path))
        let content = try Data(contentsOf: existingURL)
        #expect(String(data: content, encoding: .utf8) == "old content")
    }

    @Test("Outside-folder EPUB import reads final-name alignment sidecar")
    func outsideFolderImportReadsFinalNameAlignmentSidecar() async throws {
        let fixtureURL = try #require(
            Bundle(for: EPUBCoordinatorFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources"
        )

        let learningDB = try DatabaseService(inMemory: ())
        let learningDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: learningDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: learningDir) }

        let learningEPUB = learningDir.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixtureURL, to: learningEPUB)
        try Data("[]".utf8).write(
            to: learningDir.appendingPathComponent("minimal-book.alignment.json")
        )
        let learningID = learningDir.absoluteString
        try learningDB.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 3600)",
                arguments: [learningID]
            )
        }
        _ = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: learningEPUB,
            audiobookID: learningID,
            databaseService: learningDB,
            chapters: fixtureChapters,
            duration: 3600,
            force: true
        )
        let learnedBlockID = try #require(
            EPubBlockDAO(db: learningDB.writer).visibleBlocks(for: learningID).first?.id
        )
        let portableSuffix = AlignmentSidecar.portableSuffix(of: learnedBlockID)

        let db = try DatabaseService(inMemory: ())
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceURL)
        let sidecar = [
            AlignmentSidecar.Anchor(blockId: portableSuffix, timestamp: 123.5, confidence: 1.0)
        ]
        try JSONEncoder().encode(sidecar).write(
            to: tmpDir.appendingPathComponent("minimal-book.alignment.json")
        )
        let audiobookID = tmpDir.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 3600)",
                arguments: [audiobookID]
            )
        }

        let result = try await EPUBImportCoordinator.importEPUB(
            from: sourceURL,
            to: tmpDir,
            databaseService: db,
            chapters: fixtureChapters,
            duration: 3600
        )

        #expect(result.destinationURL == tmpDir.appendingPathComponent("minimal-book.epub"))
        let expectedLocalID = AlignmentSidecar.localBlockID(
            portableSuffix,
            audiobookID: audiobookID
        )
        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: audiobookID)
        #expect(
            anchors.contains {
                $0.epubBlockID == expectedLocalID && abs($0.audioTime - 123.5) < 0.001
            }
        )
    }

    @Test("Missing EPUB source reports a typed source error")
    func missingSourceThrowsSourceUnavailable() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let missingURL = tmpDir.appendingPathComponent("missing.epub")

        do {
            _ = try await EPUBImportCoordinator.importEPUB(
                from: missingURL,
                to: tmpDir,
                databaseService: db,
                chapters: [],
                duration: nil
            )
            Issue.record("Expected missing source to throw.")
        } catch EPUBImportCoordinator.ImportError.sourceUnavailable(let url, _) {
            #expect(url == missingURL)
        } catch {
            Issue.record("Expected sourceUnavailable, got \(error).")
        }
    }
}

@MainActor
struct PDFImportCoordinatorTests {

    @Test("Invalid PDF payload fails before copy or cleanup")
    func invalidPDFThrowsBeforeCopyOrCleanup() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let existingURL = tmpDir.appendingPathComponent("existing.pdf")
        try Data("existing".utf8).write(to: existingURL)

        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("not-really.pdf")
        try Data("this is not a pdf".utf8).write(to: sourceURL)

        let destURL = tmpDir.appendingPathComponent("not-really.pdf")
        do {
            _ = try await PDFImportCoordinator.importPDF(
                from: sourceURL,
                to: tmpDir,
                databaseService: db,
                chapters: [],
                duration: nil
            )
            Issue.record("Expected invalid PDF payload to report unreadable document.")
        } catch PDFImportCoordinator.ImportError.unreadableDocument(let url) {
            #expect(url == sourceURL)
        } catch {
            Issue.record("Expected unreadable document, got \(error).")
        }

        #expect(!FileManager.default.fileExists(atPath: destURL.path))
        #expect(FileManager.default.fileExists(atPath: existingURL.path))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("Valid PDF import returns result and creates blocks")
    func validPDFImportCreatesBlocks() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = try TestPDFFixture.singleChapter(in: outerDir)
        let audiobookID = tmpDir.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID]
            )
        }

        let result = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            to: tmpDir,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        #expect(result.copiedFile)
        #expect(result.destinationURL == tmpDir.appendingPathComponent(sourceURL.lastPathComponent))

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
        #expect(!blocks.isEmpty)
    }

    @Test("Textless but readable PDF attaches without creating text blocks")
    func textlessPDFImportSucceedsWithoutBlocks() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = try TestPDFFixture.blank(in: outerDir)
        let audiobookID = tmpDir.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID]
            )
        }
        let staleEPUBURL = tmpDir.appendingPathComponent("stale.epub")
        try Data("stale".utf8).write(to: staleEPUBURL)
        try EPubBlockDAO(db: db.writer).insert(
            EPubBlockRecord(
                id: "stale-block",
                audiobookID: audiobookID,
                spineHref: "stale.xhtml",
                spineIndex: 0,
                blockIndex: 0,
                sequenceIndex: 0,
                blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                text: "Stale EPUB text",
                htmlContent: nil,
                cardColor: nil,
                chapterThemeColor: nil,
                imagePath: nil,
                chapterIndex: 0,
                isHidden: false,
                hiddenReason: nil,
                isFrontMatter: false,
                wordCount: 3,
                markers: nil,
                textFormats: nil,
                createdAt: nil,
                modifiedAt: nil
            )
        )

        let result = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            to: tmpDir,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        #expect(result.copiedFile)
        #expect(FileManager.default.fileExists(atPath: result.destinationURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleEPUBURL.path))

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
        #expect(blocks.isEmpty)
    }
}

struct CompanionDocumentImportRequestTests {
    private enum FileImporterFailure: Error, Equatable {
        case denied
    }

    @Test("Unsupported companion document selections throw a visible selection error")
    func unsupportedSelectionThrows() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")

        #expect {
            try CompanionDocumentImportRequest(url: url)
        } throws: { error in
            guard case CompanionDocumentImportSelectionError.unsupportedFileType(let failedURL) =
                error
            else {
                return false
            }
            return failedURL == url
        }
    }

    @Test("File importer failures are preserved for presentation")
    func fileImporterFailureIsPreserved() {
        let result: Result<[URL], Error> = .failure(FileImporterFailure.denied)

        #expect {
            try CompanionDocumentImportRequest(result: result)
        } throws: { error in
            (error as? FileImporterFailure) == .denied
        }
    }
}
