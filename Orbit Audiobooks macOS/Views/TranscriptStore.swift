import Foundation
import Combine
import CryptoKit

struct GlobalTranscriptIndex: Codable {
    let fileHash: String
    let fileName: String
    let segments: [TranscriptionSegment]
}

@MainActor
class TranscriptStore: ObservableObject {
    @Published var transcriptions: [String: [TranscriptionSegment]] = [:]
    @Published var fileMapping: [String: String] = [:] // Hash -> Title

    private let transcriptDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        loadIndex()

        NotificationCenter.default.addObserver(forName: NSNotification.Name("TranscriptDidUpdate"), object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func loadIndex() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: transcriptDir, includingPropertiesForKeys: nil) else { 
            print("TranscriptStore: Could not list directory \(transcriptDir)")
            return 
        }

        print("TranscriptStore: Loading from \(transcriptDir.path), found \(files.count) files")

        var newTranscriptions: [String: [TranscriptionSegment]] = [:]
        for file in files where file.pathExtension == "json" {
            let hash = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let segments = try? JSONDecoder().decode([TranscriptionSegment].self, from: data) {
                print("TranscriptStore: Loaded \(segments.count) segments for hash \(hash)")
                newTranscriptions[hash] = segments
                fileMapping[hash] = "Audiobook"
            } else {
                print("TranscriptStore: Failed to decode \(file.lastPathComponent)")
            }
        }
        self.transcriptions = newTranscriptions
    }

    func reload() {
        loadIndex()
    }

    func search(query: String) -> [(String, TranscriptionSegment)] {
        var results: [(String, TranscriptionSegment)] = []
        for (hash, segments) in transcriptions {
            let matches = segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
            for match in matches {
                results.append((hash, match))
            }
        }
        return results
    }
}

