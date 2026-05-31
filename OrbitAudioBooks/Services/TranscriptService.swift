import Foundation
import os.log

/// Loads transcript sidecar JSON files and computes word frequency data.
/// Uses direct injection of PlaybackState (same pattern as PlaylistManager).
struct TranscriptService {
    let state: PlaybackState

    /// Loads the transcript sidecar JSON for the given audio file.
    /// The plain transcript is expected at `<audio>.transcript.json` in the same directory.
    /// The enhanced transcript (Whisper + EPUB alignment) is expected at `<audio>.enhanced.json`.
    ///
    /// File I/O is dispatched off the main actor to avoid blocking the UI during
    /// track loading, especially for large transcript JSON files (several MB for
    /// full audiobooks).  State updates are applied back on the main actor.
    func loadTranscript(for url: URL) {
        guard state.isTranscriptProcessingEnabled else { return }

        // 1. Load plain transcript sidecar
        let plainFileName = url.deletingPathExtension().lastPathComponent + ".transcript.json"
        let plainURL = url.deletingLastPathComponent().appendingPathComponent(plainFileName)

        if FileManager.default.fileExists(atPath: plainURL.path) {
            Task.detached { [state] in
                do {
                    let data = try Data(contentsOf: plainURL)
                    let segments = try JSONDecoder().decode([TranscriptionSegment].self, from: data)
                    await MainActor.run { state.transcription = segments }
                } catch {
                    os_log(.error, "Failed to load plain transcript: %{private}@", error.localizedDescription)
                    await MainActor.run { state.transcription = [] }
                }
            }
        } else {
            state.transcription = []
        }

        // 2. Load enhanced transcript sidecar (Whisper + EPUB alignment)
        let enhancedFileName = url.deletingPathExtension().lastPathComponent + ".enhanced.json"
        let enhancedURL = url.deletingLastPathComponent().appendingPathComponent(enhancedFileName)

        if FileManager.default.fileExists(atPath: enhancedURL.path) {
            Task.detached { [state] in
                do {
                    let data = try Data(contentsOf: enhancedURL)
                    let segments = try JSONDecoder().decode([EnhancedTranscriptionSegment].self, from: data)
                    await MainActor.run { state.enhancedTranscription = segments }
                } catch {
                    os_log(.error, "Failed to load enhanced transcript: %{private}@", error.localizedDescription)
                    await MainActor.run { state.enhancedTranscription = [] }
                }
            }
        } else {
            state.enhancedTranscription = []
        }

        computeWordClouds()
    }

    /// Loads the enhanced transcript sidecar (`<audio>.enhanced.json`) if present.
    /// Returns the decoded segments directly for use by the ingestion pipeline,
    /// without storing them in PlaybackState (keeping V1 surface area small).
    ///
    /// The synchronous `Data(contentsOf:)` call is intentional here — this method
    /// is called from the ingestion pipeline which runs in a background task.
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
            os_log(.error, "Failed to load enhanced transcript: %{private}@", error.localizedDescription)
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
