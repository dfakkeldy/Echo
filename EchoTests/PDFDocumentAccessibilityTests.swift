// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct PDFDocumentAccessibilityTests {
    @Test func pdfActionsAreVisibleAndAvailableToAssistiveTechnology() throws {
        let source = try Self.source("EchoCore/Views/PDFDocumentView.swift")

        #expect(
            source.contains("private enum PDFDocumentAction: CaseIterable"),
            "PDF actions should be modeled once so the menu and accessibility actions stay in sync."
        )
        #expect(
            source.contains(".overlay(alignment: .bottomTrailing)"),
            "PDFDocumentView must show a visible action menu instead of relying only on long press."
        )
        #expect(
            source.contains("private var pdfActionMenu: some View"),
            "PDFDocumentView must expose visible PDF alignment/bookmark actions."
        )
        #expect(
            source.contains("Menu { ForEach(PDFDocumentAction.allCases)"),
            "The visible PDF menu must include every PDF document action."
        )
        #expect(
            source.contains("accessibilityCustomActions = PDFDocumentAction.allCases.map"),
            "PDFKitView must expose the same PDF operations as custom VoiceOver actions."
        )
        #expect(
            source.contains("UIAccessibilityCustomAction(name: action.title)"),
            "PDF accessibility actions must use descriptive action titles."
        )
        #expect(
            source.contains("customAction.category = UIAccessibilityCustomAction.editCategory"),
            "PDF accessibility actions should be categorized as editing/context actions."
        )
    }

    @Test func pdfActionPathsShareCurrentStateResolution() throws {
        let source = try Self.source("EchoCore/Views/PDFDocumentView.swift")

        #expect(
            source.contains("performPDFAction(action, state: capturedState)"),
            "The long-press dialog must use the shared PDF action executor."
        )
        #expect(
            source.contains("performPDFAction(action, state: currentPDFActionState)"),
            "The visible PDF menu must use the shared PDF action executor."
        )
        #expect(
            source.contains("return PDFViewState(pageIndex: 0, zoomScale: 1, offsetX: 0, offsetY: 0)"),
            "The visible menu must have a first-page fallback before PDFKit publishes its first state."
        )
        #expect(
            source.contains("return parent.onAction(action, state)"),
            "The PDFView custom action must invoke the same action executor with the live PDFView state."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.replacingOccurrences(
                    of: "\\s+", with: " ", options: .regularExpression)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
