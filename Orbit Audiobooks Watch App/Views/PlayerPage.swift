import AVFoundation
import SwiftUI
import WatchKit

// MARK: - Player Page

struct PlayerPage: View {
    let slots: [WatchAction]
    let viewModel: WatchViewModel
    let layout: WatchArtworkLayout
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    private var isCompactLayout: Bool { layout == .classic }
    private var topControlInset: CGFloat { isCompactLayout ? 8 : 10 }
    private var topControlSize: CGFloat { isCompactLayout ? 40 : 42 }

    var body: some View {
        ZStack {
            if layout == .classic {
                classicContent
            } else {
                VStack(spacing: 8) {
                    Spacer(minLength: 42)

                    titleView

                    Spacer(minLength: 10)

                    bottomControls(isCompactLayout: false)
                        .padding(.bottom, 8)
                }
            }

            // Top-row slots
            VStack {
                HStack {
                    TopSlotButton(
                        action: slots[0],
                        viewModel: viewModel,
                        usesImmersiveChrome: true,
                        controlSize: topControlSize,
                        onBookmark: onBookmark,
                        onSleepTimer: onSleepTimer
                    )
                        .padding(.leading, topControlInset)
                    Spacer()
                    TopSlotButton(
                        action: slots[1],
                        viewModel: viewModel,
                        usesImmersiveChrome: true,
                        controlSize: topControlSize,
                        onBookmark: onBookmark,
                        onSleepTimer: onSleepTimer
                    )
                        .padding(.trailing, topControlInset)
                }
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    private var classicContent: some View {
        VStack(spacing: 8) {
            classicArtwork

            Text(viewModel.title)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal)

            bottomControls(isCompactLayout: true)
        }
    }

    private func bottomControls(isCompactLayout: Bool) -> some View {
        VStack(spacing: 0) {
            progressBar

            TransportRow(
                leftSlot: slots[2],
                centerSlot: slots[3],
                rightSlot: slots[4],
                viewModel: viewModel,
                usesImmersiveChrome: true,
                isCompactLayout: isCompactLayout,
                onBookmark: onBookmark,
                onSleepTimer: onSleepTimer
            )
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if !viewModel.linearBarHidden {
            let linearProgress = viewModel.linearBarMode == "chapter"
                ? viewModel.progressFraction
                : viewModel.totalProgressFraction
            ProgressView(value: linearProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.green)
                .padding(.horizontal, 16)
                .scaleEffect(y: 0.5)
                .animation(viewModel.progressAnimationSuppressed ? nil : .linear(duration: 0.5), value: linearProgress)
        }
    }

    private var titleView: some View {
        Text(viewModel.title)
            .font(.system(.caption, design: .rounded))
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.tail)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, layout == .classic ? 4 : 6)
            .frame(maxWidth: .infinity)
            .background(layout == .classic ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var classicArtwork: some View {
        if let image = viewModel.thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                .accessibilityLabel(Text(viewModel.title))
                .accessibilityAddTraits(.isImage)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.white)
                )
        }
    }
}

// MARK: - Top slot button (small, top-row chrome)

