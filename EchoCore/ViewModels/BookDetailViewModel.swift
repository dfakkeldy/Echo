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
        // AudioFileWriting stub - replacing with dummy for compilation if missing
        let writer = DummyAudioWriter()
        let cacheDir = FileManager.default.temporaryDirectory
        
        self.narrationService = NarrationService(
            db: db,
            audiobookID: audiobookID,
            tts: tts,
            audioWriter: writer,
            cacheDirectory: cacheDir,
            state: self.narrationState
        )
    }
    
    func startNarration(blocks: [EPubBlockRecord]) {
        isShowingVoicePicker = false
        
        Task {
            do {
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
}

/// Dummy writer just to satisfy compilation until real AVFoundation AudioWriter is built
struct DummyAudioWriter: AudioFileWriting {
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        return chunks.reduce(0) { $0 + $1.duration }
    }
}
