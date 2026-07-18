# Code Blocks as Visual Narration Blocks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EPUB `<pre>` and Markdown fenced code become a native `.code` block kind — displayed as monospaced, selectable, theme-aware cards (reader feed + Visual Listening slideshow) and spoken as a short caption cue instead of raw syntax.

**Architecture:** Import-time detection writes `.code` blocks whose `text` is raw preserved code and whose `narrationText` is the spoken cue; one special-case at the narration-prepare seam speaks the cue; rendering adds a `CodeCardCell` and generalizes the Visual Listening cue payload to image-or-code. Spec: `docs/superpowers/specs/2026-07-18-code-block-visual-narration-design.md` (approved).

**Tech Stack:** Swift 6 / SwiftUI + UIKit cells, GRDB, Swift Testing (`import Testing`), XMLParser-based EPUB parsing. No third-party dependencies.

## Global Constraints

- Branch: `claude/textbooks-echo-narration-47b10b`, based on `origin/nightly`. Never push to `main`/`weekly`/`nightly`; final PR targets `nightly` (`gh pr create --base nightly`).
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on line 1. A SwiftFormat hook reflows edited files — after each edit, verify the SPDX line is still line 1.
- New EchoCore view files that import UIKit must be wrapped in `#if canImport(UIKit)` … `#endif` (the project uses file-system-synchronized groups; the gate keeps macOS/echo-cli targets compiling without pbxproj membership edits).
- Builds go through the RAM gate: prefix every build/test command with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && `. Never enable uncapped parallel testing or `-jobs`.
- Test loop: `make build-tests` once, then `make test-only FILTER=EchoTests/<SuiteName>` per suite; full `make test` at the end (requires a simulator literally named "iPhone 17").
- Conventional Commits; commit at the end of every task.
- Targets: iOS 18+, macOS 15+, watchOS 11+. Swift Testing for unit tests (`struct` suites, `@Test` functions, `#expect`).
- The spoken-cue fallback string is exactly `"Code listing."` everywhere.

---

### Task 1: `.code` kind, `code_language` column, migration V36, exhaustive-switch fixes

Adding the enum case breaks three exhaustive switches at compile time; they are fixed in this task so the build stays green. Adding the stored property to the record makes GRDB write the column on every insert, so the migration ships in the same task.

**Files:**
- Modify: `Shared/Database/EPubBlockRecord.swift` (Kind enum ~line 88; properties ~line 33; CodingKeys ~line 59)
- Create: `Shared/Database/Migrations/Schema_V36.swift`
- Modify: `Shared/Database/DatabaseService.swift` (~line 155, after the `v35_library_edition_grouping` registration)
- Modify: `EchoCore/Services/BlockExportDocument.swift:70-86`
- Modify: `Shared/Services/StudyDeckSourceBuilder.swift:82-89`
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift:551-563` (a11y label switch)
- Test: `EchoTests/SchemaV36CodeLanguageTests.swift` (create)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `EPubBlockRecord.Kind.code` (raw `"code"`), `EPubBlockRecord.codeLanguage: String?` (column `code_language`), migration key `v36_code_language`. All later tasks rely on these exact names.

- [ ] **Step 1: Confirm V36 is still free.** Run:

```bash
ls Shared/Database/Migrations/ | sort -V | tail -3
git log origin/nightly --oneline -5 -- Shared/Database/Migrations/
```

Expected: `Schema_V35.swift` is the max. If a V36 appeared on nightly since this plan was written, renumber every "V36"/"v36" in this task to the next free number.

- [ ] **Step 2: Write the failing migration test** at `EchoTests/SchemaV36CodeLanguageTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct SchemaV36CodeLanguageTests {
    @Test func codeLanguageColumnRoundTrips() throws {
        let db = try DatabaseService(inMemory: true)
        var block = EPubBlockRecord(
            id: "epub-test-s0-b0",
            audiobookID: "test-book",
            spineHref: "ch01.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.code.rawValue,
            text: "print(\"hello\")",
            htmlContent: nil,
            cardColor: nil,
            imagePath: nil,
            chapterIndex: nil,
            isHidden: false,
            hiddenReason: nil,
            wordCount: 1,
            markers: nil,
            textFormats: nil,
            narrationText: "Code listing.",
            codeLanguage: "python",
            createdAt: nil,
            modifiedAt: nil)
        try db.writer.write { try block.insert($0) }
        let fetched = try db.writer.read {
            try EPubBlockRecord.fetchOne($0, key: "epub-test-s0-b0")
        }
        #expect(fetched?.codeLanguage == "python")
        #expect(fetched.flatMap { EPubBlockRecord.Kind(rawValue: $0.blockKind) } == .code)
    }
}
```

Note: match the surrounding tests' `DatabaseService(inMemory:)` spelling — check an existing test (e.g. `EchoTests/VisualListeningViewModelTests.swift` has a `makeDatabase()` helper) and reuse whichever in-memory constructor pattern it uses, keeping the assertions above.

- [ ] **Step 3: Run it to verify it fails** (compile error on `.code` / `codeLanguage` is the expected failure):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: FAIL — `type 'EPubBlockRecord.Kind' has no member 'code'`.

- [ ] **Step 4: Implement.** In `Shared/Database/EPubBlockRecord.swift`:

```swift
// In enum Kind (line ~88), add:
        case code
```

```swift
// After `var narrationText: String?` (line ~33), add:
    /// Language hint for `.code` blocks ("python", "swift", …), sniffed from
    /// markup at import. Nil for non-code blocks or unhinted listings.
    var codeLanguage: String?
```

```swift
// In CodingKeys, after `case narrationText = "narration_text"`, add:
        case codeLanguage = "code_language"
```

Property position matters: `codeLanguage` must sit between `narrationText` and `createdAt` so the memberwise initializer's argument order matches the test above and Task 2's call sites.

Create `Shared/Database/Migrations/Schema_V36.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V36 — adds `code_language` column to `epub_block` for `.code` blocks
/// (language hint sniffed at import, e.g. "python"). Nullable — nil means
/// no hint / not a code block (backward-compatible with all existing books).
enum Schema_V36 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "code_language", .text)
        }
    }
}
```

In `Shared/Database/DatabaseService.swift`, after the `v35_library_edition_grouping` block (line ~155):

```swift
        migrator.registerMigration("v36_code_language") { db in
            try Schema_V36.migrate(db)
        }
```

Fix the three exhaustive switches. `EchoCore/Services/BlockExportDocument.swift` — extend the tuple and switch:

```swift
    /// Per-kind block counts for the CLI summary line.
    var kindCounts: (paragraphs: Int, headings: Int, sentences: Int, images: Int, code: Int) {
        var paragraphs = 0
        var headings = 0
        var sentences = 0
        var images = 0
        var code = 0
        for block in blocks {
            switch EPubBlockRecord.Kind(rawValue: block.kind) {
            case .paragraph: paragraphs += 1
            case .heading: headings += 1
            case .sentence: sentences += 1
            case .image: images += 1
            case .code: code += 1
            case nil: break
            }
        }
        return (paragraphs, headings, sentences, images, code)
    }
```

Then `grep -rn "kindCounts" --include="*.swift" .` and update every consumer of the tuple (expected: one CLI summary print site) to destructure/print the fifth element, e.g. append `, \(counts.code) code` to the summary string.

`Shared/Services/StudyDeckSourceBuilder.swift` — code is not prose:

```swift
    private static func isTextBlock(kind: String) -> Bool {
        switch EPubBlockRecord.Kind(rawValue: kind) {
        case .heading, .paragraph, .sentence:
            return true
        case .image, .code, nil:
            return false
        }
    }
