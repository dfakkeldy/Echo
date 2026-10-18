// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct VideoExportDestination: Equatable, Sendable {
    let videoURL: URL
    let srtURL: URL
    let chaptersURL: URL

    init(panelURL: URL) throws {
        let baseURL = panelURL.deletingPathExtension()
        let stem = baseURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExtensionOnlyMovie = panelURL.lastPathComponent.lowercased() == ".mp4"
        guard !stem.isEmpty, !isExtensionOnlyMovie else {
            throw VideoExportDestinationError.emptyFileName
        }

        videoURL = panelURL
        srtURL = baseURL.appendingPathExtension("srt")
        chaptersURL = baseURL.appendingPathExtension("chapters.txt")
    }
}

nonisolated enum VideoExportDestinationError: LocalizedError, Equatable, Sendable {
    case emptyFileName

    var errorDescription: String? {
        String(localized: "videoExportErrorEmptyFilename")
    }
}
