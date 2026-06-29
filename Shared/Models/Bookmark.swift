// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

func peakAmplitude(of url: URL) -> Float? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let totalFrames = AVAudioFrameCount(file.length)
    guard totalFrames > 0 else { return nil }
    let chunkSize: AVAudioFrameCount = 8192
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
        return nil
    }
    var peak: Float = 0
    var framesRemaining = totalFrames
    while framesRemaining > 0 {
        let framesToRead = min(chunkSize, framesRemaining)
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: framesToRead) } catch { break }
        guard let channelData = buffer.floatChannelData else { break }
        for ch in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let s = abs(channelData[ch][frame])
                if s > peak { peak = s }
            }
        }
        framesRemaining -= buffer.frameLength
        if buffer.frameLength == 0 { break }
    }
    return peak > 0 ? peak : nil
}

func voiceMemoGain(for url: URL) -> Float {
    let targetPeak: Float = 0.9
    let maxGain: Float = 3.0
    guard let peak = peakAmplitude(of: url), peak > 0.001 else { return 1.0 }
    return min(targetPeak / peak, maxGain)
}

// `nonisolated`: a pure value model (no main-actor state — just value fields and
// file-path/string helpers). Under the iOS target's Swift 6 MainActor default
// isolation its init would otherwise be inferred `@MainActor`, which the GRDB
// record decode path (`BookmarkRecord.toModel()`, run on a nonisolated DB read)
// cannot call. Relaxing isolation is safe on every target.
nonisolated struct Bookmark: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var folderKey: String?
    var trackId: String?
    var timestamp: TimeInterval
    var note: String?
    var voiceMemoFileName: String?
    var bookmarkImageFileName: String?
    var pdfViewState: PDFViewState?
    var isEnabled: Bool = true
    var latitude: Double?
    var longitude: Double?
    var placeName: String?

    init(
        id: UUID = UUID(), title: String = "Bookmark", folderKey: String? = nil,
        trackId: String? = nil, timestamp: TimeInterval, note: String? = nil,
        voiceMemoFileName: String? = nil, bookmarkImageFileName: String? = nil,
        pdfViewState: PDFViewState? = nil, isEnabled: Bool = true,
        latitude: Double? = nil, longitude: Double? = nil, placeName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.folderKey = folderKey
        self.trackId = trackId
        self.timestamp = timestamp
        self.note = note
        self.voiceMemoFileName = voiceMemoFileName
        self.bookmarkImageFileName = bookmarkImageFileName
        self.pdfViewState = pdfViewState
        self.isEnabled = isEnabled
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
    }

    enum CodingKeys: String, CodingKey {
        case id, title, folderKey, trackId, timestamp, note
        case voiceMemoFileName, bookmarkImageFileName, pdfViewState, isEnabled
        case latitude, longitude, placeName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Bookmark"
        folderKey = try? c.decode(String.self, forKey: .folderKey)
        trackId = try? c.decode(String.self, forKey: .trackId)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        note = try? c.decode(String.self, forKey: .note)
        voiceMemoFileName = try? c.decode(String.self, forKey: .voiceMemoFileName)
        bookmarkImageFileName = try? c.decode(String.self, forKey: .bookmarkImageFileName)
        pdfViewState = try? c.decode(PDFViewState.self, forKey: .pdfViewState)
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        // The synthesized encoder writes these (they are in CodingKeys); the
        // hand-written decoder must read them too or located bookmarks lose
        // their coordinates on every JSON sidecar round-trip.
        latitude = try? c.decode(Double.self, forKey: .latitude)
        longitude = try? c.decode(Double.self, forKey: .longitude)
        placeName = try? c.decode(String.self, forKey: .placeName)
    }

    func voiceMemoURL(in folderURL: URL?) -> URL? {
        guard let name = voiceMemoFileName, !name.isEmpty else { return nil }
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            let candidate = baseDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let legacy = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            return baseDir.appendingPathComponent(name)
        }
        return legacy
    }

    static func legacyVoiceMemoDirectory() -> URL {
        let docs = URL.documentsDirectory
        let dir = docs.appendingPathComponent("VoiceMemos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func bookmarkImageURL(in folderURL: URL?) -> URL? {
        guard let name = bookmarkImageFileName, !name.isEmpty else { return nil }
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            let candidate = baseDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let legacy = Bookmark.legacyBookmarkImageDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            return baseDir.appendingPathComponent(name)
        }
        return legacy
    }

    static func legacyBookmarkImageDirectory() -> URL {
        let docs = URL.documentsDirectory
        let dir = docs.appendingPathComponent("BookmarkImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func markdownExport(for bookmarks: [Bookmark]) -> String {
        var output = "# Audiobook Bookmarks\n\n"
        for bookmark in bookmarks {
            let timestamp = Int(bookmark.timestamp)
            let mins = (timestamp % 3600) / 60
            let secs = timestamp % 60
            let timeString = String(format: "%02d:%02d", mins, secs)
            output += "## \(timeString)\n"
            if let note = bookmark.note { output += "\(note)\n\n" }
            if let memo = bookmark.voiceMemoFileName { output += "- [Voice Memo](\(memo))\n" }
            output += "[Play in App](echoaudio://play?time=\(bookmark.timestamp))\n\n"
        }
        return output
    }

    static func sidecarURL(for folderURL: URL) -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            let name = folderURL.lastPathComponent
            return folderURL.appendingPathComponent("\(name).json")
        } else {
            let baseName = folderURL.deletingPathExtension().lastPathComponent
            return folderURL.deletingLastPathComponent().appendingPathComponent("\(baseName).json")
        }
    }
}

struct BookmarkDraft: Identifiable, Hashable {
    let id: UUID
    let title: String
    let folderKey: String?
    let trackId: String?
    let timestamp: TimeInterval
    let pdfViewState: PDFViewState?

    init(
        id: UUID = UUID(), title: String, folderKey: String?, trackId: String?,
        timestamp: TimeInterval, pdfViewState: PDFViewState? = nil
    ) {
        self.id = id
        self.title = title
        self.folderKey = folderKey
        self.trackId = trackId
        self.timestamp = timestamp
        self.pdfViewState = pdfViewState
    }
}
