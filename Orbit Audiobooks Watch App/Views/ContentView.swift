import SwiftUI
import AVFoundation
import WatchConnectivity
import WatchKit
import Observation
import WidgetKit

// MARK: - WatchAction

enum WatchAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case loopMode
    case speed
    case sleepTimer
    case bookmark
    case empty

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .playPause:     return "playpause.fill"
        case .skipForward:   return "goforward.30"
        case .skipBackward:  return "gobackward.30"
        case .nextTrack:     return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .loopMode:      return "infinity"
        case .speed:         return "gauge.medium"
        case .sleepTimer:    return "moon.zzz.fill"
        case .bookmark:      return "bookmark.fill"
        case .empty:         return "plus"
        }
    }

    var command: String {
        switch self {
        case .playPause:     return "toggle"
        case .skipForward:   return "skipForward"
        case .skipBackward:  return "skipBackward"
        case .nextTrack:     return "next"
        case .previousTrack: return "previous"
        case .loopMode:      return "cycleLoopMode"
        case .speed:         return "cycleSpeed"
        case .sleepTimer:    return "toggleSleepTimer"
        case .bookmark:      return "addBookmark"
        case .empty:         return ""
        }
    }
}

// MARK: - View Model

@Observable
class WatchViewModel: NSObject, WCSessionDelegate {
    var isPlaying: Bool = false
    var title: String = "No track selected"
    var thumbnailImage: UIImage? = nil
    var progressFraction: Double = 0.0
    var loopMode: String = "off"
    var bookmarkStorageKey: String? = nil
    var folderKey: String? = nil
    var trackId: String? = nil
    var currentTime: Double = 0