struct TopSlotButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let usesImmersiveChrome: Bool
    let controlSize: CGFloat
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    private var iconSize: CGFloat { controlSize <= 40 ? 21 : 23 }
    private var speedFontSize: CGFloat { controlSize <= 40 ? 13 : 14 }
    private var countdownOffset: CGFloat { controlSize <= 40 ? 14 : 16 }

    var body: some View {
        if action == .empty {
            EmptyView()
        } else {
            Button {
                if action == .bookmark {
                    onBookmark()
                } else if action == .sleepTimer {
                    onSleepTimer()
                } else {
                    viewModel.handle(action)
                }
            } label: {
                Group {
                    if action == .loopMode && viewModel.loopMode == "bookmark" {
                        ZStack {
                            Image(systemName: "arrow.trianglehead.clockwise")
                                .font(.system(size: iconSize))
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                    } else if action == .speed {
                        Text(formatSpeed(viewModel.playbackSpeed))
                            .font(.system(size: speedFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else if action == .sleepTimer {
                        ZStack {
                            Image(systemName: viewModel.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                                .font(.system(size: iconSize, weight: .semibold))
                                .foregroundStyle(viewModel.isSleepTimerActive ? Color.accentColor : Color.white)
                            if viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerRemainingSeconds > 0 {
                                Text(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)
                                    .monospacedDigit()
                                    .offset(y: countdownOffset)
                            }
                        }
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: iconSize))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: controlSize, height: controlSize)
                .background {
                    if usesImmersiveChrome {
                        WatchControlBackground(shape: Circle())
                    }
                }
                .contentShape(Rectangle())
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
        if action == .skipForward {
            return action.dynamicIconName(forDuration: viewModel.seekForwardDuration)
        }
        if action == .skipBackward {
            return action.dynamicIconName(forDuration: viewModel.seekBackwardDuration)
        }
        return action.iconName
    }

    private var accessibilityLabelText: String {
        switch action {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward \(viewModel.seekForwardDuration) seconds"
        case .skipBackward: return "Skip back \(viewModel.seekBackwardDuration) seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .nextSection: return "Next section"
        case .previousSection: return "Previous section"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return ""
        }
    }
}

func sleepCountdownText(_ seconds: Int) -> String {
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

// MARK: - Sleep Timer Sheet

struct SleepTimerView: View {
    let viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    timerButton(label: String(localized: "15 Minutes"), systemImage: "15.circle", isOn: isMinutes(15)) {
                        viewModel.setSleepTimerMinutes(15); dismiss()
                    }
                    timerButton(label: String(localized: "30 Minutes"), systemImage: "30.circle", isOn: isMinutes(30)) {
                        viewModel.setSleepTimerMinutes(30); dismiss()
                    }
                    timerButton(label: String(localized: "45 Minutes"), systemImage: "45.circle", isOn: isMinutes(45)) {
                        viewModel.setSleepTimerMinutes(45); dismiss()
                    }
                    timerButton(label: String(localized: "1 Hour"), systemImage: "1.circle", isOn: isMinutes(60)) {
                        viewModel.setSleepTimerMinutes(60); dismiss()
                    }
                }
                Section {
                    timerButton(label: String(localized: "End of Chapter"), systemImage: "book.closed", isOn: viewModel.sleepTimerMode == "endOfChapter") {
                        viewModel.setSleepTimerEndOfChapter(); dismiss()
                    }
                }
                if viewModel.isSleepTimerActive {
                    Section {
                        Button(role: .destructive) {
                            viewModel.cancelSleepTimer(); dismiss()
                        } label: {
                            Label("Off", systemImage: "xmark.circle")
                        }
                    } footer: {
                        if viewModel.sleepTimerMode == "minutes" {
                            Text(String(localized: "Remaining: \(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))"))
                        }
                    }
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }

    private func isMinutes(_ m: Int) -> Bool {
        viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerMinutes == m
    }

    @ViewBuilder
    private func timerButton(label: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

func formatSpeed(_ speed: Double) -> String {
    let formatted: String
    if speed.truncatingRemainder(dividingBy: 1) == 0 {
        formatted = String(format: "%.0f", speed)
    } else {
        formatted = String(speed)
    }
    return "\(formatted)x"
}

// MARK: - Bottom transport row (left button | play+ring | right button)

struct TransportRow: View {
    let leftSlot: WatchAction
    let centerSlot: WatchAction
    let rightSlot: WatchAction
    let viewModel: WatchViewModel
    let usesImmersiveChrome: Bool
    let isCompactLayout: Bool
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    private var sideButtonSize: CGFloat { isCompactLayout ? 38 : 42 }
    private var centerButtonSize: CGFloat { isCompactLayout ? 40 : 42 }
    private var ringSize: CGFloat { isCompactLayout ? 48 : 52 }
    private var rowSpacing: CGFloat { isCompactLayout ? 10 : 20 }
    private var innerHorizontalPadding: CGFloat { isCompactLayout ? 6 : 10 }
    private var outerHorizontalPadding: CGFloat { isCompactLayout ? 12 : 0 }

    var body: some View {
        HStack(spacing: usesImmersiveChrome ? rowSpacing : 20) {
            SideTransportButton(action: leftSlot, viewModel: viewModel, usesImmersiveChrome: usesImmersiveChrome, controlSize: sideButtonSize, onBookmark: onBookmark, onSleepTimer: onSleepTimer)

            CenterTransportButton(action: centerSlot, viewModel: viewModel, controlSize: centerButtonSize, ringSize: ringSize, onBookmark: onBookmark, onSleepTimer: onSleepTimer)

            SideTransportButton(action: rightSlot, viewModel: viewModel, usesImmersiveChrome: usesImmersiveChrome, controlSize: sideButtonSize, onBookmark: onBookmark, onSleepTimer: onSleepTimer)
        }
        .padding(.horizontal, usesImmersiveChrome ? innerHorizontalPadding : 0)
        .padding(.vertical, usesImmersiveChrome ? 6 : 0)
        .background {
            if usesImmersiveChrome {
                WatchControlBackground(shape: Capsule())
            }
        }
        .padding(.horizontal, usesImmersiveChrome ? outerHorizontalPadding : 0)
    }
}

struct SideTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let usesImmersiveChrome: Bool
    let controlSize: CGFloat
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    private var iconSize: CGFloat { controlSize <= 38 ? 18 : 20 }
    private var speedFontSize: CGFloat { controlSize <= 38 ? 12 : 14 }
    private var countdownOffset: CGFloat { controlSize <= 38 ? 12 : 14 }

    var body: some View {
        Button {
            if action == .bookmark {
                onBookmark()
            } else if action == .sleepTimer {
                onSleepTimer()
            } else {
                viewModel.handle(action)
            }
        } label: {
            Group {
                if action == .loopMode && viewModel.loopMode == "bookmark" {
                    ZStack {
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.system(size: iconSize))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                } else if action == .speed {
                    Text(formatSpeed(viewModel.playbackSpeed))
                        .font(.system(size: speedFontSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else if action == .sleepTimer {
                    ZStack {
                        Image(systemName: viewModel.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                            .font(.system(size: iconSize, weight: .semibold))
                            .foregroundStyle(viewModel.isSleepTimerActive ? Color.accentColor : Color.white)
                        if viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerRemainingSeconds > 0 {
                            Text(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .monospacedDigit()
                                .offset(y: countdownOffset)
                        }
                    }
                } else {
                    Image(systemName: sideIconName)
                        .font(.system(size: iconSize))
                }
            }
            .frame(width: usesImmersiveChrome ? controlSize : 38, height: usesImmersiveChrome ? controlSize : 38)
            .padding(usesImmersiveChrome ? 0 : 15)
            .contentShape(Rectangle())
            .opacity(action == .empty ? 0.35 : 1.0)
        }
        .transportButtonStyle(usesImmersiveChrome: usesImmersiveChrome)
        .background {
            if usesImmersiveChrome {
                WatchControlBackground(shape: Circle())
            }
        }
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
        if action == .skipForward {
            return action.dynamicIconName(forDuration: viewModel.seekForwardDuration)
        }
        if action == .skipBackward {
            return action.dynamicIconName(forDuration: viewModel.seekBackwardDuration)
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
        case .skipForward: return "Skip forward \(viewModel.seekForwardDuration) seconds"
        case .skipBackward: return "Skip back \(viewModel.seekBackwardDuration) seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .nextSection: return "Next section"
        case .previousSection: return "Previous section"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return "Empty slot"
        }
    }
}

extension View {
    @ViewBuilder
    func transportButtonStyle(usesImmersiveChrome: Bool) -> some View {
        if usesImmersiveChrome {
            self.buttonStyle(.plain)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

struct CenterTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let controlSize: CGFloat
    let ringSize: CGFloat
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    private var iconSize: CGFloat { controlSize <= 40 ? 20 : 22 }

    var body: some View {
        ZStack {
            if !viewModel.circularRingHidden {
                let ringProgress = viewModel.circularRingMode == "total"
                    ? viewModel.totalProgressFraction
                    : viewModel.progressFraction
                // Use the suppression flag matching whichever progress source the ring tracks.
                let ringSuppressed = viewModel.circularRingMode == "chapter"
                    ? viewModel.ringAnimationSuppressed
                    : viewModel.progressAnimationSuppressed
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 4)
                    .frame(width: ringSize, height: ringSize)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: ringSize, height: ringSize)
                    .rotationEffect(.degrees(-90))
                    .animation(ringSuppressed ? nil : .linear(duration: 0.5), value: ringProgress)
            }

            Button {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else if resolvedAction == .sleepTimer {
                    onSleepTimer()
                } else {
                    viewModel.handle(resolvedAction)
                }
            } label: {
                Image(systemName: centerIconName)
                    .font(.system(size: iconSize))
                    .frame(width: controlSize, height: controlSize)
                    .background {
                        WatchControlBackground(shape: Circle())
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(centerAccessibilityLabel)

            // Hidden helper for the double-tap primary-action shortcut.
            Button("") {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else if resolvedAction == .sleepTimer {
                    onSleepTimer()
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
        case .skipForward:
            return resolvedAction.dynamicIconName(forDuration: viewModel.seekForwardDuration)
        case .skipBackward:
            return resolvedAction.dynamicIconName(forDuration: viewModel.seekBackwardDuration)
        default:
            return resolvedAction.iconName
        }
    }

    private var centerAccessibilityLabel: String {
        switch resolvedAction {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward \(viewModel.seekForwardDuration) seconds"
        case .skipBackward: return "Skip back \(viewModel.seekBackwardDuration) seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .nextSection: return "Next section"
        case .previousSection: return "Previous section"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return ""
        }
    }
}

// MARK: - New Bookmark

struct NewBookmarkView: View {
    let viewModel: WatchViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = WatchVoiceMemoRecorder()
    @State private var alertMessage = ""
    @State private var isShowingAlert = false
    @State private var quickBookmarkTimer: Timer?
    @State private var quickBookmarkStartedAt = Date()
    @State private var quickBookmarkRemaining: TimeInterval = 0
    @State private var didCompleteQuickBookmark = false

    private var recordingProgress: Double {
        min(recorder.elapsed / WatchVoiceMemoRecorder.maximumDuration, 1)
    }

    private var quickBookmarkTimeout: TimeInterval {
        TimeInterval(max(1, viewModel.watchQuickBookmarkTimeoutSeconds))
    }

    private var quickBookmarkProgress: Double {
        guard quickBookmarkTimeout > 0 else { return 0 }
        return min(max(quickBookmarkRemaining / quickBookmarkTimeout, 0), 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: recorder.isRecording ? recordingProgress : quickBookmarkProgress)
                        .stroke(recorder.isRecording ? .red : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: recorder.isRecording ? "stop.fill" : "bookmark.fill")
                        .font(.title3)
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                Text(recorder.isRecording ? recordingDurationText : quickBookmarkCountdownText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Primary, low-friction "Quick Bookmark" action. Bypasses the
                // microphone entirely and inserts a generic bookmark with a
                // title derived from the current bookmarks count.
                if !recorder.isRecording {
                    Button {
                        cancelQuickBookmarkTimer()
                        viewModel.addQuickBookmark()
                        WKInterfaceDevice.current().play(.success)
                        dismiss()
                    } label: {
                        Label("Quick Bookmark", systemImage: "bookmark.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Adds Bookmark #\(viewModel.bookmarks.count + 1) without recording audio")
                }

                Button {
                    recorder.isRecording ? saveVoiceMemo() : startVoiceBookmark()
                } label: {
                    Label(recorder.isRecording ? String(localized: "Stop") : String(localized: "Record Note"), systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
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
                        cancelQuickBookmarkTimer()
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
            .onAppear {
                startQuickBookmarkTimer()
            }
            .onDisappear {
                cancelQuickBookmarkTimer()
                if recorder.isRecording {
                    _ = recorder.stopRecording()
                }
            }
        }
    }

    private var recordingDurationText: String {
        "\(Int(recorder.elapsed.rounded(.down)))s / \(Int(WatchVoiceMemoRecorder.maximumDuration))s"
    }

    private var quickBookmarkCountdownText: String {
        "\(max(0, Int(quickBookmarkRemaining.rounded(.up))))s"
    }

    private func startQuickBookmarkTimer() {
        quickBookmarkRemaining = quickBookmarkTimeout
        quickBookmarkStartedAt = Date()
        quickBookmarkTimer?.invalidate()
        quickBookmarkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard !recorder.isRecording, !didCompleteQuickBookmark else { return }
            let elapsed = Date().timeIntervalSince(quickBookmarkStartedAt)
            let remaining = max(0, quickBookmarkTimeout - elapsed)
            quickBookmarkRemaining = remaining
            if remaining <= 0 {
                completeQuickBookmarkFromTimeout()
            }
        }
        if let quickBookmarkTimer {
            RunLoop.main.add(quickBookmarkTimer, forMode: .common)
        }
    }

    private func cancelQuickBookmarkTimer() {
        quickBookmarkTimer?.invalidate()
        quickBookmarkTimer = nil
    }

    private func completeQuickBookmarkFromTimeout() {
        guard !didCompleteQuickBookmark else { return }
        didCompleteQuickBookmark = true
        cancelQuickBookmarkTimer()
        viewModel.addQuickBookmark()
        dismiss()
    }

    private func startVoiceBookmark() {
        cancelQuickBookmarkTimer()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showAlert("Microphone access is denied. Enable microphone access for Orbit Audiobooks in Settings.")
        case .undetermined:
            Task {
                let isGranted = await AVAudioApplication.requestRecordPermission()
                isGranted ? beginRecording() : showAlert("Microphone access is required to record a voice bookmark.")
            }
        @unknown default:
            showAlert("Microphone access is unavailable.")
        }
    }

    private func beginRecording() {
        viewModel.prepareOptimisticUpdate()
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
        cancelQuickBookmarkTimer()
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
