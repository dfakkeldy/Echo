// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct AutoExportSettingsRows: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var store
    @Environment(AutoExportService.self) private var autoExport
    @State private var showingFolderPicker = false
    @State private var showingPaywall = false
    /// Off when the host shows `AutoExportStatusText` as its section footer.
    private let showsStatus: Bool

    init(showsStatus: Bool = true) {
        self.showsStatus = showsStatus
    }

    var body: some View {
        Group {
            Toggle("Auto-Export Study Notes", isOn: enabledBinding)

            if settings.studyAutoExportEnabled {
                Button {
                    showingFolderPicker = true
                } label: {
                    LabeledContent("Export Folder") {
                        Text(folderLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            if showsStatus {
                AutoExportStatusText()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                autoExport.destinationPicked(url: url)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .export)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.studyAutoExportEnabled },
            set: { newValue in
                guard !newValue || store.isPro else {
                    showingPaywall = true
                    return
                }

                settings.studyAutoExportEnabled = newValue
                if newValue {
                    Task { await autoExport.enableAndBaseline() }
                }
            }
        )
    }

    private var folderLabel: String {
        if autoExport.needsFolderRepick { return "Folder unavailable - re-select" }
        guard let path = autoExport.destinationDisplayPath else { return "Choose..." }
        return URL(fileURLWithPath: path).lastPathComponent
    }

}

/// One line on what auto-export is doing; a row or a section footer.
struct AutoExportStatusText: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(AutoExportService.self) private var autoExport

    var body: some View {
        Text(statusText)
    }

    private var statusText: String {
        guard settings.studyAutoExportEnabled else {
            return "Mirrors notes, bookmarks, and flashcards to a folder you choose."
        }
        if autoExport.needsFolderRepick {
            return "The export folder is unavailable. Re-select it to resume."
        }
        if autoExport.destinationDisplayPath == nil {
            return "Choose a folder to start exporting."
        }
        if let error = autoExport.lastErrorSummary { return error }
        if let last = autoExport.lastExportAt {
            return "Last export \(last.formatted(.relative(presentation: .named)))."
        }
        return "Waiting for the first export."
    }
}
