import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    var onShowFidget: (() -> Void)?

    var body: some View {
        HStack {
            loopModeButton
            Spacer()
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            fidgetButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Mark Passage

    private var markPassageButton: some View {
        Button {
            model.markPassageAtCurrentTime()
            Haptic.play(.light)
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.title3)
            }
        }
        .accessibilityLabel(Text("Mark passage for later"))
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Shared chip treatment

    /// Audit B2: active state is carried by a filled chip (shape), not color
    /// alone. 44pt target either way.
    private func utilityChip<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 44, height: 44)
            .background(isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Rectangle())
            .foregroundStyle(isActive ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor) : AnyShapeStyle(.secondary))
    }

    private func utilityTextChip(isActive: Bool, _ text: String) -> some View {
        Text(text)
            .customFont(.headline)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Rectangle())
            .foregroundStyle(isActive ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor) : AnyShapeStyle(.secondary))
    }

    // MARK: - Loop Mode

    private var loopModeButton: some View {
        Button {
            model.cycleLoopMode()
            Haptic.play(.medium)
        } label: {
            utilityChip(isActive: model.loopMode != .off) {
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
            }
        }
        .accessibilityLabel(Text("Loop mode"))
        .accessibilityValue(Text({
            switch model.loopMode {
            case .off: return String(localized: "Off")
            case .chapter: return String(localized: "Chapter")
            case .bookmark: return String(localized: "Bookmark")
            }
        }()))
    }

    // MARK: - Speed

    private var speedLabel: String {
        switch model.speed {
        case 0.75: return String(localized: "0.75×")
        case 1.0:  return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5:  return String(localized: "1.5×")
        case 1.75: return String(localized: "1.75×")
        case 2.0:  return String(localized: "2.0×")
        default:   return model.speed.formatted(.number.precision(.fractionLength(1))) + "×"
        }
    }


    private var speedButton: some View {
        Button {
            let speeds = SettingsManager.Defaults.speedPresets
            if let index = speeds.firstIndex(of: model.speed) {
                let nextIndex = (index + 1) % speeds.count
                model.setSpeed(speeds[nextIndex])
            } else {
                model.setSpeed(1.0)
            }
        } label: {
            utilityTextChip(isActive: model.speed != 1.0, speedLabel)
        }
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(speedLabel))
        .onChange(of: model.speed) { _, newSpeed in
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Speed \(newSpeed.formatted(.number.precision(.fractionLength(1))))×"))
        }
    }


    // MARK: - Timeline / View Toggle

    private var timelineButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                switch model.selectedTab {
                case .nowPlaying:
                    model.selectedTab = .timeline
                case .timeline:
                    model.selectedTab = .read
                case .read:
                    model.selectedTab = .stats
                case .stats:
                    model.selectedTab = .timeline
                }
            }
            Haptic.play(.medium)
        } label: {
            utilityChip(isActive: model.selectedTab == .timeline || model.selectedTab == .read) {
                Image(systemName: "list.bullet")
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text("Toggle chapters list"))
        .accessibilityValue(Text(model.selectedTab == .nowPlaying
            ? String(localized: "Player")
            : model.selectedTab == .timeline ? String(localized: "Timeline") : String(localized: "Reader")))
        .accessibilityAddTraits((model.selectedTab == .timeline || model.selectedTab == .read) ? .isSelected : [])
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Fidget

    private var fidgetButton: some View {
        Button {
            onShowFidget?()
            Haptic.play(.light)
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text("Fidget tools"))
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Bookmark

    private var addBookmarkButton: some View {
        Button {
            if let draft = model.bookmarkDraftAtCurrentTime() {
                onCreateBookmark?(draft)
                Haptic.play(.medium)
            }
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: "bookmark.fill")
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text("Add bookmark at current time"))
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - EPUB Player Controls

    private var skipBackwardButton: some View {
        Button {
            model.seek(toSeconds: max(0, model.currentPlaybackTime - 5.0))
            Haptic.play(.light)
        } label: {
            Image(systemName: "gobackward.5")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Skip backward 5 seconds"))
        .disabled(model.tracks.isEmpty)
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlayPause()
            Haptic.play(.medium)
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.title)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(model.isPlaying ? "Pause" : "Play"))
        .disabled(model.tracks.isEmpty)
    }

    private var skipForwardButton: some View {
        Button {
            let duration = model.durationSeconds ?? .infinity
            model.seek(toSeconds: min(duration, model.currentPlaybackTime + 5.0))
            Haptic.play(.light)
        } label: {
            Image(systemName: "goforward.5")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Skip forward 5 seconds"))
        .disabled(model.tracks.isEmpty)
    }
}
