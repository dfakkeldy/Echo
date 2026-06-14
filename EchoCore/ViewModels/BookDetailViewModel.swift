import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class BookDetailViewModel {
    let audiobookID: String
    private let db: DatabaseWriter

    // Core narration components
    let narrationState: NarrationState
    let narrationService: NarrationService
    let cacheDirectory: URL

    // UI state
    var isShowingVoicePicker = false
    var selectedVoice: NarrationVoice = VoiceCatalog.default

    private var renderTask: Task<Void, Never>?

    init(db: DatabaseWriter, audiobookID: String, audioEngine: AudioEngine) {
        self.audiobookID = audiobookID
        self.db = db

        self.narrationState = NarrationState()

        // Setup narration engine dependencies
        // In real app, KokoroTTSEngine and AVFoundationAudioWriter would be injected
        let tts = KokoroTTSEngine()
        let writer = AVFoundationAudioWriter()
        self.cacheDirectory = FileManager.default.temporaryDirectory

        self.narrationService = NarrationService(
            db: db,
            audiobookID: audiobookID,
            tts: tts,
            audioWriter: writer,
            cacheDirectory: self.cacheDirectory,
            state: self.narrationState
        )
    }

    func prepareTTS() async {
        try? await narrationService.tts.prepare()
    }

    func startNarration(blocks: [EPubBlockRecord]) {
        isShowingVoicePicker = false

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Pay the one-time ANE compile before the first synthesis.
                try await self.narrationService.tts.prepare()
                try await self.narrationService.renderChapter(
                    chapterIndex: 0,
                    blocks: blocks,
                    voice: self.selectedVoice.id
                )
            } catch is CancellationError {
                // Cancelled by the user — state was already reset in cancelNarration().
            } catch {
                self.narrationState.fail(error.localizedDescription)
            }
        }
    }

    func cancelNarration() {
        renderTask?.cancel()
        renderTask = nil
        narrationState.reset()
    }

    // MARK: - Export

    func exportM4B() async {
        do {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(audiobookID).m4b")
            let exportService = NarrationExportService()
            try await exportService.exportM4B(
                for: audiobookID,
                bookTitle: "Unknown Title",  // Requires reading title from DB in production
                cacheDirectory: self.cacheDirectory,
                outputURL: tempOutput
            )
            // Signal UI to show share sheet with `tempOutput`
        } catch {
            print("Export M4B failed: \(error)")
        }
    }

    func exportChapters() async {
        do {
            let exportService = NarrationExportService()
            let files = try await exportService.exportChapterFiles(
                for: audiobookID,
                cacheDirectory: self.cacheDirectory
            )
            // Signal UI to show share sheet with `files`
        } catch {
            print("Export chapters failed: \(error)")
        }
    }
}
