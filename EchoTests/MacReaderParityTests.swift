// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS reader-interaction parity in MacReaderFeedView.
/// The `Echo macOS` target is not compiled into EchoTests, so we assert against
/// source text via `MacSource`. Alignment work goes through the shared,
/// macOS-clean `AlignmentService`.
struct MacReaderParityTests {

    @Test func readerHasAlignmentContextMenu() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("alignmentMenu"),
            "The reader cards must offer a right-click alignment context menu.")
        #expect(
            src.contains("\"Align to Now\""),
            "The alignment menu must offer Align to Now (and the other per-block actions).")
    }

    @Test func alignmentRoutesThroughSharedService() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("AlignmentService(db:"),
            "Manual alignment must use the shared AlignmentService, not a macOS reimplementation.")
        #expect(
            src.contains("moveBlockToCurrentTime") && src.contains("resetAlignment"),
            "The menu must wire the AlignmentService editing entry points (move/hide/erase/reset).")
    }

    @Test func alignmentReloadsFeed() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("performAlignment("),
            "A performAlignment helper must apply the edit and reload the feed.")
    }

    @Test func readerRendersCodeAsSelectableHorizontalCard() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")

        #expect(
            src.contains("case EPubBlockRecord.Kind.code.rawValue:"),
            "The macOS reader must route code blocks to a dedicated renderer.")
        #expect(src.contains("ScrollView(.horizontal)"))
        #expect(src.contains("design: .monospaced"))
        #expect(src.contains(".textSelection(.enabled)"))
        #expect(src.contains("block.codeLanguage"))
        #expect(
            src.contains("Button(\"Seek to code listing\", systemImage: \"play.fill\""),
            "Selectable code should keep seeking available as a separate accessible control.")
    }

    @Test func readerEqualityInvalidatesStableIDKindTextAndLanguageChanges() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("lhs.block == rhs.block"),
            "MacBlockCardView equality must compare the full block, not only its stable ID.")

        let original = readerBlock()
        var changedKind = original
        changedKind.blockKind = EPubBlockRecord.Kind.code.rawValue
        var changedText = original
        changedText.text = "let value = 42"
        var changedLanguage = original
        changedLanguage.codeLanguage = "swift"

        #expect(changedKind.id == original.id)
        #expect(changedText.id == original.id)
        #expect(changedLanguage.id == original.id)
        #expect(changedKind != original)
        #expect(changedText != original)
        #expect(changedLanguage != original)
    }

    private func readerBlock() -> EPubBlockRecord {
        EPubBlockRecord(
            id: "stable-block-id",
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Flattened prose.",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: 2,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            codeLanguage: nil,
            createdAt: nil,
            modifiedAt: nil)
    }
}
