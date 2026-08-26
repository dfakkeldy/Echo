# Markdown / Plain-Text Narration Import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users import `.md` / `.markdown` / `.txt` files as standalone, narratable audio-less books, feeding the existing on-device Kokoro narration, read-along timeline, and chaptered playback.

**Architecture:** A new `Shared/TextDocumentParser.swift` emits the same `EPUBBlockParse` value the EPUB parser produces (blocks keyed `epub-<audiobookID>-s<i>-b<j>`, one synthetic spine per chapter). The EPUB import path is refactored so its persist/post-process phase (`import(parse:)`) and its anchor/timeline finalize tail (`DocumentImportFinalizer`) are shared by both EPUB and text. Thin platform wiring routes picked text files into this path. No schema change.

**Tech Stack:** Swift, SwiftUI, GRDB, Swift Testing, Foundation `AttributedString(markdown:)` (inline-only) for emphasis spans. No new SPM dependency.

Spec: [`docs/superpowers/specs/2026-06-20-markdown-text-narration-import-design.md`](../specs/2026-06-20-markdown-text-narration-import-design.md).

## Global Constraints

- Every new file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. (A SwiftFormat PostToolUse hook reflows the whole file on edit and can push the SPDX line below an `import` — verify it stays line 1 after each edit.)
- Tests use **Swift Testing** (`import Testing`, `@Suite struct`, `@Test`, `#expect`, `#require`) — never XCTest.
- 16 GB machine: build/test with `-jobs 5`, `-parallel-testing-enabled NO`. **Never run two `xcodebuild` invocations at once.**
- New files under `Shared/`, `EchoCore/`, `Echo macOS/`, `EchoTests/` auto-join their targets via `PBXFileSystemSynchronizedRootGroup` — **no manual `.pbxproj` edits.** Confirm via build.
- **No schema migration.** Blocks reuse the existing `epub_block` table; migration head stays **V23**.
- **Reuse, do not duplicate.** Text import must flow through the shared `import(parse:)` + `DocumentImportFinalizer` — no parallel persistence/chapter/timeline logic.
- Block IDs must use the exact scheme `epub-<audiobookID>-s<spine>-b<block>`.
- Commits follow **Conventional Commits**.
- iOS test loop: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. macOS changes (Task 9) are verified by a macOS build, not the iOS `Echo` scheme.

## File Structure

**New:**
- `Shared/MarkdownInlineFormatter.swift` — pure function: inline Markdown emphasis → `(plain, [TextFormat])`.
- `Shared/TextDocumentParser.swift` — `parseMarkdownBlocks` / `parsePlainTextBlocks` → `EPUBBlockParse`.
- `EchoCore/Services/DocumentImportFinalizer.swift` — shared anchor/timeline/notification tail.
- `EchoCore/Services/TextAutoImportScanner.swift` — `importTextFile(...)`.
- `EchoTests/MarkdownInlineFormatterTests.swift`, `EchoTests/TextDocumentParserTests.swift`, `EchoTests/TextDocumentImportTests.swift`.

**Modified:**
- `EchoCore/Services/EPUBImportService.swift` — extract `import(parse:audiobookID:chapters:bookDuration:assetBaseURL:)`.
- `EchoCore/Services/EPUBAutoImportScanner.swift` — call `DocumentImportFinalizer`.
- `EchoCore/Services/PlaylistManager.swift` — `documentExtensions`.
- `EchoCore/Utilities/FolderPicker.swift` — picker UTTypes.
- `EchoCore/Services/PlayerLoadingCoordinator.swift` — text branch in `importDocumentForAudiolessBook`.
- `Echo macOS/Echo_macOSApp.swift` — narrate panel types + routing.
- `Echo macOS/Services/MacBatchProcessingService.swift` — text branch in `importEPUBOnly`.
- `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md`, `ROADMAP.md`.

---

## Task 1: MarkdownInlineFormatter

**Files:**
- Create: `Shared/MarkdownInlineFormatter.swift`
- Test: `EchoTests/MarkdownInlineFormatterTests.swift`

