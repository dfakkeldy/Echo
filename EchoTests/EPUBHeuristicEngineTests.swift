// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBHeuristicEngineTests {
    private func block(_ tag: String, _ text: String, classes: [String] = []) -> TextBlockDescriptor
    {
        TextBlockDescriptor(
            kind: tag.hasPrefix("h") ? .heading : .paragraph,
            text: text,
            imagePath: nil,
            htmlContent: nil,
            rawClasses: classes,
            rawTags: tag
        )
    }

    @Test func explicitLowerLevelHeadingSurvivesLongText() {
        let text =
            "A subsection title that describes a long relationship between the subject, its surrounding examples, and the next steps in the chapter"
        let source = block("h4", text)
        var engine = EPUBHeuristicEngine(tocLabels: [], spineItemCount: 3)
        engine.buildCSSFingerprint(from: [source])

        #expect(engine.score(block: source) == .heading)
    }

    @Test func proseStartingWithChapterOrPartRemainsParagraph() {
        let examples = [
            "Part of the explanation is that readers see the examples before the rules.",
            "Chapter 2 is all about choosing the equipment that works for you. The next pages explain each option, compare the costs, and show how to get started.",
            "Part I contains a list of practical exercises that can be used throughout the book. Each exercise builds on the last one.",
            "Chapter rambles and is overwritten. Tighten.",
        ]
        var engine = EPUBHeuristicEngine(tocLabels: [], spineItemCount: 8)
        engine.buildCSSFingerprint(from: examples.map { block("p", $0, classes: ["body"]) })

        for text in examples {
            #expect(engine.score(block: block("p", text, classes: ["body"])) == .paragraph)
        }
    }

    @Test func conciseNumberedChapterAndPublisherTOCStayHeadings() {
        let numbered = [
            block("p", "Chapter 2: The Tools", classes: ["toc_chap"]),
            block("p", "CHAPTER: 1"),
            block("p", "Part One"),
            block("p", "PART TWO"),
            block("p", "Part Three: Practice"),
            block("p", "Chapter Recap"),
            block("p", "Chapter of a Story"),
            block("p", "CHAPTER THIRTEEN"),
            block("p", "Chapter Twenty-Two"),
            block("p", "Part Time or Contract Work?"),
            block(
                "p",
                "CHAPTER 2 Building a Field Guide: Selecting Materials, Planning the Sequence, Recording Observations, Comparing Results, and Sharing the Finished Reference with Readers",
                classes: ["toc_chap"]
            ),
        ]
        let toc = block("p", "A Long Publisher Supplied Section Label", classes: ["special"])
        var engine = EPUBHeuristicEngine(
            tocLabels: ["A Long Publisher Supplied Section Label"], spineItemCount: 8)
        engine.buildCSSFingerprint(from: numbered + [toc])

        for label in numbered {
            #expect(engine.score(block: label) == .heading)
        }
        #expect(engine.score(block: toc) == .heading)
    }

    @Test func sharedParserPreservesTextBlockIDsAndSourceAnchors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        let body =
            "Chapter 2 is all about choosing the right tools. This paragraph continues with enough detail to be prose rather than a chapter label."
        let title =
            "A subsection title that describes a long relationship between the subject, its surrounding examples, and the next steps in the chapter"
        try """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body>
          <h4 id="subsection">\(title)</h4>
          <p id="prose" class="rare-body">\(body)</p>
          <p id="part-prose">Part of the answer is visible in the source.</p>
          <p id="next-chapter">Chapter 3: The Next Step</p>
        </body></html>
        """.write(
            to: epub.appendingPathComponent("OEBPS/chap01.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        let parse = try parseEPUBBlocks(audiobookID: "fixture", epubURL: epub)
        let firstSpine = Array(zip(parse.blocks, parse.descriptors)).filter { $0.0.spineIndex == 0 }
        #expect(
            firstSpine.map { $0.0.text } == [
                title, body, "Part of the answer is visible in the source.",
                "Chapter 3: The Next Step",
            ])
        #expect(
            firstSpine.map { $0.0.blockKind } == ["heading", "paragraph", "paragraph", "heading"])
        #expect(firstSpine.map { $0.0.id } == (0..<4).map { "epub-fixture-s0-b\($0)" })
        #expect(
            firstSpine.map { $0.1.anchorIDs } == [
                ["subsection"], ["prose"], ["part-prose"], ["next-chapter"],
            ])
        let heading = try #require(firstSpine.first)
        #expect(heading.1.markers.contains { $0.type == .chapterStart })
    }

    @Test func imageInsideExplicitHeadingKeepsHeadingTag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        try """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <h1 id="opening"><span><img src="ornament.png" alt=""/></span>
            <span>Chapter 1 <img src="ornament.png" alt=""/><br/>
              <strong>A Careful Start</strong></span></h1>
          <p>Body text follows the heading.</p>
        </body></html>
        """.write(
            to: epub.appendingPathComponent("OEBPS/chap01.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        let parse = try parseEPUBBlocks(audiobookID: "fixture", epubURL: epub)
        let firstSpine = Array(zip(parse.blocks, parse.descriptors)).filter { $0.0.spineIndex == 0 }
        let title = try #require(
            firstSpine.first { $0.0.text?.contains("A Careful Start") == true })
        #expect(title.0.blockKind == "heading")
        #expect(title.1.rawTags == "h1")
        #expect(firstSpine.contains { $0.1.anchorIDs.contains("opening") })
    }
}
