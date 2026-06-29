// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PDFCompanionSelectorTests {
    @Test func exactTitleMatchWinsOverDuplicateCopy() {
        let urls = [
            URL(fileURLWithPath: "/Books/The Workbook (2).pdf"),
            URL(fileURLWithPath: "/Books/The Workbook.pdf"),
            URL(fileURLWithPath: "/Books/Appendix.pdf"),
        ]

        let selected = PDFCompanionSelector.preferredPDF(
            from: urls,
            bookTitle: "The Workbook")

        #expect(selected?.lastPathComponent == "The Workbook.pdf")
    }

    @Test func copySuffixIsPenalizedWhenTitleIsUnavailable() {
        let urls = [
            URL(fileURLWithPath: "/Books/The Workbook (2).pdf"),
            URL(fileURLWithPath: "/Books/The Workbook.pdf"),
        ]

        let selected = PDFCompanionSelector.preferredPDF(from: urls, bookTitle: nil)

        #expect(selected?.lastPathComponent == "The Workbook.pdf")
    }

    @Test func closeTitleMatchBeatsArbitraryFilenameOrder() {
        let urls = [
            URL(fileURLWithPath: "/Books/A-Handout.pdf"),
            URL(fileURLWithPath: "/Books/Neurodivergence Skills Workbook.pdf"),
        ]

        let selected = PDFCompanionSelector.preferredPDF(
            from: urls,
            bookTitle: "The Neurodivergence Skills Workbook for Autism and ADHD")

        #expect(selected?.lastPathComponent == "Neurodivergence Skills Workbook.pdf")
    }
}
