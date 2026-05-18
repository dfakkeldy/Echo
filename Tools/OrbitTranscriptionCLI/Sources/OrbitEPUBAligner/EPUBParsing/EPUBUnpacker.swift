import Foundation
import ZIPFoundation

struct EPUBUnpackResult {
    let tempDir: URL
    let containerXMLPath: URL
    let opfPath: URL
}

struct EPUBUnpacker {
    func unzip(_ epubURL: URL) throws -> EPUBUnpackResult {
        guard let archive = Archive(url: epubURL, accessMode: .read) else {
            throw AlignmentError.notAnEPUB(path: epubURL.path)
        }

        guard let mimetypeEntry = archive["mimetype"] else {
            throw AlignmentError.notAnEPUB(path: epubURL.path)
        }

        var mimetypeData = Data()
        _ = try archive.extract(mimetypeEntry) { chunk in
            mimetypeData.append(chunk)
        }
        let mimetypeString = String(data: mimetypeData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard mimetypeString == "application/epub+zip" else {
            throw AlignmentError.notAnEPUB(path: epubURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_align_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for entry in archive {
            guard entry.type == .file else { continue }
            let destination = tempDir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: destination)
        }

        let containerXMLPath = tempDir.appendingPathComponent("META-INF/container.xml")
        let opfPath = tempDir.appendingPathComponent("OEBPS/content.opf")

        return EPUBUnpackResult(tempDir: tempDir, containerXMLPath: containerXMLPath, opfPath: opfPath)
    }
}
