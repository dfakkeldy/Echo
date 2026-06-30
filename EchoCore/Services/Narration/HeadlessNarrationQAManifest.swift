// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct HeadlessNarrationQAChapter: Equatable, Sendable {
    let chapterIndex: Int
    let fileURL: URL
    let spokenBlockIDs: [String]
}

enum HeadlessNarrationQAManifestError: LocalizedError {
    case missingAudioForChapter(Int)
    case noChaptersFound(URL)

    var errorDescription: String? {
        switch self {
        case .missingAudioForChapter(let chapterIndex):
            "No rendered audio file was found for chapter \(chapterIndex)."
        case .noChaptersFound(let workDir):
            "No captured narration chapters were found in \(workDir.path)."
        }
    }
}

nonisolated enum HeadlessNarrationQAManifest {
    static func chapters(audiobookID: String, workDir: URL) throws -> [HeadlessNarrationQAChapter] {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(
            at: workDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )

        let audioByChapter = Dictionary(
            files.compactMap { url -> (Int, URL)? in
                guard url.pathExtension.lowercased() == "m4a",
                      let chapterIndex = Self.chapterIndex(in: url.lastPathComponent) else {
                    return nil
                }
                return (chapterIndex, url)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let captures = try files.compactMap { url -> (Int, ChapterCapture)? in
            guard url.lastPathComponent.hasPrefix(".anchors-ch"),
                  url.pathExtension == "json",
                  let chapterIndex = Self.chapterIndex(in: url.lastPathComponent) else {
                return nil
            }
            let capture = try JSONDecoder().decode(ChapterCapture.self, from: Data(contentsOf: url))
            return (chapterIndex, capture)
        }

        let chapters = try captures
            .sorted { $0.0 < $1.0 }
            .map { chapterIndex, capture -> HeadlessNarrationQAChapter in
                guard let audioURL = audioByChapter[chapterIndex] else {
                    throw HeadlessNarrationQAManifestError.missingAudioForChapter(chapterIndex)
                }
                let blockIDs = Self.stableUnique(capture.anchors.map(\.suffix)).map {
                    AlignmentSidecar.localBlockID($0, audiobookID: audiobookID)
                }
                return HeadlessNarrationQAChapter(
                    chapterIndex: chapterIndex,
                    fileURL: audioURL,
                    spokenBlockIDs: blockIDs
                )
            }

        guard !chapters.isEmpty else {
            throw HeadlessNarrationQAManifestError.noChaptersFound(workDir)
        }
        return chapters
    }

    private static func chapterIndex(in filename: String) -> Int? {
        guard let range = filename.range(of: "ch[0-9]+", options: .regularExpression) else {
            return nil
        }
        return Int(filename[range].dropFirst(2))
    }

    private static func stableUnique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

private nonisolated struct ChapterCapture: Decodable, Sendable {
    let duration: TimeInterval
    let anchors: [Anchor]

    nonisolated struct Anchor: Decodable, Sendable {
        let suffix: String
        let time: TimeInterval
    }
}
