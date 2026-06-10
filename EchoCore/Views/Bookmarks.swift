import SwiftUI
import AVFoundation
import Observation
import os.log
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Voice Memo Gain Normalization

func peakAmplitude(of url: URL) -> Float? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let totalFrames = AVAudioFrameCount(file.length)
    guard totalFrames > 0 else { return nil }

    let chunkSize: AVAudioFrameCount = 8192
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else { return nil }

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

// MARK: - Bookmark Model
//
// A Bookmark represents a saved moment in a particular audiobook. It can be
// associated with a folder (multi-track audiobook) and/or a specific track.
// Each bookmark may carry an optional text note and/or an optional voice
// memo (stored locally in the app's Documents/VoiceMemos directory).
//
// NOTE on Info.plist:
// To record voice memos on iOS, your Info.plist must contain:
//   NSMicrophoneUsageDescription = "Echo records short voice memos so you can attach narrated notes to your audiobook bookmarks."
//
struct Bookmark: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// User-editable title displayed in the playlist (e.g. "Bookmark 1").
    var title: String
    /// The owning folder/book key (e.g. folderURL.absoluteString). Optional so
    /// per-track-only bookmarks remain valid for single-file audiobooks.
    var folderKey: String?
    /// The specific track id (Track.id == url.absoluteString). May be nil for
    /// folder-wide bookmarks.
    var trackId: String?
    /// Position in the track (in seconds).
    var timestamp: TimeInterval
    /// Optional note text.
    var note: String?
    /// Filename (not full URL). Resolved relative to the audiobook folder when
    /// available; falls back to the legacy Documents/VoiceMemos directory.
    var voiceMemoFileName: String?
    /// Filename (not full URL) for a picture bookmark image stored on disk.
    var bookmarkImageFileName: String?
    /// The saved state of the PDF view when this bookmark was created.
    var pdfViewState: PDFViewState?
    /// Whether this bookmark is active. Disabled bookmarks are ignored by the
    /// voice-memo trigger, but remain visible (grayed out) in the playlist.
    var isEnabled: Bool = true

    init(
        id: UUID = UUID(),
        title: String = "Bookmark",
        folderKey: String? = nil,
        trackId: String? = nil,
        timestamp: TimeInterval,
        note: String? = nil,
        voiceMemoFileName: String? = nil,
        bookmarkImageFileName: String? = nil,
        pdfViewState: PDFViewState? = nil,
        isEnabled: Bool = true
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
    }

    /// Backward-compat decoder so older Bookmarks (without `title`) still load.
    enum CodingKeys: String, CodingKey {
        case id, title, folderKey, trackId, timestamp, note, voiceMemoFileName, bookmarkImageFileName, pdfViewState, isEnabled
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
    }


    /// Resolves the on-disk URL for the attached voice memo, preferring the
    /// audiobook's folder, falling back to the legacy Documents/VoiceMemos.
    func voiceMemoURL(in folderURL: URL?) -> URL? {
        guard let name = voiceMemoFileName, !name.isEmpty else { return nil }
        if let folderURL {
            // If folderURL is a file (single .m4b), use its parent directory.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            let candidate = baseDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let legacy = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        // Return the folder-based candidate even if it doesn't exist yet (so callers
        // can write to it). If no folder is known, fall back to legacy.
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

    /// Resolves the on-disk URL for the attached picture bookmark image,
    /// preferring the audiobook folder and falling back to Documents/BookmarkImages.
    func bookmarkImageURL(in folderURL: URL?) -> URL? {
        guard let name = bookmarkImageFileName, !name.isEmpty else { return nil }
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            let candidate = baseDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let legacy = Bookmark.legacyBookmarkImageDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
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
            if let note = bookmark.note {
                output += "\(note)\n\n"
            }
            if let memo = bookmark.voiceMemoFileName {
                output += "- [Voice Memo](\(memo))\n"
            }
            output += "[Play in App](echoaudio://play?time=\(bookmark.timestamp))\n\n"
        }
        return output
    }

    /// Resolves the on-disk URL for the `[BookName].json` bookmark sidecar
    /// associated with an audiobook.
    ///
    /// - If `folderURL` is a directory (multi-track audiobook), the sidecar
    ///   lives **inside** that folder using the folder's name.
    /// - If `folderURL` is a single audio file (`.m4b`, etc.), the sidecar
    ///   lives **next to** the file using the file's basename.
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
        id: UUID = UUID(),
        title: String,
        folderKey: String?,
        trackId: String?,
        timestamp: TimeInterval,
        pdfViewState: PDFViewState? = nil
    ) {
        self.id = id
        self.title = title
        self.folderKey = folderKey
        self.trackId = trackId
        self.timestamp = timestamp
        self.pdfViewState = pdfViewState
    }
}

