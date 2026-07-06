// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension String {
    nonisolated func strippingTrackNumberPrefix() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }

        if let stripped = trimmed.strippingKeywordTrackPrefix() {
            return stripped
        }
        if let stripped = trimmed.strippingNumericTrackPrefix() {
            return stripped
        }
        return self
    }

    private nonisolated func strippingKeywordTrackPrefix() -> String? {
        for keyword in ["track", "chapter", "chap", "ch", "part", "pt"] {
            guard lowercased().hasPrefix(keyword) else { continue }

            var index = self.index(startIndex, offsetBy: keyword.count)
            if index < endIndex, self[index] == "." {
                formIndex(after: &index)
            }
            while index < endIndex, self[index].isWhitespace {
                formIndex(after: &index)
            }

            guard index < endIndex, self[index].isNumber else { continue }
            while index < endIndex, self[index].isNumber {
                formIndex(after: &index)
            }
            return strippedTrackPrefixRemainder(after: index)
        }
        return nil
    }

    private nonisolated func strippingNumericTrackPrefix() -> String? {
        var index = startIndex
        var digitCount = 0
        while index < endIndex, self[index].isNumber {
            digitCount += 1
            formIndex(after: &index)
        }

        guard (1...3).contains(digitCount), index < endIndex else { return nil }
        return strippedTrackPrefixRemainder(after: index)
    }

    private nonisolated func strippedTrackPrefixRemainder(after index: String.Index) -> String? {
        var index = index
        var sawSeparator = false
        while index < endIndex, self[index].isTrackPrefixSeparator {
            sawSeparator = true
            formIndex(after: &index)
        }

        guard sawSeparator else { return nil }
        let candidate = self[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}

private extension Character {
    nonisolated var isTrackPrefixSeparator: Bool {
        isWhitespace || self == "." || self == "-" || self == ":" || self == "_"
    }
}
