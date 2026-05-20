import Foundation

/// Loads transcript sidecar JSON files and computes word frequency data.
/// Uses direct injection of PlaybackState (same pattern as PlaylistManager).
struct TranscriptService {
    let state: PlaybackState

    /// Loads the transcript sidecar JSON for the given audio file.
    /// The transcript is expected at `<audio>.transcript.json` in the same directory.
    func loadTranscript(for url: URL) {
        guard state.isTranscriptProcessingEnabled else { return }
        let fileName = url.deletingPathExtension().lastPathComponent + ".transcript.json"
        let transcriptURL = url.deletingLastPathComponent().appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            state.transcription = []
            return
        }

        do {
            let data = try Data(contentsOf: transcriptURL)
            state.transcription = try JSONDecoder().decode([TranscriptionSegment].self, from: data)
            computeWordClouds()
        } catch {
            print("Failed to load transcript: \(error)")
            state.transcription = []
        }
    }

    /// Loads the enhanced transcript sidecar (`<audio>.enhanced.json`) if present.
    /// Returns the decoded segments directly for use by the ingestion pipeline,
    /// without storing them in PlaybackState (keeping V1 surface area small).
    func loadEnhancedTranscript(for url: URL) -> [EnhancedTranscriptionSegment]? {
        guard state.isTranscriptProcessingEnabled else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent + ".enhanced.json"
        let enhancedURL = url.deletingLastPathComponent().appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: enhancedURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: enhancedURL)
            return try JSONDecoder().decode([EnhancedTranscriptionSegment].self, from: data)
        } catch {
            print("Failed to load enhanced transcript: \(error)")
            return nil
        }
    }

    /// Computes word frequencies for the full track, per-chapter, and rolling windows.
    /// Called after both transcript and chapter data are available.
    func computeWordClouds() {
        guard state.isTranscriptProcessingEnabled, !state.transcription.isEmpty else { return }

        // Full-track word frequencies.
        let fullFrequencies = WordFrequencyComputer.compute(from: state.transcription)

        // Per-chapter frequencies.
        if !state.chapters.isEmpty {
            state.chapterWordClouds = WordFrequencyComputer.computePerChapter(
                segments: state.transcription,
                chapters: state.chapters
            )
        } else {
            // No chapters: store full frequencies under index 0 as the only "chapter."
            state.chapterWordClouds = [0: fullFrequencies]
        }

        // Rolling 5-minute windows.
        state.rollingWordClouds = WordFrequencyComputer.computeRollingWindows(
            segments: state.transcription,
            windowDuration: 300,
            step: 60
        )
    }
}