    var page1Slots: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
    var page2Slots: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]

    private let defaults = UserDefaults(suiteName: "group.com.orbitaudiobooks")

    override init() {
        super.init()
        loadPersistedState()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    private func loadPersistedState() {
        isPlaying = defaults?.bool(forKey: "isPlaying") ?? false
        title = defaults?.string(forKey: "title") ?? "No track selected"
        progressFraction = defaults?.double(forKey: "progressFraction") ?? 0.0
        loopMode = defaults?.string(forKey: "loopMode") ?? "off"
        currentTime = defaults?.double(forKey: "currentTime") ?? 0
        bookmarkStorageKey = defaults?.string(forKey: "bookmarkStorageKey")
        folderKey = defaults?.string(forKey: "folderKey")
        trackId = defaults?.string(forKey: "trackId")

        if let thumbnailData = defaults?.data(forKey: "thumbnailData"),
           let image = UIImage(data: thumbnailData) {
            thumbnailImage = image
        }

        if let raw = defaults?.string(forKey: "watchPage1") {
            page1Slots = padded(parseSlots(raw))
        }
        if let raw = defaults?.string(forKey: "watchPage2") {
            page2Slots = padded(parseSlots(raw))
        }
    }

    private func parseSlots(_ raw: String) -> [WatchAction] {
        raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
    }

    private func padded(_ slots: [WatchAction]) -> [WatchAction] {
        var s = slots
        while s.count < 5 { s.append(.empty) }
        return Array(s.prefix(5))
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        applyState(session.receivedApplicationContext)
        requestCurrentState()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        requestCurrentState()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        applyState(applicationContext)
    }

    private func applyState(_ state: [String: Any]) {
        guard !state.isEmpty else { return }
        DispatchQueue.main.async {
            if let crownAction = state["crownAction"] as? String {
                self.defaults?.set(crownAction, forKey: "crownAction")
            }
            if let isPlaying = state["isPlaying"] as? Bool {
                self.isPlaying = isPlaying
                self.defaults?.set(isPlaying, forKey: "isPlaying")
            }
            if let title = state["title"] as? String {
                self.title = title
                self.defaults?.set(title, forKey: "title")
            }
            if let progressFraction = state["progressFraction"] as? Double {
                self.progressFraction = progressFraction
                self.defaults?.set(progressFraction, forKey: "progressFraction")
            }
            if let currentTime = state["currentTime"] as? Double {
                self.currentTime = currentTime
                self.defaults?.set(currentTime, forKey: "currentTime")
            }
            if let bookmarkStorageKey = state["bookmarkStorageKey"] as? String {
                self.bookmarkStorageKey = bookmarkStorageKey
                self.defaults?.set(bookmarkStorageKey, forKey: "bookmarkStorageKey")
            }
            if let folderKey = state["folderKey"] as? String {
                self.folderKey = folderKey
                self.defaults?.set(folderKey, forKey: "folderKey")
            }
            if let trackId = state["trackId"] as? String {
                self.trackId = trackId
                self.defaults?.set(trackId, forKey: "trackId")
            }
            if let loopMode = state["loopMode"] as? String {
                self.loopMode = loopMode
                self.defaults?.set(loopMode, forKey: "loopMode")
            }
            if let watchPage1 = state["watchPage1"] as? String {
                self.page1Slots = self.padded(self.parseSlots(watchPage1))
                self.defaults?.set(watchPage1, forKey: "watchPage1")
            }
            if let watchPage2 = state["watchPage2"] as? String {
                self.page2Slots = self.padded(self.parseSlots(watchPage2))
                self.defaults?.set(watchPage2, forKey: "watchPage2")
            }
            if let thumbnailData = state["thumbnailData"] as? Data {
                self.defaults?.set(thumbnailData, forKey: "thumbnailData")
                if let image = UIImage(data: thumbnailData) {
                    self.thumbnailImage = image
                }
            } else if let hasThumbnail = state["hasThumbnail"] as? Bool, !hasThumbnail {
                self.defaults?.removeObject(forKey: "thumbnailData")
                self.thumbnailImage = nil
            }
            if state["commandResult"] as? String == "bookmarkJump" {
                WKInterfaceDevice.current().play(.success)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func requestCurrentState() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        if session.activationState == .activated {
            applyState(session.receivedApplicationContext)
        }

        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["command": "requestState"], replyHandler: { [weak self] reply in
            self?.applyState(reply)
        }, errorHandler: { error in
            print("Error requesting state: \(error)")
        })
    }

    private static func isDirectionalCommand(_ command: String) -> Bool {
        command == "next" || command == "previous" || command == "skipForward" || command == "skipBackward"
    }

    private static func isForwardCommand(_ command: String) -> Bool {
        command == "next" || command == "skipForward"
    }

    @discardableResult
    func sendCommand(_ command: String, params: [String: Any]? = nil) -> Bool {
        guard !command.isEmpty else { return false }
        let session = WCSession.default
        if session.activationState == .activated {
            applyState(session.receivedApplicationContext)
        }

        var didSend = false
        if session.activationState == .activated, session.isReachable {
            var message: [String: Any] = ["command": command]
            if let params = params {
                for (key, value) in params {
                    message[key] = value
                }
            }
            session.sendMessage(message, replyHandler: { [weak self] reply in
                self?.applyState(reply)
                if Self.isDirectionalCommand(command),
                   self?.loopMode == "bookmark",
                   reply["commandResult"] as? String != "bookmarkJump" {
                    WKInterfaceDevice.current().play(Self.isForwardCommand(command) ? .directionUp : .directionDown)
                }
            }, errorHandler: { [weak self] error in
                print("Error sending command: \(error)")
                self?.requestCurrentState()
            })
            didSend = true
        }

        guard didSend else {
            requestCurrentState()
            return false
        }

        if loopMode == "bookmark" && Self.isDirectionalCommand(command) {
            return true
        }

        switch command {
        case "play", "pause", "toggle":
            WKInterfaceDevice.current().play(.click)
        case "next", "skipForward":
            WKInterfaceDevice.current().play(.directionUp)
        case "skipBackward", "previous":
            WKInterfaceDevice.current().play(.directionDown)
        default:
            WKInterfaceDevice.current().play(.click)
        }

        return true
    }

    /// Trigger the action for a tapped slot, with local state echoes for
    /// playPause / loopMode so the UI feels instant.
    func handle(_ action: WatchAction) {
        switch action {
        case .empty:
            return
        case .playPause:
            if sendCommand(isPlaying ? "pause" : "play") {
                isPlaying.toggle()
            }
        case .loopMode:
            sendCommand("cycleLoopMode")
        default:
            sendCommand(action.command)
        }
    }

    func queueTextBookmark(note: String) throws {
        var payload = try bookmarkPayload(command: "addWatchTextBookmark")
        payload["note"] = note
        WCSession.default.transferUserInfo(payload)
        WKInterfaceDevice.current().play(.success)
    }

    func queueVoiceBookmark(fileURL: URL) async throws {
        var metadata = try bookmarkPayload(command: "addWatchVoiceBookmark")
        metadata["voiceMemoFileName"] = fileURL.lastPathComponent
        metadata["voiceMemoData"] = try await Task.detached {
            try Data(contentsOf: fileURL)
        }.value

        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(metadata, replyHandler: nil) { error in
                print("Immediate voice bookmark send failed: \(error)")
                WCSession.default.transferUserInfo(metadata)
            }
        } else {
            session.transferUserInfo(metadata)
        }
        WKInterfaceDevice.current().play(.success)
    }

    private func bookmarkPayload(command: String) throws -> [String: Any] {
        guard WCSession.isSupported() else {
            throw WatchBookmarkError.watchConnectivityUnavailable
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            throw WatchBookmarkError.watchConnectivityInactive
        }

        guard let bookmarkStorageKey else {
            throw WatchBookmarkError.noActiveBook
        }

        var payload: [String: Any] = [
            "command": command,
            "bookmarkID": UUID().uuidString,
            "bookmarkStorageKey": bookmarkStorageKey,
            "timestamp": max(0, currentTime),
            "createdAt": Date().timeIntervalSince1970
        ]

        if let folderKey {
            payload["folderKey"] = folderKey
        }
        if let trackId {
            payload["trackId"] = trackId
        }

        return payload
    }
}

