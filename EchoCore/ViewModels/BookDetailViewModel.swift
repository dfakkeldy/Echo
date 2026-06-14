import AVFoundation
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
    private var player: AVAudioPlayer?

    init(db: DatabaseWriter, audiobookID: String, audioEngine: AudioEngine) {
        self.audiobookID = audiobookID
        self.db = db

        self.narrationState = NarrationState()

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

    /// Eagerly pay the one-time ANE compile so the first Listen tap isn't a long stall.
    func prepareTTS() async {
        try? await narrationService.tts.prepare()
    }

    /// Render the loaded book's chapter 1 with the selected voice, then play it.
    func startNarration() {
        isShowingVoicePicker = false

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.narrationService.tts.prepare()
                let blocks = try EPubBlockDAO(db: self.db)
                    .blocks(for: self.audiobookID, chapterIndex: 0)
                try await self.narrationService.renderChapter(
                    chapterIndex: 0,
                    blocks: blocks,
                    voice: self.selectedVoice.id
                )
                // Play the rendered chapter file.
                let url = self.cacheDirectory.appendingPathComponent(
                    NarrationFileNaming.chapterFileName(
                        audiobookID: self.audiobookID, chapterIndex: 0,
                        voice: self.selectedVoice.id))
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player = try AVAudioPlayer(contentsOf: url)
                self.player?.play()
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
        player?.stop()
        narrationState.reset()
    }

    // MARK: - Export

    func exportM4B() async {
        do {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(NarrationFileNaming.safeToken(audiobookID)).m4b")
            let exportService = NarrationExportService()
            try await exportService.exportM4B(
                for: audiobookID,
                bookTitle: "Unknown Title",  // TODO: read the real title from the DB
                cacheDirectory: self.cacheDirectory,
                outputURL: tempOutput
            )
            // TODO: surface a share sheet for `tempOutput`.
        } catch {
            print("Export M4B failed: \(error)")
        }
    }

    func exportChapters() async {
        do {
            let exportService = NarrationExportService()
            _ = try await exportService.exportChapterFiles(
                for: audiobookID,
                cacheDirectory: self.cacheDirectory
            )
            // TODO: surface a share sheet for the returned files.
        } catch {
            print("Export chapters failed: \(error)")
        }
    }
}
