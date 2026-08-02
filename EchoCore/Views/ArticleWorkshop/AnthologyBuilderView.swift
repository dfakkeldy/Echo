// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI
    import UniformTypeIdentifiers

    struct AnthologyBuilderView: View {
        let viewModel: AnthologyBuilderViewModel
        let cleanupContext: ArticleCleanupContext?

        @State private var title: String
        @State private var subtitle: String
        @State private var creator: String
        @State private var showingCoverImporter = false
        @State private var showingArticlePicker = false
        @State private var coverMessage: String?
        @State private var pendingRemoval: AnthologyProjectEntry?

        init(
            viewModel: AnthologyBuilderViewModel,
            cleanupContext: ArticleCleanupContext?
        ) {
            self.viewModel = viewModel
            self.cleanupContext = cleanupContext
            _title = State(initialValue: viewModel.project.anthology.title)
            _subtitle = State(initialValue: viewModel.project.anthology.subtitle ?? "")
            _creator = State(initialValue: viewModel.project.anthology.creator ?? "")
        }

        var body: some View {
            Form {
                statusSection
                metadataSection
                coverSection
                tableOfContentsSection
                chapterSection
                buildSection
            }
            .fileImporter(
                isPresented: $showingCoverImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false,
                onCompletion: importCover
            )
            .sheet(isPresented: $showingArticlePicker) {
                AnthologyArticlePickerSheet(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Articles", systemImage: "plus") {
                        Task {
                            await viewModel.loadAvailableCaptures()
                            if viewModel.userMessage == nil {
                                showingArticlePicker = true
                            }
                        }
                    }
                    .disabled(viewModel.isLoadingAvailableCaptures || viewModel.isSaving)
                    .accessibilityHint("Selects more Inbox articles for this anthology")
                }
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                }
            }
            .confirmationDialog(
                "Remove this article from the anthology?",
                isPresented: removalPresented,
                presenting: pendingRemoval
            ) { entry in
                Button("Remove from Anthology", role: .destructive) {
                    Task {
                        await viewModel.remove(entryID: entry.entry.id)
                        pendingRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingRemoval = nil
                }
            } message: { entry in
                Text(
                    "\(chapterTitle(entry)) stays in Article Inbox and can be added again later."
                )
            }
            .alert("Cover", isPresented: coverErrorPresented) {
                Button("OK") { coverMessage = nil }
            } message: {
                Text(coverMessage ?? "")
            }
        }

        private var statusSection: some View {
            Section("Project Status") {
                switch viewModel.status {
                case .saved:
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .unsaved:
                    Label("Not Saved", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                case .changesAvailable:
                    Label("Changes Available", systemImage: "arrow.triangle.2.circlepath")
                case .prepared(let revision, let changesAvailable):
                    Label(
                        "Edition \(revision) prepared",
                        systemImage: "doc.badge.checkmark")
                    if changesAvailable {
                        Label(
                            "Changes Available",
                            systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if viewModel.isSaving {
                    ProgressView("Saving…")
                }

                if let summary = viewModel.preparedManifest?.imageInclusionSummary {
                    Label(
                        summary,
                        systemImage: viewModel.preparedManifest?.imageFailures?.isEmpty == false
                            ? "exclamationmark.triangle"
                            : "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                }

                if let message = viewModel.userMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                    if viewModel.retryActionAvailable {
                        Button("Try Again") {
                            Task { await viewModel.retry() }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }

        private var metadataSection: some View {
            Section("Book Details") {
                TextField("Title", text: $title)
                    .textContentType(.name)
                    .onChange(of: title) {
                        persistMetadata()
                    }

                TextField("Subtitle", text: $subtitle)
                    .onChange(of: subtitle) {
                        persistMetadata()
                    }

                TextField("Creator or Editor", text: $creator)
                    .textContentType(.name)
                    .onChange(of: creator) {
                        persistMetadata()
                    }
            }
        }

        private var coverSection: some View {
            Section("Cover") {
                if viewModel.project.anthology.coverPath != nil {
                    Label("Using Chosen Image", systemImage: "photo")
                } else {
                    Label("Generated Cover", systemImage: "wand.and.stars")
                    Text("Echo will generate a cover from the anthology details.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Choose Image", systemImage: "photo.badge.plus") {
                    showingCoverImporter = true
                }
                .frame(minHeight: 44)

                Button("Use Generated Cover", systemImage: "wand.and.stars") {
                    Task {
                        await viewModel.updateProject(
                            title: title,
                            subtitle: subtitle,
                            creator: creator,
                            coverPath: nil)
                    }
                }
                .frame(minHeight: 44)
                .disabled(viewModel.project.anthology.coverPath == nil)
            }
        }

        private var tableOfContentsSection: some View {
            Section("Table of Contents Preview") {
                if viewModel.project.entries.isEmpty {
                    Text("Add at least one article before building.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        Array(viewModel.project.entries.enumerated()),
                        id: \.element.entry.id
                    ) { index, entry in
                        LabeledContent(
                            "\(index + 1)",
                            value:
                                "\(chapterTitle(entry)), stable slot \(entry.entry.stableSlot)")
                    }
                }
            }
        }

        private var chapterSection: some View {
            Section {
                ForEach(viewModel.project.entries, id: \.entry.id) { entry in
                    AnthologyChapterEditor(
                        entry: entry,
                        policy: viewModel.policy(for: entry.entry.id),
                        cleanupContext: cleanupContext,
                        onUpdate: { titleOverride, voiceID in
                            Task {
                                await viewModel.updateEntry(
                                    id: entry.entry.id,
                                    chapterTitleOverride: titleOverride,
                                    narrationVoiceID: voiceID)
                            }
                        },
                        onMoveUp: {
                            Task {
                                await viewModel.moveUp(entryID: entry.entry.id)
                            }
                        },
                        onMoveDown: {
                            Task {
                                await viewModel.moveDown(entryID: entry.entry.id)
                            }
                        },
                        onRemove: {
                            pendingRemoval = entry
                        },
                        onCleanupReturn: {
                            Task { await viewModel.refreshFromStorage() }
                        })
                }
                .onMove(perform: reorder)
            } header: {
                Text("Chapters")
            } footer: {
                Text(
                    "Drag chapters or use Move Up and Move Down. Stable slots preserve chapter identity across editions."
                )
            }
        }

        private var buildSection: some View {
            Section("Edition") {
                Button(viewModel.buildActionTitle, systemImage: "hammer") {
                    Task { await viewModel.prepareBuild() }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(viewModel.project.entries.isEmpty || viewModel.isSaving)
                .accessibilityHint(
                    "Freezes the current article revisions into a new anthology edition"
                )
            }
        }

        private var removalPresented: Binding<Bool> {
            Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in
                    if isPresented == false {
                        pendingRemoval = nil
                    }
                })
        }

        private var coverErrorPresented: Binding<Bool> {
            Binding(
                get: { coverMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        coverMessage = nil
                    }
                })
        }

        private func persistMetadata() {
            let coverPath = viewModel.project.anthology.coverPath
            Task {
                await viewModel.updateProject(
                    title: title,
                    subtitle: subtitle,
                    creator: creator,
                    coverPath: coverPath)
            }
        }

        private func reorder(from source: IndexSet, to destination: Int) {
            var entryIDs = viewModel.project.entries.map(\.entry.id)
            entryIDs.move(fromOffsets: source, toOffset: destination)
            Task {
                await viewModel.reorder(entryIDs: entryIDs)
            }
        }

        private func importCover(_ result: Result<[URL], any Error>) {
            guard case .success(let urls) = result, let source = urls.first else {
                if case .failure(let error) = result {
                    coverMessage = error.localizedDescription
                }
                return
            }
            guard let anthologyID = UUID(uuidString: viewModel.project.anthology.id) else {
                coverMessage = "This anthology could not accept a cover safely."
                return
            }
            let store = AnthologyCoverStore()
            Task {
                do {
                    let filename = try await Task.detached {
                        try store.importCover(
                            from: source,
                            anthologyID: anthologyID)
                    }.value
                    await viewModel.updateProject(
                        title: title,
                        subtitle: subtitle,
                        creator: creator,
                        coverPath: filename)
                } catch {
                    coverMessage = error.localizedDescription
                }
            }
        }

        private func chapterTitle(_ entry: AnthologyProjectEntry) -> String {
            let candidate =
                entry.entry.chapterTitleOverride
                ?? entry.cleanArticle?.metadata.title
                ?? entry.capture.title
            let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Untitled Article" : title
        }
    }

    private struct AnthologyArticlePickerSheet: View {
        let viewModel: AnthologyBuilderViewModel

        @Environment(\.dismiss) private var dismiss
        @State private var selectedCaptureIDs: Set<String> = []

        var body: some View {
            NavigationStack {
                Group {
                    if viewModel.availableCaptures.isEmpty {
                        ContentUnavailableView(
                            "No More Articles",
                            systemImage: "checkmark.circle",
                            description: Text(
                                "Every available Inbox article is already in this anthology."
                            ))
                    } else {
                        List(viewModel.availableCaptures, id: \.id) { capture in
                            Button {
                                if selectedCaptureIDs.contains(capture.id) {
                                    selectedCaptureIDs.remove(capture.id)
                                } else {
                                    selectedCaptureIDs.insert(capture.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(capture.title)
                                            .foregroundStyle(.primary)
                                        if let siteName = capture.siteName {
                                            Text(siteName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedCaptureIDs.contains(capture.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .accessibilityLabel(capture.title)
                            .accessibilityValue(
                                selectedCaptureIDs.contains(capture.id)
                                    ? "Selected" : "Not selected")
                        }
                    }
                }
                .navigationTitle("Add Articles")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            let orderedIDs = viewModel.availableCaptures
                                .map(\.id)
                                .filter(selectedCaptureIDs.contains)
                            Task {
                                await viewModel.addCaptures(orderedIDs)
                                dismiss()
                            }
                        }
                        .disabled(selectedCaptureIDs.isEmpty || viewModel.isSaving)
                    }
                }
            }
        }
    }

    private struct AnthologyChapterEditor: View {
        let entry: AnthologyProjectEntry
        let policy: AnthologyEntryPolicy?
        let cleanupContext: ArticleCleanupContext?
        let onUpdate: (_ titleOverride: String?, _ voiceID: String?) -> Void
        let onMoveUp: () -> Void
        let onMoveDown: () -> Void
        let onRemove: () -> Void
        let onCleanupReturn: () -> Void

        @State private var titleOverride: String
        @State private var voiceID: String?

        init(
            entry: AnthologyProjectEntry,
            policy: AnthologyEntryPolicy?,
            cleanupContext: ArticleCleanupContext?,
            onUpdate: @escaping (_ titleOverride: String?, _ voiceID: String?) -> Void,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onRemove: @escaping () -> Void,
            onCleanupReturn: @escaping () -> Void
        ) {
            self.entry = entry
            self.policy = policy
            self.cleanupContext = cleanupContext
            self.onUpdate = onUpdate
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onRemove = onRemove
            self.onCleanupReturn = onCleanupReturn
            _titleOverride = State(initialValue: entry.entry.chapterTitleOverride ?? "")
            _voiceID = State(initialValue: entry.entry.narrationVoiceID)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(resolvedTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                if let policy {
                    Text(policy.stableSlotLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Chapter Title Override", text: $titleOverride)
                    .onChange(of: titleOverride) {
                        onUpdate(titleOverride, voiceID)
                    }

                Picker("Narration Voice", selection: $voiceID) {
                    Text("Project Default").tag(String?.none)
                    ForEach(VoiceCatalog.sections) { section in
                        Section(section.title) {
                            ForEach(section.voices) { voice in
                                Text("\(voice.displayName) — \(voice.descriptor)")
                                    .tag(Optional(voice.id.rawValue))
                            }
                        }
                    }
                }
                .onChange(of: voiceID) {
                    onUpdate(titleOverride, voiceID)
                }

                HStack {
                    Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                        .frame(minHeight: 44)
                        .disabled(policy?.canMoveUp != true)

                    Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                        .frame(minHeight: 44)
                        .disabled(policy?.canMoveDown != true)
                }

                if let cleanupContext {
                    NavigationLink {
                        ArticleCleanupLoadingView(
                            captureID: entry.capture.id,
                            context: cleanupContext
                        )
                        .onDisappear(perform: onCleanupReturn)
                    } label: {
                        Label("Clean Up", systemImage: "wand.and.stars")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Opens reversible cleanup for this article")
                }

                Button(
                    "Remove from Anthology",
                    systemImage: "minus.circle",
                    role: .destructive,
                    action: onRemove
                )
                .frame(minHeight: 44)
            }
            .padding(.vertical, 4)
            .accessibilityActions {
                if policy?.canMoveUp == true {
                    Button("Move Up", action: onMoveUp)
                }
                if policy?.canMoveDown == true {
                    Button("Move Down", action: onMoveDown)
                }
                Button("Remove from Anthology", action: onRemove)
            }
        }

        private var resolvedTitle: String {
            let candidate =
                entry.entry.chapterTitleOverride
                ?? entry.cleanArticle?.metadata.title
                ?? entry.capture.title
            let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Untitled Article" : title
        }
    }
#endif