// MARK: - Voice Memo Recorder

@Observable
final class VoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording: Bool = false
    private(set) var lastFileName: String?
    private var recorder: AVAudioRecorder?
    private(set) var elapsed: TimeInterval = 0
    private var timer: Timer?

    /// Tracks the security-scoped folder we opened for writing, so we can release it.
    private var scopedFolderURL: URL?

    /// Start recording. The memo is written next to the audiobook (`folderURL`)
    /// when possible; otherwise it falls back to Documents/VoiceMemos.
    func startRecording(in folderURL: URL?) throws {
        let session = AVAudioSession.sharedInstance()
        // Use playAndRecord so microphone + speaker routing are configured for memo capture.
        var options: AVAudioSession.CategoryOptions = []
        #if !os(watchOS)
        options = [.defaultToSpeaker, .allowBluetoothHFP]
        #endif
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)

        let fileName = "memo-\(UUID().uuidString).m4a"
        let url = Self.recordingURL(forFileName: fileName, in: folderURL, scopedURLOut: &scopedFolderURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        r.prepareToRecord()
        r.record()
        recorder = r
        isRecording = true
        lastFileName = fileName
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder, r.isRecording else { return }
            self.elapsed = r.currentTime
        }
    }

    @discardableResult
    func stopRecording() -> String? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        // Restore audiobook session category.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        if let scoped = scopedFolderURL {
            scoped.stopAccessingSecurityScopedResource()
            scopedFolderURL = nil
        }
        return lastFileName
    }

    func discard(in folderURL: URL?) {
        if let name = lastFileName {
            // Try the audiobook folder first, then the legacy directory.
            if let folderURL {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
                let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: baseDir.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(name))
        }
        lastFileName = nil
        elapsed = 0
    }

    /// Build the recording URL — preferring the audiobook folder (with
    /// security scope), falling back to Documents/VoiceMemos if the folder
    /// is not writable or no folder is provided.
    private static func recordingURL(
        forFileName fileName: String,
        in folderURL: URL?,
        scopedURLOut: inout URL?
    ) -> URL {
        if let folderURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            let baseDir = isDir.boolValue ? folderURL : folderURL.deletingLastPathComponent()
            // Try to acquire security-scoped access for writing.
            let didStart = baseDir.startAccessingSecurityScopedResource()
            if didStart { scopedURLOut = baseDir }
            // Confirm we can write here by checking the parent directory.
            if FileManager.default.isWritableFile(atPath: baseDir.path) {
                return baseDir.appendingPathComponent(fileName)
            }
            // Not writable — release scope and fall through.
            if didStart {
                baseDir.stopAccessingSecurityScopedResource()
                scopedURLOut = nil
            }
        }
        return Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(fileName)
    }
}

// MARK: - Edit Bookmark Sheet

#if !os(watchOS)
struct EditBookmarkView: View {
    @Environment(PlayerModel.self) private var model
    /// The id of the bookmark being edited.
    let bookmarkID: UUID?
    let draft: BookmarkDraft?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var note: String = ""
    @State private var timestamp: TimeInterval = 0
    @State private var voiceMemoFileName: String?
    @State private var bookmarkImageFileName: String?
    #if canImport(PhotosUI)
    @State private var selectedImageItem: PhotosPickerItem?
    #endif

