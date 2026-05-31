import Foundation
import os.log

struct EPubTextExtraction {
    let id: String
    let text: String
}

struct MacEPUBParser {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "MacEPUBParser")
    
    /// Extracts text blocks from an EPUB file (or directory).
    /// Does not interact with SQL. Returns an array of text structures.
    func extractText(from epubURL: URL) async throws -> [EPubTextExtraction] {
        var unzippedURL = epubURL
        var needsCleanup = false

        if epubURL.pathExtension.lowercased() == "epub" {
            let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", epubURL.path, "-d", tempDir.path]

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "MacEPUBParser",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to unzip EPUB (code \(proc.terminationStatus))"]
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }

            // Validate that no extracted files escape the temp directory (path-traversal prevention)
            let tempDirStandardized = tempDir.standardized
            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.standardized.path.hasPrefix(tempDirStandardized.path) else {
                        throw NSError(domain: "MacEPUBParser", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: "Path traversal detected: extracted file \(fileURL.path) escapes temp directory"
                        ])
                    }
                }
            }

            unzippedURL = tempDir
            needsCleanup = true
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: unzippedURL)
            }
        }
        
        let containerURL = unzippedURL.appending(path: "META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw NSError(domain: "MacEPUBParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid EPUB: missing container.xml"])
        }
        
        let opfRelativePath = try parseContainerXML(at: containerURL)
        let opfURL = unzippedURL.appending(path: opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()
        let spine = try parseOPF(at: opfURL)
        
        var extractions: [EPubTextExtraction] = []
        var blockCount = 0
        
        for (spineIdx, item) in spine.enumerated() {
            let href = item.href
            let xhtmlURL: URL
            if href.hasPrefix("/") || href.contains("://") {
                xhtmlURL = unzippedURL.appending(path: href)
            } else {
                xhtmlURL = opfDir.appending(path: href)
            }
            
            guard FileManager.default.fileExists(atPath: xhtmlURL.path) else { continue }
            let xhtmlData = try Data(contentsOf: xhtmlURL)
            let blocks = parseXHTML(from: xhtmlData)

            for blockText in blocks {
                guard let text = blockText.text else { continue }
                let id = "epub-mac-s\(spineIdx)-b\(blockCount)"
                extractions.append(EPubTextExtraction(id: id, text: text))
                blockCount += 1
            }
        }
        
        return extractions
    }
    
    // MARK: - XML Parsing

    private func parseContainerXML(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let path = parseContainerXML(from: data) else {
            throw NSError(domain: "MacEPUBParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing OPF path"])
        }
        return path
    }

    private func parseOPF(at url: URL) throws -> [SpineItemDescriptor] {
        let data = try Data(contentsOf: url)
        return parseOPF(from: data)
    }
}