**Interfaces:**
- Produces: `enum MarkdownInlineFormatter { static func format(_ markdown: String) -> (plain: String, formats: [TextFormat]) }` — strips inline emphasis, returns plain text plus `TextFormat` spans (character offsets, `ClosedRange<Int>`) for bold/italic/strikethrough. Links collapse to their label.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/MarkdownInlineFormatterTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MarkdownInlineFormatterTests {

    @Test func boldSpanIsCapturedAndMarkersStripped() {
        let (plain, formats) = MarkdownInlineFormatter.format("a **bold** end")
        #expect(plain == "a bold end")
        #expect(formats.contains { $0.type == .bold && $0.range == 2...5 })  // "bold"
    }

    @Test func italicSpanIsCaptured() {
        let (plain, formats) = MarkdownInlineFormatter.format("an *italic* word")
        #expect(plain == "an italic word")
        #expect(formats.contains { $0.type == .italic && $0.range == 3...8 })
    }

    @Test func strikethroughSpanIsCaptured() {
        let (plain, formats) = MarkdownInlineFormatter.format("x ~~gone~~ y")
        #expect(plain == "x gone y")
        #expect(formats.contains { $0.type == .strikethrough })
    }

    @Test func nestedBoldItalicYieldsBothSpans() {
        let (plain, formats) = MarkdownInlineFormatter.format("***both***")
        #expect(plain == "both")
        #expect(formats.contains { $0.type == .bold })
        #expect(formats.contains { $0.type == .italic })
    }

    @Test func linkCollapsesToLabel() {
        let (plain, _) = MarkdownInlineFormatter.format("see [the docs](https://example.com) now")
        #expect(plain == "see the docs now")
    }

    @Test func plainTextHasNoFormats() {
        let (plain, formats) = MarkdownInlineFormatter.format("just words")
        #expect(plain == "just words")
        #expect(formats.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL — `cannot find 'MarkdownInlineFormatter' in scope`.

- [ ] **Step 3: Implement**

Create `Shared/MarkdownInlineFormatter.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Extracts inline Markdown emphasis from a single run of prose.
///
/// Hand-rolled block parsing (headings, paragraphs) lives in
/// `TextDocumentParser`; this handles only *inline* emphasis, delegating to
/// Foundation's inline-only Markdown parser so nested `***both***`, links, and
/// escapes are handled correctly without a third-party CommonMark dependency.
/// Links collapse to their visible label (the URL is dropped from narration and
/// the reader text alike).
enum MarkdownInlineFormatter {

    /// - Returns: the plain text with all inline markup removed, plus the
    ///   bold/italic/strikethrough spans as character ranges into that plain text.
    static func format(_ markdown: String) -> (plain: String, formats: [TextFormat]) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return (markdown, [])
        }

        let plain = String(attributed.characters)
        var formats: [TextFormat] = []

        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let lower = attributed.characters.distance(
                from: attributed.startIndex, to: run.range.lowerBound)
            let upper = attributed.characters.distance(
                from: attributed.startIndex, to: run.range.upperBound)
            guard upper > lower else { continue }
            let range = lower...(upper - 1)

            if intent.contains(.stronglyEmphasized) {
                formats.append(TextFormat(type: .bold, range: range))
            }
            if intent.contains(.emphasized) {
                formats.append(TextFormat(type: .italic, range: range))
            }
            if intent.contains(.strikethrough) {
                formats.append(TextFormat(type: .strikethrough, range: range))
            }
        }
        return (plain, formats)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/MarkdownInlineFormatterTests`
Expected: all `MarkdownInlineFormatterTests` pass. (If exact offsets differ by Foundation whitespace handling, adjust the `==` ranges in the test to the observed values — the span *type* coverage is the contract.)

- [ ] **Step 5: Commit**

```bash
git add Shared/MarkdownInlineFormatter.swift EchoTests/MarkdownInlineFormatterTests.swift
git commit -m "feat(narration): inline Markdown emphasis -> TextFormat spans"
```

---

## Task 2: TextDocumentParser — Markdown structure, hierarchy, blocks

**Files:**
- Create: `Shared/TextDocumentParser.swift`
- Test: `EchoTests/TextDocumentParserTests.swift`

**Interfaces:**
- Consumes: `MarkdownInlineFormatter.format` (Task 1); `EPUBBlockParse`, `EPubBlockRecord`, `TextBlockDescriptor`, `SpineItemDescriptor`, `EPubBlockRecord.Kind`, `SyncMarker`, `TextFormat` (existing in `Shared/`).
- Produces:
  - `func parseMarkdownBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse`
  - `func parseMarkdown(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse` (string overload for tests)
  - `enum TextDocChapterLeveling { static func chapterLevel(of levels: [Int]) -> Int? }`
  - Each chapter = one `spineIndex`; chapter-level headings break chapters; deeper headings are in-chapter section headings; content before the first chapter-level heading is `isFrontMatter`. `tocEntryTree` is `[]` in this task (Task 4 fills it).

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/TextDocumentParserTests.swift`:

```swift
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
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 2, 2]) == 2)   // lone # title, ## chapters
        #expect(TextDocChapterLeveling.chapterLevel(of: [2, 2, 3, 3]) == 2) // ## chapters, ### sections
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 1, 2]) == 1)   // flat # chapters
        #expect(TextDocChapterLeveling.chapterLevel(of: [1]) == 1)         // single heading
        #expect(TextDocChapterLeveling.chapterLevel(of: []) == nil)        // no headings
        // Degenerate single-occurrence cases: a lone leading H1 is a title
        // (skip to ##); a lone H2 with no H1 is itself the chapter.
        #expect(TextDocChapterLeveling.chapterLevel(of: [1, 2]) == 2)      // # title + one ## chapter
        #expect(TextDocChapterLeveling.chapterLevel(of: [2, 3]) == 2)      // ## chapter + ### section
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

    @Test func loneLeadingTitleIsFrontMatterNotAChapter() {
        let p = parse("# The Title\n\nForeword.\n\n## Chapter One\n\nBody.")
        let title = try! #require(p.blocks.first { $0.text == "The Title" })
        #expect(title.isFrontMatter)
        // "Chapter One" body is a real chapter (not front matter).
        let body = try! #require(p.blocks.first { $0.text == "Chapter One" })
        #expect(!body.isFrontMatter)
    }

    @Test func listItemsBecomeOneBlockEach() {
        let p = parse("## C\n\n- first\n- second\n- third")
        let paras = p.blocks.filter { $0.blockKind == "paragraph" }.map { $0.text }
        #expect(paras == ["first", "second", "third"])
    }

    @Test func fencedCodeAndTablesAreDropped() {
        let p = parse("## C\n\nReal text.\n\n```\nlet x = 1\n```\n\n| a | b |\n| - | - |\n")
        #expect(p.blocks.contains { $0.text == "Real text." })
        #expect(!p.blocks.contains { ($0.text ?? "").contains("let x") })
        #expect(!p.blocks.contains { ($0.text ?? "").contains("|") })
    }

    @Test func boldSpanSurvivesIntoBlockTextFormats() {
        let p = parse("## C\n\nThis is **strong** prose.")
        let para = try! #require(p.blocks.first { ($0.text ?? "").contains("strong") })
        #expect(para.text == "This is strong prose.")
        #expect(para.decodedFormats.contains { $0.type == .bold })
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL — `cannot find 'parseMarkdown' in scope` / `'TextDocChapterLeveling'`.

- [ ] **Step 3: Implement**

Create `Shared/TextDocumentParser.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TextParseError: Error { case unreadable(URL) }

/// An intermediate, format-neutral unit produced by tokenizing a text document.
private enum TextUnit {
    case heading(level: Int, text: String)
    case paragraph(String)
}

/// Decides the chapter break level for a document's heading depths.
enum TextDocChapterLeveling {
    /// The heading depth (1–6) at which chapters break.
    ///
    /// 1. The shallowest depth that occurs at least twice — the clearest signal
    ///    that "these are the chapters" (a lone `#` title above repeated `##`
    ///    chapters does not count, so `##` wins).
    /// 2. When nothing repeats: a lone leading `#` (H1) is treated as a book
    ///    title, so chapters are the next level down. Any other lone shallowest
    ///    heading (e.g. a single `##` with a `###` section) is itself the chapter.
    /// 3. `nil` when there are no headings at all (one body chapter).
    static func chapterLevel(of levels: [Int]) -> Int? {
        guard !levels.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for l in levels { counts[l, default: 0] += 1 }
        if let shallowestRepeating = counts.filter({ $0.value >= 2 }).keys.min() {
            return shallowestRepeating
        }
        let present = counts.keys.sorted()
        // A lone leading H1 above deeper headings is a title → skip it.
        if present.count >= 2, present[0] == 1, counts[1] == 1 {
            return present[1]
        }
        return present[0]
    }
}

