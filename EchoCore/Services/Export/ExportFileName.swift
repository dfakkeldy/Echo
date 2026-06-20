// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Strips path separators and other illegal characters from a book title so the
/// derived file name can't escape the temp/destination directory.
enum ExportFileName {
    static func safe(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Audiobook" : cleaned
    }
}
