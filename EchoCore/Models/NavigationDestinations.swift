// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Programmatic navigation destinations across Echo.
///
/// Each case maps to a view that can be pushed onto a tab's `NavigationStack`
/// via `NavigationStack(path:)` + `.navigationDestination(for:)` in
/// `RootTabView`.  Use placeholders (simple `Text` views) for sub-views that
/// are currently `private` inside `SettingsView`; those live in a follow-up
/// extraction task (see also: `Task 2.2` report).
enum NavigationDestination: Hashable, Codable {
    case settingsAppearance
    case settingsAudio
    case settingsChimes
    case settingsSmartRewind
    case settingsPhonePlayer
    case settingsWatchApp
    case settingsProTranscripts
    /// Navigate to a specific chapter by index.
    case chapter(Int)

    @ViewBuilder
    func view(using model: PlayerModel) -> some View {
        switch self {
        case .settingsAppearance:
            SettingsAppearanceView()
        case .settingsAudio:
            SettingsPlaceholder(title: "Audio Settings")
        case .settingsChimes:
            ChimeSettingsView(engine: nil)
        case .settingsSmartRewind:
            SmartRewindSettingsView()
        case .settingsPhonePlayer:
            PhonePlayerSettingsView()
        case .settingsWatchApp:
            WatchAppSettingsView()
        case .settingsProTranscripts:
            ProTranscriptsSettingsView()
        case .chapter(let index):
            ChapterDestinationPlaceholder(chapterIndex: index)
        }
    }
}

// MARK: - Placeholder

/// Temporary stand-in for sub-views that are still `private` inside
/// `SettingsView` and have not yet been extracted into their own file.
/// Temporary stand-in for chapter navigation — shows which chapter index
/// was requested until the full chapter-detail view is extracted.
private struct ChapterDestinationPlaceholder: View {
    let chapterIndex: Int

    var body: some View {
        Form {
            Section {
                Text("Chapter \(chapterIndex + 1)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Chapter \(chapterIndex + 1)")
    }
}

private struct SettingsPlaceholder: View {
    let title: String

    var body: some View {
        Form {
            Section {
                Text("\(title) — coming soon")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
    }
}
