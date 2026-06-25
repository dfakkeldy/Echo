// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation

/// Minimal synthetic PDFs for runner/import tests.
enum TestPDFFixture {
    enum FixtureError: Error {
        case failedToCreatePDF
    }

    static func singleChapter(in dir: URL) throws -> URL {
        try makePDF(
            at: dir.appendingPathComponent("fixture-one-chapter.pdf"),
            lines: [
                "PDF Fixture",
                "This PDF uses a single narration chapter.",
                "It keeps the text short so PDF parsing and import remain fast."
            ])
    }

    static func twoChapters(in dir: URL) throws -> URL {
        try makePDF(
            at: dir.appendingPathComponent("fixture-two-chapters.pdf"),
            lines: [
                "Chapter 1",
                "This is the first chapter paragraph. It contains enough words",
                "to seed two stable text blocks when parsed for narration.",
                "Chapter 2",
                "This is the second chapter paragraph and keeps assertions fast."
            ])
    }

    static func threePagesWithoutChapterMarkers(in dir: URL) throws -> URL {
        try makePDF(
            at: dir.appendingPathComponent("fixture-three-pages.pdf"),
            pages: [
                [
                    "Opening notes",
                    "This first page has ordinary prose without a chapter heading.",
                    "It should become the first synthetic PDF narration chapter."
                ],
                [
                    "More practical notes",
                    "This second page also avoids chapter marker language.",
                    "It should become the second synthetic PDF narration chapter."
                ],
                [
                    "Closing notes",
                    "This third page keeps the fixture small and deterministic.",
                    "It should become the third synthetic PDF narration chapter."
                ]
            ])
    }

    private static func makePDF(at url: URL, lines: [String]) throws -> URL {
        try makePDF(at: url, pages: [lines])
    }

    private static func makePDF(at url: URL, pages: [[String]]) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError.failedToCreatePDF
        }

        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw FixtureError.failedToCreatePDF
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let cgFont = CTFontCopyGraphicsFont(font, nil)

        for lines in pages {
            context.beginPDFPage(nil as CFDictionary?)
            context.textMatrix = CGAffineTransform.identity
            context.setTextDrawingMode(CGTextDrawingMode.fill)
            context.setFontSize(24)
            context.setFont(cgFont)

            var currentY = mediaBox.height - 80
            let lineHeight: CGFloat = 30
            for line in lines {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentY -= lineHeight
                    continue
                }

                guard let attributed = CFAttributedStringCreate(
                    nil,
                    line as CFString,
                    [kCTFontAttributeName: font] as CFDictionary)
                else {
                    throw FixtureError.failedToCreatePDF
                }
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: currentY)
                CTLineDraw(ctLine, context)
                currentY -= lineHeight
            }
            context.endPDFPage()
        }
        context.closePDF()

        return url
    }
}
