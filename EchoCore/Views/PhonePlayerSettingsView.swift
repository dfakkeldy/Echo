import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PhonePlayerSettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    enum ConfigMode { case tap, longPress }
    @State private var configMode: ConfigMode = .tap
    @State private var slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var longPressSlots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var showingSaveAlert = false
    @State private var newPresetName = ""
    @State private var showingSoundscapePicker = false
    @State private var showingChimeSettings = false

    private let palette: [WatchAction] = [
        .playPause, .skipForward, .skipBackward, .nextTrack,
        .previousTrack, .nextSection, .previousSection,
        .loopMode, .speed, .sleepTimer, .bookmark
    ]

    /// Actions the mini-player slots can perform (no sleep timer — that lives
    /// in the top pill; no pomodoro yet).
    private let miniPlayerChoices: [WatchAction] = [
        .playPause, .skipBackward, .skipForward, .previousTrack, .nextTrack,
        .previousSection, .nextSection, .loopMode, .speed, .bookmark, .empty
    ]

    private func miniPlayerChoiceName(_ action: WatchAction) -> String {
        switch action {
        case .playPause: return String(localized: "Play / Pause")
        case .skipBackward: return String(localized: "Skip Back")
        case .skipForward: return String(localized: "Skip Forward")
        case .previousTrack: return String(localized: "Previous Chapter")
        case .nextTrack: return String(localized: "Next Chapter")
        case .previousSection: return String(localized: "Previous Section")
        case .nextSection: return String(localized: "Next Section")
        case .loopMode: return String(localized: "Loop Mode")
        case .speed: return String(localized: "Speed")
        case .bookmark: return String(localized: "Bookmark")
        case .sleepTimer: return String(localized: "Sleep Timer")
        case .pomodoro: return String(localized: "Pomodoro")
        case .empty: return String(localized: "Empty")
        }
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Player Layout Style
                VStack(alignment: .leading, spacing: 12) {
                    Text("Player Layout Style")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)
                    
                    Picker("Layout Style", selection: $settings.playerLayoutStyle) {
                        Text("Default").tag("default")
                        Text("Compact").tag("compact")
                    }
                    .pickerStyle(.segmented)
                    
                    Text("The Compact layout uses a smaller scrubber and reorganizes transport controls for a more minimalist look.")
                        .customFont(.subheadline, appFont: settings.appFont)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Mini-Player Buttons
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mini-Player Buttons")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    ForEach(0..<3, id: \.self) { slot in
                        Picker(String(localized: "Slot \(slot + 1)"), selection: Binding(
                            get: { settings.miniPlayerPage.indices.contains(slot) ? settings.miniPlayerPage[slot] : .empty },
                            set: { newAction in
                                var page = settings.miniPlayerPage
                                while page.count < 3 { page.append(.empty) }
                                page[slot] = newAction
                                settings.miniPlayerPage = page
                            }
                        )) {
                            ForEach(miniPlayerChoices) { action in
                                Label(miniPlayerChoiceName(action), systemImage: action.iconName).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Text("The three buttons shown in the mini-player on the Timeline and Reader tabs.")
                        .customFont(.subheadline, appFont: settings.appFont)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Phone App Designer Info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Customize your playback control layout by dragging actions into the slots on the phone preview below.")
                        .customFont(.subheadline, appFont: settings.appFont)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Designer Canvas
                VStack(alignment: .leading, spacing: 12) {
                    Text("Phone Player Designer")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    Picker("Configure", selection: $configMode) {
                        Text("Tap Actions").tag(ConfigMode.tap)
                        Text("Long Press").tag(ConfigMode.longPress)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    VStack(spacing: 16) {
                        PhonePreviewCanvas(
                            slots: configMode == .tap ? $slots : $longPressSlots,
                            onChange: saveSlots
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Available Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Actions (Drag to slots)")
                        .customFont(.subheadline, weight: .semibold, appFont: settings.appFont)
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

                // MARK: Focus
                VStack(alignment: .leading, spacing: 12) {
                    Text("Focus")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    Button {
                        showingSoundscapePicker = true
                    } label: {
                        Label("Soundscape", systemImage: "waveform")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingChimeSettings = true
                    } label: {
                        Label("Interval Chime", systemImage: "bell")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Layout Presets
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Layout Presets")
                            .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            newPresetName = ""
                            showingSaveAlert = true
                        } label: {
                            Label("Save Current", systemImage: "plus.circle")
                        }
                    }

                    if settings.phonePresets.isEmpty {
                        Text("No presets saved yet.")
                            .customFont(.subheadline, appFont: settings.appFont)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(settings.phonePresets) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name)
                                        .customFont(.headline, weight: .bold, appFont: settings.appFont)
                                    Text("Slots: \(preset.slots.map { $0 == .empty ? "➕" : $0.rawValue }.joined(separator: ", "))")
                                        .customFont(.caption2, appFont: settings.appFont)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                
                                Button {
                                    slots = padded(preset.slots)
                                    if let lps = preset.longPressSlots {
                                        longPressSlots = padded(lps)
                                    } else {
                                        longPressSlots = Array(repeating: .empty, count: 5)
                                    }
                                    saveSlots()
                                    Haptic.play(.medium)
                                } label: {
                                    Text("Load")
                                        .customFont(.caption, weight: .bold, appFont: settings.appFont)
                                }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                
                                Button(role: .destructive) {
                                    settings.phonePresets.removeAll(where: { $0.id == preset.id })
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .padding(.leading, 8)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.quaternary)
                            )
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )
                .alert("Save Current Layout", isPresented: $showingSaveAlert) {
                    TextField("Preset Name", text: $newPresetName)
                    Button("Save") {
                        saveCurrentAsPreset()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Enter a name for this phone layout configuration.")
                }

                Button {
                    slots = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]
                    longPressSlots = Array(repeating: .empty, count: 5)
                    saveSlots()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text("Reset to Defaults")
                        .customFont(.headline, weight: .bold, appFont: settings.appFont)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("Phone Player Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSlots() }
        .sheet(isPresented: $showingSoundscapePicker) {
            SoundscapePickerView(engine: model.audioEngine.soundscapeMixer)
        }
        .sheet(isPresented: $showingChimeSettings) {
            ChimeSettingsView(engine: model.audioEngine.chimePlayer)
        }
    }

    private func loadSlots() {
        slots = padded(settings.phonePage)
        longPressSlots = padded(settings.phoneLongPressPage)
    }

    private func saveSlots() {
        settings.phonePage = slots
        settings.phoneLongPressPage = longPressSlots
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = PhonePreset(name: name, slots: slots, longPressSlots: longPressSlots)
        settings.phonePresets.append(preset)
        newPresetName = ""
    }

    private func padded(_ s: [WatchAction]) -> [WatchAction] {
        var out = s
        while out.count < 5 { out.append(.empty) }
        return Array(out.prefix(5))
    }
}

// A draggable palette chip showing the action icon + label.
private struct PaletteItem: View {
    let action: WatchAction
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 56, height: 56)
                let duration = action == .skipBackward ? settings.seekBackwardDuration : settings.seekForwardDuration
                Image(systemName: action.dynamicIconName(forDuration: duration))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text(action.rawValue)
                .customFont(.caption, appFont: settings.appFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 78)
        .accessibilityLabel(Text("Action: \(action.rawValue)"))
        .onDrag {
            NSItemProvider(object: NSString(string: action.rawValue))
        }
    }
}

// Faux Phone frame that previews the live layout.
private struct PhonePreviewCanvas: View {
    @Binding var slots: [WatchAction]
    var onChange: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(Color.black)
                )
            
            VStack(spacing: 16) {
                // Mock Artwork using AppIconThumbnail equivalent or simple styled headphones icon
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.tint)
                    )
                    .padding(.top, 20)

                VStack(spacing: 4) {
                    Text(String(localized: "Audiobook Title"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(String(localized: "Ch 1"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                // Mock Progress Bar
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 70, height: 4)
                        }
                }
                .padding(.horizontal, 24)

                // Transport Row (5 Slots)
                HStack(spacing: 6) {
                    ForEach(0..<5) { idx in
                        DropSlot(slot: $slots[idx], shape: .circle, onChange: onChange)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 260, height: 320)
    }
}

private struct DesignerControlBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Color.black.opacity(0.52))
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
    }
}

