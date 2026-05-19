import Foundation
import Testing
import ZIPFoundation
@testable import OrbitEPUBAligner

@Test func testUntimestampedItemsForEPUBOnlyContent() async throws {
    // EPUB has an image between two paragraphs. The transcript only covers
    // the text — the image has no corresponding audio.
    // Pipeline should emit the image as an un-timestamped segment with
    // nil startTime/endTime and a valid sequenceIndex.

    let epubURL = try makeMinimalEPUB()

    // Transcript covers "dark and stormy night" and "captain spoke" only.
    // The <img> between them has no transcript equivalent.
    let segments: [PlainSegment] = [
        PlainSegment(text: "It was a dark and stormy night.", startTime: 0, endTime: 3),
        PlainSegment(text: "The captain spoke quietly.", startTime: 3, endTime: 6),
        PlainSegment(text: "The ship set sail at dawn.", startTime: 6, endTime: 9),
        PlainSegment(text: "To the west!", startTime: 9, endTime: 12),
    ]
    let transcriptURL = try makeTempJSON(segments)

    let pipeline = EPUBAlignmentPipeline()
    let enhanced = try await pipeline.process(
        epubPath: epubURL.path,
        transcriptPath: transcriptURL.path
    )

    // ---- Assertions ----

    // 1. Output is not empty
    #expect(!enhanced.isEmpty)

    // 2. Timestamped segments are present and have valid timestamps
    let timestamped = enhanced.filter { $0.isTimestamped }
    #expect(!timestamped.isEmpty)
    for seg in timestamped {
        #expect(seg.startTime != nil)
        #expect(seg.endTime != nil)
    }

    // 3. At least one un-timestamped segment exists (the orphaned image marker)
    let untimestamped = enhanced.filter { !$0.isTimestamped }
    #expect(!untimestamped.isEmpty, "Expected at least one un-timestamped segment for EPUB-only content")

    // 4. Un-timestamped segments have nil times and valid markers
    for seg in untimestamped {
        #expect(seg.startTime == nil)
        #expect(seg.endTime == nil)
        #expect(seg.markers != nil, "Un-timestamped segment should carry its source marker")
    }

    // 5. All segment IDs are based on sequenceIndex (not timestamps)
    for seg in enhanced {
        #expect(seg.id == "\(seg.sequenceIndex)")
    }

    // 6. Sequence indices are consecutive and cover the full range
    let indices = enhanced.map(\.sequenceIndex).sorted()
    #expect(indices.first == 0)
    #expect(indices.last == enhanced.count - 1)
    #expect(Set(indices).count == enhanced.count, "Sequence indices must be unique")

    // 7. Timestamped segments are sorted by time
    let timestamps = timestamped.compactMap { $0.startTime }
    #expect(timestamps == timestamps.sorted())
}

@Test func testFullPipelineMinimalEPUB() async throws {
    let epubURL = try makeMinimalEPUB()

    let segments: [PlainSegment] = [
        PlainSegment(text: "It was a dark and stormy night.", startTime: 0, endTime: 3),
        PlainSegment(text: "The captain spoke quietly.", startTime: 3, endTime: 6),
        PlainSegment(text: "The ship set sail at dawn.", startTime: 6, endTime: 9),
        PlainSegment(text: "To the west!", startTime: 9, endTime: 12),
    ]
    let transcriptURL = try makeTempJSON(segments)

    let pipeline = EPUBAlignmentPipeline()
    let enhanced = try await pipeline.process(
        epubPath: epubURL.path,
        transcriptPath: transcriptURL.path
    )

    #expect(!enhanced.isEmpty)

    let allMarkers = enhanced.compactMap { $0.markers }.flatMap { $0 }
    #expect(allMarkers.contains(where: { $0.type == .chapterStart }))
    #expect(allMarkers.contains(where: { $0.type == .image }))
    #expect(allMarkers.contains(where: { $0.type == .blockquote }))
}

private func makeTempJSON(_ segments: [PlainSegment]) throws -> URL {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(segments)
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("epub_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let url = tmpDir.appendingPathComponent("transcript.json")
    try data.write(to: url)
    return url
}

// Note: makeMinimalEPUB() is duplicated from EPUBUnpackerTests.swift.
// Future: extract to Tests/OrbitEPUBAlignerTests/Helpers/EPUBFixtureBuilder.swift
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
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    try containerXML.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
      <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Test</dc:title></metadata>
      <manifest>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
    </package>
    """
    try opfXML.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

    let ch1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><body>
    <h1>The Beginning</h1><p>It was a dark and stormy night.</p>
    <img src="images/map.jpg" alt="Treasure Map"/><p>The captain spoke quietly.</p></body></html>
    """
    try ch1.write(to: oebps.appendingPathComponent("chapter1.xhtml"), atomically: true, encoding: .utf8)

    let ch2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><body>
    <h1>The Voyage</h1><p>The ship set sail at dawn.</p>
    <blockquote><p>To the west!</p></blockquote></body></html>
    """
    try ch2.write(to: oebps.appendingPathComponent("chapter2.xhtml"), atomically: true, encoding: .utf8)

    let epubURL = tmpDir.appendingPathComponent("minimal.epub")
    guard let archive = Archive(url: epubURL, accessMode: .create) else {
        throw NSError(domain: "test", code: 1)
    }
    let mimetypeData = "application/epub+zip".data(using: .utf8)!
    try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(mimetypeData.count),
                         compressionMethod: .none, provider: { _, _ in mimetypeData })
    let files = [
        ("META-INF/container.xml", metaInf.appendingPathComponent("container.xml")),
        ("OEBPS/content.opf", oebps.appendingPathComponent("content.opf")),
        ("OEBPS/chapter1.xhtml", oebps.appendingPathComponent("chapter1.xhtml")),
        ("OEBPS/chapter2.xhtml", oebps.appendingPathComponent("chapter2.xhtml")),
    ]
    for (entryPath, fileURL) in files {
        try archive.addEntry(with: entryPath, fileURL: fileURL)
    }
    return epubURL
}
