// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves the deliberately narrow source contract accepted by
/// `echo-cli export-blocks`. Unlike sidecar tooling, exports must preserve a
/// one-to-one relationship between the supplied path, the imported source, and
/// any file-byte identity in the v2 document.
nonisolated enum BlockExportSourceResolver {
    struct ResolvedSource: Equatable {
        let url: URL
        let epubName: String
        /// `nil` means this is an expanded EPUB directory, which cannot bind
        /// external consumers to archive file bytes.
        let epubSHA256: String?
    }

    enum Error: Equatable, LocalizedError {
        case missingSource(URL)
        case symbolicLink(URL)
        case unsupportedFile(URL)
        case unsupportedDirectory(URL)
        case unsupportedInput(URL)

        var errorDescription: String? {
            switch self {
            case .missingSource(let url):
                "export-blocks source does not exist: \(url.path)"
            case .symbolicLink(let url):
                "export-blocks does not accept symbolic-link sources: \(url.path)"
            case .unsupportedFile(let url):
                "export-blocks requires a direct regular .epub file, not: \(url.path)"
            case .unsupportedDirectory(let url):
                "export-blocks requires an expanded EPUB directory at the supplied path, not: \(url.path)"
            case .unsupportedInput(let url):
                "export-blocks requires a regular .epub file or expanded EPUB directory: \(url.path)"
            }
        }
    }

    static func resolve(at sourceURL: URL) throws -> ResolvedSource {
        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)) != nil {
            throw Error.symbolicLink(sourceURL)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw Error.missingSource(sourceURL)
        }

        guard let type = attributes[.type] as? FileAttributeType else {
            throw Error.unsupportedInput(sourceURL)
        }
        if type == .typeRegular {
            guard sourceURL.pathExtension.lowercased() == "epub" else {
                throw Error.unsupportedFile(sourceURL)
            }
            return ResolvedSource(
                url: sourceURL,
                epubName: sourceURL.lastPathComponent,
                epubSHA256: try PronunciationArtifactIntegrity.sha256Hex(of: sourceURL)
            )
        }
        if type == .typeDirectory {
            guard isExpandedEPUB(directoryURL: sourceURL) else {
                throw Error.unsupportedDirectory(sourceURL)
            }
            return ResolvedSource(
                url: sourceURL,
                epubName: sourceURL.lastPathComponent,
                epubSHA256: nil
            )
        }
        throw Error.unsupportedInput(sourceURL)
    }

    private static func isExpandedEPUB(directoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: directoryURL.appendingPathComponent("META-INF/container.xml").path
        ) && fileManager.fileExists(atPath: directoryURL.appendingPathComponent("mimetype").path)
    }
}
