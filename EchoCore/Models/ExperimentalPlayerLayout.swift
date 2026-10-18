// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Anchor slots for the experimental player's floating buttons (spec §5.2).
enum PlayerSnapZone: String, Codable, CaseIterable {
    case upperLeading, upperTrailing
    case midLeading, midTrailing
    case lowerLeading, lowerCenter, lowerTrailing
}

/// One configured floating button: which action, which zone, and a bounded
/// fine-tune offset in points from the zone's anchor.
struct ExperimentalPlayerButton: Codable, Equatable, Identifiable {
    var action: WatchAction
    var zone: PlayerSnapZone
    var offset: CGSize = .zero

    var id: String { action.rawValue }
}

/// The persisted button arrangement. Decode failures always fall back to
/// `defaultLayout` — a corrupt blob must never blank the player's controls.
struct ExperimentalPlayerLayout: Codable, Equatable {
    var version: Int = 1
    var buttons: [ExperimentalPlayerButton]

    static let defaultLayout = ExperimentalPlayerLayout(buttons: [
        ExperimentalPlayerButton(action: .skipBackward, zone: .lowerLeading),
        ExperimentalPlayerButton(action: .playPause, zone: .lowerCenter),
        ExperimentalPlayerButton(action: .skipForward, zone: .lowerTrailing),
        ExperimentalPlayerButton(action: .bookmark, zone: .midLeading),
        ExperimentalPlayerButton(action: .speed, zone: .midTrailing),
    ])

    static func decode(_ data: Data) -> ExperimentalPlayerLayout {
        guard !data.isEmpty,
            let layout = try? JSONDecoder().decode(ExperimentalPlayerLayout.self, from: data),
            !layout.buttons.isEmpty
        else { return defaultLayout }
        return layout
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Actions eligible for a new button: not already configured, and not the
    /// placeholder cases (`empty`) or phone-non-actions (`pomodoro` renders as a
    /// blank slot in the classic transport bar — see TransportControlsView).
    var availableActions: [WatchAction] {
        let used = Set(buttons.map(\.action))
        return WatchAction.allCases.filter {
            !used.contains($0) && $0 != .empty && $0 != .pomodoro
        }
    }

    func adding(_ action: WatchAction) -> ExperimentalPlayerLayout {
        guard !buttons.contains(where: { $0.action == action }) else { return self }
        let occupied = Set(buttons.map(\.zone))
        let zone = PlayerSnapZone.allCases.first { !occupied.contains($0) } ?? .lowerCenter
        var copy = self
        copy.buttons.append(ExperimentalPlayerButton(action: action, zone: zone))
        return copy
    }

    func removing(_ action: WatchAction) -> ExperimentalPlayerLayout {
        var copy = self
        copy.buttons.removeAll { $0.action == action }
        return copy
    }

    func moving(
        _ action: WatchAction, to zone: PlayerSnapZone, offset: CGSize
    ) -> ExperimentalPlayerLayout {
        var copy = self
        guard let index = copy.buttons.firstIndex(where: { $0.action == action }) else { return self }
        copy.buttons[index].zone = zone
        copy.buttons[index].offset = offset
        return copy
    }
}