private struct DropSlot: View {
    enum SlotShape { case squircle, circle }

    @Binding var slot: WatchAction
    let shape: SlotShape
    var onChange: () -> Void

    @Environment(SettingsManager.self) private var settings
    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: width, height: height)
        .padding(max(0, (max(52, width + 12) - width) / 2))
        .frame(minWidth: 52, minHeight: 52)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { string, _ in
                if let raw = string as? String,
                   let action = WatchAction(rawValue: raw) {
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
        case .squircle: return 40
        case .circle:   return 38
        }
    }
    private var height: CGFloat { width }

    @ViewBuilder
    private var background: some View {
        let isEmpty = slot == .empty
        let dashed = StrokeStyle(lineWidth: 1.5, dash: [4, 4])
        let dashColor = Color.gray.opacity(isTargeted ? 0.9 : 0.7)

        switch shape {
        case .squircle:
            if isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(dashColor, style: dashed)
            } else {
                DesignerControlBackground(shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .circle:
            if isEmpty {
                Circle()
                    .stroke(dashColor, style: dashed)
            } else {
                DesignerControlBackground(shape: Circle())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if slot == .empty {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            let duration = slot == .skipBackward ? settings.seekBackwardDuration : settings.seekForwardDuration
            Image(systemName: slot.dynamicIconName(forDuration: duration))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
