// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct ReaderFeedAccessibilityTests {
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