private enum WatchBookmarkError: LocalizedError {
    case watchConnectivityUnavailable
    case watchConnectivityInactive
    case noActiveBook

    var errorDescription: String? {
        switch self {
        case .watchConnectivityUnavailable:
            return "Watch sync is not available on this device."
        case .watchConnectivityInactive:
            return "Watch sync is still starting. Try again in a moment."
        case .noActiveBook:
            return "Start playback on iPhone before creating a bookmark."
        }
    }
}

// MARK: - Watch Voice Memo Recorder

@Observable
final class WatchVoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 30

    private(set) var isRecording: Bool = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var recordingURL: URL?

    func startRecording() throws {
        let directory = try Self.recordingsDirectory()
        let fileURL = directory.appendingPathComponent("watch-memo-\(UUID().uuidString).m4a")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.prepareToRecord()
        audioRecorder.record(forDuration: Self.maximumDuration)

        recorder = audioRecorder
        recordingURL = fileURL
        elapsed = 0
        isRecording = true
        startTimer()
    }

    @discardableResult
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordingURL
    }

    func discardRecording() {
        if isRecording {
            _ = stopRecording()
        }
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        elapsed = 0
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = min(recorder.currentTime, Self.maximumDuration)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            self.elapsed = min(recorder.currentTime, Self.maximumDuration)
            if self.elapsed >= Self.maximumDuration {
                _ = self.stopRecording()
            }
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchVoiceMemos", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}

// MARK: - Accessibility Helper

private struct ToggleTraitModifier: ViewModifier {
    let isToggle: Bool
    let value: String?

    func body(content: Content) -> some View {
        if isToggle {
            content
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(value ?? "")
        } else {
            content
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = WatchViewModel()
    @AppStorage("crownAction", store: UserDefaults(suiteName: "group.com.orbitaudiobooks")) private var crownAction = "volume"
    @State private var crownAccumulator: Double = 0.0
    @State private var selectedPage: Int = 0
    @State private var isShowingNewBookmark = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Blurred background derived from the artwork (preserved from blueprint)
            if let image = viewModel.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.6))
            } else {
                Color.black.ignoresSafeArea()
            }

            TabView(selection: $selectedPage) {
                PlayerPage(slots: viewModel.page1Slots, viewModel: viewModel) {
                    isShowingNewBookmark = true
                }
                    .tag(0)
                PlayerPage(slots: viewModel.page2Slots, viewModel: viewModel) {
                    isShowingNewBookmark = true
                }
                    .tag(1)
            }
            .tabViewStyle(.page)
        }
        .focusable()
        .digitalCrownRotation($crownAccumulator)
        .focused($isFocused)
        .sheet(isPresented: $isShowingNewBookmark) {
            NewBookmarkView(viewModel: viewModel)
        }
        .onChange(of: crownAccumulator) { oldValue, newValue in
            let delta = newValue - oldValue
            if crownAction == "scrub" {
                viewModel.sendCommand("scrubDelta", params: ["delta": delta])
            } else {
                viewModel.sendCommand("volumeDelta", params: ["delta": delta])
            }
        }
        .onAppear {
            isFocused = true
            viewModel.requestCurrentState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            isFocused = true
            viewModel.requestCurrentState()
        }
        .onChange(of: crownAction) { _, _ in isFocused = true }
    }
}

