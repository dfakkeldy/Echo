import Foundation
import AVFoundation

/// Handles the export of generated narration (Phase 2).
/// Supports exporting raw AAC files per chapter, or combining into a single `.m4b` file.
actor NarrationExportService {
    
    enum ExportError: Error {
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
        case missingAudiobook
    }
    
    /// Collects the per-chapter `.m4a` cache files for a book and returns them for sharing.
    /// This is the fast, free export path (7a).
    func exportChapterFiles(for bookID: String, cacheDirectory: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let prefix = "narration_\(bookID)_"
        
        let allFiles = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        
        let bookFiles = allFiles
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
        return bookFiles
    }
    
    /// Joins the chapter files into a single gapless `.m4b` file with `chpl` atoms.
    /// This requires an AVAssetExportSession full re-encode (7b).
    func exportM4B(for bookID: String, bookTitle: String, cacheDirectory: URL, outputURL: URL) async throws {
        let chapterFiles = try await exportChapterFiles(for: bookID, cacheDirectory: cacheDirectory)
        guard !chapterFiles.isEmpty else { throw ExportError.missingAudiobook }
        
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.compositionFailed
        }
        
        var currentPosition = CMTime.zero
        var chapters: [ChapterAtom] = []
        
        for (index, fileURL) in chapterFiles.enumerated() {
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            
            // Add chapter metadata
            let chapterName = "Chapter \(index + 1)" // In a real app we'd fetch actual title
            chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: chapterName))
            
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try audioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentPosition)
            
            currentPosition = CMTimeAdd(currentPosition, duration)
        }
        
        // Export to M4A first
        let tempM4A = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.exportSessionFailed
        }
        exportSession.outputURL = tempM4A
        exportSession.outputFileType = .m4a
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ExportError.exportSessionFailed
        }
        
        // Inject chapters to make it an M4B
        let marker = AudioMarker()
        do {
            try marker.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
            // Cleanup temp
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }
    }
}