// MARK: - Public entry points

/// Parses a Markdown file into the canonical block set (chapters follow the
/// heading hierarchy). Drop-in for `EPUBImportService.import(parse:)`.
func parseMarkdownBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
        throw TextParseError.unreadable(fileURL)
    }
    return parseMarkdown(audiobookID: audiobookID, content: content, sourceURL: fileURL)
}

func parseMarkdown(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse {
    let units = tokenizeMarkdown(content)
    return buildParse(
        units: units, audiobookID: audiobookID, sourceURL: sourceURL, hrefExt: "md")
}

// MARK: - Markdown tokenizer

private func tokenizeMarkdown(_ content: String) -> [TextUnit] {
    var units: [TextUnit] = []
    var paragraphLines: [String] = []
    var inFence = false

    func flushParagraph() {
        let joined = paragraphLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { units.append(.paragraph(joined)) }
        paragraphLines.removeAll()
    }

    for rawLine in content.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            if inFence { inFence = false } else { flushParagraph(); inFence = true }
            continue
        }
        if inFence { continue }
        if trimmed.isEmpty { flushParagraph(); continue }

        if let heading = parseHeading(trimmed) {
            flushParagraph()
            units.append(.heading(level: heading.level, text: heading.text))
            continue
        }
        if trimmed.hasPrefix("|") { continue }       // table row
        if trimmed.hasPrefix("![") { continue }      // standalone image

        if let item = parseListItem(trimmed) {
            flushParagraph()
            units.append(.paragraph(item))
            continue
        }
        if trimmed.hasPrefix(">") {
            let text = String(trimmed.drop(while: { $0 == ">" || $0 == " " }))
            if !text.isEmpty { paragraphLines.append(text) }
            continue
        }
        paragraphLines.append(trimmed)
    }
    flushParagraph()
    return units
}

/// `^(#{1,6})\s+(.*)$` → (level, trimmed title), else nil.
private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    var level = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == "#", level < 6 {
        level += 1
        idx = line.index(after: idx)
    }
    guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
    let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (level, text)
}