// MARK: - Player Page (per-page layout matching the blueprint)
//
// Layout invariants (from the blueprint / "Source of Truth"):
//   • Artwork is centered horizontally, ~80×80, rounded.
//   • The chapter / track title sits directly under the artwork with its own
//     horizontal padding — NOTHING is allowed to overlap it.
//   • Top-left / top-right slot buttons are anchored to the very top of the
//     screen (in line with the system clock area), which guarantees clear
//     breathing room between them and the title below the artwork.
//   • The 3-button transport row sits at the bottom with the large play
//     control (with progress ring) in the middle.

private struct PlayerPage: View {
    let slots: [WatchAction]
    let viewModel: WatchViewModel
    let onBookmark: () -> Void

    var body: some View {
        ZStack {
            // Main vertical content (artwork + title + transport row)
            VStack(spacing: 12) {
                if let image = viewModel.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title)
                                .foregroundColor(.white)
                        )
                }

                Text(viewModel.title)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal)

                TransportRow(
                    leftSlot: slots[2],
                    centerSlot: slots[3],
                    rightSlot: slots[4],
                    viewModel: viewModel,
                    onBookmark: onBookmark
                )
                .padding(.top, 6)
            }

            // Top-row slots (anchored to the top — well above the title).
            VStack {
                HStack {
                    TopSlotButton(action: slots[0], viewModel: viewModel, onBookmark: onBookmark)
                        .padding(.leading, 8)
                    Spacer()
                    TopSlotButton(action: slots[1], viewModel: viewModel, onBookmark: onBookmark)
                        .padding(.trailing, 8)
                }
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}

// MARK: - Top slot button (small, top-row chrome)

private struct TopSlotButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void

    var body: some View {
        if action == .empty {
            EmptyView()
        } else {
            Button {
                if action == .bookmark {
                    onBookmark()
                } else {
                    viewModel.handle(action)
                }
            } label: {
                if action == .loopMode && viewModel.loopMode == "bookmark" {
                    ZStack {
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.system(size: 24))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabelText)
            .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? loopModeAccessibilityValue : nil))
        }
    }

    private var loopModeAccessibilityValue: String {
        switch viewModel.loopMode {
        case "chapter": return "Chapter"
        case "bookmark": return "Bookmark"
        default: return "Off"
        }
    }

    private var iconName: String {
        if action == .loopMode {
            switch viewModel.loopMode {
            case "chapter": return "infinity.circle.fill"
            case "bookmark": return "arrow.trianglehead.clockwise"
            default: return "infinity.circle"
            }
        }
        return action.iconName
    }

    private var accessibilityLabelText: String {
        switch action {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward 30 seconds"
        case .skipBackward: return "Skip back 30 seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return ""
        }
    }
}

// MARK: - Bottom transport row (left button | play+ring | right button)

private struct TransportRow: View {
    let leftSlot: WatchAction
    let centerSlot: WatchAction
    let rightSlot: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            SideTransportButton(action: leftSlot, viewModel: viewModel, onBookmark: onBookmark)

            CenterTransportButton(action: centerSlot, viewModel: viewModel, onBookmark: onBookmark)

            SideTransportButton(action: rightSlot, viewModel: viewModel, onBookmark: onBookmark)
        }
    }
}

