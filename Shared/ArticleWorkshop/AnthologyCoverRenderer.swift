// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum AnthologyCoverRenderer {
    static func generatedCover(manifest: AnthologyBuildManifest) -> Data {
        let title = lines(manifest.title, maximumLines: 5)
        let creator = lines(manifest.creator, maximumLines: 2)
        let titleElements = title.enumerated().map { index, line in
            """
              <text x="120" y="\(760 + index * 150)" fill="#ffffff" font-family="serif" font-size="112">\(EPUBXMLWriter.escapeText(line))</text>
            """
        }.joined(separator: "\n")
        let creatorElements = creator.enumerated().map { index, line in
            """
              <text x="120" y="\(1800 + index * 80)" fill="#b9c8e5" font-family="sans-serif" font-size="56">\(EPUBXMLWriter.escapeText(line))</text>
            """
        }.joined(separator: "\n")
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="2560" viewBox="0 0 1600 2560">
              <title>\(EPUBXMLWriter.escapeText(manifest.title))</title>
              <rect width="1600" height="2560" fill="#18243a"/>
            \(titleElements)
            \(creatorElements)
            </svg>
            """.utf8)
    }

    private static func lines(_ value: String, maximumLines: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for word in value.split(whereSeparator: \.isWhitespace).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= 22 {
                current += " \(word)"
            } else {
                result.append(current)
                current = word
            }
            if result.count == maximumLines { break }
        }
        if result.count < maximumLines, current.isEmpty == false {
            result.append(current)
        }
        return result
    }
}
