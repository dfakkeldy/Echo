#if DEBUG
import Foundation
import os.log

struct MockMediaProvider {
    static let sampleFileName = "BIFF.m4b"
    private static let logger = Logger(category: "MockMediaProvider")

    static func seedSampleAudiobookIfNeeded() {
        let fm = FileManager.default
        let documents = URL.documentsDirectory
        let destination = documents.appendingPathComponent(sampleFileName)

        if fm.fileExists(atPath: destination.path) { return }

        guard let bundleURL = Bundle.main.url(forResource: "BIFF", withExtension: "m4b") else {
            logger.info("Sample audiobook not found in bundle.")
            return
        }

        do {
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            logger.error("Failed to copy sample audiobook: \(error)")
        }
    }

    static func sampleAudiobookURL() -> URL? {
        let documents = URL.documentsDirectory
        let url = documents.appendingPathComponent(sampleFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
