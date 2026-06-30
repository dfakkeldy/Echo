// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI

/// The per-book override controls, reusable in two homes (audit E1):
/// the top of the unified Settings sheet, and the standalone book-info sheet
/// opened from the player's eyebrow. "Inherit" on each picker is the
/// per-row "use global" affordance.
struct BookOverridesSections: View {
    @Bindable var model: PlayerModel
    /// Shown as the section header; pass the book title in the unified
    /// Settings sheet so the section reads "Emotional Design — overrides global".
    var headerTitle: String? = nil

    @State private var isUploading = false
    @State private var uploadAlert: (title: String, message: String)?

    var body: some View {
        Section {
            Picker(
                "Font Override",
                selection: Binding(
                    get: { model.bookFontOverride ?? "inherit" },
                    set: { newValue in
                        model.updateBookFontOverride(newValue == "inherit" ? nil : newValue)
                    }
                )
            ) {
                Text("Inherit Global").tag("inherit")
                Text("Lexend").tag("Lexend")
                Text("OpenDyslexic").tag("OpenDyslexic")
                Text("System").tag("System")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Play Bookmarks Inline")
                    .font(.subheadline)
                Picker(
                    "Bookmarks Inline Mode",
                    selection: Binding(
                        get: { model.bookPlayBookmarksInlineOverride ?? "inherit" },
                        set: { newValue in
                            model.updateBookPlayBookmarksInlineOverride(
                                newValue == "inherit" ? nil : newValue)
                        }
                    )
                ) {
                    Text("Inherit").tag("inherit")
                    Text("Always On").tag("alwaysOn")
                    Text("Always Off").tag("alwaysOff")
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Volume Boost")
                    .font(.subheadline)
                Picker(
                    "Volume Boost Mode",
                    selection: Binding(
                        get: { model.bookVolumeBoostOverride ?? "inherit" },
                        set: { newValue in
                            model.updateBookVolumeBoostOverride(
                                newValue == "inherit" ? nil : newValue)
                        }
                    )
                ) {
                    Text("Inherit").tag("inherit")
                    Text("Always On").tag("alwaysOn")
                    Text("Always Off").tag("alwaysOff")
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)

            Button {
                Task { await shareAlignment() }
            } label: {
                if isUploading {
                    ProgressView()
                } else {
                    Label("Share Alignment to CloudKit", systemImage: "icloud.and.arrow.up")
                }
            }
            .disabled(isUploading)
            // Presentation modifiers belong on a plain row view, not the
            // Section, so both Form homes present the alert reliably.
            .alert(
                uploadAlert?.title ?? "",
                isPresented: Binding(
                    get: { uploadAlert != nil },
                    set: { if !$0 { uploadAlert = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                if let message = uploadAlert?.message {
                    Text(message)
                }
            }
        } header: {
            if let headerTitle {
                Text(headerTitle)
            }
        } footer: {
            Text(
                "Overrides apply to this book only. \u{201C}Inherit\u{201D} follows the global setting."
            )
        }
    }

    private func shareAlignment() async {
        guard let db = model.databaseService?.writer,
            let audiobookID = model.state.folderURL?.absoluteString
        else {
            uploadAlert = ("Error", "No book loaded.")
            return
        }

        let folderURL = URL(string: audiobookID) ?? URL(fileURLWithPath: audiobookID)
        let record = try? AudiobookDAO(db: db).get(audiobookID)
        let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
            folderURL: folderURL, record: record)
        let fallbackDuration =
            model.state.totalBookDuration > 0
            ? model.state.totalBookDuration : (model.state.durationSeconds ?? 0.0)
        let duration = (record?.duration).flatMap { $0 > 0 ? $0 : nil } ?? fallbackDuration

        isUploading = true
        defer { isUploading = false }

        do {
            let syncService = CloudKitSyncService(db: db)
            let result = try await syncService.uploadAnchors(
                audiobookID: audiobookID, title: title, author: author, duration: duration)
            switch result {
            case .uploaded, .merged:
                uploadAlert = ("Success", "Alignment anchors uploaded and shared successfully.")
            case .noUploadableAnchors:
                uploadAlert = (
                    "No Alignment Anchors",
                    "This book does not have uploadable alignment anchors yet."
                )
            case .rateLimited:
                uploadAlert = (
                    "Try Again Later",
                    "Alignment sharing is temporarily rate limited for this book."
                )
            }
        } catch {
            uploadAlert = ("Upload Failed", error.localizedDescription)
        }
    }
}

/// Standalone book-info sheet, opened by tapping the player's eyebrow title.
struct BookSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var studyPlanPresentation: StudyPlanSheetPresentation?
    @State private var studyDeckGenerationPresentation: StudyDeckGenerationSheetPresentation?
    @State private var echoDeckBuilderExportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Study") {
                    Button("Study Plan", systemImage: "rectangle.stack.badge.play") {
                        studyPlanPresentation = StudyPlanSheetPresentation(model: model)
                    }
                    .disabled(model.databaseService == nil || model.folderURL == nil)

                    Button("Generate Study Deck", systemImage: "rectangle.stack.badge.plus") {
                        studyDeckGenerationPresentation = StudyDeckGenerationSheetPresentation(
                            model: model
                        )
                    }
                    .disabled(model.databaseService == nil || model.folderURL == nil)

                    #if os(iOS)
                        // Only EPUB-backed books can be sent to EchoDeckBuilder.
                        // Gate on a real resolved .epub (not `hasEPUB`, which is
                        // also true for parsed PDF / .md / .txt books that have no
                        // .epub file) so the row is disabled — like the macOS
                        // sibling — rather than enabled-but-always-failing.
                        if let echoDeckBuilderExportURL {
                            ShareLink(item: echoDeckBuilderExportURL) {
                                Label(
                                    "Make Flashcards in EchoDeckBuilder",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                        } else {
                            Button(
                                "Make Flashcards in EchoDeckBuilder",
                                systemImage: "square.and.arrow.up"
                            ) {}
                            .disabled(true)
                        }
                    #endif
                }

                BookOverridesSections(model: model)

                #if os(iOS)
                    // Narration QA review — only for a loaded book. The pass itself
                    // reports "no rendered audio" if the book isn't narrated yet.
                    if let db = model.databaseService?.writer,
                        let audiobookID = model.state.folderURL?.absoluteString
                    {
                        Section("Narration") {
                            NavigationLink {
                                NarrationQAReviewView(
                                    model: NarrationQAReviewModel(db: db, audiobookID: audiobookID))
                            } label: {
                                Label(
                                    "Narration QA",
                                    systemImage: "waveform.badge.magnifyingglass")
                            }
                        }
                    }
                #endif
            }
            .navigationTitle("Book Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $studyPlanPresentation) { presentation in
            StudyPlanSheetHost(presentation: presentation)
        }
        .sheet(item: $studyDeckGenerationPresentation) { presentation in
            StudyDeckGenerationSheetHost(presentation: presentation)
        }
        .task(id: echoDeckBuilderRefreshKey) {
            refreshEchoDeckBuilderExportURL()
        }
        .environment(
            \.font,
            model.resolvedAppFont == SettingsManager.systemFontName
                ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
    }

    private var canMakeFlashcardsInEchoDeckBuilder: Bool {
        model.folderURL != nil && model.hasEPUB
    }

    private var echoDeckBuilderRefreshKey: EchoDeckBuilderRefreshKey {
        EchoDeckBuilderRefreshKey(
            folderURL: model.folderURL,
            sourceDocumentURL: model.state.sourceDocumentURL,
            currentTrackURL: currentTrackURL,
            documentIngestionTrigger: model.state.documentIngestionTrigger
        )
    }

    private var currentTrackURL: URL? {
        model.tracks.indices.contains(model.currentIndex)
            ? model.tracks[model.currentIndex].url
            : nil
    }

    private func refreshEchoDeckBuilderExportURL() {
        guard canMakeFlashcardsInEchoDeckBuilder else {
            echoDeckBuilderExportURL = nil
            return
        }

        // Resolution failure (e.g. a PDF/.md/.txt book with no .epub on disk)
        // simply leaves the row disabled; there is no action to surface an error.
        echoDeckBuilderExportURL = try? EchoDeckBuilderHandoffService.currentEPUBURL(
            bookURL: model.folderURL,
            sourceDocumentURL: model.state.sourceDocumentURL,
            currentTrackURL: currentTrackURL
        )
    }
}

private struct EchoDeckBuilderRefreshKey: Equatable {
    var folderURL: URL?
    var sourceDocumentURL: URL?
    var currentTrackURL: URL?
    var documentIngestionTrigger: Int
}

private struct StudyPlanSheetPresentation: Identifiable {
    let audiobookID: String
    let bookTitle: String
    let db: DatabaseWriter

    var id: String { audiobookID }

    init?(model: PlayerModel) {
        guard let db = model.databaseService?.writer,
            let folderURL = model.folderURL
        else {
            return nil
        }

        let audiobookID = folderURL.absoluteString
        self.audiobookID = audiobookID
        self.bookTitle = StudyPlanBookTitleResolver.resolve(
            audiobookID: audiobookID,
            folderURL: folderURL,
            db: db,
            currentTitle: model.currentTitle
        )
        self.db = db
    }
}

private struct StudyPlanSheetHost: View {
    @State private var viewModel: StudyPlanViewModel

    init(presentation: StudyPlanSheetPresentation) {
        _viewModel = State(
            wrappedValue: StudyPlanViewModel(
                audiobookID: presentation.audiobookID,
                bookTitle: presentation.bookTitle,
                db: presentation.db
            )
        )
    }

    var body: some View {
        StudyPlanSheet(viewModel: viewModel)
    }
}

private struct StudyDeckGenerationSheetPresentation: Identifiable {
    let audiobookID: String
    let bookTitle: String
    let db: DatabaseWriter

    var id: String { audiobookID }

    init?(model: PlayerModel) {
        guard let db = model.databaseService?.writer,
            let folderURL = model.folderURL
        else {
            return nil
        }

        let audiobookID = folderURL.absoluteString
        self.audiobookID = audiobookID
        self.bookTitle = StudyPlanBookTitleResolver.resolve(
            audiobookID: audiobookID,
            folderURL: folderURL,
            db: db,
            currentTitle: model.currentTitle
        )
        self.db = db
    }
}

private struct StudyDeckGenerationSheetHost: View {
    @State private var viewModel: StudyDeckGenerationViewModel

    init(presentation: StudyDeckGenerationSheetPresentation) {
        // Read key + model on the MainActor (View.init is @MainActor). Capture
        // plain Strings so the @Sendable closure never crosses actor boundaries
        // with a @MainActor-isolated object.
        let store = APIKeyStore()
        let hasKey = store.hasKey
        let key = store.anthropicKey ?? ""
        let model = AICardGenerationSettings.selectedModel
        let generator = StudyDeckGeneratorFactory.make(
            preference: AICardGenerationSettings.providerPreference,
            hasKey: hasKey,
            fmAvailable: StudyDeckFMAvailability.isAvailable
        ) {
            AnthropicStudyDeckGenerator(
                client: AnthropicMessagesClient(apiKey: key, model: model))
        }
        _viewModel = State(
            wrappedValue: StudyDeckGenerationViewModel(
                audiobookID: presentation.audiobookID,
                bookTitle: presentation.bookTitle,
                db: presentation.db,
                generator: generator
            )
        )
    }

    var body: some View {
        StudyDeckGenerationSheet(viewModel: viewModel)
    }
}

enum StudyPlanBookTitleResolver {
    static func resolve(
        audiobookID: String,
        folderURL: URL,
        db: DatabaseWriter,
        currentTitle: String
    ) -> String {
        let audiobook = try? AudiobookDAO(db: db).get(audiobookID)
        return resolve(
            storedTitle: audiobook?.title,
            folderTitle: folderURL.lastPathComponent,
            currentTitle: currentTitle
        )
    }

    static func resolve(
        storedTitle: String?,
        folderTitle: String,
        currentTitle: String
    ) -> String {
        normalizedTitle(storedTitle)
            ?? normalizedTitle(folderTitle)
            ?? normalizedTitle(currentTitle)
            ?? "Book"
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
