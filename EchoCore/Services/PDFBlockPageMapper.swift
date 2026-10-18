// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps each imported block to the source PDF page whose raw text contains it.
/// Whitespace/case-insensitive; advances a page cursor so sequential blocks
/// resolve monotonically and an unmatched (e.g. synthetic-heading) block
/// carries the previous block's page.
enum PDFBlockPageMapper {
    static func map(
        blocks: [(id: String, text: String)], pages: [String]
    ) -> [(blockID: String, pageIndex: Int)] {
        let norm = pages.map { normalize($0) }
        var cursor = 0
        var out: [(blockID: String, pageIndex: Int)] = []
        for block in blocks {
            let needle = normalize(block.text)
            var found: Int?
            if !needle.isEmpty {
                // Prefer the current page or later (monotonic reading order).
                for p in cursor..<norm.count where norm[p].contains(needle) {
                    found = p
                    break
                }
                if found == nil {
                    for p in 0..<norm.count where norm[p].contains(needle) {
                        found = p
                        break
                    }
                }
            }
            let page = found ?? cursor
            cursor = max(cursor, page)
            out.append((blockID: block.id, pageIndex: page))
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
