#if DEBUG
import Foundation

struct MockMediaProvider {
    static let sampleFileName = "BIFF.m4b"

    static func seedSampleAudiobookIfNeeded() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destination = documents.appendingPathComponent(sampleFileName)

        if fm.fileExists(atPath: destination.path) { return }

        guard let bundleURL = Bundle.main.url(forResource: "BIFF", withExtension: "m4b") else {
            print("[MockMediaProvider] Sample audiobook not found in bundle.")
            return
        }

        do {
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            print("[MockMediaProvider] Failed to copy sample audiobook: \(error)")
        }
    }

    static func sampleAudiobookURL() -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documents.appendingPathComponent(sampleFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