private struct SideTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void

    var body: some View {
        Button {
            if action == .bookmark {
                onBookmark()
            } else {
                viewModel.handle(action)
            }
        } label: {
            Group {
                if action == .loopMode && viewModel.loopMode == "bookmark" {
                    ZStack {
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.system(size: 20))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                } else {
                    Image(systemName: sideIconName)
                        .font(.system(size: 20))
                }
            }
            .frame(width: 38, height: 38)
            .padding(15)
            .contentShape(Rectangle())
            .opacity(action == .empty ? 0.35 : 1.0)
        }
        .buttonStyle(.borderedProminent)
        .disabled(action == .empty)
        .accessibilityLabel(accessibilityLabelText)
        .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? loopModeAccessibilityValue : nil))
    }

    private var sideIconName: String {
        if action == .loopMode {
            switch viewModel.loopMode {
            case "chapter": return "infinity.circle.fill"
            case "bookmark": return "arrow.trianglehead.clockwise"
            default: return "infinity.circle"
            }
        }
        return action == .empty ? "plus" : action.iconName
    }

    private var loopModeAccessibilityValue: String {
        switch viewModel.loopMode {
        case "chapter": return "Chapter"
        case "bookmark": return "Bookmark"
        default: return "Off"
        }
    }

    private var accessibilityLabelText: String {
        switch action {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward 30 seconds"
        case .skipBackward: return "Skip back 30 seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return "Empty slot"
        }
    }
}

private struct CenterTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 4)
                .frame(width: 52, height: 52)

            Circle()
                .trim(from: 0, to: viewModel.progressFraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 52, height: 52)
                .rotationEffect(.degrees(-90))

            Button {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else {
                    viewModel.handle(resolvedAction)
                }
            } label: {
                Image(systemName: centerIconName)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(resolvedAction == .playPause ? (viewModel.isPlaying ? "Pause" : "Play") : resolvedAction.iconName)

            // Hidden helper for the double-tap primary-action shortcut.
            Button("") {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else {
                    viewModel.handle(resolvedAction)
                }
            }
            .opacity(0)
            .handGestureShortcut(.primaryAction)
        }
    }

    /// If the designer left the center slot empty, keep the play/pause control
    /// (the blueprint's hero element) so the UI is never broken.
    private var resolvedAction: WatchAction {
        action == .empty ? .playPause : action
    }

    private var centerIconName: String {
        switch resolvedAction {
        case .playPause:
            return viewModel.isPlaying ? "pause.fill" : "play.fill"
        default:
            return resolvedAction.iconName
        }
    }
}

// MARK: - New Bookmark

private struct NewBookmarkView: View {
    let viewModel: WatchViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = WatchVoiceMemoRecorder()
    @State private var alertMessage = ""
    @State private var isShowingAlert = false

    private var recordingProgress: Double {
        min(recorder.elapsed / WatchVoiceMemoRecorder.maximumDuration, 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: recordingProgress)
                        .stroke(.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                Text(recordingDurationText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    recorder.isRecording ? saveVoiceMemo() : startVoiceBookmark()
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(recorder.isRecording ? .red : .accentColor)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("New Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        recorder.discardRecording()
                        dismiss()
                    }
                }
            }
            .alert("Bookmark Not Saved", isPresented: $isShowingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onChange(of: recorder.isRecording) { oldValue, newValue in
                if oldValue, !newValue, recorder.elapsed >= WatchVoiceMemoRecorder.maximumDuration {
                    saveVoiceMemo()
                }
            }
            .onDisappear {
                if recorder.isRecording {
                    _ = recorder.stopRecording()
                }
            }
        }
    }

    private var recordingDurationText: String {
        "\(Int(recorder.elapsed.rounded(.down)))s / \(Int(WatchVoiceMemoRecorder.maximumDuration))s"
    }

    private func startVoiceBookmark() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showAlert("Microphone access is denied. Enable microphone access for Orbit Audiobooks in Settings.")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { isGranted in
                Task { @MainActor in
                    isGranted ? beginRecording() : showAlert("Microphone access is required to record a voice bookmark.")
                }
            }
        @unknown default:
            showAlert("Microphone access is unavailable.")
        }
    }

    private func beginRecording() {
        if viewModel.sendCommand("pause") {
            viewModel.isPlaying = false
        }

        do {
            try recorder.startRecording()
            WKInterfaceDevice.current().play(.start)
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func saveVoiceMemo() {
        guard let fileURL = recorder.stopRecording() else {
            showAlert("No recording was captured.")
            return
        }

        Task {
            do {
                try await viewModel.queueVoiceBookmark(fileURL: fileURL)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    recorder.discardRecording()
                    showAlert(error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        isShowingAlert = true
    }
}

#Preview {
    ContentView()
}
