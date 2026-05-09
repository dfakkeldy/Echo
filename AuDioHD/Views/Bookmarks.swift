import SwiftUI
import AVFoundation
import Observation

// MARK: - Voice Memo Gain Normalization

func peakAmplitude(of url: URL) -> Float? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else { return nil }
    do { try file.read(into: buffer) } catch { return nil }
    guard let channelData = buffer.floatChannelData else { return nil }
    var peak: Float = 0
    for ch in 0..<Int(format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            let s = abs(channelData[ch][frame])
            if s > peak { peak = s }
        }
    }
    return peak
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
//   NSMicrophoneUsageDescription = "AuDioHD records short voice memos so you can attach narrated notes to your audiobook bookmarks."
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
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.folderKey = folderKey
        self.trackId = trackId
        self.timestamp = timestamp
        self.note = note
        self.voiceMemoFileName = voiceMemoFileName
        self.isEnabled = isEnabled
    }

    /// Backward-compat decoder so older Bookmarks (without `title`) still load.
    enum CodingKeys: String, CodingKey {
        case id, title, folderKey, trackId, timestamp, note, voiceMemoFileName, isEnabled
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceMemos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

struct BookmarkDraft: Identifiable, Hashable {
    let id: UUID
    let title: String
    let folderKey: String?
    let trackId: String?
    let timestamp: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        folderKey: String?,
        trackId: String?,
        timestamp: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.folderKey = folderKey
        self.trackId = trackId
        self.timestamp = timestamp
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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
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

struct EditBookmarkView: View {
    @Bindable var model: PlayerModel
    /// The id of the bookmark being edited.
    let bookmarkID: UUID?
    let draft: BookmarkDraft?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var note: String = ""
    @State private var timestamp: TimeInterval = 0
    @State private var voiceMemoFileName: String?

    @State private var recorder = VoiceMemoRecorder()
    @State private var previewEngine: AVAudioEngine?
    @State private var previewPlayerNode: AVAudioPlayerNode?
    @State private var isPreviewPlaying: Bool = false
    @State private var alertMessage: String = ""
    @State private var isShowingAlert: Bool = false

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

                        Spacer()

                        Text(formatHMS(timestamp))
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
                    }
                }

                Section("Note") {
                    TextField("Add a note…", text: $note, axis: .vertical)
                        .lineLimit(3...8)
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
            return
        }

        guard let draft else { return }
        title = draft.title
        note = ""
        timestamp = draft.timestamp
        voiceMemoFileName = nil
    }

    private func startVoiceMemoRecording() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showAlert("Microphone access is denied. Enable microphone access for AuDioHD in Settings.")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { isGranted in
                Task { @MainActor in
                    isGranted ? beginRecording() : showAlert("Microphone access is required to record a voice memo.")
                }
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
                voiceMemoFileName: voiceMemoFileName
            )
        } else if let draft {
            model.appendBookmark(
                from: draft,
                title: savedTitle,
                timestamp: timestamp,
                note: savedNote,
                voiceMemoFileName: voiceMemoFileName
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

    private func togglePreview(fileName: String) {
        if isPreviewPlaying {
            stopPreview()
            return
        }
        let probe = Bookmark(timestamp: 0, voiceMemoFileName: fileName)
        guard let url = probe.voiceMemoURL(in: model.folderURL) else { return }
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)
            engine.mainMixerNode.outputVolume = voiceMemoGain(for: url)
            try engine.start()

            playerNode.scheduleFile(audioFile, at: nil) { [self] in
                DispatchQueue.main.async { self.stopPreview() }
            }
            playerNode.play()

            previewEngine = engine
            previewPlayerNode = playerNode
            isPreviewPlaying = true
        } catch {
            print("Preview error: \(error)")
        }
    }

    private func stopPreview() {
        previewPlayerNode?.stop()
        previewEngine?.stop()
        previewPlayerNode = nil
        previewEngine = nil
        isPreviewPlaying = false
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
