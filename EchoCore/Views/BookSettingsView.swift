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
    /// Book Settings (a cover-themed sheet) gives rows the translucent sheet
    /// card; the Settings root keeps the neutral system look. Both put the
    /// rule in the footer, under the controls it explains.
    var coverThemed: Bool = false

    private var explanation: Text {
        Text(
            "Overrides apply to this book only. \u{201C}Inherit\u{201D} follows the global setting."
        )
    }

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

        } header: {
            if let headerTitle {
                Text(headerTitle)
            }
        } footer: {
            // The rule sits under the card it explains in both homes, at
            // the same footnote size as every other section footer (the
            // sheets set `\.font` to body size for their rows).
            explanation
                .settingsFooterStyle()
        }
        .listRowBackground(coverThemed ? CoverSheetRowBackground() : nil)
    }
}

/// Standalone book-info sheet, opened by tapping the player's eyebrow title.
struct BookSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var studyPlanPresentation: StudyPlanSheetPresentation?
    @State private var studyDeckGenerationPresentation: StudyDeckGenerationSheetPresentation?
    @State private var echoDeckBuilderExportURL: URL?
    @State private var readAlongStatus: String?
    @State private var readAlongRecoveryHint: String?

    var body: some View {
        CoverThemedSheet(theme: model.coverTheme) {
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
                            // Same accent as its sibling actions: all three
                            // rows act at once (open a sheet or share sheet).
                            // A Form draws a ShareLink's title in primary and
                            // ignores a tint on the title text, so the row
                            // takes the borderless button style, which draws
                            // its label in the accent. The full-width shape
                            // keeps the whole row tappable.
                            ShareLink(item: echoDeckBuilderExportURL) {
                                Label(
                                    "Make Flashcards in EchoDeckBuilder",
                                    systemImage: "square.and.arrow.up"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                        } else {
                            // On the wash a disabled Form button keeps a
                            // primary title, so it read as a live row in the
                            // wrong colour. Draw it plainly disabled and say
                            // what it needs.
                            Button {
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Make Flashcards in EchoDeckBuilder")
                                        Text("Needs this book's EPUB")
                                            .font(.footnote)
                                    }
                                } icon: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .foregroundStyle(.secondary)
                            }
                            .disabled(true)
                        }
                    #endif
                }
                .listRowBackground(CoverSheetRowBackground())

                // Headed like the sections around it, so the override card
                // does not float without a name.
                BookOverridesSections(
                    model: model,
                    headerTitle: String(localized: "This Book"),
                    coverThemed: true
                )

                // Read-along status: whether word-level (sidecar) highlighting is
                // active, or why it fell back to paragraph-level. Cross-platform
                // (no iOS-only dependency) so macOS gets parity. Lives here rather
                // than in the reader chrome to keep the reader UX untouched.
                // It is status, not a control, so it is a plain value row
                // ("Highlighting … Paragraph-level"), not an icon-led card
                // that looks tappable.
                if model.databaseService?.writer != nil, model.state.folderURL != nil {
                    Section {
                        LabeledContent("Highlighting") {
                            Text(readAlongStatus ?? String(localized: "Checking…"))
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("Read-Along")
                    } footer: {
                        // Only present when the state is user-fixable, and it
                        // names the action that fixes it rather than leaving
                        // the reason as a dead end.
                        if let readAlongRecoveryHint {
                            Text(readAlongRecoveryHint)
                                .settingsFooterStyle()
                        }
                    }
                    .listRowBackground(CoverSheetRowBackground())
                }

                #if os(iOS)
                    // Narration QA review — only for a loaded book. The pass itself
                    // reports "no rendered audio" if the book isn't narrated yet.
                    if let db = model.databaseService?.writer,
                        let audiobookID = model.bookIdentityURL?.absoluteString
                    {
                        Section("Narration") {
                            NarrationQASettingsLink(db: db, audiobookID: audiobookID)
                                .id(audiobookID)
                        }
                        .listRowBackground(CoverSheetRowBackground())
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
        .task(id: readAlongRefreshKey) {
            computeReadAlongStatus()
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

    /// Recomputes when the book changes or a document (re)ingests, so a
    /// just-imported sidecar's status is reflected without reopening the sheet.
    private var readAlongRefreshKey: String {
        "\(model.state.folderURL?.absoluteString ?? "")#\(model.state.documentIngestionTrigger)"
    }

    private func computeReadAlongStatus() {
        guard let db = model.databaseService?.writer,
            let audiobookID = model.state.folderURL?.absoluteString
        else {
            readAlongStatus = nil
            readAlongRecoveryHint = nil
            return
        }
        readAlongStatus = ReadAlongStatusResolver.statusLine(
            audiobookID: audiobookID, writer: db)
        readAlongRecoveryHint = ReadAlongStatusResolver.recoveryHint(audiobookID: audiobookID)
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

#if os(iOS)
    private struct NarrationQASettingsLink: View {
        @State private var qaModel: NarrationQAReviewModel

        init(db: DatabaseWriter, audiobookID: String) {
            _qaModel = State(
                initialValue: NarrationQAReviewModel(db: db, audiobookID: audiobookID))
        }

        var body: some View {
            NavigationLink {
                NarrationQAReviewView(model: qaModel)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        "Narration QA",
                        systemImage: "waveform.badge.magnifyingglass")
                    if qaModel.hasPronunciationReviewIssues {
                        Label(
                            "Pronunciation review available",
                            systemImage: "textformat.abc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .task { qaModel.load() }
        }
    }
#endif

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
            let folderURL = model.folderURL,
            let audiobookID = model.bookIdentityURL?.absoluteString
        else {
            return nil
        }

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
            let folderURL = model.folderURL,
            let audiobookID = model.bookIdentityURL?.absoluteString
        else {
            return nil
        }

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
        // Resolve provider state on the MainActor, then capture Sendable values.
        let store = AIProviderSettingsStore()
        let preference = store.generatorPreference
        let fmAvailable = StudyDeckFMAvailability.isAvailable
        let clients: (primary: AnthropicMessagesClient, brief: AnthropicMessagesClient)?
        if store.hasConfiguredCloudProvider,
            let config = store.config,
            let token = store.token(for: config.preset)
        {
            clients = AnthropicMessagesClient.clients(config: config, token: token)
        } else {
            clients = nil
        }

        let providerClients = clients
        let makeGenerator:
            (@escaping @Sendable (Int, Int) -> Void) ->
                (any StudyDeckGenerating)? = { progress in
                    let cloud: (@Sendable () -> any StudyDeckGenerating)?
                    if let pair = providerClients {
                        cloud = {
                            AnthropicStudyDeckGenerator(
                                client: pair.primary,
                                briefClient: pair.brief,
                                progress: progress
                            )
                        }
                    } else {
                        cloud = nil
                    }
                    return StudyDeckGeneratorFactory.makeForUI(
                        preference: preference,
                        fmAvailable: fmAvailable,
                        cloud: cloud
                    )
                }
        let model = StudyDeckGenerationViewModel(
            audiobookID: presentation.audiobookID,
            bookTitle: presentation.bookTitle,
            db: presentation.db,
            makeGenerator: makeGenerator
        )
        _viewModel = State(wrappedValue: model)
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
