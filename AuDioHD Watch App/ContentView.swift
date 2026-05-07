import SwiftUI
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
        case .loopMode:      return "toggleLoopMode"
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
    var title: String = "No track"
    var thumbnailImage: UIImage? = nil
    var progressFraction: Double = 0.0
    var loopModeOn: Bool = true

    var page1Slots: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
    var page2Slots: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]

    override init() {
        super.init()
        loadPersistedSlots()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    private func loadPersistedSlots() {
        let defaults = UserDefaults(suiteName: "group.com.bookloop")
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

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            let defaults = UserDefaults(suiteName: "group.com.bookloop")
            if let crownAction = applicationContext["crownAction"] as? String {
                defaults?.set(crownAction, forKey: "crownAction")
            }
            if let isPlaying = applicationContext["isPlaying"] as? Bool {
                self.isPlaying = isPlaying
                defaults?.set(isPlaying, forKey: "isPlaying")
            }
            if let title = applicationContext["title"] as? String {
                self.title = title
                defaults?.set(title, forKey: "title")
            }
            if let progressFraction = applicationContext["progressFraction"] as? Double {
                self.progressFraction = progressFraction
                defaults?.set(progressFraction, forKey: "progressFraction")
            }
            if let loopModeOn = applicationContext["loopModeOn"] as? Bool {
                self.loopModeOn = loopModeOn
                defaults?.set(loopModeOn, forKey: "loopModeOn")
            }
            if let watchPage1 = applicationContext["watchPage1"] as? String {
                self.page1Slots = self.padded(self.parseSlots(watchPage1))
                defaults?.set(watchPage1, forKey: "watchPage1")
            }
            if let watchPage2 = applicationContext["watchPage2"] as? String {
                self.page2Slots = self.padded(self.parseSlots(watchPage2))
                defaults?.set(watchPage2, forKey: "watchPage2")
            }
            if let thumbnailData = applicationContext["thumbnailData"] as? Data {
                defaults?.set(thumbnailData, forKey: "thumbnailData")
                if let image = UIImage(data: thumbnailData) {
                    self.thumbnailImage = image
                }
            } else {
                defaults?.removeObject(forKey: "thumbnailData")
                self.thumbnailImage = nil
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func sendCommand(_ command: String, params: [String: Any]? = nil) {
        guard !command.isEmpty else { return }
        if WCSession.default.isReachable {
            var message: [String: Any] = ["command": command]
            if let params = params {
                for (key, value) in params {
                    message[key] = value
                }
            }
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { error in
                print("Error sending command: \(error)")
            })
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
    }

    /// Trigger the action for a tapped slot, with local state echoes for
    /// playPause / loopMode so the UI feels instant.
    func handle(_ action: WatchAction) {
        switch action {
        case .empty:
            return
        case .playPause:
            sendCommand(isPlaying ? "pause" : "play")
            isPlaying.toggle()
        case .loopMode:
            sendCommand("toggleLoopMode")
            loopModeOn.toggle()
        default:
            sendCommand(action.command)
        }
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
    @State private var viewModel = WatchViewModel()
    @AppStorage("crownAction", store: UserDefaults(suiteName: "group.com.bookloop")) private var crownAction = "volume"
    @State private var crownAccumulator: Double = 0.0
    @State private var lastAccumulator: Double = 0.0
    @State private var selectedPage: Int = 0
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
                PlayerPage(slots: viewModel.page1Slots, viewModel: viewModel)
                    .tag(0)
                PlayerPage(slots: viewModel.page2Slots, viewModel: viewModel)
                    .tag(1)
            }
            .tabViewStyle(.page)
        }
        .focusable(true)
        .focused($isFocused)
        .digitalCrownRotation($crownAccumulator)
        .onChange(of: crownAccumulator) { _, newValue in
            let delta = newValue - lastAccumulator
            lastAccumulator = newValue
            if crownAction == "scrub" {
                viewModel.sendCommand("scrubDelta", params: ["delta": delta])
            } else {
                viewModel.sendCommand("volumeDelta", params: ["delta": delta])
            }
        }
        .onAppear { isFocused = true }
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
                    viewModel: viewModel
                )
                .padding(.top, 6)
            }

            // Top-row slots (anchored to the top — well above the title).
            VStack {
                HStack {
                    TopSlotButton(action: slots[0], viewModel: viewModel)
                        .padding(.leading, 8)
                    Spacer()
                    TopSlotButton(action: slots[1], viewModel: viewModel)
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

    var body: some View {
        if action == .empty {
            EmptyView()
        } else {
            Button {
                viewModel.handle(action)
            } label: {
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabelText)
            .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? (viewModel.loopModeOn ? "On" : "Off") : nil))
        }
    }

    private var iconName: String {
        if action == .loopMode {
            return viewModel.loopModeOn ? "infinity.circle.fill" : "infinity.circle"
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

    var body: some View {
        HStack(spacing: 20) {
            SideTransportButton(action: leftSlot, viewModel: viewModel)

            CenterTransportButton(action: centerSlot, viewModel: viewModel)

            SideTransportButton(action: rightSlot, viewModel: viewModel)
        }
    }
}

private struct SideTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel

    var body: some View {
        Button {
            viewModel.handle(action)
        } label: {
            Image(systemName: action == .empty ? "plus" : action.iconName)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .padding(15)
                .contentShape(Rectangle())
                .opacity(action == .empty ? 0.35 : 1.0)
        }
        .buttonStyle(.borderedProminent)
        .disabled(action == .empty)
        .accessibilityLabel(accessibilityLabelText)
        .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? (viewModel.loopModeOn ? "On" : "Off") : nil))
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
                viewModel.handle(resolvedAction)
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
                viewModel.handle(resolvedAction)
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

#Preview {
    ContentView()
}
