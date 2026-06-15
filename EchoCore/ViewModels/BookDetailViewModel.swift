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
    
    func startNarration(blocks: [EPubBlockRecord]) {
        isShowingVoicePicker = false
        
        Task {
            do {
                // Trigger compilation/preparation early so it doesn't block the first synthesis delay
                try await narrationService.tts.prepare()
                
                // In v1, we just render chapter 0 as a starting point.
                // In full implementation, we determine the current chapter and pass its blocks.
                try await narrationService.renderChapter(
                    chapterIndex: 0,
                    blocks: blocks,
                    voice: selectedVoice.id
                )
            } catch {
                narrationState.fail(error.localizedDescription)
            }
        }
    }
    
    func cancelNarration() {
        narrationState.reset()
    }
    
    // MARK: - Export
    
    func exportM4B() async {
        do {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent("\(audiobookID).m4b")
            let exportService = NarrationExportService()
            try await exportService.exportM4B(
                for: audiobookID,
                bookTitle: "Unknown Title", // Requires reading title from DB in production
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
