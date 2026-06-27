// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Hosts a *parsed* PDF book's two reading surfaces — the visual page
/// (`PDFDocumentView`) and the reflow card feed (`ReaderTab`) — behind a
/// per-book page⇄reflow toggle. Only used when both surfaces are available
/// (see `ReaderSurfaceResolver.offersToggle`).
struct PDFReadingSurface: View {
    let folderURL: URL
    @State private var mode: ReaderSurfaceMode = .page

    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    private var audiobookID: String { folderURL.absoluteString }

    /// The saved voice preference, or the catalog default — mirrors NowPlayingTab.
    private var preferredVoice: NarrationVoice {
        let savedID = settings.narrationVoiceID
        guard !savedID.isEmpty else { return VoiceCatalog.default }
        return VoiceCatalog.voice(for: VoiceID(savedID)) ?? VoiceCatalog.default
    }

    /// True only when the same conditions NowPlayingTab gates the nudge on:
    /// the book has narratable blocks, no audio loaded, and narration isn't running.
    private var showsNarrateButton: Bool {
        model.isNarrationBook
            && NarrationCapability.supportsOnDeviceNarration
            && NarrationNudgePolicy.showsNudge(
                tracksEmpty: model.tracks.isEmpty,
                isRunning: model.narrationPlaybackState.isRunning)
    }

    var body: some View {
        Group {
            switch mode {
            case .page:
                PDFDocumentView(folderURL: folderURL)
            case .reflow:
                ReaderTab(folderURL: folderURL)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Reading mode", selection: $mode) {
                Text("Page").tag(ReaderSurfaceMode.page)
                Text("Reflow").tag(ReaderSurfaceMode.reflow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityLabel(Text("Reading mode"))
        }
        .toolbar {
            // Show a "Narrate" toolbar item only when this PDF has narratable
            // blocks and no audio yet (same gate as NowPlayingTab's nudge).
            // Placed in the navigation bar so it never overlaps the page/reflow
            // Picker which lives in the safeAreaInset(edge: .top) below the bar.
            if showsNarrateButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        settings.narrationVoiceID = preferredVoice.id.rawValue
                        model.startNarrationPlayback(voice: preferredVoice)
                    } label: {
                        Label("Narrate", systemImage: "play.circle")
                    }
                    .accessibilityHint(Text("Start on-device narration for this book"))
                }
            }
        }
        // Re-seed the toggle whenever the book changes; `.page` default avoids a flash.
        .task(id: audiobookID) {
            mode = BookPreferencesService.loadPDFViewMode(for: audiobookID)
        }
        .onChange(of: mode) { _, newMode in
            BookPreferencesService.savePDFViewMode(newMode, for: audiobookID)
        }
    }
}
