import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func testParsesContainerXML() throws {
    let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opf_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let containerPath = tmpDir.appendingPathComponent("container.xml")
    try containerXML.write(to: containerPath, atomically: true, encoding: .utf8)

    let parser = OPFParser()
    let opfPath = try parser.findOPFPath(from: containerPath)
    #expect(opfPath == "OEBPS/content.opf")
}

@Test func testParsesOPFMetadata() throws {
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="3.0" unique-identifier="book-id"
             xmlns="http://www.idpf.org/2007/opf">
      <metadata>
        <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Moby Dick</dc:title>
        <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Herman Melville</dc:creator>
      </metadata>
      <manifest>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="img1" href="images/cover.jpg" media-type="image/jpeg"/>
      </manifest>
      <spine>
        <itemref idref="ch1"/>
      </spine>
    </package>
    """
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opf_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let opfPath = tmpDir.appendingPathComponent("content.opf")
    try opfXML.write(to: opfPath, atomically: true, encoding: .utf8)

    let parser = OPFParser()
    let structure = try parser.parse(opfURL: opfPath, epubRoot: tmpDir)
    #expect(structure.title == "Moby Dick")
    #expect(structure.author == "Herman Melville")
    #expect(structure.spine.count == 1)
    #expect(structure.spine[0].id == "ch1")
    #expect(structure.spine[0].href == "chapter1.xhtml")
}

@Test func testParsesSpineOrder() throws {
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="3.0" unique-identifier="book-id"
             xmlns="http://www.idpf.org/2007/opf">
      <metadata>
        <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Test</dc:title>
      </metadata>
      <manifest>
        <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
        <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
        <itemref idref="c3"/>
      </spine>
    </package>
    """
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opf_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let opfPath = tmpDir.appendingPathComponent("content.opf")
    try opfXML.write(to: opfPath, atomically: true, encoding: .utf8)

    let parser = OPFParser()
    let structure = try parser.parse(opfURL: opfPath, epubRoot: tmpDir)
    #expect(structure.spine.map(\.id) == ["c1", "c2", "c3"])
}
