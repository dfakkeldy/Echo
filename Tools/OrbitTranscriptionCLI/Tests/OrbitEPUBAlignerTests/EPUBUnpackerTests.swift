import Foundation
import Testing
import ZIPFoundation
@testable import OrbitEPUBAligner

private func makeMinimalEPUB() throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("epub_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let metaInf = tmpDir.appendingPathComponent("META-INF")
    try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
    let oebps = tmpDir.appendingPathComponent("OEBPS")
    try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

    let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
    try containerXML.write(to: metaInf.appendingPathComponent("container.xml"),
                           atomically: true, encoding: .utf8)

    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="3.0" unique-identifier="book-id"
             xmlns="http://www.idpf.org/2007/opf">
      <metadata>
        <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Test Book</dc:title>
        <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Test Author</dc:creator>
      </metadata>
      <manifest>
        <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
        <item id="image1" href="images/map.jpg" media-type="image/jpeg"/>
      </manifest>
      <spine>
        <itemref idref="chapter1"/>
        <itemref idref="chapter2"/>
      </spine>
    </package>
    """
    try opfXML.write(to: oebps.appendingPathComponent("content.opf"),
                     atomically: true, encoding: .utf8)

    let ch1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter 1</title></head>
    <body><h1>The Beginning</h1><p>It was a dark and stormy night.</p>
    <img src="images/map.jpg" alt="Treasure Map"/><p>The <em>captain</em> spoke quietly.</p></body></html>
    """
    try ch1.write(to: oebps.appendingPathComponent("chapter1.xhtml"),
                  atomically: true, encoding: .utf8)

    let ch2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter 2</title></head>
    <body><h1>The Voyage</h1><p>The ship set sail at dawn.</p>
    <blockquote><p>To the west!</p></blockquote></body></html>
    """
    try ch2.write(to: oebps.appendingPathComponent("chapter2.xhtml"),
                  atomically: true, encoding: .utf8)

    let epubURL = tmpDir.appendingPathComponent("minimal.epub")
    guard let archive = Archive(url: epubURL, accessMode: .create) else {
        throw NSError(domain: "test", code: 1)
    }

    let mimetypeData = "application/epub+zip".data(using: .utf8)!
    try archive.addEntry(with: "mimetype", type: .file,
                         uncompressedSize: Int64(mimetypeData.count),
                         compressionMethod: .none,
                         provider: { _, _ in mimetypeData })

    let filesToAdd = [
        ("META-INF/container.xml", metaInf.appendingPathComponent("container.xml")),
        ("OEBPS/content.opf", oebps.appendingPathComponent("content.opf")),
        ("OEBPS/chapter1.xhtml", oebps.appendingPathComponent("chapter1.xhtml")),
        ("OEBPS/chapter2.xhtml", oebps.appendingPathComponent("chapter2.xhtml")),
    ]
    for (entryPath, fileURL) in filesToAdd {
        try archive.addEntry(with: entryPath, fileURL: fileURL)
    }

    return epubURL
}

@Test func testUnzipValidEPUB() async throws {
    let epubURL = try makeMinimalEPUB()
    let unpacker = EPUBUnpacker()

    let result = try unpacker.unzip(epubURL)
    #expect(FileManager.default.fileExists(atPath: result.tempDir.path))
    #expect(FileManager.default.fileExists(
        atPath: result.tempDir.appendingPathComponent("META-INF/container.xml").path))
    #expect(FileManager.default.fileExists(
        atPath: result.tempDir.appendingPathComponent("OEBPS/content.opf").path))
    #expect(FileManager.default.fileExists(
        atPath: result.tempDir.appendingPathComponent("OEBPS/chapter1.xhtml").path))
}

@Test func testRejectsNonEPUBZip() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("epub_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let dummyFile = tmpDir.appendingPathComponent("hello.txt")
    try "hello".write(to: dummyFile, atomically: true, encoding: .utf8)

    let zipURL = tmpDir.appendingPathComponent("not-an-epub.epub")
    guard let archive = Archive(url: zipURL, accessMode: .create) else {
        throw NSError(domain: "test", code: 2)
    }
    try archive.addEntry(with: "hello.txt", fileURL: dummyFile)

    let unpacker = EPUBUnpacker()
    #expect(throws: AlignmentError.self) {
        _ = try unpacker.unzip(zipURL)
    }
}