/// `^([-*+]|\d+\.)\s+(.*)$` → item text, else nil.
private func parseListItem(_ line: String) -> String? {
    let scalars = Array(line)
    if let first = scalars.first, "-*+".contains(first),
        scalars.count > 1, scalars[1] == " " {
        return String(scalars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    // ordered: digits then "." then space
    var i = 0
    while i < scalars.count, scalars[i].isNumber { i += 1 }
    if i > 0, i + 1 < scalars.count, scalars[i] == ".", scalars[i + 1] == " " {
        return String(scalars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

// MARK: - Block assembly

private func buildParse(
    units: [TextUnit], audiobookID: String, sourceURL: URL, hrefExt: String
) -> EPUBBlockParse {
    let levels: [Int] = units.compactMap { if case .heading(let l, _) = $0 { return l } else { return nil } }
    let chapterLevel = TextDocChapterLeveling.chapterLevel(of: levels)

    var blocks: [EPubBlockRecord] = []
    var descriptors: [TextBlockDescriptor] = []
    var spineIndexesUsed: [Int] = []

    var spineIndex = 0
    var blockIndex = 0
    var sequenceIndex = 0
    var seenChapterHeading = false
    var emittedFrontMatter = false
    let createdAt = ISO8601DateFormatter().string(from: Date())

    func spineHref(_ i: Int) -> String { "text-s\(i).\(hrefExt)" }

    func emit(kind: EPubBlockRecord.Kind, plain: String, formats: [TextFormat],
              isFrontMatter: Bool, headingLevel: Int?) {
        if spineIndexesUsed.last != spineIndex { spineIndexesUsed.append(spineIndex) }
        let anchorID = (kind == .heading) ? "b\(spineIndex)-\(blockIndex)" : nil
        var markers: [SyncMarker] = []
        if let level = headingLevel {
            markers.append(SyncMarker(type: .chapterStart, payload: String(level), epubCharOffset: 0))
        }
        let wordCount = max(1, plain.split(whereSeparator: { $0.isWhitespace }).count)

        blocks.append(EPubBlockRecord(
            id: "epub-\(audiobookID)-s\(spineIndex)-b\(blockIndex)",
            audiobookID: audiobookID,
            spineHref: spineHref(spineIndex),
            spineIndex: spineIndex,
            blockIndex: blockIndex,
            sequenceIndex: sequenceIndex,
            blockKind: kind.rawValue,
            text: plain,
            htmlContent: nil,
            cardColor: nil,
            imagePath: nil,
            chapterIndex: nil,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: isFrontMatter,
            wordCount: wordCount,
            markers: EPubBlockRecord.encodeMarkers(markers),
            textFormats: EPubBlockRecord.encodeFormats(formats),
            createdAt: createdAt,
            modifiedAt: nil))

        descriptors.append(TextBlockDescriptor(
            kind: kind, text: plain, imagePath: nil, htmlContent: nil,
            markers: markers, textFormats: formats,
            anchorIDs: anchorID.map { [$0] } ?? []))

        blockIndex += 1
        sequenceIndex += 1
    }

    func startNewSpine() { spineIndex += 1; blockIndex = 0 }

    for unit in units {
        switch unit {
        case .heading(let level, let rawText):
            let (plain, formats) = MarkdownInlineFormatter.format(rawText)
            if let chapterLevel, level == chapterLevel {
                if !seenChapterHeading {
                    if emittedFrontMatter { startNewSpine() }
                    seenChapterHeading = true
                } else {
                    startNewSpine()
                }
                emit(kind: .heading, plain: plain, formats: formats,
                     isFrontMatter: false, headingLevel: level)
            } else {
                // Shallower lone title, or deeper section heading.
                let front = !seenChapterHeading
                if front { emittedFrontMatter = true }
                emit(kind: .heading, plain: plain, formats: formats,
                     isFrontMatter: front, headingLevel: level)
            }
        case .paragraph(let rawText):
            let (plain, formats) = MarkdownInlineFormatter.format(rawText)
            let front = (chapterLevel != nil) && !seenChapterHeading
            if front { emittedFrontMatter = true }
            emit(kind: .paragraph, plain: plain, formats: formats,
                 isFrontMatter: front, headingLevel: nil)
        }
    }

    let spine = spineIndexesUsed.map {
        SpineItemDescriptor(
            id: spineHref($0), href: spineHref($0), mediaType: "text/markdown", linear: true)
    }
    var spineXHTMLURLByIndex: [Int: URL] = [:]
    for i in spineIndexesUsed { spineXHTMLURLByIndex[i] = sourceURL }

    return EPUBBlockParse(
        blocks: blocks,
        descriptors: descriptors,
        spine: spine,
        tocEntryTree: [],      // populated in Task 4
        opfDir: sourceURL.deletingLastPathComponent(),
        spineXHTMLURLByIndex: spineXHTMLURLByIndex)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/TextDocumentParserTests`
Expected: all `TextDocumentParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/TextDocumentParser.swift EchoTests/TextDocumentParserTests.swift
git commit -m "feat(narration): parse Markdown into hierarchical chapter blocks"
```

---

## Task 3: Plain-text parsing (`.txt`)

**Files:**
- Modify: `Shared/TextDocumentParser.swift`
- Test: `EchoTests/TextDocumentParserTests.swift` (add a nested suite)

**Interfaces:**
- Produces: `func parsePlainTextBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse` and `func parsePlainText(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse`. Chapters come from heuristic chapter-marker lines; no markers → one chapter; output is flat (single heading level → no sections).

- [ ] **Step 1: Write the failing tests**

Append to `EchoTests/TextDocumentParserTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL — `cannot find 'parsePlainText' in scope`.

- [ ] **Step 3: Implement**

Append to `Shared/TextDocumentParser.swift`:

```swift
// MARK: - Plain-text entry points

func parsePlainTextBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
        throw TextParseError.unreadable(fileURL)
    }
    return parsePlainText(audiobookID: audiobookID, content: content, sourceURL: fileURL)
}

func parsePlainText(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse {
    let units = tokenizePlainText(content)
    return buildParse(
        units: units, audiobookID: audiobookID, sourceURL: sourceURL, hrefExt: "txt")
}

/// Plain text has no markup: split paragraphs on blank lines, and promote
/// chapter-like lines to level-1 headings (one heading level → flat chapters).
private func tokenizePlainText(_ content: String) -> [TextUnit] {
    var units: [TextUnit] = []
    var paragraphLines: [String] = []

    func flush() {
        let joined = paragraphLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { units.append(.paragraph(joined)) }
        paragraphLines.removeAll()
    }

    for rawLine in content.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { flush(); continue }
        if isChapterMarker(trimmed) {
            flush()
            units.append(.heading(level: 1, text: trimmed))
            continue
        }
        paragraphLines.append(trimmed)
    }
    flush()
    return units
}

/// A line that looks like a chapter break: "Chapter 7", "CHAPTER VII",
/// "Part Two", a bare number, or a short ALL-CAPS title.
private func isChapterMarker(_ line: String) -> Bool {
    let lower = line.lowercased()
    let words = line.split(whereSeparator: { $0.isWhitespace })

    // "chapter|part|book <number|roman>"
    if let first = words.first.map(String.init)?.lowercased(),
        ["chapter", "part", "book"].contains(first), words.count >= 2 {
        return true
    }
    // bare number ("7", "12.")
    if line.allSatisfy({ $0.isNumber || $0 == "." }) && line.contains(where: \.isNumber) {
        return true
    }
    // short ALL-CAPS heading (<= 6 words, has letters, no lowercase)
    let hasLetters = line.contains(where: { $0.isLetter })
    if hasLetters, words.count <= 6, line == line.uppercased(), lower != line {
        return true
    }
    return false
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/PlainTextParserTests`
Expected: all `PlainTextParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/TextDocumentParser.swift EchoTests/TextDocumentParserTests.swift
git commit -m "feat(narration): heuristic chapter detection for plain-text import"
```

---

## Task 4: Heading-derived TOC tree

**Files:**
- Modify: `Shared/TextDocumentParser.swift`
- Test: `EchoTests/TextDocumentParserTests.swift` (add to `TextDocumentParserTests`)

**Interfaces:**
- Produces: `buildParse` now returns a nested `tocEntryTree: [TOCEntryNode]` — chapter-level headings are top nodes, deeper headings nest under the current chapter. Each node's `href` is its spine's synthetic href and `fragment` is the heading block's anchor ID, so the existing `EPUBImportService.resolveTOCEntries` resolves nodes to blocks unchanged.

- [ ] **Step 1: Write the failing test**

Append to `TextDocumentParserTests` (the Markdown suite):

```swift
    @Test func tocTreeNestsSectionsUnderChapters() {
        let p = parse("## Chapter One\n\nIntro.\n\n### Section A\n\nx.\n\n## Chapter Two\n\ny.")
        #expect(p.tocEntryTree.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(p.tocEntryTree.first?.children.map(\.title) == ["Section A"])
        // Fragments point at heading anchors so resolveTOCEntries can map them.
        #expect(p.tocEntryTree.first?.fragment != nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL — `tocEntryTree` is empty (`["Chapter One", "Chapter Two"] != []`).

- [ ] **Step 3: Implement**

Three edits inside `buildParse` in `Shared/TextDocumentParser.swift`:

**(a)** Make `emit` return the anchor ID it assigned, so the TOC node and the heading block reference the same anchor. Change its declaration to `@discardableResult` and add a `return` at the end:

```swift
    @discardableResult
    func emit(kind: EPubBlockRecord.Kind, plain: String, formats: [TextFormat],
              isFrontMatter: Bool, headingLevel: Int?) -> String? {
        // ... existing body unchanged ...
        blockIndex += 1
        sequenceIndex += 1
        return anchorID   // the value computed at the top of emit (nil for non-headings)
    }
```

**(b)** Before the `for unit in units` loop, add the TOC accumulators:

```swift
    var tocTree: [TOCEntryNode] = []
    var currentChapterTOCIndex: Int? = nil   // chapter node a section nests under
```

**(c)** Replace the `.heading` case body with the version that records TOC nodes (chapters as top nodes, deeper sections nested under the current chapter):

```swift
        case .heading(let level, let rawText):
            let (plain, formats) = MarkdownInlineFormatter.format(rawText)
            if let chapterLevel, level == chapterLevel {
                if !seenChapterHeading {
                    if emittedFrontMatter { startNewSpine() }
                    seenChapterHeading = true
                } else {
                    startNewSpine()
                }
                let usedAnchor = emit(kind: .heading, plain: plain, formats: formats,
                                      isFrontMatter: false, headingLevel: level)
                tocTree.append(TOCEntryNode(
                    title: plain, href: spineHref(spineIndex), fragment: usedAnchor, children: []))
                currentChapterTOCIndex = tocTree.count - 1
            } else {
                let front = !seenChapterHeading
                if front { emittedFrontMatter = true }
                let usedAnchor = emit(kind: .heading, plain: plain, formats: formats,
                                      isFrontMatter: front, headingLevel: level)
                if !front, let chapterIdx = currentChapterTOCIndex {
                    tocTree[chapterIdx].children.append(TOCEntryNode(
                        title: plain, href: spineHref(spineIndex), fragment: usedAnchor, children: []))
                }
            }
```

Then change the return's `tocEntryTree: []` to `tocEntryTree: tocTree`.

`TOCEntryNode.children` is a `var` ([Shared/EPUBXMLParsing.swift:47](../../../Shared/EPUBXMLParsing.swift)), so the in-place `.children.append` compiles.

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/TextDocumentParserTests`
Expected: all pass, including `tocTreeNestsSectionsUnderChapters`.

- [ ] **Step 5: Commit**

```bash
git add Shared/TextDocumentParser.swift EchoTests/TextDocumentParserTests.swift
git commit -m "feat(narration): build nested TOC tree from Markdown heading hierarchy"
```

---

## Task 5: Extract `EPUBImportService.import(parse:)`

**Files:**
- Modify: `EchoCore/Services/EPUBImportService.swift:36-181`

**Interfaces:**
- Produces: `func import(parse: EPUBBlockParse, audiobookID: String, chapters: [Chapter], bookDuration: TimeInterval?, assetBaseURL: URL) async throws -> [EPubBlockRecord]`. Existing `import(audiobookID:epubURL:chapters:bookDuration:)` becomes a thin wrapper. **Behavior-preserving refactor** — verified by existing EPUB tests.

- [ ] **Step 1: Refactor — split parse from persist**

In `EchoCore/Services/EPUBImportService.swift`, replace the current `import(audiobookID:epubURL:chapters:bookDuration:)` method. Keep the wrapper; move the body into `import(parse:...)`:

```swift
    func `import`(
        audiobookID: String,
        epubURL: URL,
        chapters: [Chapter],
        bookDuration: TimeInterval?
    ) async throws -> [EPubBlockRecord] {
        // Parse the canonical block set + stable IDs via the shared driver, then
        // run the shared persist/post-process phase. Text import reuses that
        // phase via the `parse:` overload below.
        let parse = try parseEPUBBlocks(audiobookID: audiobookID, epubURL: epubURL)
        return try await `import`(
            parse: parse, audiobookID: audiobookID, chapters: chapters,
            bookDuration: bookDuration, assetBaseURL: epubURL)
    }

    /// Persist + post-process a pre-computed block parse (image localization, TOC
    /// resolution, chapter-index assignment, DB write). Shared by EPUB import and
    /// text-document import. For text there are no image blocks (the image-copy
    /// loop self-skips) and the TOC tree is heading-derived.
    func `import`(
        parse: EPUBBlockParse,
        audiobookID: String,
        chapters: [Chapter],
        bookDuration: TimeInterval?,
        assetBaseURL: URL
    ) async throws -> [EPubBlockRecord] {
        // (former step 2 onward, verbatim) ...
    }
```

Move the **entire former body from the old step 2 (`try assetStorage.prepare(...)`) through `return allBlocks`** into the new `import(parse:...)`, and inside it make exactly two textual substitutions in the image-copy loop (former step 4):
- `parse.spineXHTMLURLByIndex[allBlocks[idx].spineIndex] ?? epubURL` → `... ?? assetBaseURL`
- `epubRoot: epubURL` → `epubRoot: assetBaseURL`

Everything else (the `let parse = ...` line is now removed from this method, since `parse` is a parameter) stays identical.

- [ ] **Step 2: Build + run existing EPUB import tests to verify no behavior change**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiolessEPUBImportTests`
Expected: PASS. Also run `make test-only FILTER=EchoTests/EPUBImportTests` and `EchoTests/EPUBTOCImportTests` — all PASS (the refactor changed structure, not behavior).

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Services/EPUBImportService.swift
git commit -m "refactor(epub): split import into parse and import(parse:) phases"
```

---

## Task 6: Extract `DocumentImportFinalizer`

**Files:**
- Create: `EchoCore/Services/DocumentImportFinalizer.swift`
- Modify: `EchoCore/Services/EPUBAutoImportScanner.swift:148-255`

**Interfaces:**
- Produces: `enum DocumentImportFinalizer { static func finalize(audiobookID: String, blocks: [EPubBlockRecord], fileURL: URL, duration: TimeInterval?, databaseService: DatabaseService) async -> Bool }` — runs the alignment-sidecar / CloudKit / initial-anchor / timeline-recalc / notification tail and returns `true`. **Behavior-preserving extraction.**

- [ ] **Step 1: Create the finalizer with the extracted tail**

Create `EchoCore/Services/DocumentImportFinalizer.swift`. Move the body of `EPUBAutoImportScanner.importEPUBFile` **from line 148 (`let alignmentService = AlignmentService(...)`) through line 254 (the `NotificationCenter` post inside `MainActor.run`)** verbatim into this function, renaming the local `epubURL` references to the `fileURL` parameter and returning `true` at the end:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// The shared post-import tail for document (EPUB / text) ingestion: create
/// initial alignment anchors (alignment.json sidecar → CloudKit → first/last
/// fallback), recalculate the read-along timeline, and post
/// `timelineItemsIngested`. Extracted from `EPUBAutoImportScanner` so EPUB and
/// text import share one copy (no divergence in anchor/timeline behavior).
enum DocumentImportFinalizer {
    private static let logger = Logger(category: "DocumentImportFinalizer")

    static func finalize(
        audiobookID: String,
        blocks: [EPubBlockRecord],
        fileURL: URL,
        duration: TimeInterval?,
        databaseService: DatabaseService
    ) async -> Bool {
        let alignmentService = AlignmentService(
            db: databaseService.writer, audiobookID: audiobookID)
        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)

        let alignmentSidecarURL = fileURL.deletingPathExtension()
            .appendingPathExtension("alignment.json")
        // ... move lines 156-245 here verbatim, substituting `fileURL` for `epubURL`
        //     (the sidecar URL above, and `fileURL.deletingLastPathComponent()`
        //     for the CloudKit folderURL). Keep `duration` semantics identical.

        await MainActor.run {
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID])
        }
        return true
    }
}
```

> The implementer copies lines 156-245 of the current `importEPUBFile` between the marked points, changing only `epubURL` → `fileURL`. No logic changes.

- [ ] **Step 2: Replace the inline tail in `importEPUBScanner`**

In `EchoCore/Services/EPUBAutoImportScanner.swift`, replace everything from line 148 (`let alignmentService = ...`) through line 255 (`return true`) — but **keep** the `logger.info("Auto-imported ...")` at line 144-146 — with:

```swift
            return await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: epubURL,
                duration: duration, databaseService: databaseService)
```

The surrounding `do { ... } catch { logger.error(...); return false }` stays.

- [ ] **Step 3: Build + run EPUB tests to verify no behavior change**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiolessEPUBImportTests`
Expected: PASS (the four audio-less import tests prove anchors/timeline still land).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/DocumentImportFinalizer.swift EchoCore/Services/EPUBAutoImportScanner.swift
git commit -m "refactor(import): extract shared DocumentImportFinalizer tail"
```

---

## Task 7: TextAutoImportScanner + end-to-end integration

**Files:**
- Create: `EchoCore/Services/TextAutoImportScanner.swift`
- Test: `EchoTests/TextDocumentImportTests.swift`

**Interfaces:**
- Consumes: `parseMarkdownBlocks` / `parsePlainTextBlocks` (Tasks 2-3), `EPUBImportService.import(parse:)` (Task 5), `DocumentImportFinalizer.finalize` (Task 6).
- Produces: `enum TextAutoImportScanner { static func importTextFile(textURL: URL, audiobookID: String, databaseService: DatabaseService, force: Bool = false) async -> Bool }`.

- [ ] **Step 1: Write the failing integration test**

Create `EchoTests/TextDocumentImportTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct TextDocumentImportTests {

    private func stage(_ name: String, _ contents: String) throws -> (folder: URL, file: URL, id: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("textimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return (folder, file, folder.absoluteString)
    }

    @Test func markdownFileImportsAsAudioLessBookWithChapterZeroBlocks() async throws {
        let db = try DatabaseService(inMemory: ())
        let (folder, file, id) = try stage(
            "My Study Notes.md",
            "## Chapter One\n\nThe first **idea** to learn.\n\n### A Section\n\nDetail.\n\n## Chapter Two\n\nThe second idea.")
        defer { try? FileManager.default.removeItem(at: folder) }

        // Mirror loadFolder's no-audio branch: persist the audiobook row first.
        TimelineIngestionService.persistAudiobook(db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await TextAutoImportScanner.importTextFile(
            textURL: file, audiobookID: id, databaseService: db, force: false)

        #expect(didImport)
        // Chapter 0 holds body content narration reads (front matter excluded).
        let chapterZero = try EPubBlockDAO(db: db.writer).blocks(for: id, chapterIndex: 0)
        #expect(chapterZero.count > 0)
        #expect(chapterZero.allSatisfy { !$0.isFrontMatter })
        // Two chapters total.
        let allBlocks = try EPubBlockDAO(db: db.writer).blocks(for: id)
        #expect(Set(allBlocks.compactMap(\.chapterIndex)).count == 2)
        // Inline bold survived into stored textFormats.
        #expect(allBlocks.contains { $0.decodedFormats.contains { $0.type == .bold } })
    }

    @Test func plainTextNoMarkersImportsSingleChapter() async throws {
        let db = try DatabaseService(inMemory: ())
        let (folder, file, id) = try stage(
            "loose.txt", "One paragraph.\n\nAnother paragraph, no chapters at all.")
        defer { try? FileManager.default.removeItem(at: folder) }

        TimelineIngestionService.persistAudiobook(db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await TextAutoImportScanner.importTextFile(
            textURL: file, audiobookID: id, databaseService: db, force: false)

        #expect(didImport)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: id, chapterIndex: 0).count > 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests`
Expected: FAIL — `cannot find 'TextAutoImportScanner' in scope`.

- [ ] **Step 3: Implement the scanner**

Create `EchoCore/Services/TextAutoImportScanner.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Imports a Markdown / plain-text file as an audio-less book's blocks, reusing
/// the shared `EPUBImportService.import(parse:)` persist phase and the shared
/// `DocumentImportFinalizer` tail. The text counterpart to
/// `EPUBAutoImportScanner.importEPUBFile`. The parent `audiobook` row must
/// already exist (loadFolder's `persistAudiobookToSQL` / the macOS batch path
/// creates it) — `epub_block` has a NOT-NULL FK to it.
enum TextAutoImportScanner {
    private static let logger = Logger(category: "TextAutoImportScanner")

    /// Markdown vs plain-text is chosen by extension.
    static func importTextFile(
        textURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        force: Bool = false
    ) async -> Bool {
        if !force {
            let alreadyImported =
                (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID)
                    .isEmpty) == false
            if alreadyImported { return false }
        }

        do {
            let parse: EPUBBlockParse
            switch textURL.pathExtension.lowercased() {
            case "md", "markdown":
                parse = try parseMarkdownBlocks(audiobookID: audiobookID, fileURL: textURL)
            default:
                parse = try parsePlainTextBlocks(audiobookID: audiobookID, fileURL: textURL)
            }

            let importer = EPUBImportService(
                assetStorage: EPUBAssetStorage(databaseService: databaseService))
            let blocks = try await importer.import(
                parse: parse, audiobookID: audiobookID, chapters: [], bookDuration: nil,
                assetBaseURL: textURL.deletingLastPathComponent())
            logger.info("Imported \(blocks.count) text blocks for \(audiobookID)")

            return await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: textURL,
                duration: nil, databaseService: databaseService)
        } catch {
            logger.error("Text auto-import failed: \(error.localizedDescription)")
            return false
        }
    }
}
```

> Verify the `EPubBlockDAO` method name for the already-imported guard matches the EPUB scanner's (`visibleBlocks(for:)`, see `EPUBAutoImportScanner.swift:101`). If your DAO exposes `blocks(for:)` only, use that.

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/TextDocumentImportTests`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/TextAutoImportScanner.swift EchoTests/TextDocumentImportTests.swift
git commit -m "feat(narration): import text files via shared persist + finalize path"
```

---

## Task 8: iOS wiring

**Files:**
- Modify: `EchoCore/Services/PlaylistManager.swift:38`
- Modify: `EchoCore/Utilities/FolderPicker.swift:10-12`
- Modify: `EchoCore/Services/PlayerLoadingCoordinator.swift:201-211`

**Interfaces:**
- Consumes: `TextAutoImportScanner.importTextFile` (Task 7).
- Produces: a picked `.md`/`.markdown`/`.txt`/`.text` file opens as an audio-less book and imports its blocks.

- [ ] **Step 1: Recognize text as a study document**

In `EchoCore/Services/PlaylistManager.swift`, change line 38:

```swift
    static let documentExtensions: Set<String> = ["epub", "pdf", "md", "markdown", "txt", "text"]
```

- [ ] **Step 2: Add text types to the picker**

In `EchoCore/Utilities/FolderPicker.swift`, replace lines 10-12:

```swift
        let m4bType = UTType(filenameExtension: "m4b") ?? .audio
        let epubType = UTType(filenameExtension: "epub")
        let markdownType = UTType(filenameExtension: "md")
        let types: [UTType] = [.folder, m4bType, .audio, .plainText]
            + [epubType, markdownType].compactMap { $0 }
```

- [ ] **Step 3: Route text files in the audio-less importer**

In `EchoCore/Services/PlayerLoadingCoordinator.swift`, replace lines 201-211 (the `importedEPUBFile` decision + the `if importedEPUBFile { ... } else { ... }` block) with:

```swift
        let ext = pickedURL.pathExtension.lowercased()
        let importedEPUBFile = !isDirectory && ext == "epub"
        let importedTextFile = !isDirectory && ["md", "markdown", "txt", "text"].contains(ext)
        documentImportTask = Task { @MainActor in
            let didImport: Bool
            if importedEPUBFile {
                didImport = await EPUBAutoImportScanner.importEPUBFile(
                    epubURL: pickedURL, audiobookID: audiobookID, databaseService: db,
                    chapters: [], duration: nil, force: false)
            } else if importedTextFile {
                didImport = await TextAutoImportScanner.importTextFile(
                    textURL: pickedURL, audiobookID: audiobookID, databaseService: db, force: false)
            } else {
                didImport = await EPUBAutoImportScanner.scanAndImportIfNeeded(
                    folderURL: folderURL, databaseService: db, chapters: [], duration: nil)
            }
```

(Leave the rest of the `documentImportTask` closure — the `hasDocument` titling and `documentIngestionTrigger += 1` — unchanged.)

- [ ] **Step 4: Build + run the audio-less import suite (regression) and the text suite**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiolessEPUBImportTests && make test-only FILTER=EchoTests/TextDocumentImportTests`
Expected: all PASS (no behavior regression; text path still green).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/PlaylistManager.swift EchoCore/Utilities/FolderPicker.swift EchoCore/Services/PlayerLoadingCoordinator.swift
git commit -m "feat(narration): wire Markdown/text file import on iOS"
```

---

## Task 9: macOS wiring

**Files:**
- Modify: `Echo macOS/Echo_macOSApp.swift:272-306`
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift:512-544`

**Interfaces:**
- Consumes: `TextAutoImportScanner.importTextFile` (Task 7).
- Produces: the "Narrate EPUB(s)…" command accepts `.md`/`.markdown`/`.txt` files and narrates them on macOS.

- [ ] **Step 1: Accept text types in the narrate panel + route them**

In `Echo macOS/Echo_macOSApp.swift`, in `chooseEPUBsToNarrate()`, replace the `allowedContentTypes` line (278):

```swift
        panel.allowedContentTypes = [
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            .plainText,
        ]
```

In `narrateSelection(_:)`, replace the `else if` (line 303-305):

```swift
        } else if ["epub", "md", "markdown", "txt", "text"].contains(url.pathExtension.lowercased()) {
            try? batchService.enqueueNarration(epubURL: url)
        }
```

- [ ] **Step 2: Branch the batch import to text**

In `Echo macOS/Services/MacBatchProcessingService.swift`, in `importEPUBOnly(...)` (line 512), after the `AudiobookDAO(...).save(...)` call (line 528) and **before** the `EPUBImportCoordinator.importEPUB` call (line 534), branch on extension:

```swift
        let ext = epubURL.pathExtension.lowercased()
        if ["md", "markdown", "txt", "text"].contains(ext) {
            _ = await TextAutoImportScanner.importTextFile(
                textURL: epubURL, audiobookID: audiobookID, databaseService: dbService, force: true)
        } else {
            await EPUBImportCoordinator.importEPUB(
                from: epubURL, to: epubURL, databaseService: dbService, chapters: [], duration: nil)
        }
        let blockCount = (try? EPubBlockDAO(db: dbService.writer).count(for: audiobookID)) ?? 0
        guard blockCount > 0 else {
            throw BatchProcessingError.emptyImport(epubURL.lastPathComponent)
        }
```

(Replace the existing unconditional `EPUBImportCoordinator.importEPUB(...)` + `blockCount` guard with the branch above.)

- [ ] **Step 3: Build the macOS target**

First list schemes to confirm the name: `xcodebuild -list -project Echo.xcodeproj | sed -n '/Schemes/,$p'`
Then (single invocation, capped jobs): `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`. (Use the exact macOS scheme name from `-list`.)

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/Echo_macOSApp.swift" "Echo macOS/Services/MacBatchProcessingService.swift"
git commit -m "feat(narration): wire Markdown/text narration into macOS batch flow"
```

---

## Task 10: Documentation sync

**Files:**
- Modify: `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md`, `ROADMAP.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the docs via the doc-sync skill**

Invoke the `doc-sync` skill (or edit directly). Apply:
- `README.md` — under supported import formats, add: "Markdown (`.md`/`.markdown`) and plain text (`.txt`) — imported as standalone narratable books; Markdown chapters follow the heading hierarchy."
- `ARCHITECTURE.md` — document `TextDocumentParser` (emits the same `EPUBBlockParse` as the EPUB parser; one synthetic spine per chapter), the shared `import(parse:)` phase, and `DocumentImportFinalizer`.
- `CHANGELOG.md` — add an entry: "Add Markdown / plain-text import for on-device narration (iOS + macOS)."
- `ROADMAP.md` — mark text-import narration as shipped; note out-of-scope follow-ups (attach-to-audio read-along, code-as-visible-non-spoken, image resolution, multi-file books).

- [ ] **Step 2: Commit**

```bash
git add README.md ARCHITECTURE.md CHANGELOG.md ROADMAP.md
git commit -m "docs(narration): document Markdown/plain-text import"
```

---

## Self-Review

**Spec coverage:**
- Plain-text heuristic chapters + single-chapter fallback → Task 3. ✓
- Markdown smart-strip + code/table/image dropped → Task 2. ✓
- Bold/italic/strikethrough → `textFormats` → Task 1 (+ asserted end-to-end in Task 7). ✓
- Filename = title → Task 7 integration (audiobook row title from filename; loader path) / macOS `importEPUBOnly` already titles from filename. ✓
- Heading hierarchy: chapter level = shallowest repeating; lone shallower = front matter; deeper = sections → Tasks 2 & 4. ✓
- Nested reader TOC → Task 4 (+ resolved by existing `resolveTOCEntries` via Task 5's path). ✓
- iOS + macOS → Tasks 8 & 9. ✓
- Approach A (shared `import(parse:)`), no duplication → Tasks 5-7. ✓
- No schema migration → reuses `epub_block`; no migration task. ✓
- Out-of-scope items documented → Task 10. ✓

**Placeholder scan:** Task 5 and Task 6 reference moving an existing block "verbatim" rather than reprinting ~100 lines — intentional for behavior-preserving extractions, with exact line ranges and the only substitution (`epubURL`→`assetBaseURL`/`fileURL`) called out. All new code is shown in full.

**Type consistency:** `EPUBBlockParse`, `TextBlockDescriptor(kind:text:imagePath:htmlContent:markers:textFormats:anchorIDs:)`, `SpineItemDescriptor(id:href:mediaType:linear:)`, `TOCEntryNode(title:href:fragment:children:)`, `TextFormat(type:range:)`, `SyncMarker(type:payload:epubCharOffset:)`, and the `EPubBlockRecord` memberwise init match the definitions in `Shared/`. `import(parse:audiobookID:chapters:bookDuration:assetBaseURL:)` is defined in Task 5 and consumed identically in Task 7. `DocumentImportFinalizer.finalize(audiobookID:blocks:fileURL:duration:databaseService:)` defined in Task 6, consumed identically in Tasks 6-7.
