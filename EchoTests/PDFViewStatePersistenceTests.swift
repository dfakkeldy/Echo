// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct PDFViewStatePersistenceTests {
    @Test func storesPDFViewStatePerBook() {
        let model = PlayerModel()
        let firstBook = URL(fileURLWithPath: "/Books/First", isDirectory: true)
        let secondBook = URL(fileURLWithPath: "/Books/Second", isDirectory: true)
        let firstState = PDFViewState(pageIndex: 2, zoomScale: 1.5, offsetX: 12, offsetY: 34)
        let secondState = PDFViewState(pageIndex: 8, zoomScale: 2.0, offsetX: 56, offsetY: 78)

        model.updatePDFViewState(firstState, for: firstBook)
        model.updatePDFViewState(secondState, for: secondBook)

        #expect(model.pdfViewState(for: firstBook) == firstState)
        #expect(model.pdfViewState(for: secondBook) == secondState)
        #expect(model.currentPDFViewState == secondState)
    }
}
