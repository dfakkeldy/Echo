import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func testExtractsPlainText() throws {
    let xhtml = "<html><body><p>Hello world.</p><p>Goodbye.</p></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    #expect(result.rawText.contains("Hello world."))
    #expect(result.rawText.contains("Goodbye."))
    #expect(!result.rawText.contains("<p>"))
}

@Test func testExtractsImageMarkers() throws {
    let xhtml = "<html><body><p>Look at this:</p><img src=\"images/map.jpg\" alt=\"Treasure Map\"/><p>End.</p></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    let imageMarkers = result.markers.filter { $0.type == .image }
    #expect(imageMarkers.count == 1)
    #expect(imageMarkers[0].payload == "images/map.jpg")
}

@Test func testExtractsHeadingMarkers() throws {
    let xhtml = "<html><body><h1>Chapter One</h1><p>Once upon a time...</p><h2>Section A</h2><p>More text.</p></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    let headings = result.markers.filter { $0.type == .chapterStart }
    #expect(headings.count == 2)
    #expect(headings[0].payload == "Chapter One")
    #expect(headings[1].payload == "Section A")
}

@Test func testExtractsInlineFormatting() throws {
    let xhtml = "<html><body><p>The <em>quick</em> brown <strong>fox</strong> jumps.</p></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    let formats = result.textFormats
    #expect(formats.count >= 2)
    #expect(formats.contains { $0.type == .italic })
    #expect(formats.contains { $0.type == .bold })
}

@Test func testStripsScriptAndStyle() throws {
    let xhtml = "<html><head><style>body { color: red; }</style></head><body><p>Visible text.</p><script>console.log('hidden');</script></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    #expect(!result.rawText.contains("console.log"))
    #expect(!result.rawText.contains("color: red"))
    #expect(result.rawText.contains("Visible text."))
}

@Test func testBlockquoteMarker() throws {
    let xhtml = "<html><body><p>He said:</p><blockquote><p>Hello there.</p></blockquote></body></html>"
    let parser = XHTMLParser()
    let result = try parser.parse(xhtml: xhtml, baseHref: "ch1.xhtml")

    let blockquotes = result.markers.filter { $0.type == .blockquote }
    #expect(blockquotes.count >= 1)
}
