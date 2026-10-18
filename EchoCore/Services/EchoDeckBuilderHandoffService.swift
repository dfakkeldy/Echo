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
        sourceDocumentURL: URL? = nil,
        currentTrackURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let sourceDocumentURL,
            isEPUB(sourceDocumentURL),
            isRegularFile(sourceDocumentURL, fileManager: fileManager)
        {
            return sourceDocumentURL
        }

        guard let bookURL else {
            throw EchoDeckBuilderHandoffError.noLoadedBook
        }

        if isEPUB(bookURL), isRegularFile(bookURL, fileManager: fileManager) {
            return bookURL
        }

        let searchRoot = searchRoot(for: bookURL, fileManager: fileManager)
        let candidates = epubCandidates(in: searchRoot, fileManager: fileManager)

        // Prefer a sibling whose base name matches the current track or the
        // directly-opened document, so "Chapter 02.m4b" / "Notes.pdf" map to
        // "Chapter 02.epub" / "Notes.epub" rather than to an unrelated sibling.
        let nameMatchTargets = [currentTrackURL, sourceDocumentURL]
            .compactMap { $0?.deletingPathExtension().lastPathComponent }
        if !nameMatchTargets.isEmpty,
            let matchingCandidate = candidates.first(where: { candidate in
                let base = candidate.deletingPathExtension().lastPathComponent
                return nameMatchTargets.contains {
                    base.localizedStandardCompare($0) == .orderedSame
                }
            })
        {
            return matchingCandidate
        }

        // A lone sibling resolves an audiobook / standalone-EPUB folder, but NOT a
        // folder we only reached because the user opened an unrelated non-EPUB
        // document there — that must name-match (handled above) or fail explicitly,
        // so we never hand off an unrelated book.
        let openedForeignDocument = sourceDocumentURL.map { !isEPUB($0) } ?? false
        if !openedForeignDocument, candidates.count == 1, let onlyCandidate = candidates.first {
            return onlyCandidate
        }

        if candidates.isEmpty || openedForeignDocument {
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
            isDirectory.boolValue
        {
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

        return
            urls
            .filter { isEPUB($0) && isRegularFile($0, fileManager: fileManager) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }
}

/// A one-off message surfaced by the EchoDeckBuilder handoff UI (the iOS Book
/// Settings row and the macOS "More" menu). Shared so the two platforms don't
/// each redeclare it.
struct EchoDeckBuilderAlert {
    let message: String
}
