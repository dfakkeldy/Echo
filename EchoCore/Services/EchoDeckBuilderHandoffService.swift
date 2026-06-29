// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EchoDeckBuilderHandoffError: Error, Equatable, LocalizedError {
    case noLoadedBook
    case noEPUBFound(URL)
    case multipleEPUBCandidates([String])

    var errorDescription: String? {
        switch self {
        case .noLoadedBook:
            "Open an EPUB-backed book before sending it to EchoDeckBuilder."
        case .noEPUBFound(let url):
            "No EPUB file was found for \(url.lastPathComponent)."
        case .multipleEPUBCandidates(let names):
            "Multiple EPUB files match this book: \(names.joined(separator: ", "))."
        }
    }
}

enum EchoDeckBuilderHandoffService {
    static func currentEPUBURL(
        bookURL: URL?,
        preferredEPUBURL: URL? = nil,
        currentTrackURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let preferredEPUBURL,
           isEPUB(preferredEPUBURL),
           isRegularFile(preferredEPUBURL, fileManager: fileManager) {
            return preferredEPUBURL
        }

        guard let bookURL else {
            throw EchoDeckBuilderHandoffError.noLoadedBook
        }

        if isEPUB(bookURL), isRegularFile(bookURL, fileManager: fileManager) {
            return bookURL
        }

        let searchRoot = searchRoot(for: bookURL, fileManager: fileManager)
        let candidates = epubCandidates(in: searchRoot, fileManager: fileManager)

        if let currentTrackURL,
           let matchingCandidate = candidates.first(where: {
               $0.deletingPathExtension().lastPathComponent
                   .localizedStandardCompare(currentTrackURL.deletingPathExtension().lastPathComponent)
                   == .orderedSame
           }) {
            return matchingCandidate
        }

        if candidates.count == 1, let onlyCandidate = candidates.first {
            return onlyCandidate
        }

        if candidates.isEmpty {
            throw EchoDeckBuilderHandoffError.noEPUBFound(searchRoot)
        }

        throw EchoDeckBuilderHandoffError.multipleEPUBCandidates(
            candidates.map(\.lastPathComponent)
        )
    }

    private static func isEPUB(_ url: URL) -> Bool {
        url.pathExtension.localizedCaseInsensitiveCompare("epub") == .orderedSame
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func searchRoot(for url: URL, fileManager: FileManager) -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url
        }

        return url.deletingLastPathComponent()
    }

    private static func epubCandidates(in directory: URL, fileManager: FileManager) -> [URL] {
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return urls
            .filter { isEPUB($0) && isRegularFile($0, fileManager: fileManager) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }
}
