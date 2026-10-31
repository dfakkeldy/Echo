// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

#if os(iOS)
    import UIKit
    @testable import Echo

    /// The reader is one continuous page: paragraphs carry no box, the block
    /// being read gets a soft wash in the cover colour, and a colour the user
    /// chose for a paragraph stays a highlight.
    struct ReaderPageStyleTests {
        private let settings = ReaderSettings(
            fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8", appFont: "System")

        @MainActor
        @Test func paragraphSitsOnThePageUntilItIsBeingRead() throws {
            let cell = ParagraphCardCell(frame: CGRect(x: 0, y: 0, width: 360, height: 80))
            cell.configure(
                with: Self.block(cardColor: nil, chapterThemeColor: nil),
                settings: settings, tint: .systemBackground, isExplicitHighlight: false,
                accent: .systemTeal)

            cell.isActiveBlock = false
            #expect(Self.alpha(of: cell.contentView.backgroundColor) == 0)

            cell.isActiveBlock = true
            let wash = try #require(cell.contentView.backgroundColor)
            #expect(Self.alpha(of: wash) > 0 && Self.alpha(of: wash) < 0.2)
            #expect(Self.sameHue(wash, .systemTeal))
        }

        @MainActor
        @Test func chapterThemeColourLeadsTheWash() throws {
            let cell = ParagraphCardCell(frame: CGRect(x: 0, y: 0, width: 360, height: 80))
            cell.configure(
                with: Self.block(cardColor: nil, chapterThemeColor: "#FF0000"),
                settings: settings, tint: .systemBackground, isExplicitHighlight: false,
                accent: .systemTeal)
            cell.isActiveBlock = true
            let wash = try #require(cell.contentView.backgroundColor)
            #expect(Self.sameHue(wash, UIColor(red: 1, green: 0, blue: 0, alpha: 1)))
        }

        @MainActor
        @Test func userColouredParagraphKeepsItsHighlightAndShowsWhenRead() throws {
            let yellow = UIColor(red: 1, green: 0.96, blue: 0.62, alpha: 1)
            let cell = ParagraphCardCell(frame: CGRect(x: 0, y: 0, width: 360, height: 80))
            cell.configure(
                with: Self.block(cardColor: "#FFF59D", chapterThemeColor: nil),
                settings: settings, tint: yellow, isExplicitHighlight: true,
                accent: .systemTeal)
            for active in [false, true] {
                cell.isActiveBlock = active
                #expect(cell.contentView.backgroundColor == yellow)
                // An accent outline marks it as the block being read.
                #expect(cell.contentView.layer.borderWidth == (active ? 2 : 0))
            }
        }

        @Test func sourceDropsTheCardChrome() throws {
            for file in [
                "EchoCore/Views/Cells/ParagraphCardCell.swift",
                "EchoCore/Views/Cells/HeadingCardCell.swift",
            ] {
                let source = try Self.source(file)
                #expect(!source.contains("activeBar"), "\(file) must not draw the old blue bar.")
                #expect(!source.contains("withAlphaComponent(0.08)"), "\(file) must not box every block.")
                #expect(source.contains("applyPageBackground()"))
            }
            let feed = try Self.source("EchoCore/Views/ReaderFeedCollectionView.swift")
            #expect(feed.contains("section.interGroupSpacing = 0"))
            #expect(feed.contains("accent: pageAccent"))
            #expect(!feed.contains("|| block.chapterThemeColor != nil, searchQuery"))
        }

        private static func block(cardColor: String?, chapterThemeColor: String?) -> EPubBlockRecord {
            EPubBlockRecord(
                id: "page-style", audiobookID: "book", spineHref: "chapter.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                text: "A paragraph on the page.", htmlContent: nil,
                cardColor: cardColor, chapterThemeColor: chapterThemeColor,
                imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
                wordCount: nil, markers: nil, textFormats: nil, createdAt: nil, modifiedAt: nil)
        }

        private static func alpha(of color: UIColor?) -> CGFloat {
            guard let color else { return 0 }
            var white: CGFloat = 0, alpha: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            return alpha
        }

        private static func sameHue(_ a: UIColor, _ b: UIColor) -> Bool {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return abs(ar - br) < 0.02 && abs(ag - bg) < 0.02 && abs(ab - bb) < 0.02
        }

        private static func source(_ relativePath: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
            let raw = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
            return raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }
#endif
