import Foundation

/// Detects available assets in a folder and selects the appropriate ingestion strategy.
///
/// Decision logic:
/// - `EnhancedTranscript.json` exists → RichIngestionStrategy (dense feed)
/// - Only M4B/M4A files → AudioOnlyIngestionStrategy (sparse feed)
/// - No audio files → nil (cannot ingest)
struct IngestionFactory {

    /// Returns the best strategy for the given folder, or nil if no audio files exist.
    static func strategy(for folderURL: URL) -> IngestionStrategy? {
        let assets = detectAssets(in: folderURL)

        guard !assets.audioFiles.isEmpty else {
            return nil
        }

        if assets.hasEnhancedTranscript {
            return RichIngestionStrategy()
        }

        return AudioOnlyIngestionStrategy()
    }

    // MARK: - Asset Detection

    struct DetectedAssets {
        let audioFiles: [URL]
        let epubFile: URL?
        let transcriptJSON: URL?
        let enhancedTranscriptJSON: URL?
        let hasEnhancedTranscript: Bool

        var hasEPUB: Bool { epubFile != nil }
    }

    static func detectAssets(in folderURL: URL) -> DetectedAssets {
        let contents = fileURLs(in: folderURL)

        let audioFiles = contents.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "m4b" || ext == "m4a" || ext == "mp3"
        }

        let epubFile = contents.first {
            $0.pathExtension.lowercased() == "epub"
        }

        let transcriptJSON = contents.first {
            $0.lastPathComponent.hasSuffix(".transcript.json")
                && !$0.lastPathComponent.contains("Enhanced")
        }

        let enhancedTranscriptJSON = contents.first {
            $0.lastPathComponent.contains("EnhancedTranscript")
                && $0.pathExtension.lowercased() == "json"
        }

        return DetectedAssets(
            audioFiles: audioFiles,
            epubFile: epubFile,
            transcriptJSON: transcriptJSON,
            enhancedTranscriptJSON: enhancedTranscriptJSON,
            hasEnhancedTranscript: enhancedTranscriptJSON != nil
        )
    }

    private static func fileURLs(in folderURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents
    }
}