```

`EchoCore/Views/ReaderFeedCollectionView.swift` a11y switch (~line 551) — add before the `.paragraph, .sentence` case:

```swift
            case .code:
                return clippedText.isEmpty
                    ? String(localized: "Code listing")
                    : String(localized: "Code listing. \(clippedText)")
```

- [ ] **Step 5: Run the test to verify it passes:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/SchemaV36CodeLanguageTests
```

Expected: PASS.

- [ ] **Step 6: Run the schema-migration-reviewer agent** on the diff (it checks version collisions, registration order, and re-import implications). Address anything it flags.

- [ ] **Step 7: Commit:**

```bash
git add Shared/Database/ EchoCore/Services/BlockExportDocument.swift Shared/Services/StudyDeckSourceBuilder.swift EchoCore/Views/ReaderFeedCollectionView.swift EchoTests/SchemaV36CodeLanguageTests.swift
git commit -m "feat(db): add .code block kind and code_language column (V36)"
```

---

### Task 2: EPUB parser — `<pre>` raw capture, language sniff, figcaption cue

**Files:**
- Modify: `Shared/EPUBXMLParsing.swift` (`TextBlockDescriptor` ~line 69; `XHTMLBlockDelegate` ~lines 476-822)
- Modify: `Shared/EPUBBlockParser.swift` (heuristic re-wrap ~line 144; record mapping ~line 212)
- Test: `EchoTests/EPUBCodeBlockParsingTests.swift` (create)

