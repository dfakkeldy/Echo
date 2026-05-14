import SwiftUI
import Observation
import UniformTypeIdentifiers
import UIKit
import ImageIO

// MARK: - Beginner notes (Xcode settings you MUST enable)
//
// In Xcode:
// 1) Select your project (blue icon) -> select the app target -> "Signing & Capabilities"
// 2) Click "+ Capability" -> add "Background Modes"
// 3) Check:
//    - "Audio, AirPlay, and Picture in Picture"
//    - (Optional) "Background fetch" (not required for basic audio playback, but you requested it)
//
// Also ensure you have a valid entitlement to play audio in background (Background Modes capability).

// MARK: - Loop Mode


// MARK: - Folder picker (Files app)

struct FolderPicker: UIViewControllerRepresentable {
    let onPickFolder: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let m4bType = UTType(filenameExtension: "m4b") ?? .audio
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, m4bType, .audio], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickFolder: onPickFolder)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickFolder: (URL) -> Void

        init(onPickFolder: @escaping (URL) -> Void) {
            self.onPickFolder = onPickFolder
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPickFolder(url)
        }
    }
}

// MARK: - UI (single screen)

struct CustomFontModifier: ViewModifier {
    @AppStorage("appFont") private var appFont = "Helvetica"
    var style: Font.TextStyle
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        
        if appFont == "Helvetica" {
            return AnyView(content.font(.system(style, design: .default, weight: weight)))
        } else {
            return AnyView(content.font(.custom(appFont, size: size, relativeTo: style).weight(weight)))
        }
    }
}

extension View {
    func customFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        self.modifier(CustomFontModifier(style: style, weight: weight))
    }

    func accessibleButton(_ label: String) -> some View {
        self.accessibilityLabel(label)
    }

}

/// Format a remaining-seconds count for the Sleep Timer chip.
/// Uses `m:ss` while ≤ 60 minutes; falls back to `h:mm` for longer.
private func sleepTimerCountdownText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 {
        let h = s / 3600
        let m = (s % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }
    let m = s / 60
    let sec = s % 60
    return String(format: "%d:%02d", m, sec)
}

