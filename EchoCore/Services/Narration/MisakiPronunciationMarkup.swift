// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated enum MisakiPronunciationMarkup {
    struct Link {
        let range: Range<String.Index>
        let displayText: Substring
    }

    static func displayText(from source: String) -> String {
        var result = ""
        var index = source.startIndex

        while index < source.endIndex {
            if let link = link(in: source, startingAt: index) {
                result.append(contentsOf: link.displayText)
                index = link.range.upperBound
            } else {
                result.append(source[index])
                index = source.index(after: index)
            }
        }

        return result
    }

    static func link(in source: String, startingAt start: String.Index) -> Link? {
        guard source[start] == "[" else { return nil }

        let displayStart = source.index(after: start)
        guard
            let displayEnd = source[displayStart...].firstIndex(of: "]"),
            displayStart < displayEnd
        else {
            return nil
        }

        let openParenthesis = source.index(after: displayEnd)
        guard
            openParenthesis < source.endIndex,
            source[openParenthesis] == "("
        else {
            return nil
        }

        let openingSlash = source.index(after: openParenthesis)
        guard openingSlash < source.endIndex, source[openingSlash] == "/" else {
            return nil
        }

        let ipaStart = source.index(after: openingSlash)
        guard
            let closeParenthesis = source[ipaStart...].firstIndex(of: ")"),
            ipaStart < closeParenthesis
        else {
            return nil
        }

        let closingSlash = source.index(before: closeParenthesis)
        guard closingSlash > openingSlash, source[closingSlash] == "/" else {
            return nil
        }

        return Link(
            range: start..<source.index(after: closeParenthesis),
            displayText: source[displayStart..<displayEnd]
        )
    }
}