    @State private var recorder = VoiceMemoRecorder()
    @State private var previewPlayer: SnippetPlayer? = nil
    @State private var isPreviewPlaying: Bool = false
    /// Tracks whether the main audiobook player was playing when we started
    /// the voice memo preview, so we can optionally resume it afterwards.
    @State private var didPauseMainPlayerForPreview: Bool = false
    @State private var alertMessage: String = ""
    @State private var isShowingAlert: Bool = false
    private let logger = Logger(category: "EditBookmark")

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Bookmark title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
                Section("Time") {
                    HStack {
                        Button {
                            timestamp = max(0, timestamp - 1)
                        } label: {
                            Label("-1s", systemImage: "minus.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)

                        Spacer()

                        Text(NowPlayingController.formatTime(timestamp))
                            .font(.system(.title3, design: .monospaced))
                            .frame(maxWidth: .infinity)

                        Spacer()

                        Button {
                            timestamp += 1
                        } label: {
                            Label("+1s", systemImage: "plus.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                    }
                }

                Section("Note") {
                    TextField("Add a note…", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Picture Bookmark") {
                    if let name = bookmarkImageFileName {
                        HStack {
                            Image(systemName: "photo")
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                removeBookmarkImage(named: name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete image")
                        .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Text("Remove picture bookmark image"))
                        }
                    }

                    #if canImport(PhotosUI)
                    PhotosPicker(selection: $selectedImageItem, matching: .images) {
                        Label(bookmarkImageFileName == nil ? String(localized: "Attach Image") : String(localized: "Replace Image"), systemImage: "photo.badge.plus")
                    }
                    #else
                    Text("Image selection is unavailable on this platform.")
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("Voice Memo") {
                    if let name = voiceMemoFileName {
                        HStack {
                            Image(systemName: "waveform")
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                togglePreview(fileName: name)
                            } label: {
                                Image(systemName: isPreviewPlaying ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isPreviewPlaying ? "Stop preview" : "Preview voice memo")
                            Button(role: .destructive) {
                                stopPreview()
                                let probe = Bookmark(timestamp: 0, voiceMemoFileName: name)
                                if let url = probe.voiceMemoURL(in: model.folderURL) {
                                    try? FileManager.default.removeItem(at: url)
                                }
                                voiceMemoFileName = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete voice memo")
                        }
                    } else {
                        if recorder.isRecording {
                            HStack {
                                Image(systemName: "record.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Recording… \(String(format: "%.1fs", recorder.elapsed))")
                                Spacer()
                                Button("Stop") {
                                    saveVoiceMemo()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button {
                                startVoiceMemoRecording()
                            } label: {
                                Label("Record Voice Memo", systemImage: "mic.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        if recorder.isRecording { _ = recorder.stopRecording() }
                        stopPreview()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveBookmark()
                    }
                    .bold()
                }
            }
            .alert("Bookmark Not Saved", isPresented: $isShowingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onAppear(perform: loadFromModel)
            #if canImport(PhotosUI)
            .onChange(of: selectedImageItem) { _, newItem in
                guard let newItem else { return }
                Task { await importBookmarkImage(from: newItem) }
            }
            #endif
            .onDisappear {
                if recorder.isRecording { _ = recorder.stopRecording() }
                stopPreview()
            }
        }
    }

    private func loadFromModel() {
        if let bookmarkID,
           let bm = model.bookmarks.first(where: { $0.id == bookmarkID }) {
            title = bm.title
            note = bm.note ?? ""
            timestamp = bm.timestamp
            voiceMemoFileName = bm.voiceMemoFileName
            bookmarkImageFileName = bm.bookmarkImageFileName
            return
        }

        guard let draft else { return }
        title = draft.title
        note = ""
        timestamp = draft.timestamp
        voiceMemoFileName = nil
        bookmarkImageFileName = nil
    }

    private func startVoiceMemoRecording() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showAlert("Microphone access is denied. Enable microphone access for Echo in Settings.")
        case .undetermined:
            Task {
                let isGranted = await AVAudioApplication.requestRecordPermission()
                isGranted ? beginRecording() : showAlert("Microphone access is required to record a voice memo.")
            }
        @unknown default:
            showAlert("Microphone access is unavailable.")
        }
    }

    private func beginRecording() {
        // Pause the main audiobook before we hijack the audio session.
        model.pause()
        do {
            try recorder.startRecording(in: model.folderURL)
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func saveVoiceMemo() {
        guard let name = recorder.stopRecording() else {
            showAlert("No recording was captured.")
            return
        }

        let probe = Bookmark(timestamp: timestamp, voiceMemoFileName: name)
        guard probe.voiceMemoURL(in: model.folderURL) != nil else {
            showAlert("The voice memo could not be saved.")
            return
        }

        voiceMemoFileName = name
        saveBookmark()
    }

    private func saveBookmark() {
        if recorder.isRecording {
            saveVoiceMemo()
            return
        }

        stopPreview()
        let savedTitle = title.isEmpty ? "Bookmark" : title
        let savedNote = note.isEmpty ? nil : note

        if let bookmarkID {
            model.updateBookmark(
                id: bookmarkID,
                title: savedTitle,
                timestamp: timestamp,
                note: savedNote,
                voiceMemoFileName: voiceMemoFileName,
                bookmarkImageFileName: bookmarkImageFileName
            )
        } else if let draft {
            model.appendBookmark(
                from: draft,
                title: savedTitle,
                timestamp: timestamp,
                note: savedNote,
                voiceMemoFileName: voiceMemoFileName,
                bookmarkImageFileName: bookmarkImageFileName
            )
        } else {
            showAlert("The bookmark could not be saved.")
            return
        }
        dismiss()
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        isShowingAlert = true
    }

    #if canImport(PhotosUI) && canImport(UIKit)
    private func importBookmarkImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                await MainActor.run { showAlert("The selected image could not be loaded.") }
                return
            }

            let fileName = "bookmark-\(imageBookmarkID.uuidString).jpg"
            let probe = Bookmark(timestamp: timestamp, bookmarkImageFileName: fileName)
            guard let url = probe.bookmarkImageURL(in: model.folderURL) else {
                await MainActor.run { showAlert("The image could not be saved.") }
                return
            }

            let didStart = url.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.deletingLastPathComponent().stopAccessingSecurityScopedResource()
                }
            }

            let jpegData = resizedJPEGData(from: image, maxDimension: ImageEncoding.bookmarkMaxDimension, compressionQuality: ImageEncoding.bookmarkJPEGQuality)
            try jpegData.write(to: url, options: .atomic)
            await MainActor.run {
                bookmarkImageFileName = fileName
            }
        } catch {
            await MainActor.run {
                showAlert(error.localizedDescription)
            }
        }
    }

    private var imageBookmarkID: UUID {
        bookmarkID ?? draft?.id ?? UUID()
    }

    private func resizedJPEGData(from image: UIImage, maxDimension: CGFloat, compressionQuality: CGFloat) -> Data {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else {
            return image.jpegData(compressionQuality: compressionQuality) ?? Data()
        }

        let scale = maxDimension / longestSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: compressionQuality) ?? Data()
    }
    #endif

    private func removeBookmarkImage(named name: String) {
        let probe = Bookmark(timestamp: timestamp, bookmarkImageFileName: name)
        if let url = probe.bookmarkImageURL(in: model.folderURL) {
            try? FileManager.default.removeItem(at: url)
        }
        bookmarkImageFileName = nil
    }

    private func togglePreview(fileName: String) {
        if isPreviewPlaying {
            stopPreview()
            return
        }
        let probe = Bookmark(timestamp: 0, voiceMemoFileName: fileName)
        guard let url = probe.voiceMemoURL(in: model.folderURL) else { return }

        // Enforce mutually-exclusive audio streams: pause the main audiobook
        // before starting the voice-memo preview so we never have two
        // concurrent streams playing through the output.
        if model.isPlaying {
            model.pause()
            didPauseMainPlayerForPreview = true
        } else {
            didPauseMainPlayerForPreview = false
        }

        previewPlayer = SnippetPlayer()
        previewPlayer?.play(url: url, volume: voiceMemoGain(for: url)) {
            stopPreview()
        }
        isPreviewPlaying = true
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false

        // Restore the shared audio session category for spoken audiobook
        // playback (the preview engine may have nudged the category) without
        // deactivating the session — that would be the hack we want to avoid.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])

        // Optionally resume the main audiobook if we were the ones who paused
        // it when starting the preview.
        if didPauseMainPlayerForPreview {
            didPauseMainPlayerForPreview = false
            model.play()
        }
    }

}
#endif
