// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// One figure rasterized from a PDF page. `pngData` is the cropped, composited
/// figure (codec-proof: rendered from the page, so JPEG-2000 + soft masks work).
///
/// `nonisolated`: a pure `Sendable` value carried out of the extractor's detached
/// work. Under Swift 6 MainActor default isolation it would otherwise be inferred
/// `@MainActor`, blocking off-main construction.
nonisolated struct ExtractedFigure: Sendable {
    let pageIndex: Int  // 0-based
    let order: Int  // order on the page, top-to-bottom
    let pngData: Data
}

/// Finds embedded image placements per page (content-stream scan for `Do` +
/// CTM tracking), filters tiny/decorative ones, and rasterizes each rect from
/// the rendered page. Pure/synchronous CoreGraphics — run inside a detached task.
///
/// `nonisolated`: the extraction is CPU-bound, allocation-free of shared state,
/// and meant to run off the main actor (Task 7 calls it inside a detached task).
nonisolated enum PDFFigureExtractor {
    private static let logger = Logger(subsystem: "Echo", category: "PDFFigureExtractor")

    static func extractFigures(
        from pdfURL: URL, minPointSize: CGFloat = 72, renderScale: CGFloat = 2.0
    ) -> [ExtractedFigure] {
        guard let doc = CGPDFDocument(pdfURL as CFURL) else { return [] }
        var out: [ExtractedFigure] = []
        for pageNumber in 1...max(1, doc.numberOfPages) {
            guard doc.numberOfPages >= pageNumber, let page = doc.page(at: pageNumber) else {
                continue
            }
            let rects = imageRects(on: page, minPointSize: minPointSize)
            guard !rects.isEmpty else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            for (order, rect) in rects.enumerated() {
                if let png = rasterize(
                    page: page, rect: rect, mediaBox: mediaBox, scale: renderScale)
                {
                    out.append(
                        ExtractedFigure(pageIndex: pageNumber - 1, order: order, pngData: png))
                }
            }
        }
        return out
    }

    // MARK: content-stream scan for image XObject placements

    /// Mutable scan state threaded through the `@convention(c)` operator callbacks
    /// via the scanner's `info` pointer. Touched synchronously on one thread for
    /// the duration of a single scan, so it needs no synchronization.
    ///
    /// `nonisolated`: the C callbacks run with no actor context; MainActor
    /// isolation here would make the property mutations illegal from that context.
    private nonisolated final class ScanState {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
    }

    private static func imageRects(on page: CGPDFPage, minPointSize: CGFloat) -> [CGRect] {
        let state = ScanState()
        guard let table = CGPDFOperatorTableCreate() else { return [] }

        // `cm`: concatenate matrix. Operands pop in REVERSE order, so fill f[5…0].
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            var f = [CGFloat](repeating: 0, count: 6)
            for i in (0..<6).reversed() {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { return }
                f[i] = CGFloat(v)
            }
            let m = CGAffineTransform(a: f[0], b: f[1], c: f[2], d: f[3], tx: f[4], ty: f[5])
            s.ctm = m.concatenating(s.ctm)
        }
        // `q` / `Q`: save/restore graphics state (CTM).
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            if let top = s.stack.popLast() { s.ctm = top }
        }
        // `Do`: draw XObject. In PDF, an image XObject is the unit square under
        // the CTM. (Form XObjects also emit `Do`; the size filter below drops the
        // non-figure noise, and the rasterizer renders whatever is under the rect.)
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name) else { return }
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm)
            s.rects.append(unit)
        }

        // `state` stays strongly referenced for the whole scan, so passing it
        // unretained through `info` is safe (no premature deallocation).
        let info = Unmanaged.passUnretained(state).toOpaque()
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        // Create Rule: the table is an unmanaged `OpaquePointer` (ARC doesn't own
        // it), so release it explicitly to avoid leaking one table per page.
        CGPDFOperatorTableRelease(table)

        // Keep only sizable placements (drop icons/rules/decorative marks).
        return state.rects.filter { $0.width >= minPointSize && $0.height >= minPointSize }
    }

    // MARK: rasterize a page rect to PNG

    private static func rasterize(
        page: CGPDFPage, rect: CGRect, mediaBox: CGRect, scale: CGFloat
    ) -> Data? {
        let clamped = rect.intersection(mediaBox)
        guard !clamped.isNull, clamped.width > 1, clamped.height > 1 else { return nil }
        let pxW = Int((clamped.width * scale).rounded())
        let pxH = Int((clamped.height * scale).rounded())
        guard pxW > 0, pxH > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        // Map the figure rect to the bitmap origin at `scale`.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -clamped.origin.x, y: -clamped.origin.y)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
