// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Audit C2: "Part Two – Design in Practice:" repeated on every row is
/// structure pretending to be content. This groups consecutive display titles
/// that share a part prefix (any "<prefix>: " shared by ≥2 consecutive rows)
/// into sections, stripping the prefix from row titles. Pure string → string;
/// the view maps groups back to chapters by running index.
enum ChapterPartGrouper {
    struct Group: Equatable {
        let header: String?
        let rowTitles: [String]
    }

    /// Splits "Part One – Foo: 1. Bar" into (part: "Part One – Foo", rest: "1. Bar").
    /// Returns nil when the title has no ": " separator.
    private static func splitPart(_ title: String) -> (part: String, rest: String)? {
        guard let sepRange = title.range(of: ": ") else { return nil }
        let part = String(title[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(title[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !part.isEmpty, !rest.isEmpty else { return nil }
        return (part, rest)
    }

    static func group(displayTitles: [String]) -> [Group] {
        var groups: [Group] = []
        var header: String? = nil
        var titles: [String] = []
        var raw: [String] = []

        func flush() {
            guard !titles.isEmpty else { return }
            // A part with a single row isn't structure — restore raw titles.
            if header != nil && titles.count < 2 {
                groups.append(Group(header: nil, rowTitles: raw))
            } else {
                groups.append(Group(header: header, rowTitles: titles))
            }
            header = nil
            titles = []
            raw = []
        }

        for title in displayTitles {
            let split = splitPart(title)
            if let split, split.part == header {
                titles.append(split.rest)
                raw.append(title)
            } else if let split {
                flush()
                header = split.part
                titles = [split.rest]
                raw = [title]
            } else {
                if header != nil { flush() }
                titles.append(title)
                raw.append(title)
            }
        }
        flush()

        // Merge adjacent headerless groups produced by the single-row restore.
        var merged: [Group] = []
        for group in groups {
            if group.header == nil, let last = merged.last, last.header == nil {
                merged[merged.count - 1] = Group(header: nil, rowTitles: last.rowTitles + group.rowTitles)
            } else {
                merged.append(group)
            }
        }
        return merged
    }
}
