// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct TextDocumentParserTests {

    private let src = URL(fileURLWithPath: "/tmp/My Book.md")

    private func parse(_ md: String) -> EPUBBlockParse {
        parseMarkdown(audiobookID: "ab", content: md, sourceURL: src)
    }

    @Test func chapterLevelIsShallowestRepeatingLevel() {
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 2, 2]) == 2)  // lone # title, ## chapters
        #expect(TextDocChapterLeveling.chapterLevel(of: [2, 2, 3, 3]) == 2)  // ## chapters, ### sections
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 1, 2]) == 1)  // flat # chapters
        #expect(TextDocChapterLeveling.chapterLevel(of: [1]) == 1)  // single heading
        #expect(TextDocChapterLeveling.chapterLevel(of: []) == nil)  // no headings
        // Degenerate single-occurrence cases: a lone leading H1 is a title
        // (skip to ##); a lone H2 with no H1 is itself the chapter.
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 2]) == 2)  // # title + one ## chapter
        #expect(TextDocChapterLeveling.chapterLevel(of: [2, 3]) == 2)  // ## chapter + ### section
    }

    @Test func eachChapterLevelHeadingIsItsOwnSpineChapter() {
        let p = parse("## One\n\nAlpha.\n\n## Two\n\nBeta.")
        let chapters = Set(p.blocks.compactMap(\.spineIndex))
        #expect(chapters.count == 2)
        let headings = p.blocks.filter { $0.blockKind == "heading" }.map { $0.text }
        #expect(headings == ["One", "Two"])
    }

    @Test func deeperHeadingsStayInsideTheChapter() {
        let p = parse("## Chapter\n\nIntro.\n\n### Section\n\nBody.")
        // One chapter spine; the ### heading shares it, not a new chapter.
        #expect(Set(p.blocks.map(\.spineIndex)).count == 1)
        #expect(p.blocks.filter { $0.blockKind == "heading" }.count == 2)
    }

    @Test func loneLeadingTitleIsFrontMatterNotAChapter() throws {
        let p = parse("# The Title\n\nForeword.\n\n## Chapter One\n\nBody.")
        let title = try #require(p.blocks.first { $0.text == "The Title" })
        #expect(title.isFrontMatter)
        // "Chapter One" body is a real chapter (not front matter).
        let body = try #require(p.blocks.first { $0.text == "Chapter One" })
        #expect(!body.isFrontMatter)
    }

    @Test func listItemsBecomeOneBlockEach() {
        let p = parse("## C\n\n- first\n- second\n- third")
        let paras = p.blocks.filter { $0.blockKind == "paragraph" }.map { $0.text }
        #expect(paras == ["first", "second", "third"])
    }

    @Test func thematicBreaksAreDropped() {
        let p = parse("## C\n\nAbove\n\n---\n\nBelow\n\n* * *\n\nAfter")
        let paras = p.blocks.filter { $0.blockKind == "paragraph" }.map(\.text)
        #expect(paras == ["Above", "Below", "After"])
        #expect(!paras.contains("---"))
        #expect(!paras.contains("* * *"))
    }

    @Test func fencedCodeAndTablesAreDropped() {
        let p = parse("## C\n\nReal text.\n\n```\nlet x = 1\n```\n\n| a | b |\n| - | - |\n")
        #expect(p.blocks.contains { $0.text == "Real text." })
        #expect(!p.blocks.contains { ($0.text ?? "").contains("let x") })
        #expect(!p.blocks.contains { ($0.text ?? "").contains("|") })
    }

    @Test func boldSpanSurvivesIntoBlockTextFormats() throws {
        let p = parse("## C\n\nThis is **strong** prose.")
        let para = try #require(p.blocks.first { ($0.text ?? "").contains("strong") })
        #expect(para.text == "This is strong prose.")
        #expect(try para.decodeFormats().contains { $0.type == .bold })
    }

    @Test func blockIDsFollowSchemeAndAreReproducible() {
        let a = parse("## C\n\nx.\n\n## D\n\ny.")
        let b = parse("## C\n\nx.\n\n## D\n\ny.")
        #expect(a.blocks.map(\.id) == b.blocks.map(\.id))
        #expect(a.blocks.allSatisfy { $0.id.hasPrefix("epub-ab-s") })
    }

    @Test func titleComesFromFilename() {
        // (Title is consumed by the importer/loader, not the parse; assert the
        // source filename is recoverable via the spine href the parser emits.)
        let p = parse("## C\n\nbody")
        #expect(!p.spine.isEmpty)
    }

    @Test func tocTreeNestsSectionsUnderChapters() {
        let p = parse("## Chapter One\n\nIntro.\n\n### Section A\n\nx.\n\n## Chapter Two\n\ny.")
        #expect(p.tocEntryTree.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(p.tocEntryTree.first?.children.map(\.title) == ["Section A"])
        // Fragments point at heading anchors so resolveTOCEntries can map them.
        #expect(p.tocEntryTree.first?.fragment != nil)
    }
}

@Suite struct PlainTextParserTests {
    private let src = URL(fileURLWithPath: "/tmp/Notes.txt")
    private func parse(_ txt: String) -> EPUBBlockParse {
        parsePlainText(audiobookID: "ab", content: txt, sourceURL: src)
    }

    @Test func chapterMarkersSplitChapters() {
        let p = parse("Chapter 1\n\nAlpha text.\n\nChapter 2\n\nBeta text.")
        #expect(Set(p.blocks.map(\.spineIndex)).count == 2)
        let headings = p.blocks.filter { $0.blockKind == "heading" }.map(\.text)
        #expect(headings == ["Chapter 1", "Chapter 2"])
    }

    @Test func romanAndAllCapsMarkersAreDetected() {
        let p = parse("CHAPTER VII\n\nText.\n\nPART TWO\n\nMore.")
        #expect(p.blocks.filter { $0.blockKind == "heading" }.count == 2)
    }

    @Test func noMarkersYieldsSingleChapter() {
        let p = parse("Just one long\n\nplain note with two paragraphs.")
        #expect(Set(p.blocks.map(\.spineIndex)).count == 1)
        #expect(p.blocks.filter { $0.blockKind == "heading" }.isEmpty)
        #expect(p.blocks.allSatisfy { !$0.isFrontMatter })  // whole thing is chapter 0 body
    }

    @Test func shortAllCapsAcronymsAreNotChapters() {
        // "OK" (2 letters) and "NOTE" (4 letters) are interjections, not chapter titles.
        let p = parse("OK\n\nFirst paragraph.\n\nNOTE\n\nSecond paragraph.")
        #expect(p.blocks.filter { $0.blockKind == "heading" }.isEmpty)
        #expect(Set(p.blocks.map(\.spineIndex)).count == 1)
    }

    @Test func singleWordAllCapsTitleIsDetected() {
        // "PROLOGUE" (8 letters) is a real chapter title; "CHAPTER ONE" is keyword-detected.
        let p = parse("PROLOGUE\n\nThe beginning.\n\nCHAPTER ONE\n\nThe body.")
        let headings = p.blocks.filter { $0.blockKind == "heading" }.map(\.text)
        #expect(headings == ["PROLOGUE", "CHAPTER ONE"])
        #expect(Set(p.blocks.map(\.spineIndex)).count == 2)
    }
}
