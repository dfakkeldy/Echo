// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Hosts a *parsed* PDF book's two reading surfaces — the visual page
/// (`PDFDocumentView`) and the reflow card feed (`ReaderTab`) — behind a
/// per-book page⇄reflow toggle. Only used when both surfaces are available
/// (see `ReaderSurfaceResolver.offersToggle`).
struct PDFReadingSurface: View {
    let folderURL: URL
    @State private var mode: ReaderSurfaceMode = .page

    private var audiobookID: String { folderURL.absoluteString }

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
        // Re-seed the toggle whenever the book changes; `.page` default avoids a flash.
        .task(id: audiobookID) {
            mode = BookPreferencesService.loadPDFViewMode(for: audiobookID)
        }
        .onChange(of: mode) { _, newMode in
            BookPreferencesService.savePDFViewMode(newMode, for: audiobookID)
        }
    }
}