struct ContentView: View {
    @State private var model = PlayerModel()
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("appFont") private var appFont = "Helvetica"
    @State private var showingFolderPicker = false
    @State private var showingPlaylist = false
    @State private var showingSettings = false
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
            ZStack {
            // MARK: Primary player UI (single block — gets the gray-out treatment)
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 12) {
                if let image = model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                        .padding(.horizontal, 16)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 80, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .center, spacing: 6) {
                    Text(model.chapters.count >= 2 ? "Current Chapter" : "Current Title")
                        .customFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.chapters.count >= 2 ? (model.currentSubtitle.isEmpty ? "Chapter \(model.currentChapterIndex ?? 0 + 1)" : model.currentSubtitle) : model.currentTitle)
                        .customFont(.title2, weight: .semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            if model.chapters.count >= 2 {
                Text("Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)")
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
            } else if !model.tracks.isEmpty {
                Text("Track \(model.currentIndex + 1) of \(model.tracks.count)")
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            PlayerScrubberView(model: model)

            HStack {
                Spacer()
                
                Button {
                    let didJumpToBookmark = model.skipBackwardNavigation()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.chapters.count >= 2 ? "Previous chapter" : "Previous track")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipBackward30()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Skip back 30 seconds")

                Spacer()

                Button {
                    model.togglePlayPause()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 76, height: 76)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipForward30()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Skip forward 30 seconds")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipForwardNavigation()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.chapters.count >= 2 ? "Next chapter" : "Next track")
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            }
            // Apply gray-out + opacity to the ENTIRE primary player block at once.
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            // Single floating "Playing Voice Memo" badge centered over the
            // grayed-out player block.
            if model.isPlayingVoiceMemo {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    Text("Playing Voice Memo")
                        .customFont(.headline)
                    Button {
                        model.stopVoiceMemo()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop voice memo")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .transition(.opacity.combined(with: .scale))
                .overlay(alignment: .bottom) {
                    ProgressView(value: model.voiceMemoProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .padding(.bottom, -22)
                }
            }

            }
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            // Custom Bottom Toolbar to avoid UIKitToolbar errors
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        model.cycleLoopMode()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        ZStack {
                            switch model.loopMode {
                            case .off:
                                Image(systemName: "infinity.circle")
                                    .font(.title2)
                            case .chapter:
                                Image(systemName: "infinity.circle.fill")
                                    .font(.title2)
                            case .bookmark:
                                Image(systemName: "arrow.trianglehead.clockwise")
                                    .font(.title2)
                                    .overlay(
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 9, weight: .bold))
                                    )
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Loop mode")
                    .accessibilityValue({
                        switch model.loopMode {
                        case .off: return "Off"
                        case .chapter: return "Chapter"
                        case .bookmark: return "Bookmark"
                        }
                    }())

                    Spacer()

                    Button {
                        let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 10.0]
                        if let index = speeds.firstIndex(of: model.speed) {
                            let nextIndex = (index + 1) % speeds.count
                            model.setSpeed(speeds[nextIndex])
                        } else {
                            model.setSpeed(1.0)
                        }
                    } label: {
                        Text(String(format: "%gx", model.speed))
                            .customFont(.headline)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Playback speed, \(String(format: "%g", model.speed)) times")

                    Spacer()

                    // MARK: Sleep Timer (secondary utility row)
                    // HIG-compliant placement: separated from primary transport
                    // controls. Native SwiftUI Menu so users get the system
                    // sheet treatment expected on iOS 18/26.
                    Menu {
                        Button {
                            model.setSleepTimer(.minutes(15))
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: { Label("15 Minutes", systemImage: "15.circle") }
                        Button {
                            model.setSleepTimer(.minutes(30))
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: { Label("30 Minutes", systemImage: "30.circle") }
                        Button {
                            model.setSleepTimer(.minutes(45))
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: { Label("45 Minutes", systemImage: "45.circle") }
                        Button {
                            model.setSleepTimer(.minutes(60))
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: { Label("1 Hour", systemImage: "1.circle") }
                        Divider()
                        Button {
                            model.setSleepTimer(.endOfChapter)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: { Label("End of Chapter", systemImage: "book.closed") }
                        if model.sleepTimerMode.isActive {
                            Divider()
                            Button(role: .destructive) {
                                model.cancelSleepTimer()
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: { Label("Off", systemImage: "xmark.circle") }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz")
                                .font(.title2)
                            // Minimalist countdown when a time-based sleep timer
                            // is active. Format mm:ss for compactness.
                            if case .minutes = model.sleepTimerMode,
                               model.sleepTimerRemainingSeconds > 0 {
                                Text(sleepTimerCountdownText(model.sleepTimerRemainingSeconds))
                                    .customFont(.caption2, weight: .semibold)
                                    .foregroundStyle(Color.accentColor)
                                    .monospacedDigit()
                            } else if case .endOfChapter = model.sleepTimerMode {
                                Text("EOC")
                                    .customFont(.caption2, weight: .semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sleep Timer")
                    .accessibilityValue({
                        switch model.sleepTimerMode {
                        case .off: return "Off"
                        case .minutes(let m): return "\(m) minutes, \(model.sleepTimerRemainingSeconds) seconds remaining"
                        case .endOfChapter: return "End of chapter"
                        }
                    }())

                    Spacer()

                    Button {
                        if let draft = model.bookmarkDraftAtCurrentTime() {
                            newBookmarkDraft = draft
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add bookmark at current time")
                    .disabled(model.tracks.isEmpty)

                    Spacer()

                    Button {
                        showingPlaylist = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Playlist")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // Use native bar material for background to match HIG natively without the UIKit warning
            .background(.bar)
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
        .padding(.horizontal)
        .padding(.top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Open folder")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.loadFolder(url)
            }
        }
        .sheet(isPresented: $showingPlaylist) {
            PlaylistView(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .sheet(item: Binding(
            get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
            set: { editingBookmarkID = $0?.id }
        )) { wrapper in
            EditBookmarkView(model: model, bookmarkID: wrapper.id, draft: nil)
        }
        .sheet(item: $newBookmarkDraft) { draft in
            EditBookmarkView(model: model, bookmarkID: nil, draft: draft)
        }
        .onAppear {
            // Configure remote commands early so the Watch/Now Playing UI is stable once audio starts.
            // (The model also guards to configure only once.)
            model.setDisplayScale(displayScale)
            model.restoreLastSelectionIfPossible()
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: PlayerModel
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("appFont") private var appFont = "Helvetica"
    @Environment(\.dismiss) private var dismiss

    @State private var localCrownAction: String = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Appearance") {
                        Form {
                            Section {
                                Toggle("Dark Mode", isOn: $isDarkMode)
                            }
                            Section {
                                Picker("Font", selection: $appFont) {
                                    Text("Helvetica").tag("Helvetica")
                                    Text("OpenDyslexic").tag("OpenDyslexic")
                                    Text("Lexend").tag("Lexend")
                                }
                            }
                        }
                        .navigationTitle("Appearance")
                    }
                }
                Section {
                    NavigationLink("Watch App") {
                        WatchAppSettingsView(model: model)
                    }
                }
                Section {
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }
                Section(footer: Text("When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp.")) {
                    Toggle("Play Bookmarks Inline", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "playBookmarksInline") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "playBookmarksInline") }
                    ))
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

private struct SmartRewindSettingsView: View {
    @AppStorage("isRewindEnabled") private var isRewindEnabled = false
    @AppStorage("rewindPauseSecondsThreshold") private var rewindPauseSecondsThreshold = 30
    @AppStorage("rewindAmountAfterSeconds") private var rewindAmountAfterSeconds = 10
    @AppStorage("rewindPauseMinutesThreshold") private var rewindPauseMinutesThreshold = 5
    @AppStorage("rewindAmountAfterMinutes") private var rewindAmountAfterMinutes = 30
    @AppStorage("rewindPauseHoursThreshold") private var rewindPauseHoursThreshold = 1
    @AppStorage("rewindAmountAfterHours") private var rewindAmountAfterHours = 90
    @AppStorage("rewindHoursToChapterStart") private var rewindHoursToChapterStart = false

    var body: some View {
        Form {
            Section(
                footer: Text("Automatically rewinds on resume. Longer pause rules override shorter pause rules.")
            ) {
                Toggle("Enable Smart Rewind", isOn: $isRewindEnabled)
            }

            if isRewindEnabled {
                Section("Short Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseSecondsThreshold,
                        range: 5...300,
                        step: 5,
                        valueText: "\(rewindPauseSecondsThreshold)s"
                    )
                    InlineStepperRow(
                        title: "Rewind by:",
                        value: $rewindAmountAfterSeconds,
                        range: 5...180,
                        step: 5,
                        valueText: "\(rewindAmountAfterSeconds)s"
                    )
                }

                Section("Medium Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseMinutesThreshold,
                        range: 1...120,
                        step: 1,
                        valueText: "\(rewindPauseMinutesThreshold)m"
                    )
                    InlineStepperRow(
                        title: "Rewind by:",
                        value: $rewindAmountAfterMinutes,
                        range: 10...600,
                        step: 5,
                        valueText: "\(rewindAmountAfterMinutes)s"
                    )
                }

                Section("Long Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseHoursThreshold,
                        range: 1...24,
                        step: 1,
                        valueText: "\(rewindPauseHoursThreshold)h"
                    )
                    if !rewindHoursToChapterStart {
                        InlineStepperRow(
                            title: "Rewind by:",
                            value: $rewindAmountAfterHours,
                            range: 15...3600,
                            step: 15,
                            valueText: "\(rewindAmountAfterHours)s"
                        )
                    }
                    Toggle("Jump to chapter start", isOn: $rewindHoursToChapterStart)
                }
            }
        }
        .navigationTitle("Smart Rewind")
    }
}

private struct InlineStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let valueText: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .center)

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            .accessibilityHint("Use minus and plus buttons to adjust")
        }
    }
}

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

/// A unified row in the playlist that mixes chapters, tracks, and bookmarks
/// in chronological order.
private enum PlaylistRow: Identifiable {
    case chapter(index: Int, chapter: PlayerModel.Chapter)
    case track(index: Int, track: PlayerModel.Track)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .chapter(_, let c): return "chapter-\(c.id)"
        case .track(_, let t):   return "track-\(t.id)"
        case .bookmark(let b):   return "bookmark-\(b.id.uuidString)"
        }
    }

    var sortKey: Double {
        switch self {
        case .chapter(_, let c): return c.startSeconds
        case .track(let i, _):   return Double(i) // track ordering
        case .bookmark(let b):   return b.timestamp
        }
    }
}

struct PlaylistView: View {
    @Bindable var model: PlayerModel
    @AppStorage("appFont") private var appFont = "Helvetica"
    @Environment(\.dismiss) private var dismiss
    @State private var editingBookmarkID: UUID? = nil

    private enum PlaylistTab: Hashable { case items, bookmarks }
    @State private var selectedTab: PlaylistTab
    @State private var showChapters: Bool = false

    init(model: PlayerModel) {
        self.model = model
        _selectedTab = State(initialValue: model.loopMode == .bookmark ? .bookmarks : .items)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        } else {
            return "\(m)m"
        }
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Indices into `model.bookmarks` for the bookmarks that are visible in the
    /// current track scope (i.e. those returned by `currentTrackBookmarks`).
    private var visibleBookmarkIndices: [Int] {
        let trackId = model.tracks.indices.contains(model.currentIndex) ? model.tracks[model.currentIndex].id : nil
        return model.bookmarks.indices.filter { i in
            let bm = model.bookmarks[i]
            return bm.trackId == nil || bm.trackId == trackId
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    Text(model.chapters.count >= 2 ? "Chapters" : "Tracks").tag(PlaylistTab.items)
                    Text("Bookmarks").tag(PlaylistTab.bookmarks)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == .items {
                    List {
                        if model.chapters.count >= 2 {
                            ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                                chapterRow(index: index, chapter: chapter)
                            }
                            .onMove { source, destination in
                                model.moveChapters(from: source, to: destination)
                            }
                        } else {
                            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                                trackRow(index: index, track: track)
                            }
                            .onMove { source, destination in
                                model.moveTracks(from: source, to: destination)
                            }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                } else {
                    let sortedBookmarks: [Bookmark] = {
                        let trackId = model.tracks.indices.contains(model.currentIndex) ? model.tracks[model.currentIndex].id : nil
                        return model.bookmarks
                            .filter { $0.trackId == nil || $0.trackId == trackId }
                            .sorted { $0.timestamp < $1.timestamp }
                    }()

                    if sortedBookmarks.isEmpty && !showChapters {
                        ContentUnavailableView(
                            "No Bookmarks",
                            systemImage: "bookmark",
                            description: Text("Tap the bookmark button while playing to save a moment.")
                        )
                    } else {
                        List {
                            if model.chapters.count >= 2 {
                                Toggle("Show Chapters", isOn: $showChapters)
                            }

                            if showChapters {
                                Section("Chapters") {
                                    ForEach(model.chapters) { chapter in
                                        Button {
                                            model.seek(toSeconds: chapter.startSeconds + 0.05)
                                        } label: {
                                            HStack {
                                                Image(systemName: "list.bullet")
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 22)
                                                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                                                Spacer()
                                                Text(formatHMS(chapter.startSeconds))
                                                    .customFont(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                        }
                                    }
                                }
                            }

                            if !sortedBookmarks.isEmpty {
                                Section(showChapters ? "Bookmarks" : "") {
                                    ForEach(sortedBookmarks, id: \.id) { bm in
                                        bookmarkRow(bm)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playlist")


            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        model.resetPlaylist()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
                set: { editingBookmarkID = $0?.id }
            )) { wrapper in
                EditBookmarkView(model: model, bookmarkID: wrapper.id, draft: nil)
            }
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
    }

    @ViewBuilder
    private func chapterRow(index: Int, chapter: PlayerModel.Chapter) -> some View {
        Button {
            model.toggleChapterEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                Spacer()
                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                    .customFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func trackRow(index: Int, track: PlayerModel.Track) -> some View {
        Button {
            model.toggleTrackEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(track.title)
            }
            .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: Bookmark) -> some View {
        Button {
            model.jumpToBookmark(bm)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: bm.voiceMemoFileName != nil ? "mic.fill" : "note.text")
                    .foregroundStyle(bm.isEnabled ? (bm.voiceMemoFileName != nil ? Color.red : Color.accentColor) : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bm.title.isEmpty ? "Bookmark" : bm.title)
                        .lineLimit(1)
                    Text(formatHMS(bm.timestamp))
                        .customFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
            }
            .foregroundStyle(bm.isEnabled ? .primary : .tertiary)
        }
        .listRowBackground(Color.accentColor.opacity(bm.isEnabled ? 0.06 : 0.02))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleBookmarkEnabled(id: bm.id)
            } label: {
                Label(bm.isEnabled ? "Disable" : "Enable", systemImage: bm.isEnabled ? "bookmark.slash" : "bookmark")
            }
            .tint(bm.isEnabled ? .orange : .green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.deleteBookmark(id: bm.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingBookmarkID = bm.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}


// MARK: - Persistence helper


// MARK: - Watch App Settings (Designer)

/// The action enum mirrors the watch's WatchAction (kept inline so the iOS
/// target doesn't need to import the Watch target).
enum DesignerWatchAction: String, Codable, CaseIterable, Identifiable {
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
}

struct WatchAppSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("crownAction") private var crownAction: String = "volume"
    @AppStorage("crownVolumeSensitivity") private var volumeSensitivity: Double = 0.05
    @AppStorage("crownScrubSensitivity") private var scrubSensitivity: Double = 0.5
    @AppStorage("watchPage1") private var page1Raw: String = "empty,empty,skipBackward,playPause,skipForward"
    @AppStorage("watchPage2") private var page2Raw: String = "loopMode,empty,speed,sleepTimer,bookmark"
    @AppStorage("watchQuickBookmarkTimeoutSeconds", store: AppGroupDefaults.shared) private var quickBookmarkTimeoutSeconds: Int = 5

    // Progress indicator configuration
    @AppStorage("linearBarMode") private var linearBarMode: String = "total"
    @AppStorage("linearBarHidden") private var linearBarHidden: Bool = false
    @AppStorage("circularRingMode") private var circularRingMode: String = "chapter"
    @AppStorage("circularRingHidden") private var circularRingHidden: Bool = false

    @State private var page1Slots: [DesignerWatchAction] = Array(repeating: .empty, count: 5)
    @State private var page2Slots: [DesignerWatchAction] = Array(repeating: .empty, count: 5)
    @State private var selectedPage: Int = 0

    private let palette: [DesignerWatchAction] = [
        .playPause, .skipForward, .skipBackward, .nextTrack,
        .previousTrack, .loopMode, .speed, .sleepTimer, .bookmark
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Digital Crown Control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Digital Crown Control")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Picker("Digital Crown", selection: $crownAction) {
                        Text("Volume").tag("volume")
                        Text("Scrubbing").tag("scrub")
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                    .onChange(of: crownAction) { _, _ in
                        model.syncToWatch()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume Sensitivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $volumeSensitivity, in: 0.01...0.1, step: 0.01)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(volumeSensitivity, specifier: "%.2f")×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scrubbing Sensitivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $scrubSensitivity, in: 0.1...1.0, step: 0.1)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(scrubSensitivity, specifier: "%.1f")×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // MARK: Haptics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haptics")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Toggle("Button Haptics", isOn: Binding(
                        get: { AppGroupDefaults.isHapticFeedbackEnabled },
                        set: { 
                            AppGroupDefaults.isHapticFeedbackEnabled = $0
                            model.syncToWatch()
                        }
                    ))
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Bookmark Timeout
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bookmark Timeout")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Stepper(value: $quickBookmarkTimeoutSeconds, in: 1...15) {
                        HStack {
                            Label("Quick Bookmark", systemImage: "timer")
                            Spacer()
                            Text("\(quickBookmarkTimeoutSeconds)s")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: quickBookmarkTimeoutSeconds) { _, newValue in
                        AppGroupDefaults.watchQuickBookmarkTimeoutSeconds = newValue
                        model.syncToWatch()
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Progress Indicators
                VStack(alignment: .leading, spacing: 8) {
                    Text("Progress Indicators")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Picker("Linear Bar", selection: $linearBarMode) {
                            Text("Chapter Progress").tag("chapter")
                            Text("Total Book Progress").tag("total")
                        }
                        .pickerStyle(.menu)
                        .onChange(of: linearBarMode) { _, _ in
                            model.syncToWatch()
                        }

                        Toggle("Show Linear Bar", isOn: Binding(
                            get: { !linearBarHidden },
                            set: { linearBarHidden = !$0 }
                        ))
                        .onChange(of: linearBarHidden) { _, _ in
                            model.syncToWatch()
                        }

                        Divider()

                        Picker("Circular Ring", selection: $circularRingMode) {
                            Text("Chapter Progress").tag("chapter")
                            Text("Total Book Progress").tag("total")
                        }
                        .pickerStyle(.menu)
                        .onChange(of: circularRingMode) { _, _ in
                            model.syncToWatch()
                        }

                        Toggle("Show Circular Ring", isOn: Binding(
                            get: { !circularRingHidden },
                            set: { circularRingHidden = !$0 }
                        ))
                        .onChange(of: circularRingHidden) { _, _ in
                            model.syncToWatch()
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Watch App Designer
                VStack(alignment: .leading, spacing: 12) {
                    Text("Watch App Designer")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 16) {
                        Picker("Page", selection: $selectedPage) {
                            Text("Page 1").tag(0)
                            Text("Page 2").tag(1)
                        }
                        .pickerStyle(.segmented)

                        WatchPreviewCanvas(
                            slots: selectedPage == 0 ? $page1Slots : $page2Slots,
                            onChange: saveSlots
                        )
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Available Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Actions (Drag to slots)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(palette) { action in
                                PaletteItem(action: action)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Force Sync
                Button {
                    saveSlots()
                    model.syncToWatch()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text("Force Sync to Watch")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("Watch App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSlots() }
    }

    private func loadSlots() {
        page1Slots = padded(parse(page1Raw))
        page2Slots = padded(parse(page2Raw))
    }

    private func saveSlots() {
        page1Raw = page1Slots.map { $0.rawValue }.joined(separator: ",")
        page2Raw = page2Slots.map { $0.rawValue }.joined(separator: ",")
        model.syncToWatch()
    }

    private func parse(_ raw: String) -> [DesignerWatchAction] {
        raw.split(separator: ",").compactMap { DesignerWatchAction(rawValue: String($0)) }
    }

    private func padded(_ s: [DesignerWatchAction]) -> [DesignerWatchAction] {
        var out = s
        while out.count < 5 { out.append(.empty) }
        return Array(out.prefix(5))
    }
}

// A draggable palette chip showing the action icon + label.
private struct PaletteItem: View {
    let action: DesignerWatchAction

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: action.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text(action.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 78)
        .onDrag {
            NSItemProvider(object: NSString(string: action.rawValue))
        }
    }
}

// Faux Apple Watch frame that previews the live layout. This view is laid out
// to match the breathing room of the real watch UI: top-left + top-right
// slots are anchored to the very top, with the artwork-and-title block
// vertically centered and a 3-button transport row at the bottom.
private struct WatchPreviewCanvas: View {
    @Binding var slots: [DesignerWatchAction]
    var onChange: () -> Void

    var body: some View {
        ZStack {
            // Watch bezel
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .fill(Color.black)
                )

            VStack(spacing: 8) {
                // Artwork (real app icon)
                AppIconThumbnail(size: 64)
                    .padding(.top, 4)

                Text("Chapter 1")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.horizontal, 8)

                HStack(spacing: 8) {
                    DropSlot(slot: $slots[2], shape: .squircle, onChange: onChange)
                    DropSlot(slot: $slots[3], shape: .circle,   onChange: onChange)
                    DropSlot(slot: $slots[4], shape: .squircle, onChange: onChange)
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 14)

            // Top-row slots — anchored to the top of the frame so they NEVER
            // crowd the title. This mirrors the watch's actual layout.
            VStack {
                HStack {
                    DropSlot(slot: $slots[0], shape: .topGlyph, onChange: onChange)
                        .padding(.leading, 12)
                    Spacer()
                    DropSlot(slot: $slots[1], shape: .topGlyph, onChange: onChange)
                        .padding(.trailing, 12)
                }
                .padding(.top, 12)
                Spacer()
            }
        }
        .frame(width: 220, height: 268)
    }
}

// MARK: - Drop slot

private struct DropSlot: View {
    enum SlotShape { case squircle, circle, topGlyph }

    @Binding var slot: DesignerWatchAction
    let shape: SlotShape
    var onChange: () -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: width, height: height)
        // Expand the invisible hit-target to satisfy Apple HIG's 44x44 minimum
        // interaction size (and a bit more for comfortable drag-and-drop).
        // The visible dashed placeholder above keeps its original proportions;
        // the surrounding padding becomes a transparent "catch area".
        .padding(max(0, (max(60, width + 20) - width) / 2))
        .frame(minWidth: 60, minHeight: 60)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in

            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { string, _ in
                if let raw = string as? String,
                   let action = DesignerWatchAction(rawValue: raw) {
                    DispatchQueue.main.async {
                        slot = action
                        onChange()
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(role: .destructive) {
                slot = .empty
                onChange()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
        }
    }

    private var width: CGFloat {
        switch shape {
        case .squircle: return 46
        case .circle:   return 50
        case .topGlyph: return 28
        }
    }
    private var height: CGFloat { width }

    @ViewBuilder
    private var background: some View {
        let isEmpty = slot == .empty
        let dashed = StrokeStyle(lineWidth: 2, dash: [5, 5])
        let solidColor = Color.white.opacity(isTargeted ? 0.6 : 0.25)
        let dashColor = Color.gray.opacity(isTargeted ? 0.9 : 0.7)

        switch shape {
        case .squircle:
            if isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(dashColor, style: dashed)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(solidColor, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        case .circle:
            if isEmpty {
                Circle()
                    .stroke(dashColor, style: dashed)
            } else {
                Circle()
                    .stroke(solidColor, lineWidth: 1)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.12))
                    )
            }
        case .topGlyph:
            // Always show a placeholder outline in the designer so slots [0]
            // and [1] are visible even when empty. The real watch UI keeps
            // these invisible when empty — that's handled on the watch side.
            if isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(dashColor, style: dashed)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isTargeted ? 0.6 : 0.0), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if slot == .empty {
            Image(systemName: "plus")
                .font(.system(size: shape == .topGlyph ? 12 : 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            Image(systemName: slot.iconName)
                .font(.system(size: shape == .topGlyph ? 16 : 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - App icon thumbnail (uses the real AppIcon)

private struct AppIconThumbnail: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let img = Self.loadAppIcon() {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                // Fallback: filled rounded square so it's never a black box.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private static func loadAppIcon() -> UIImage? {
        loadAppIconImage()
    }
}

func loadAppIconImage() -> UIImage? {
    if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
       let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
       let files = primary["CFBundleIconFiles"] as? [String],
       let last = files.last,
       let img = UIImage(named: last) {
        return img
    }
    return UIImage(named: "AppIcon")
}

#Preview {
    ContentView()
}
