// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

#if os(iOS)
import UIKit
@testable import Echo
#endif

struct ReaderFeedAccessibilityTests {
    #if os(iOS)
    @MainActor
    @Test func readerSettingsUIFontScalesForAccessibilityContentSizeCategory() {
        let settings = ReaderSettings(
            fontSize: 17,
            lineSpacing: 1.4,
            cardTintHex: "#F5F0E8",
            appFont: "System"
        )

        let largeTrait = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTrait = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

        let largeFont = settings.uiFont(forTextStyle: .body, compatibleWith: largeTrait)
        let accessibilityFont = settings.uiFont(
            forTextStyle: .body,
            compatibleWith: accessibilityTrait)

        #expect(
            accessibilityFont.pointSize > largeFont.pointSize,
            "ReaderSettings.uiFont must grow for accessibility Dynamic Type categories."
        )

        let largeLineSpacing = settings.scaledLineSpacing(compatibleWith: largeTrait)
        let accessibilityLineSpacing = settings.scaledLineSpacing(compatibleWith: accessibilityTrait)
        #expect(
            accessibilityLineSpacing > largeLineSpacing,
            "ReaderSettings must scale paragraph line spacing with Dynamic Type."
        )

        settings.fontSize = 24
        let largerReaderFont = settings.uiFont(forTextStyle: .body, compatibleWith: largeTrait)
        #expect(
            largerReaderFont.pointSize > largeFont.pointSize,
            "Reader font-size control must remain the base before Dynamic Type scaling."
        )
    }

    @MainActor
    @Test func readerTextCellsSelfSizeAtAccessibilityContentSizeCategory() throws {
        let settings = ReaderSettings(
            fontSize: 17,
            lineSpacing: 1.4,
            cardTintHex: "#F5F0E8",
            appFont: "System"
        )
        let width: CGFloat = 320
        let largeTrait = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTrait = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

        let largeParagraph = try Self.measureParagraphCell(
            settings: settings, trait: largeTrait, width: width)
        let accessibilityParagraph = try Self.measureParagraphCell(
            settings: settings, trait: accessibilityTrait, width: width)

        #expect(accessibilityParagraph.contentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(accessibilityParagraph.numberOfLines == 0)
        #expect(accessibilityParagraph.cellHeight > largeParagraph.cellHeight)
        #expect(
            accessibilityParagraph.cellHeight
                >= accessibilityParagraph.labelRequiredHeight + Self.textCellVerticalPadding - 0.5,
            "Paragraph cell self-sizing height must fit its full Dynamic Type label height."
        )

        let largeParagraphFont = try #require(largeParagraph.baseFontPointSize)
        let accessibilityParagraphFont = try #require(accessibilityParagraph.baseFontPointSize)
        #expect(accessibilityParagraphFont > largeParagraphFont)

        let largeLineSpacing = try #require(largeParagraph.lineSpacing)
        let accessibilityLineSpacing = try #require(accessibilityParagraph.lineSpacing)
        #expect(accessibilityLineSpacing > largeLineSpacing)

        let accessibilitySearchFont = try #require(accessibilityParagraph.searchFontPointSize)
        let expectedSearchFont = settings.uiFont(
            forTextStyle: .body,
            weight: .bold,
            compatibleWith: accessibilityTrait
        ).pointSize
        #expect(abs(accessibilitySearchFont - expectedSearchFont) < 0.5)

        let largeHeading = try Self.measureHeadingCell(
            settings: settings, trait: largeTrait, width: width)
        let accessibilityHeading = try Self.measureHeadingCell(
            settings: settings, trait: accessibilityTrait, width: width)

        #expect(accessibilityHeading.contentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(accessibilityHeading.numberOfLines == 0)
        #expect(accessibilityHeading.cellHeight > largeHeading.cellHeight)
        #expect(
            accessibilityHeading.cellHeight
                >= accessibilityHeading.labelRequiredHeight + Self.textCellVerticalPadding - 0.5,
            "Heading cell self-sizing height must fit its full Dynamic Type label height."
        )

        let largeHeadingFont = try #require(largeHeading.baseFontPointSize)
        let accessibilityHeadingFont = try #require(accessibilityHeading.baseFontPointSize)
        #expect(accessibilityHeadingFont > largeHeadingFont)
    }

    private static let textCellVerticalPadding: CGFloat = 28

    private struct TextCellMeasurement {
        var cellHeight: CGFloat
        var labelRequiredHeight: CGFloat
        var numberOfLines: Int
        var contentSizeCategory: UIContentSizeCategory
        var baseFontPointSize: CGFloat?
        var searchFontPointSize: CGFloat?
        var lineSpacing: CGFloat?
    }

    @MainActor
    private static func measureParagraphCell(
        settings: ReaderSettings,
        trait: UITraitCollection,
        width: CGFloat
    ) throws -> TextCellMeasurement {
        let cell = ParagraphCardCell(
            frame: CGRect(origin: .zero, size: CGSize(width: width, height: 1)))
        let block = block(
            kind: .paragraph,
            text:
                "This accessible paragraph contains a highlight term and enough surrounding text "
                + "to wrap onto multiple lines at larger content sizes without truncating.")

        return try measureTextCell(cell, trait: trait, width: width, searchQuery: "highlight") {
            cell in
            cell.configure(
                with: block,
                settings: settings,
                tint: .systemBackground,
                isExplicitHighlight: false,
                searchQuery: "highlight",
                highlightedWordIndex: 3
            )
        }
    }

    @MainActor
    private static func measureHeadingCell(
        settings: ReaderSettings,
        trait: UITraitCollection,
        width: CGFloat
    ) throws -> TextCellMeasurement {
        let cell = HeadingCardCell(
            frame: CGRect(origin: .zero, size: CGSize(width: width, height: 1)))
        let block = block(
            kind: .heading,
            text: "Accessible heading with enough words to wrap cleanly")

        return try measureTextCell(cell, trait: trait, width: width, searchQuery: nil) {
            cell in
            cell.configure(
                with: block,
                settings: settings,
                tint: .systemBackground,
                isExplicitHighlight: false,
                highlightedWordIndex: 2
            )
        }
    }

    @MainActor
    private static func measureTextCell<Cell: UICollectionViewCell>(
        _ cell: Cell,
        trait: UITraitCollection,
        width: CGFloat,
        searchQuery: String?,
        configure: (Cell) -> Void
    ) throws -> TextCellMeasurement {
        let parent = UIViewController()
        let child = UIViewController()
        parent.loadViewIfNeeded()
        child.loadViewIfNeeded()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.traitOverrides.preferredContentSizeCategory =
            trait.preferredContentSizeCategory
        child.didMove(toParent: parent)

        child.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 1_000))
        cell.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 1))
        child.view.addSubview(cell)
        defer {
            cell.removeFromSuperview()
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        configure(cell)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let label = try #require(mainLabel(in: cell))
        let fittingSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let cellSize = cell.contentView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let labelWidth = width - 28
        let labelSize = label.sizeThatFits(
            CGSize(width: labelWidth, height: .greatestFiniteMagnitude))

        let attributed = label.attributedText
        let baseFont = attributed?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let paragraphStyle =
            attributed?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let searchFont = searchQuery.flatMap { query -> UIFont? in
            guard let attributed else { return nil }
            let range = (attributed.string as NSString).range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound else { return nil }
            return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        }

        return TextCellMeasurement(
            cellHeight: cellSize.height,
            labelRequiredHeight: labelSize.height,
            numberOfLines: label.numberOfLines,
            contentSizeCategory: cell.traitCollection.preferredContentSizeCategory,
            baseFontPointSize: baseFont?.pointSize,
            searchFontPointSize: searchFont?.pointSize,
            lineSpacing: paragraphStyle?.lineSpacing
        )
    }

    private static func mainLabel(in cell: UICollectionViewCell) -> UILabel? {
        cell.contentView.subviews
            .compactMap { $0 as? UILabel }
            .first { $0.numberOfLines == 0 }
    }

    private static func block(kind: EPubBlockRecord.Kind, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "test-\(kind.rawValue)",
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
    #endif

    @Test func readerBlockCellsExposeVoiceOverActions() throws {
        let collectionSource = try Self.source("EchoCore/Views/ReaderFeedCollectionView.swift")
        let readerSource = try Self.source("EchoCore/Views/ReaderTab.swift")
        let alignmentSource = try Self.source("EchoCore/Views/ReaderTab+Alignment.swift")

        #expect(
            collectionSource.contains(
                "var onAccessibilityActions: ((EPubBlockRecord) -> [UIAccessibilityCustomAction])?"
            ),
            "Reader feed must accept a VoiceOver custom-action provider for block cells."
        )
        #expect(
            readerSource.contains("onAccessibilityActions: { (block: EPubBlockRecord)"),
            "ReaderTab must pass the same block context into the accessibility-action provider."
        )
        #expect(
            readerSource.contains("buildAccessibilityActions(block: block)"),
            "ReaderTab should reuse its existing block action logic for accessibility actions."
        )
        #expect(
            alignmentSource.contains("func buildAccessibilityActions(block: EPubBlockRecord)"),
            "ReaderTab+Alignment must build accessibility actions beside the context menu builder."
        )

        let actionNames = [
            "Align to Now",
            "Align to 5s Ago",
            "Save Bookmark",
            "Copy Text",
        ]
        for name in actionNames {
            #expect(
                alignmentSource.contains("UIAccessibilityCustomAction(name: \"\(name)\""),
                "Reader accessibility actions must expose \(name)."
            )
        }
    }

    @Test func readerBlockCellsAreAccessibleElements() throws {
        for file in [
            "EchoCore/Views/Cells/ParagraphCardCell.swift",
            "EchoCore/Views/Cells/HeadingCardCell.swift",
            "EchoCore/Views/Cells/ImageCardCell.swift",
        ] {
            let source = try Self.source(file)
            #expect(
                source.contains("func configureAccessibility("),
                "\(file) must expose a reusable accessibility configuration hook."
            )
            #expect(
                source.contains("isAccessibilityElement = true"),
                "\(file) must make the card itself reachable as one VoiceOver element."
            )
            #expect(
                source.contains("accessibilityTraits = [.button]"),
                "\(file) must announce the card as actionable because double-tap seeks/opens it."
            )
            #expect(
                source.contains("accessibilityCustomActions = actions"),
                "\(file) must attach the Reader block custom actions."
            )
        }
    }

    @Test func readerTextCellsRebuildAttributedTextForDynamicTypeChanges() throws {
        let settingsSource = try Self.source("Shared/ReaderSettings.swift")
        #expect(
            settingsSource.contains("UIFontMetrics(forTextStyle: style).scaledFont"),
            "ReaderSettings.uiFont must scale selected reader fonts through UIFontMetrics."
        )
        #expect(
            settingsSource.contains("compatibleWith traitCollection"),
            "ReaderSettings.uiFont must accept a trait collection for cell-specific scaling."
        )
        #expect(
            settingsSource.contains("UIFontMetrics(forTextStyle: style).scaledValue"),
            "ReaderSettings must scale paragraph line spacing through UIFontMetrics."
        )

        for file in [
            "EchoCore/Views/Cells/ParagraphCardCell.swift",
            "EchoCore/Views/Cells/HeadingCardCell.swift",
        ] {
            let source = try Self.source(file)
            #expect(
                source.contains("adjustsFontForContentSizeCategory = true"),
                "\(file) must opt its main label into Dynamic Type."
            )
            #expect(
                source.contains("label.numberOfLines = 0"),
                "\(file) must allow reader text to grow vertically at accessibility sizes."
            )
            #expect(
                source.contains(
                    "registerForTraitChanges([UITraitPreferredContentSizeCategory.self])"
                ),
                "\(file) must listen for preferred content-size category changes."
            )
            #expect(
                source.contains("rebuildAttributedTextForCurrentTraits()"),
                "\(file) must rebuild attributed strings after trait changes."
            )
            #expect(
                source.contains("highlightedWordIndex"),
                "\(file) must retain the current karaoke word index across rebuilds."
            )
            #expect(
                source.contains("weight: .bold, compatibleWith: traitCollection"),
                "\(file) must build search-highlight bold runs from ReaderSettings and the current trait collection."
            )
            #expect(
                !source.contains("UIFont.systemFont(ofSize: font.pointSize"),
                "\(file) must not replace custom/scaled search fonts with fixed system fonts."
            )
        }
    }

    @Test func readerFeedReconfiguresSnapshotItemsWhenReaderSettingsChange() throws {
        let collectionSource = try Self.source("EchoCore/Views/ReaderFeedCollectionView.swift")

        #expect(
            collectionSource.contains("fileprivate struct ReaderSettingsSnapshot: Equatable"),
            "Reader feed must compare reader setting values instead of the mutable settings object identity."
        )
        #expect(
            collectionSource.contains("let shouldReconfigureReaderItems = settingsChanged || searchChanged"),
            "Reader feed must reconfigure existing cells when reader settings change without section changes."
        )
        #expect(
            collectionSource.contains("func readerItemIDs() -> [String]"),
            "Reader feed must include current snapshot identifiers so offscreen cells pick up new settings when dequeued."
        )
        #expect(
            collectionSource.contains("snapshot.reconfigureItems(toReconfigure)"),
            "Reader feed must ask the diffable data source to reconfigure visible matching item identifiers."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                // Collapse runs of whitespace (including newlines) to a single space so the
                // substring assertions stay robust to SwiftFormat line-wrapping: the project's
                // format-on-edit hook may wrap a long call (e.g. the `onAccessibilityActions`
                // closure header) across lines without changing its meaning, which must not
                // break these structural checks.
                return raw.replacingOccurrences(
                    of: "\\s+", with: " ", options: .regularExpression)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
