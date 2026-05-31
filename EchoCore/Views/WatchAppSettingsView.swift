import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WatchAppSettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var page1Slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var page2Slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var page3Slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var page4Slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var page5Slots: [WatchAction] = Array(repeating: .empty, count: 5)
    @State private var selectedPage: Int = 0
    @State private var showingSaveAlert = false
    @State private var newPresetName = ""

    private let palette: [WatchAction] = [
        .playPause, .skipForward, .skipBackward, .nextTrack,
        .previousTrack, .nextSection, .previousSection,
        .loopMode, .speed, .sleepTimer, .bookmark
    ]

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Digital Crown Control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Digital Crown Control")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    Picker("Digital Crown", selection: $settings.crownAction) {
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
                    .onChange(of: settings.crownAction) { _, _ in
                        model.syncToWatch()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume Sensitivity")
                            .customFont(.caption, appFont: settings.appFont)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $settings.crownVolumeSensitivity, in: 0.01...0.1, step: 0.01)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(settings.crownVolumeSensitivity, specifier: "%.2f")×")
                            .customFont(.caption2, appFont: settings.appFont)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scrubbing Sensitivity")
                            .customFont(.caption, appFont: settings.appFont)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $settings.crownScrubSensitivity, in: 0.1...1.0, step: 0.1)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(settings.crownScrubSensitivity, specifier: "%.1f")×")
                            .customFont(.caption2, appFont: settings.appFont)
                            .foregroundStyle(.tertiary)
                    }
                }

                // MARK: Haptics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haptics")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    Toggle("Button Haptics", isOn: Binding(
                        get: { settings.isHapticFeedbackEnabled },
                        set: {
                            settings.isHapticFeedbackEnabled = $0
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
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    Stepper(value: $settings.watchQuickBookmarkTimeoutSeconds, in: 1...15) {
                        HStack {
                            Label("Quick Bookmark", systemImage: "timer")
                            Spacer()
                            Text("\(settings.watchQuickBookmarkTimeoutSeconds)s")
                                .customFont(.body, appFont: settings.appFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.watchQuickBookmarkTimeoutSeconds) { _, _ in
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
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Picker("Linear Bar", selection: $settings.linearBarMode) {
                            Text("Chapter Progress").tag("chapter")
                            Text("Total Book Progress").tag("total")
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.linearBarMode) { _, _ in
                            model.syncToWatch()
                        }

                        Toggle("Show Linear Bar", isOn: Binding(
                            get: { !settings.linearBarHidden },
                            set: { settings.linearBarHidden = !$0 }
                        ))
                        .onChange(of: settings.linearBarHidden) { _, _ in
                            model.syncToWatch()
                        }

                        Divider()

                        Picker("Circular Ring", selection: $settings.circularRingMode) {
                            Text("Chapter Progress").tag("chapter")
                            Text("Total Book Progress").tag("total")
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.circularRingMode) { _, _ in
                            model.syncToWatch()
                        }

                        Toggle("Show Circular Ring", isOn: Binding(
                            get: { !settings.circularRingHidden },
                            set: { settings.circularRingHidden = !$0 }
                        ))
                        .onChange(of: settings.circularRingHidden) { _, _ in
                            model.syncToWatch()
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Artwork Layout
                VStack(alignment: .leading, spacing: 8) {
                    Text("Watch Appearance")
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Face Style")
                                .customFont(.caption, appFont: settings.appFont)
                                .foregroundStyle(.secondary)

                            Picker("Face Style", selection: $settings.watchArtworkLayout) {
                                Label("Full Face", systemImage: "rectangle.expand.vertical").tag("immersive")
                                Label("Classic", systemImage: "photo").tag("classic")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: settings.watchArtworkLayout) { _, _ in
                                model.syncToWatch()
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Classic Background")
                                .customFont(.caption, appFont: settings.appFont)
                                .foregroundStyle(.secondary)

                            Picker("Classic Background", selection: $settings.watchBackgroundStyle) {
                                Text("Blurred").tag("artwork")
                                Text("Black").tag("black")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: settings.watchBackgroundStyle) { _, _ in
                                model.syncToWatch()
                            }
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
                        .customFont(.title3, weight: .semibold, appFont: settings.appFont)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        Text("Page \(selectedPage + 1) of 5")
                            .customFont(.subheadline, weight: .medium, appFont: settings.appFont)
                            .foregroundStyle(.secondary)
                            
                        TabView(selection: $selectedPage) {
                            WatchPreviewCanvas(slots: $page1Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(0)
                            WatchPreviewCanvas(slots: $page2Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(1)
                            WatchPreviewCanvas(slots: $page3Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(2)
                            WatchPreviewCanvas(slots: $page4Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(3)
                            WatchPreviewCanvas(slots: $page5Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(4)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .frame(height: 320)
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
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

                    if settings.watchPresets.isEmpty {
                        Text("No presets saved yet.")
                            .customFont(.subheadline, appFont: settings.appFont)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(settings.watchPresets) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name)
                                        .customFont(.headline, weight: .bold, appFont: settings.appFont)
                                    Text("P1: \(preset.page1.map { $0 == .empty ? "➕" : $0.rawValue }.joined(separator: ", "))")
                                        .customFont(.caption2, appFont: settings.appFont)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                
                                Button {
                                    page1Slots = padded(preset.page1)
                                    page2Slots = padded(preset.page2)
                                    if let p3 = preset.page3 { page3Slots = padded(p3) } else { page3Slots = Array(repeating: .empty, count: 5) }
                                    if let p4 = preset.page4 { page4Slots = padded(p4) } else { page4Slots = Array(repeating: .empty, count: 5) }
                                    if let p5 = preset.page5 { page5Slots = padded(p5) } else { page5Slots = Array(repeating: .empty, count: 5) }
                                    saveSlots()
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                } label: {
                                    Text("Load")
                                        .customFont(.caption, weight: .bold, appFont: settings.appFont)
                                }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                
                                Button(role: .destructive) {
                                    settings.watchPresets.removeAll(where: { $0.id == preset.id })
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
                    Text("Enter a name for this watch layout configuration.")
                }

                // MARK: Force Sync
                Button {
                    saveSlots()
                    model.syncToWatch()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text("Force Sync to Watch")
                        .customFont(.headline, weight: .bold, appFont: settings.appFont)
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
        page1Slots = padded(settings.watchPage1)
        page2Slots = padded(settings.watchPage2)
        page3Slots = padded(settings.watchPage3)
        page4Slots = padded(settings.watchPage4)
        page5Slots = padded(settings.watchPage5)
    }

    private func saveSlots() {
        settings.watchPage1 = page1Slots
        settings.watchPage2 = page2Slots
        settings.watchPage3 = page3Slots
        settings.watchPage4 = page4Slots
        settings.watchPage5 = page5Slots
        model.syncToWatch()
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = WatchPreset(name: name, page1: page1Slots, page2: page2Slots, page3: page3Slots, page4: page4Slots, page5: page5Slots)
        settings.watchPresets.append(preset)
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

// Faux Apple Watch frame that previews the live layout. This view is laid out
// to match the breathing room of the real watch UI: top-left + top-right
// slots are anchored to the very top, with the artwork-and-title block
// vertically centered and a 3-button transport row at the bottom.
private struct WatchPreviewCanvas: View {
    @Binding var slots: [WatchAction]
    let backgroundStyle: String
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

            if backgroundStyle == "artwork" {
                AppIconThumbnail(size: 190)
                    .blur(radius: 22)
                    .opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            }

            VStack(spacing: 8) {
                // Artwork (real app icon)
                AppIconThumbnail(size: 64)
                    .padding(.top, 4)

                Text(String(localized: "Chapter 1"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.horizontal, 8)

                HStack(spacing: 8) {
                    DropSlot(slot: $slots[2], shape: .circle, onChange: onChange)
                    DropSlot(slot: $slots[3], shape: .circle,   onChange: onChange)
                    DropSlot(slot: $slots[4], shape: .circle, onChange: onChange)
                }
                .padding(.top, 2)
                .padding(.vertical, 4)
                .background {
                    DesignerControlBackground(shape: Capsule())
                }
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
    enum SlotShape { case squircle, circle, topGlyph }

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
        case .squircle: return 46
        case .circle:   return 44
        case .topGlyph: return 36
        }
    }
    private var height: CGFloat { width }

    @ViewBuilder
    private var background: some View {
        let isEmpty = slot == .empty
        let dashed = StrokeStyle(lineWidth: 2, dash: [5, 5])
        let dashColor = Color.gray.opacity(isTargeted ? 0.9 : 0.7)

        switch shape {
        case .squircle:
            if isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(dashColor, style: dashed)
            } else {
                DesignerControlBackground(shape: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .circle:
            if isEmpty {
                Circle()
                    .stroke(dashColor, style: dashed)
            } else {
                DesignerControlBackground(shape: Circle())
            }
        case .topGlyph:
            // Always show a placeholder outline in the designer so slots [0]
            // and [1] are visible even when empty. The real watch UI keeps
            // these invisible when empty — that's handled on the watch side.
            if isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                .font(.system(size: shape == .topGlyph ? 12 : 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            let duration = slot == .skipBackward ? settings.seekBackwardDuration : settings.seekForwardDuration
            Image(systemName: slot.dynamicIconName(forDuration: duration))
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
