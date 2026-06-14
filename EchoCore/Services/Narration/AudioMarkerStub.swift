import Foundation

/// A local stub mimicking the atelier-socle/swift-audio-marker package interface.
/// Added for compilation purposes until the remote SPM package is linked.
struct ChapterAtom {
    let startTime: Double
    let title: String
}

struct AudioMarker {
    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) throws {
        // Simulates injecting the chapters. In reality, it copies the source to output
        // and inserts the Nero chapter atoms and `stik` flags.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
    }
}
