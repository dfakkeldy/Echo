// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing

@testable import Echo

@Suite struct BlockExportSourceResolverTests {
    @Test func resolvesDirectRegularEPUBWithExactByteDigest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = root.appendingPathComponent("frozen.epub")
        try Data([
            0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xAF, 0xBE,
            0xEF, 0x00, 0x01, 0x02, 0x03,
        ]).write(to: epub)

        let resolved = try BlockExportSourceResolver.resolve(at: epub)

        #expect(resolved.url == epub)
        #expect(resolved.epubName == "frozen.epub")
        #expect(
            resolved.epubSHA256
                == "e26d8566b08629bd81db1593023d05777307b6fb7173e2c56d4e0e41057b9574")
    }

    @Test func resolvesExpandedEPUBAtExactSuppliedDirectoryWithNullDigest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try makeExpandedEPUB(at: expanded)

        let resolved = try BlockExportSourceResolver.resolve(at: expanded)

        #expect(resolved.url == expanded)
        #expect(resolved.epubName == "expanded")
        #expect(resolved.epubSHA256 == nil)
    }

    @Test func rejectsGenericContainerDirectoryEvenWhenItContainsAnEPUB() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("not an expanded EPUB".utf8).write(
            to: container.appendingPathComponent("nested.epub"))

        #expect(throws: BlockExportSourceResolver.Error.unsupportedDirectory(container)) {
            try BlockExportSourceResolver.resolve(at: container)
        }
    }

    @Test func rejectsPDFInput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("book.pdf")
        try Data("%PDF-1.7".utf8).write(to: pdf)

        #expect(throws: BlockExportSourceResolver.Error.unsupportedFile(pdf)) {
            try BlockExportSourceResolver.resolve(at: pdf)
        }
    }

    @Test func rejectsSymlinkInputWithoutFollowingIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.epub")
        let link = root.appendingPathComponent("linked.epub")
        try Data("EPUB bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: BlockExportSourceResolver.Error.symbolicLink(link)) {
            try BlockExportSourceResolver.resolve(at: link)
        }
    }

    @Test func rejectsNonregularFIFOInputWithoutOpeningIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("source.epub")
        #expect(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

        #expect(throws: BlockExportSourceResolver.Error.unsupportedInput(fifo)) {
            try BlockExportSourceResolver.resolve(at: fifo)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-export-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExpandedEPUB(at url: URL) throws {
        let metaInf = url.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: url.appendingPathComponent("mimetype"))
        try Data("<container/>".utf8).write(to: metaInf.appendingPathComponent("container.xml"))
    }
}
