// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PDFBlockPageMapperTests {
    @Test func assignsBlocksToTheirSourcePage() {
        let pages = [
            "Chapter One\nThe quick brown fox jumps over the lazy dog.",
            "Chapter Two\nA second page with different words entirely here.",
        ]
        let blocks = [
            (id: "b0", text: "Chapter One"),
            (id: "b1", text: "The quick brown fox jumps over the lazy dog."),
            (id: "b2", text: "Chapter Two"),
            (id: "b3", text: "A second page with different words entirely here."),
        ]
        let result = PDFBlockPageMapper.map(blocks: blocks, pages: pages)
        #expect(result.first(where: { $0.blockID == "b0" })?.pageIndex == 0)
        #expect(result.first(where: { $0.blockID == "b1" })?.pageIndex == 0)
        #expect(result.first(where: { $0.blockID == "b2" })?.pageIndex == 1)
        #expect(result.first(where: { $0.blockID == "b3" })?.pageIndex == 1)
    }

    @Test func toleratesWhitespaceAndCaseDifferences() {
        let pages = ["the   QUICK\nbrown fox"]
        let blocks = [(id: "b0", text: "The quick brown fox")]
        #expect(PDFBlockPageMapper.map(blocks: blocks, pages: pages).first?.pageIndex == 0)
    }

    @Test func unmatchedBlockFallsBackToLastKnownPage() {
        let pages = ["page zero text", "page one text"]
        let blocks = [
            (id: "b0", text: "page zero text"),
            (id: "b1", text: "synthetic heading not on any page"),
            (id: "b2", text: "page one text"),
        ]
        let r = PDFBlockPageMapper.map(blocks: blocks, pages: pages)
        #expect(r.first(where: { $0.blockID == "b0" })?.pageIndex == 0)
        #expect(r.first(where: { $0.blockID == "b1" })?.pageIndex == 0)  // carries previous
        #expect(r.first(where: { $0.blockID == "b2" })?.pageIndex == 1)
    }
}