**Interfaces:**
- Consumes: `EPubBlockRecord.Kind.code`, `EPubBlockRecord.codeLanguage` (Task 1).
- Produces: `TextBlockDescriptor.narrationCue: String?` and `TextBlockDescriptor.codeLanguage: String?`; `.code` descriptors whose `text` preserves whitespace; records with `narrationText` = cue and `code_language` populated. Also `XHTMLBlockDelegate.codeLanguage(fromClassAttribute:)` (static, internal — reused conceptually by Task 3's fence parsing but Markdown has its own info-string parser).

- [ ] **Step 1: Write the failing tests** at `EchoTests/EPUBCodeBlockParsingTests.swift`. These call `parseXHTML(from:)` directly (same pattern as `EchoTests/EPUBStructureParsingTests.swift`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBCodeBlockParsingTests {

    private func blocks(_ xhtml: String) -> [TextBlockDescriptor] {
        parseXHTML(from: Data(xhtml.utf8)).blocks
    }

    @Test func preBecomesCodeBlockWithWhitespacePreserved() {
        let parsed = blocks("""
            <html><body>
            <p>Consider this function:</p>
            <pre><code class="language-python">def greet(name):
                print(f"hi {name}")

                return name</code></pre>
            <p>It greets people.</p>
            </body></html>
            """)
        #expect(parsed.count == 3)
        #expect(parsed[1].kind == .code)
        #expect(parsed[1].text == "def greet(name):\n    print(f\"hi {name}\")\n\n    return name")
        #expect(parsed[1].codeLanguage == "python")
        #expect(parsed[1].narrationCue == "Code listing.")
        // Neighbors are untouched prose.
        #expect(parsed[0].text == "Consider this function:")
        #expect(parsed[2].text == "It greets people.")
    }

    @Test func syntaxHighlightSpansInsidePreContributeCharactersOnly() {
        let parsed = blocks("""
            <html><body><pre><span class="kw">let</span> x = <span class="num">5</span></pre></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .code)
        #expect(parsed[0].text == "let x = 5")
    }

    @Test func inlineCodeOutsidePreStaysSpokenProse() {
        let parsed = blocks("""
            <html><body><p>Call <code>len()</code> on the list.</p></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .paragraph)
        #expect(parsed[0].text == "Call len() on the list.")
    }

    @Test func figureFigcaptionSuppliesTheCue() {
        let parsed = blocks("""
            <html><body>
            <figure>
            <pre><code>x = 1</code></pre>
            <figcaption>Listing 4-2. Assigning a variable</figcaption>
            </figure>
            </body></html>
            """)
        let code = parsed.first { $0.kind == .code }
        #expect(code?.narrationCue == "Listing 4-2. Assigning a variable")
        // figcaption text must NOT leak into prose blocks.
        #expect(!parsed.contains { $0.kind == .paragraph && $0.text?.contains("Listing 4-2") == true })
    }

    @Test func figcaptionBeforePreAlsoSuppliesTheCue() {
        let parsed = blocks("""
            <html><body>
            <figure>
            <figcaption>Listing 1-1. Hello</figcaption>
            <pre>print("hi")</pre>
            </figure>
            </body></html>
            """)
        #expect(parsed.first { $0.kind == .code }?.narrationCue == "Listing 1-1. Hello")
    }

    @Test func emptyPreIsDropped() {
        let parsed = blocks("<html><body><pre>   \n  \n</pre><p>After.</p></body></html>")
        #expect(!parsed.contains { $0.kind == .code })
        #expect(parsed.count == 1)
    }

    @Test func brInsidePreBecomesNewline() {
        let parsed = blocks("<html><body><pre>line one<br/>line two</pre></body></html>")
        #expect(parsed[0].text == "line one\nline two")
    }

    @Test func languageSniffVariants() {
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "language-Swift") == "swift")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "highlight lang-rb") == "rb")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "brush:python") == "python")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "pretty") == nil)
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: nil) == nil)
    }

    @Test func tablesStillFlattenAsToday() {
        let parsed = blocks("""
            <html><body><table><tr><td>Topic</td><td>Entropy</td></tr></table></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .paragraph)
        #expect(parsed[0].text == "Topic Entropy")
    }
}
```

- [ ] **Step 2: Run to verify failure:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: FAIL — `TextBlockDescriptor` has no `narrationCue`/`codeLanguage`, `Kind.code` unhandled in parser (compile errors first, then assertion failures once it compiles).

- [ ] **Step 3: Implement.**

**3a — `TextBlockDescriptor`** (`Shared/EPUBXMLParsing.swift:69`): add two properties and defaulted init params (appended after `anchorIDs`, so all existing call sites compile unchanged):

```swift
struct TextBlockDescriptor: Sendable {
    let kind: EPubBlockRecord.Kind
    var text: String?
    let imagePath: String?
    let htmlContent: String?
    let markers: [SyncMarker]
    let textFormats: [TextFormat]
    let rawClasses: [String]
    let rawTags: String
    let anchorIDs: [String]
    /// Spoken cue for `.code` blocks (figcaption or "Code listing."). Nil otherwise.
    var narrationCue: String?
    /// Language hint for `.code` blocks. Nil otherwise.
    let codeLanguage: String?

    init(
        kind: EPubBlockRecord.Kind, text: String?, imagePath: String?, htmlContent: String?,
        markers: [SyncMarker] = [], textFormats: [TextFormat] = [],
        rawClasses: [String] = [], rawTags: String = "", anchorIDs: [String] = [],
        narrationCue: String? = nil, codeLanguage: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.htmlContent = htmlContent
        self.markers = markers
        self.textFormats = textFormats
        self.rawClasses = rawClasses
        self.rawTags = rawTags
        self.anchorIDs = anchorIDs
        self.narrationCue = narrationCue
        self.codeLanguage = codeLanguage
    }
}
```

(Keep the doc comment above the struct in sync: "paragraph, heading, image, or code".)

**3b — `XHTMLBlockDelegate` state** (after `blockquoteDepth`/`currentBlockHasBlockquote`, ~line 491):

```swift
    // MARK: - Code block (<pre>) capture
    private var isInPre = false
    private var currentCodeText = ""
    private var currentCodeLanguage: String?
    // MARK: - Figure / figcaption (code-listing captions)
    private var figureDepth = 0
    private var isInFigcaption = false
    private var figcaptionText = ""
    /// Indices into `textBlocks` of code blocks emitted inside the open <figure>,
    /// so a <figcaption> in either position (before or after the <pre>) can
    /// retroactively supply their cue at </figure>.
    private var pendingFigureCodeBlockIndices: [Int] = []
```

**3c — `didStartElement`**: at the very top, BEFORE the `skipTags` check, capture figcaption-in-figure instead of skipping it:

```swift
        if elementName == "figcaption", figureDepth > 0, skipDepth == 0 {
            isInFigcaption = true
            return
        }
        if skipTags.contains(elementName) {
            skipDepth += 1
            return
        }
```

After the `head`/`title` checks and BEFORE `insertSoftWordBreakIfStructural(elementName)`, add the pre-mode short-circuit and the `<pre>`/`<figure>` openers:

```swift
        if isInPre {
            // Inside <pre>, nested markup contributes characters only — no soft
            // word breaks, no block flushes. <br/> is a real line break; a nested
            // <code class="language-…"> may carry the language hint.
            if elementName == "br" { currentCodeText += "\n" }
            if elementName == "code", currentCodeLanguage == nil {
                currentCodeLanguage = Self.codeLanguage(
                    fromClassAttribute: attributeDict["class"])
            }
            return
        }
        if elementName == "figure" { figureDepth += 1 }
        if elementName == "pre" {
            flushBlock()
            captureAnchorID(attributeDict["id"])
            isInPre = true
            currentCodeText = ""
            currentCodeLanguage = Self.codeLanguage(fromClassAttribute: attributeDict["class"])
            return
        }
```

(The existing `let anchorID = attributeDict["id"]` line stays where it is for the other branches; the `pre` branch reads the attribute directly because it returns early.)

**3d — `foundCharacters`**: after the `guard skipDepth == 0` and head/title handling, before the existing collapsing appends:

```swift
        if isInFigcaption {
            appendCollapsed(string, to: &figcaptionText)
            return
        }
        if isInPre {
            currentCodeText += string  // raw — indentation and newlines are content
            return
        }
```

**3e — `didEndElement`**: at the very top, mirror-order with didStart:

```swift
        if elementName == "figcaption", isInFigcaption {
            isInFigcaption = false
            return
        }
        if skipTags.contains(elementName) {
            skipDepth = max(0, skipDepth - 1)
            return
        }
        guard skipDepth == 0 else { return }

        if isInPre {
            if elementName == "pre" {
                isInPre = false
                emitCodeBlock()
            }
            return  // ignore inner closes (span/code) while in pre
        }
        if elementName == "figure" {
            figureDepth = max(0, figureDepth - 1)
            attachFigcaptionToPendingCodeBlocks()
            // fall through: figure was always transparent; keep the soft word
            // break below by NOT returning here.
        }
```

(The `head`/`title` checks and `insertSoftWordBreakIfStructural` that follow stay exactly as they are.)

**3f — new private helpers** (below `flushBlock()`):

```swift
    /// Emits the accumulated <pre> content as a `.code` descriptor. Leading and
    /// trailing blank lines are dropped; internal indentation is preserved.
    private func emitCodeBlock() {
        let lines = currentCodeText.components(separatedBy: "\n")
        let isBlank: (String) -> Bool = {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let trimmed = Array(
            lines.drop(while: isBlank).reversed().drop(while: isBlank).reversed())
        let code = trimmed.joined(separator: "\n")
        currentCodeText = ""
        let language = currentCodeLanguage
        currentCodeLanguage = nil
        guard !code.isEmpty else { return }
        textBlocks.append(
            TextBlockDescriptor(
                kind: .code,
                text: code,
                imagePath: nil,
                htmlContent: nil,
                rawTags: "pre",
                anchorIDs: pendingAnchorIDs,
                narrationCue: "Code listing.",
                codeLanguage: language
            ))
        pendingAnchorIDs = []
        if figureDepth > 0 {
            pendingFigureCodeBlockIndices.append(textBlocks.count - 1)
        }
    }

    /// At </figure>, a captured <figcaption> becomes the spoken cue for the
    /// figure's code blocks (handles caption-before-pre and caption-after-pre).
    private func attachFigcaptionToPendingCodeBlocks() {
        let caption = figcaptionText.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty {
            for index in pendingFigureCodeBlockIndices {
                textBlocks[index].narrationCue = caption
            }
        }
        figcaptionText = ""
        pendingFigureCodeBlockIndices = []
    }

    /// "language-python" / "lang-rb" / "brush:swift" → "python"/"rb"/"swift".
    static func codeLanguage(fromClassAttribute classAttr: String?) -> String? {
        guard let classAttr else { return nil }
        for cls in classAttr.split(separator: " ") {
            let lower = cls.lowercased()
            for prefix in ["language-", "lang-", "brush:"] where lower.hasPrefix(prefix) {
                let value = String(lower.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
```

**3g — heuristic re-wrap** (`Shared/EPUBBlockParser.swift:144`): the score pass rebuilds each descriptor field-by-field — without this edit the new fields are silently dropped. (`EPUBHeuristicEngine.score` already passes non-paragraph/heading kinds through untouched, so `.code` keeps its kind.) Add the two fields to the rebuild:

```swift
            textBlocks[j] = TextBlockDescriptor(
                kind: newKind,
                text: textBlocks[j].text,
                imagePath: textBlocks[j].imagePath,
                htmlContent: textBlocks[j].htmlContent,
                markers: textBlocks[j].markers,
                textFormats: textBlocks[j].textFormats,
                rawClasses: textBlocks[j].rawClasses,
                rawTags: textBlocks[j].rawTags,
                anchorIDs: textBlocks[j].anchorIDs,
                narrationCue: textBlocks[j].narrationCue,
                codeLanguage: textBlocks[j].codeLanguage
            )
```

**3h — record mapping** (`Shared/EPUBBlockParser.swift:212`, the `EPubBlockRecord(` init inside the block loop): insert two labeled arguments between `textFormats:` and `createdAt:`:

```swift
                markers: EPubBlockRecord.encodeMarkers(textBlock.markers),
                textFormats: EPubBlockRecord.encodeFormats(textBlock.textFormats),
                narrationText: textBlock.narrationCue,
                codeLanguage: textBlock.codeLanguage,
                createdAt: createdAt,
```

- [ ] **Step 4: Run the suite:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/EPUBCodeBlockParsingTests
```

Expected: PASS. Also run the existing parser suites to catch regressions:

```bash
make test-only FILTER=EchoTests/EPUBStructureParsingTests && make test-only FILTER=EchoTests/EPUBBlockParserParityTests && make test-only FILTER=EchoTests/EPUBTextNormalizationTests
```

Expected: PASS (no behavior change for non-code markup).

- [ ] **Step 5: Commit:**

```bash
git add Shared/EPUBXMLParsing.swift Shared/EPUBBlockParser.swift EchoTests/EPUBCodeBlockParsingTests.swift
git commit -m "feat(epub): parse <pre> into .code blocks with preserved whitespace, language sniff, figcaption cues"
```

---

### Task 3: Markdown parser — fenced code emission

**Files:**
- Modify: `Shared/TextDocumentParser.swift` (TextUnit ~line 7; tokenizer ~lines 58-116; `emit` + `buildParse` ~lines 158-292)
- Test: `EchoTests/MarkdownCodeFenceTests.swift` (create)

**Interfaces:**
- Consumes: `EPubBlockRecord.Kind.code`, record fields from Task 1; descriptor fields from Task 2.
- Produces: `.code` blocks from ``` / ~~~ fences with `narrationText = "Code listing."` and `codeLanguage` from the fence info string.

- [ ] **Step 1: Write the failing tests** at `EchoTests/MarkdownCodeFenceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct MarkdownCodeFenceTests {

    private func parse(_ md: String) -> EPUBBlockParse {
        parseMarkdown(
            audiobookID: "md-test", content: md,
            sourceURL: URL(fileURLWithPath: "/tmp/test.md"))
    }

    @Test func fencedCodeBecomesCodeBlockWithIndentationPreserved() {
        let parsed = parse("""
            # Chapter One

            Some prose.

            ```python
            def f():
                return 1
            ```

            More prose.
            """)
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code != nil)
        #expect(code?.text == "def f():\n    return 1")
        #expect(code?.codeLanguage == "python")
        #expect(code?.narrationText == "Code listing.")
        // Prose neighbors intact.
        #expect(parsed.blocks.contains { $0.text == "Some prose." })
        #expect(parsed.blocks.contains { $0.text == "More prose." })
    }

    @Test func fenceWithoutInfoStringHasNilLanguage() {
        let parsed = parse("```\nx = 1\n```")
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code?.codeLanguage == nil)
        #expect(code?.text == "x = 1")
    }

    @Test func unterminatedFenceAtEOFStillEmits() {
        let parsed = parse("Prose.\n\n```swift\nlet x = 5")
        let code = parsed.blocks.first {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        }
        #expect(code?.text == "let x = 5")
        #expect(code?.codeLanguage == "swift")
    }

    @Test func emptyFenceIsDropped() {
        let parsed = parse("```\n\n```\n\nProse.")
        #expect(!parsed.blocks.contains {
            EPubBlockRecord.Kind(rawValue: $0.blockKind) == .code
        })
    }
}
```

- [ ] **Step 2: Run to verify failure:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/MarkdownCodeFenceTests
```

Expected: FAIL — no code blocks emitted (fenced lines are currently discarded).

- [ ] **Step 3: Implement.**

**3a — `TextUnit`** (line ~7):

```swift
private enum TextUnit {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(text: String, language: String?)
}
```

**3b — tokenizer** (`tokenizeMarkdown`, lines ~58-116). Replace the fence handling and the `if inFence { continue }` line:

```swift
    var inFence = false
    var fenceLines: [String] = []
    var fenceLanguage: String?

    func flushFence() {
        let isBlank: (String) -> Bool = {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let trimmed = Array(
            fenceLines.drop(while: isBlank).reversed().drop(while: isBlank).reversed())
        let code = trimmed.joined(separator: "\n")
        if !code.isEmpty {
            units.append(.code(text: code, language: fenceLanguage))
        }
        fenceLines.removeAll()
        fenceLanguage = nil
    }
```

Inside the loop, replace the existing fence branch (lines ~73-82):

```swift
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            if inFence {
                inFence = false
                flushFence()
            } else {
                flushParagraph()
                inFence = true
                let info = trimmed.drop(while: { $0 == "`" || $0 == "~" })
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                fenceLanguage = info.split(separator: " ").first.map(String.init)
                if fenceLanguage?.isEmpty == true { fenceLanguage = nil }
            }
            continue
        }
        if inFence {
            fenceLines.append(rawLine)  // RAW line — indentation is content
            continue
        }
```

After the loop, next to the final `flushParagraph()`:

```swift
    flushParagraph()
    if inFence { flushFence() }  // unterminated fence at EOF
    return units
```

**3c — `emit` in `buildParse`** (line ~180): add two defaulted parameters and pass them through to the record and descriptor:

```swift
    func emit(
        kind: EPubBlockRecord.Kind, plain: String, formats: [TextFormat],
        isFrontMatter: Bool, headingLevel: Int?,
        narrationText: String? = nil, codeLanguage: String? = nil
    ) -> String? {
```

In its `EPubBlockRecord(` call, insert between `textFormats:` and `createdAt:`:

```swift
                textFormats: EPubBlockRecord.encodeFormats(formats),
                narrationText: narrationText,
                codeLanguage: codeLanguage,
                createdAt: createdAt,
```

In its `TextBlockDescriptor(` call, append after `anchorIDs:`:

```swift
                anchorIDs: anchorID.map { [$0] } ?? [],
                narrationCue: narrationText,
                codeLanguage: codeLanguage))
```

**3d — the unit switch** (line ~235): add the case after `.paragraph`:

```swift
        case .code(let text, let language):
            let front = (chapterLevel != nil) && !seenChapterHeading
            if front { emittedFrontMatter = true }
            emit(
                kind: .code, plain: text, formats: [],
                isFrontMatter: front, headingLevel: nil,
                narrationText: "Code listing.", codeLanguage: language)
```

Note: `emit` runs `plain` through nothing (no `MarkdownInlineFormatter`) for code — the case above passes the raw fence text and empty formats, so backticks/underscores inside code are NOT reinterpreted as inline formatting. (`MarkdownInlineFormatter.format` is applied by the *callers* for heading/paragraph; do not apply it here.)

- [ ] **Step 4: Run:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/MarkdownCodeFenceTests
```

Expected: PASS. Also re-run any existing markdown/text import suites: `grep -rl "parseMarkdown\|tokenizePlainText" EchoTests/ | xargs -n1 basename` and `make test-only FILTER=EchoTests/<each>`.

- [ ] **Step 5: Commit:**

```bash
git add Shared/TextDocumentParser.swift EchoTests/MarkdownCodeFenceTests.swift
git commit -m "feat(markdown): emit fenced code as .code blocks instead of discarding"
```

---

### Task 4: Narration cue + alignment exclusion

**Files:**
- Create: `EchoCore/Services/Narration/NarrationCodeBlockCue.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift:836-841` (prepare loop)
- Modify: `EchoCore/Services/AlignmentService.swift:198`
- Modify: `EchoCore/Services/EstimatedAlignmentSidecar.swift:78`
- Test: `EchoTests/NarrationCodeBlockCueTests.swift` (create)

**Interfaces:**
- Consumes: `.code` kind + `narrationText` cue (Tasks 1-2).
- Produces: `NarrationCodeBlockCue.spokenText(for:) -> String?` (returns the cue for `.code` blocks, nil for every other kind) and `NarrationCodeBlockCue.fallback == "Code listing."`. Task 6's subtitle special-case uses the same fallback string.

- [ ] **Step 1: Write the failing tests** at `EchoTests/NarrationCodeBlockCueTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationCodeBlockCueTests {

    private func block(kind: EPubBlockRecord.Kind, text: String?, cue: String?)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: "b1", audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: 0, sequenceIndex: 0, blockKind: kind.rawValue,
            text: text, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: nil, isHidden: false, hiddenReason: nil,
            wordCount: 1, markers: nil, textFormats: nil,
            narrationText: cue, codeLanguage: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func codeBlockSpeaksItsCue() {
        let b = block(kind: .code, text: "let x = 5", cue: "Listing 4-2. Retry decorator")
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Listing 4-2. Retry decorator")
    }

    @Test func codeBlockWithoutCueSpeaksFallback() {
        let b = block(kind: .code, text: "let x = 5", cue: nil)
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Code listing.")
    }

    @Test func blankCueFallsBack() {
        let b = block(kind: .code, text: "let x = 5", cue: "   ")
        #expect(NarrationCodeBlockCue.spokenText(for: b) == "Code listing.")
    }

    @Test func nonCodeBlocksReturnNil() {
        #expect(NarrationCodeBlockCue.spokenText(
            for: block(kind: .paragraph, text: "Prose.", cue: nil)) == nil)
        #expect(NarrationCodeBlockCue.spokenText(
            for: block(kind: .image, text: nil, cue: nil)) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** (compile error — type doesn't exist):

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] **Step 3: Implement.** Create `EchoCore/Services/Narration/NarrationCodeBlockCue.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Spoken-audio policy for `.code` blocks: narration speaks a short cue (the
/// import-time caption in `narrationText`, else a generic fallback) and never
/// the code itself. QA compares against `narrationText ?? text`, so keeping
/// the cue in `narrationText` keeps audio, storage, and QA consistent.
enum NarrationCodeBlockCue {
    static let fallback = "Code listing."

    /// The exact string narration should synthesize for `block`, or nil when
    /// the block is not a code block (normal pipeline applies).
    static func spokenText(for block: EPubBlockRecord) -> String? {
        guard EPubBlockRecord.Kind(rawValue: block.blockKind) == .code else { return nil }
        let cue = block.narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cue, !cue.isEmpty { return cue }
        return fallback
    }
}
```

In `EchoCore/Services/Narration/NarrationService.swift`, inside `prepareBlocksForRenderPlan`'s loop, immediately AFTER the existing `guard block.text?.isEmpty == false, !block.isHidden else { … continue }` (lines ~837-841) and BEFORE `let normalized = TextNormalizer.normalize(...)`:

```swift
            // Code blocks speak their short cue, never the code — skip
            // TextNormalizer/FM/occurrence overrides entirely.
            if let cueText = NarrationCodeBlockCue.spokenText(for: block) {
                var preparedBlock = block
                preparedBlock.text = cueText
                prepared.append(
                    NarrationPreparedBlock(block: preparedBlock, pronunciationDecisionSeeds: []))
                continue
            }
```

In `EchoCore/Services/AlignmentService.swift` (~line 198), widen the zero-weight test:

```swift
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            let weight: Double
            if block.isHidden || kind == .image || kind == .code {
                weight = 0.0
            } else {
                weight = Double(max(1, block.text?.count ?? 1))
            }
```

In `EchoCore/Services/EstimatedAlignmentSidecar.swift` (~line 78), the filter currently requires `Kind(rawValue:) != .image`; replace that clause:

```swift
                guard !block.isHidden,
                    { let k = EPubBlockRecord.Kind(rawValue: block.blockKind)
                      return k != .image && k != .code }(),
                    let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return false }
```

(If an inline closure reads poorly against surrounding style, hoist `let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)` above the guard — same semantics.)

- [ ] **Step 4: Review the remaining `== .image` equality sites** with the rule "code behaves like image (non-prose), EXCEPT it has spoken cue text": run

```bash
grep -rn "Kind(rawValue: .*)\s*[!=]= \.image\|== EPubBlockRecord.Kind.image.rawValue" --include="*.swift" Shared EchoCore "Echo macOS" | grep -v VisualListening
```

For each hit (expected: `TimelineItem.swift:114`, `ReaderTab+Alignment.swift:186,313`, plus the two files just edited): decide per the rule and record the decision as a one-line code comment ONLY where a change is made. Expected outcome: `TimelineItem` and `ReaderTab+Alignment` treat image blocks as non-seekable/non-anchorable *because they have no audio*; code blocks HAVE audio (the cue), so they stay on the default path — no change. If inspection contradicts this, make the minimal consistent change and note it in the commit body. Visual-Listening sites are handled in Task 6.

- [ ] **Step 5: Run:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/NarrationCodeBlockCueTests
```

Expected: PASS. Also run narration + alignment suites to catch regressions:

```bash
make test-only FILTER=EchoTests/NarrationRenderPlanTests 2>/dev/null; ls EchoTests | grep -iE "narration|alignment"
```

Run `make test-only FILTER=EchoTests/<Suite>` for each existing narration/alignment suite listed. Expected: PASS.

- [ ] **Step 6: Verify the QA classifier tolerates 2-word blocks.** Read the divergence classifier used by `NarrationQAService` (follow `runQA` → issue creation) and confirm a short expected text ("Code listing.") cannot be auto-flagged as a whole-block omission purely due to length. If a minimum-length gate exists that would misfire, note it in the commit body and file it as a follow-up — do NOT change QA thresholds in this task.

- [ ] **Step 7: Commit:**

```bash
git add EchoCore/Services/Narration/NarrationCodeBlockCue.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/Services/AlignmentService.swift EchoCore/Services/EstimatedAlignmentSidecar.swift EchoTests/NarrationCodeBlockCueTests.swift
git commit -m "feat(narration): speak short cue for .code blocks; exclude code from alignment token streams"
```

---

### Task 5: Reader feed — `CodeCardCell`

**Files:**
- Create: `EchoCore/Views/Cells/CodeCardCell.swift`
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift` (registration ~line 116; dispatch switch ~line 458)

**Interfaces:**
- Consumes: `.code` blocks with `text` (code) from earlier tasks; the a11y label case added in Task 1.
- Produces: `CodeCardCell` with `static let reuseIdentifier = "CodeCardCell"`, `func configure(with block: EPubBlockRecord, tint: UIColor)`, `var isActiveBlock: Bool`, and `configureAccessibility(label:hint:actions:)` matching `ImageCardCell`'s signature.

- [ ] **Step 1: Create `EchoCore/Views/Cells/CodeCardCell.swift`** (no unit test — UIKit layout; verified visually in Task 7 and by the existing UIWindow render-test pattern if one covers the reader feed):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
import UIKit

/// Card cell for `.code` blocks: monospaced, theme-aware, selectable code with
/// horizontal scrolling for long lines (code is never wrapped). No word-level
/// highlight — narration speaks only the block's short cue, so highlighting is
/// block-level (`isActiveBlock`).
final class CodeCardCell: UICollectionViewCell {
    static let reuseIdentifier = "CodeCardCell"

    private static let maxCodeHeight: CGFloat = 320

    private let textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true  // scrolls both axes inside the capped card
        tv.alwaysBounceVertical = false
        tv.backgroundColor = .clear
        tv.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        tv.adjustsFontForContentSizeCategory = true
        tv.textContainer.lineBreakMode = .byClipping
        tv.textContainer.widthTracksTextView = false
        tv.textContainer.size = CGSize(
            width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let languageLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var textViewHeight: NSLayoutConstraint?

    var isActiveBlock: Bool = false {
        didSet { updateActiveAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(textView)
        contentView.addSubview(languageLabel)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.borderWidth = 0

        let height = textView.heightAnchor.constraint(equalToConstant: 60)
        textViewHeight = height
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -14),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            height,

            languageLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 14),
            languageLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -14),
            languageLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 6),
            languageLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, tint: UIColor) {
        let code = block.text ?? ""
        textView.text = code
        languageLabel.text = block.codeLanguage
        languageLabel.isHidden = block.codeLanguage == nil

        // Height: fit the code up to the cap; beyond it, the text view scrolls.
        let lineHeight = textView.font?.lineHeight ?? 17
        let lineCount = max(1, code.components(separatedBy: "\n").count)
        let fitted = CGFloat(lineCount) * lineHeight
            + textView.textContainerInset.top + textView.textContainerInset.bottom
        textViewHeight?.constant = min(fitted, Self.maxCodeHeight)

        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.borderColor = tint.cgColor
        updateActiveAppearance()
    }

    func configureAccessibility(
        label accessibilityLabel: String,
        hint accessibilityHint: String,
        actions: [UIAccessibilityCustomAction]
    ) {
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = textView.text
        self.accessibilityHint = accessibilityHint
        accessibilityTraits = [.button]
        accessibilityCustomActions = actions
        textView.isAccessibilityElement = false
        languageLabel.isAccessibilityElement = false
    }

    private func updateActiveAppearance() {
        contentView.layer.borderWidth = isActiveBlock ? 2 : 0
    }
}
#endif
```

- [ ] **Step 2: Register and dispatch.** In `EchoCore/Views/ReaderFeedCollectionView.swift`, next to the `ImageCardCell` registration (~line 115):

```swift
        collectionView.register(
            CodeCardCell.self, forCellWithReuseIdentifier: CodeCardCell.reuseIdentifier)
```

In the `case .block(let block):` switch (~line 458), add a case between the `image` case and `default`:

```swift
                case EPubBlockRecord.Kind.code.rawValue:
                    guard
                        let codeCell = collectionView.dequeueReusableCell(
                            withReuseIdentifier: CodeCardCell.reuseIdentifier, for: indexPath
                        ) as? CodeCardCell
                    else { return UICollectionViewCell() }
                    let cardTint =
                        UIColor(
                            hex: block.cardColor ?? block.chapterThemeColor ?? settings.cardTintHex)
                        ?? UIColor.systemBackground
                    codeCell.configure(with: block, tint: cardTint)
                    codeCell.isActiveBlock = (block.id == activeBlockID)
                    codeCell.configureAccessibility(
                        label: accessibilityLabel(for: block, kind: .code),
                        hint: accessibilityHint(for: block),
                        actions: onAccessibilityActions?(block) ?? []
                    )
                    return codeCell
```

(No `highlightedWordIndex`, no `setManuallyAligned` — code cards are block-level only, by design.)

- [ ] **Step 3: Build:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compiles. Check whether the active-block update path (~line 186, the `if let headingCell = cell as? HeadingCardCell … else if let paraCell = cell as? ParagraphCardCell` chain) needs a `CodeCardCell` arm for live `isActiveBlock` updates — read that block; if it toggles `isActiveBlock` on visible cells, add:

```swift
                        } else if let codeCell = cell as? CodeCardCell {
                            codeCell.isActiveBlock = (blockID == activeBlockID)
```

matching the surrounding pattern exactly (adapt variable names to what that closure actually uses).

- [ ] **Step 4: Commit:**

```bash
git add EchoCore/Views/Cells/CodeCardCell.swift EchoCore/Views/ReaderFeedCollectionView.swift
git commit -m "feat(reader): CodeCardCell — monospaced selectable code cards with block-level highlight"
```

---

### Task 6: Visual Listening — generalize cues to image-or-code

**Files:**
- Modify: `Shared/VisualListeningCueResolver.swift` (whole file is in scope)
- Modify: `EchoCore/ViewModels/VisualListeningViewModel.swift:138-154` (`hasContent`)
- Modify: `EchoCore/Views/VisualListeningStageView.swift`
- Modify: `Echo macOS/Views/MacVisualStageView.swift`
- Modify: `EchoTests/VisualListeningViewModelTests.swift` + `EchoTests/MacVisualListeningParityTests.swift` (rename fallout only)
- Test: `EchoTests/VisualListeningCodeCueTests.swift` (create)

**Interfaces:**
- Consumes: `.code` blocks (text + `narrationText` cue + `codeLanguage`), `NarrationCodeBlockCue.fallback` (Task 4).
- Produces: `VisualListeningVisualContent` enum (`.image(path: String)` / `.code(text: String, language: String?)`); `VisualListeningVisualCue` (renamed from `VisualListeningImageCue`) with `let content: VisualListeningVisualContent` and computed `var imagePath: String?`; `VisualListeningSnapshot.visualCue` (renamed from `imageCue`).

- [ ] **Step 1: Write the failing resolver tests** at `EchoTests/VisualListeningCodeCueTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VisualListeningCodeCueTests {

    private func codeBlock(
        id: String, sequence: Int, code: String, cue: String?, chapter: Int = 0
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.code.rawValue,
            text: code, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: chapter, isHidden: false, hiddenReason: nil,
            wordCount: 1, markers: nil, textFormats: nil,
            narrationText: cue, codeLanguage: "python", createdAt: nil, modifiedAt: nil)
    }

    private func textBlock(id: String, sequence: Int, text: String, chapter: Int = 0)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: id, audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: chapter, isHidden: false, hiddenReason: nil,
            wordCount: 3, markers: nil, textFormats: nil,
            narrationText: nil, codeLanguage: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func codeBlockWithTimelineRowBecomesVisualCue() {
        let blocks = [
            textBlock(id: "t1", sequence: 0, text: "Consider this function."),
            codeBlock(id: "c1", sequence: 1, code: "def f():\n    return 1", cue: "Listing 1."),
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 5, blockID: "t1", chapterIndex: 0, segmentKey: nil),
            (start: 5, end: 7, blockID: "c1", chapterIndex: 0, segmentKey: nil),
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 5.5,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        guard case .code(let text, let language) = snapshot.visualCue?.content else {
            Issue.record("expected a code visual cue, got \(String(describing: snapshot.visualCue))")
            return
        }
        #expect(text == "def f():\n    return 1")
        #expect(language == "python")
        #expect(snapshot.visualCue?.caption == "Listing 1.")
    }

    @Test func codeSubtitleIsTheCueNeverTheRawCode() {
        let blocks = [
            codeBlock(id: "c1", sequence: 0, code: "let x = 5", cue: "Listing 2.")
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 2, blockID: "c1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 1,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(snapshot.subtitleCue?.text == "Listing 2.")
    }

    @Test func codeBlockWithoutTimelineRowDerivesWindowFromNeighborProse() {
        let blocks = [
            textBlock(id: "t1", sequence: 0, text: "The next listing shows the loop."),
            codeBlock(id: "c1", sequence: 1, code: "for x in items:\n    use(x)", cue: nil),
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 10, blockID: "t1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 2,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        guard case .code = snapshot.visualCue?.content else {
            Issue.record("expected derived-window code cue")
            return
        }
        #expect(snapshot.visualCue?.source == .derivedFromNearbyText)
    }

    @Test func imageCuesStillWork() {
        var image = textBlock(id: "i1", sequence: 0, text: "A caption")
        image.blockKind = EPubBlockRecord.Kind.image.rawValue
        image.imagePath = "figs/one.png"
        let blocks = [image, textBlock(id: "t1", sequence: 1, text: "Prose after.")]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 10, blockID: "t1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 2,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(snapshot.visualCue?.imagePath == "figs/one.png")
        guard case .image(let path) = snapshot.visualCue?.content else {
            Issue.record("expected image content")
            return
        }
        #expect(path == "figs/one.png")
    }
}
```

(If `ReaderActiveBlockResolver.TimelineRow` tuple labels differ from `(start:end:blockID:chapterIndex:segmentKey:)`, match the real declaration — check `ReaderActiveBlockResolver.swift` first.)

- [ ] **Step 2: Run to verify failure:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: FAIL — `visualCue`/`content` don't exist.

- [ ] **Step 3: Implement the resolver.** In `Shared/VisualListeningCueResolver.swift`:

**3a — content enum + renamed cue struct** (replace `VisualListeningImageCue`, lines 14-27):

```swift
/// What the visual stage shows for a cue: a figure image or a code listing.
enum VisualListeningVisualContent: Equatable, Sendable {
    case image(path: String)
    case code(text: String, language: String?)
}

struct VisualListeningVisualCue: Equatable, Identifiable, Sendable {
    var id: String { blockID }

    let blockID: String
    let content: VisualListeningVisualContent
    let caption: String?
    let subtitleBlockID: String?
    let chapterIndex: Int?
    let sequenceIndex: Int
    let displayStartTime: TimeInterval
    let displayEndTime: TimeInterval
    let syncPoint: VisualListeningSyncPoint
    let source: VisualListeningImageCueSource

    /// Image path when the content is an image; nil for code. Kept so
    /// image-loading call sites stay simple (`visualCue?.imagePath`).
    var imagePath: String? {
        if case .image(let path) = content { return path }
        return nil
    }
}
```

(Leave `VisualListeningImageCueSource` named as-is — its raw values may be persisted in settings; renaming it is not required.)

**3b — snapshot** (lines 39-49): rename the property:

```swift
struct VisualListeningSnapshot: Equatable, Sendable {
    var visualCue: VisualListeningVisualCue?
    var subtitleCue: VisualListeningSubtitleCue?
    var activeBlockID: String?

    static let empty = VisualListeningSnapshot(
        visualCue: nil,
        subtitleCue: nil,
        activeBlockID: nil
    )
}
```

**3c — selection** (`imageCues`, lines 128-189 — rename to `visualCues`, and `activeImageCue` → `activeVisualCue`): replace the image-only filter with:

```swift
        let visualBlocks = blocks.filter { block in
            guard !block.isHidden else { return false }
            switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
            case .image: return block.imagePath?.isEmpty == false
            case .code: return block.text?.isEmpty == false
            default: return false
            }
        }
```

and build content per kind. Replace `makeImageCue` (lines 241-262) with:

```swift
    private static func makeVisualCue(
        block: EPubBlockRecord,
        subtitleBlockID: String?,
        displayStart: TimeInterval,
        displayEnd: TimeInterval,
        syncPoint: VisualListeningSyncPoint,
        source: VisualListeningImageCueSource
    ) -> VisualListeningVisualCue? {
        let content: VisualListeningVisualContent
        let caption: String?
        switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
        case .image:
            guard let path = block.imagePath, !path.isEmpty else { return nil }
            content = .image(path: path)
            caption = block.text
        case .code:
            guard let code = block.text, !code.isEmpty else { return nil }
            content = .code(text: code, language: block.codeLanguage)
            caption = block.narrationText
        default:
            return nil
        }
        return VisualListeningVisualCue(
            blockID: block.id,
            content: content,
            caption: caption,
            subtitleBlockID: subtitleBlockID,
            chapterIndex: block.chapterIndex,
            sequenceIndex: block.sequenceIndex,
            displayStartTime: displayStart,
            displayEndTime: displayEnd,
            syncPoint: syncPoint,
            source: source
        )
    }
```

Update both call sites in the (renamed) `visualCues` to `makeVisualCue(block:subtitleBlockID:displayStart:displayEnd:syncPoint:source:)` — they no longer pass `imagePath` — and use `compactMap`-compatible optionality (the closure already returns optionals in the derived branch; the explicit branch's `return makeImageCue(...)` becomes `return makeVisualCue(...)`). In the explicit-timeline branch, the subtitle choice for code blocks stays `block.id` (subtitle special-case below renders the cue, not the code):

```swift
                let subtitleBlockID = block.text?.isEmpty == false
                    ? block.id
                    : referenceRow(for: block, rows: scopedRows, blocksByID: blocksByID)?.blockID
```

**3d — `referenceRow`** (line ~201): visual blocks can't be their neighbors' subtitle reference. Replace the image-only exclusion:

```swift
                guard row.end > row.start,
                    row.chapterIndex == imageBlock.chapterIndex,
                    let block = blocksByID[row.blockID],
                    {
                        let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
                        return kind != .image && kind != .code
                    }(),
                    block.text?.isEmpty == false
                else { return false }
```

(Rename the parameter `imageBlock` → `visualBlock` while there.)

**3e — `subtitleCue`** (line ~264): code blocks subtitle their CUE, never the raw code:

```swift
        guard let blockID,
            let block = blocksByID[blockID]
        else { return nil }

        let text: String
        if EPubBlockRecord.Kind(rawValue: block.blockKind) == .code {
            text = block.narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? (block.narrationText ?? NarrationCodeBlockCue.fallback)
                : NarrationCodeBlockCue.fallback
        } else if let t = block.text, !t.isEmpty {
            text = t
        } else {
            return nil
        }
```

(then use `text` where `block.text` was used below — including the `VisualListeningSubtitleCue(text:)` argument). Note `NarrationCodeBlockCue` lives in EchoCore while the resolver is in Shared — if Shared cannot see EchoCore (check target membership with a quick build), inline the literal `"Code listing."` here instead and leave a comment pointing at `NarrationCodeBlockCue.fallback`.

**3f — snapshot assembly** (lines 74-99): rename local `imageCue` → `visualCue` and field labels accordingly.

- [ ] **Step 4: `hasContent`** (`EchoCore/ViewModels/VisualListeningViewModel.swift:138-154`):

```swift
    private static func hasContent(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow]
    ) -> Bool {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let hasVisual = blocks.contains { block in
            switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
            case .image: return block.imagePath?.isEmpty == false
            case .code: return block.text?.isEmpty == false
            default: return false
            }
        }
        let hasSubtitle = timeline.contains { row in
            guard let block = blockByID[row.blockID] else { return false }
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            guard kind != .image, kind != .code else { return false }
            return block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        return hasVisual && hasSubtitle
    }
```

- [ ] **Step 5: Stage views.** `EchoCore/Views/VisualListeningStageView.swift`: replace every `snapshot.imageCue` with `snapshot.visualCue` (4 sites: `onChange` of `imagePath`, `animation` value, a11y caption, `loadImageIfNeeded`) — the computed `imagePath: String?` keeps those expressions type-compatible. In `visualStage`'s ZStack, render code content:

```swift
    private var visualStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if case .code(let text, _) = snapshot.visualCue?.content {
                VisualListeningCodeView(text: text)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.25), value: snapshot.visualCue?.id)
        .accessibilityLabel(Text(accessibilityLabel))
    }
```

Add at file scope (inside the existing `#if canImport(UIKit)`):

```swift
private struct VisualListeningCodeView: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .accessibilityHidden(true)  // the stage's accessibilityLabel covers it
    }
}
```

Update `accessibilityLabel` so code cues say listing, not figure:

```swift
    private var accessibilityLabel: String {
        let isCode: Bool
        if case .code = snapshot.visualCue?.content { isCode = true } else { isCode = false }
        if let caption = snapshot.visualCue?.caption, !caption.isEmpty {
            return isCode
                ? String(localized: "Current code listing: \(caption)")
                : String(localized: "Current figure: \(caption)")
        }
        if isCode { return String(localized: "Current code listing") }
        if let subtitle = snapshot.subtitleCue?.text, !subtitle.isEmpty {
            return String(localized: "Current figure for subtitle: \(subtitle)")
        }
        return String(localized: "Current figure")
    }
```

Apply the SAME set of edits to `Echo macOS/Views/MacVisualStageView.swift` (its structure mirrors the iOS view: 4 `imageCue` sites + `visualStage` + a11y label; duplicate `VisualListeningCodeView` there as a private struct — it is 12 lines and the two files are platform-separated by design).

- [ ] **Step 6: Fix rename fallout.** Build and follow the compiler:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected fallout sites: `EchoTests/VisualListeningViewModelTests.swift` and `EchoTests/MacVisualListeningParityTests.swift` (assertions on `.imageCue` → `.visualCue`; assertions on `.imagePath` still compile via the computed property). `EchoCore/Views/NowPlayingTab.swift` and `Echo macOS/Views/MacTriPaneView.swift` use snapshot/view-model level APIs only — verify with `grep -n "imageCue" EchoCore/Views/NowPlayingTab.swift "Echo macOS/Views/MacTriPaneView.swift"` (expected: no hits after the stage-view edits).

- [ ] **Step 7: Run:**

```bash
make test-only FILTER=EchoTests/VisualListeningCodeCueTests && make test-only FILTER=EchoTests/VisualListeningViewModelTests && make test-only FILTER=EchoTests/MacVisualListeningParityTests
```

Expected: PASS.

- [ ] **Step 8: Commit:**

```bash
git add Shared/VisualListeningCueResolver.swift EchoCore/ViewModels/VisualListeningViewModel.swift EchoCore/Views/VisualListeningStageView.swift "Echo macOS/Views/MacVisualStageView.swift" EchoTests/
git commit -m "feat(visual-listening): generalize cues to image-or-code; code listings surface in the slideshow"
```

---

### Task 7: Docs, full verification, PR

**Files:**
- Modify: `ARCHITECTURE.md` (block-kind + narration pipeline + Visual Listening sections)
- Modify: `CHANGELOG.md` (unreleased section, follow existing entry style)

**Interfaces:**
- Consumes: everything above.
- Produces: the merged-ready PR into `nightly`.

- [ ] **Step 1: Doc updates.** In `ARCHITECTURE.md`, locate the sections describing EPUB block parsing, narration rendering, and Visual Listening (search for "block_kind", "narration_text", "Visual Listening"). Add, in matching prose style: the `.code` kind (raw `"code"`, `code_language` column, V36); `<pre>`/fence detection with preserved whitespace; the spoken-cue policy (`narrationText` = cue, `NarrationCodeBlockCue`); block-level (not word-level) highlighting for code cards; the generalized `VisualListeningVisualContent` payload; alignment exclusion of `.code`; and the explicit non-goals (tables, PDF, syntax highlighting, deck-card code images — deferred). In `CHANGELOG.md`, add an entry under the unreleased heading:

```markdown
- Coding-textbook support: EPUB `<pre>` and Markdown fenced code now import as
  code blocks — shown as monospaced, selectable cards in the reader and the
  Visual Listening stage, and narrated as a short caption cue ("Code listing."
  or the book's own listing caption) instead of being read aloud as word soup.
  Existing books pick this up on re-import.
```

- [ ] **Step 2: Full test suite:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
```

Expected: PASS (Keychain-related sim failures are a known environmental issue under `CODE_SIGNING_ALLOWED=NO`; anything else must be fixed before proceeding).

- [ ] **Step 3: Run the cross-platform-parity-reviewer agent** over the branch diff (shared-logic change consumed by iOS + macOS; watch/widget don't render the reader feed or Visual Listening, but let the reviewer confirm). Address findings.

- [ ] **Step 4: End-to-end smoke (best-effort, report honestly).** Import a real Python-textbook EPUB (or synthesize one: zip a minimal OPF + one XHTML chapter containing prose + `<pre><code class="language-python">` listings), then narrate one chapter:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
.build/cli/Build/Products/Release/echo-cli narrate --help
```

Follow the CLI's actual flags to narrate the test book, then verify: (a) the chapter audio contains the cue followed by prose (listen or re-transcribe via the QA path), (b) no chunk contains code tokens (inspect the render-plan/debug output if the CLI exposes it). If the CLI path can't exercise import for this format, state exactly what was and wasn't verified in the PR body.

- [ ] **Step 5: Commit docs:**

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: code-block visual narration — architecture + changelog"
```

- [ ] **Step 6: Rebase, push, PR:**

```bash
git fetch origin && git rebase origin/nightly
git push -u origin claude/textbooks-echo-narration-47b10b
gh pr create --base nightly \
  --title "feat: code blocks as visual narration blocks (coding-textbook support)" \
  --body "$(cat <<'EOF'
## Summary
- EPUB `<pre>` and Markdown fenced code import as a new `.code` block kind: raw whitespace-preserved code in `text`, spoken cue in `narration_text`, language hint in new `code_language` column (Schema V36).
- Narration speaks the cue ("Code listing." / the book's figcaption), never the code; QA validates the cue for free via `narrationText ?? text`.
- Reader feed renders `CodeCardCell` (monospaced, selectable, horizontal-scroll, block-level highlight); Visual Listening cues generalize to image-or-code and show listings on the stage (iOS + macOS).
- Auto-alignment excludes `.code` like `.image` (human narrators skip code).
- Deferred by design: tables, PDF code detection, syntax highlighting, deck-card code images.

Spec: docs/superpowers/specs/2026-07-18-code-block-visual-narration-design.md
Plan: docs/superpowers/plans/2026-07-18-code-block-visual-narration.md

## Test plan
- [x] EPUBCodeBlockParsingTests / MarkdownCodeFenceTests / NarrationCodeBlockCueTests / VisualListeningCodeCueTests / SchemaV36CodeLanguageTests
- [x] Existing parser, narration, alignment, and Visual Listening suites
- [x] `make test` full run

Note: already-imported books keep old flattened blocks until re-imported (import-time data model, by design).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Watch CI to green:**

```bash
gh pr checks --watch
```

If `Build gate + tests` fails, read the failing job log first, fix the concrete blocker, push, re-watch. Final report states CI status explicitly.

---

## Self-review notes (already applied)

- Spec coverage: §1 data model → Task 1; §2 parsing → Tasks 2-3; §3 audio/QA/timing/alignment → Task 4 (+ QA-classifier verify step); §4 reader → Task 5; §5 Visual Listening (incl. mac parity) → Task 6; §6 study surfaces → Task 1 (`StudyDeckSourceBuilder`); testing + docs + E2E → per-task tests + Task 7.
- Cross-task name consistency: `Kind.code` / `codeLanguage` / `code_language` / `narrationCue` (descriptor) vs `narrationText` (record) / `NarrationCodeBlockCue.fallback == "Code listing."` / `VisualListeningVisualCue.content` / `snapshot.visualCue` — verified consistent across tasks.
- Known judgment points left to the executor, each with an explicit decision rule: TimelineRow tuple labels (Task 6 Step 1), Shared→EchoCore visibility for the fallback constant (Task 6 Step 3e), active-cell update chain (Task 5 Step 3), QA short-block classifier (Task 4 Step 6, verify-only).
