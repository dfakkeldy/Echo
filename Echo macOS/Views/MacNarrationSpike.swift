// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
    import Foundation

    /// TEMPORARY P0 spike — deleted in P1 once the cross-platform engine seam and
    /// shared `NarrationCache` land. Proves on-device Kokoro synthesis runs on a
    /// real Apple Silicon Mac before any further investment: it drives the first
    /// narratable chapter of an open book through the same `NarrationService` the
    /// iOS app uses, with the real `KokoroTTSEngine`.
    enum MacNarrationSpike {
        /// Renders the first planned chapter of `audiobookID` to the narration
        /// cache via the real engine. Logs success/failure to the console; touches
        /// nothing in the shipping flow.
        @MainActor
        static func run(audiobookID: String, dbService: DatabaseService) async {
            do {
                let blocks = try EPubBlockDAO(db: dbService.writer).blocks(for: audiobookID)
                let chapters = NarrationChapterPlanner.plan(from: blocks)
                guard let first = chapters.first else {
                    print("[SPIKE] no narratable chapters for \(audiobookID)")
                    return
                }
                let service = NarrationService(
                    db: dbService.writer,
                    audiobookID: audiobookID,
                    tts: KokoroTTSEngine(),
                    audioWriter: AVFoundationAudioWriter(),
                    cacheDirectory: spikeCacheDirectory(),
                    state: NarrationState())
                try await service.renderChapter(
                    chapterIndex: first.index, chapterNumber: first.displayNumber,
                    blocks: first.blocks, voice: VoiceCatalog.default.id)
                print("[SPIKE] rendered chapter \(first.index) OK → narration cache")
            } catch {
                print("[SPIKE] FAILED: \(error)")
            }
        }

        /// Inline copy of the iOS-only `PlayerModel.narrationCacheDirectory()`.
        /// P1 replaces this with the shared `NarrationCache.directory()`.
        private static func spikeCacheDirectory() -> URL {
            let fm = FileManager.default
            let dir =
                (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory)
                .appendingPathComponent("Narration", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif
