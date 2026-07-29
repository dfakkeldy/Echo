// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI
    import UIKit

    struct ArticleCleanupLoadingView: View {
        let captureID: String
        let context: ArticleCleanupContext

        @State private var coordinator: ArticleCleanupLoadingCoordinator

        init(captureID: String, context: ArticleCleanupContext) {
            self.captureID = captureID
            self.context = context
            _coordinator = State(
                initialValue: ArticleCleanupLoadingCoordinator(
                    loadState: { captureID in
                        try await context.loader.load(captureID: captureID)
                    },
                    publishRevision: context.publishRevision))
        }

        var body: some View {
            Group {
                if let viewModel = coordinator.viewModel {
                    ArticleCleanupView(viewModel: viewModel)
                } else if let userMessage = coordinator.userMessage {
                    ContentUnavailableView {
                        Label(
                            "Cleanup Unavailable",
                            systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(userMessage)
                    } actions: {
                        Button("Try Again") {
                            coordinator.retry()
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    ProgressView("Loading original capture…")
                }
            }
            .navigationTitle("Clean Up")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: captureID) {
                coordinator.start(captureID: captureID)
            }
            .onDisappear {
                coordinator.cancel()
            }
        }
    }

    struct ArticleCleanupView: View {
        let viewModel: ArticleCleanupViewModel

        @Environment(\.dismiss) private var dismiss
        @State private var isMetadataPresented = false
        @State private var metadataDraft = MetadataDraft()
        @State private var isDiscardConfirmationPresented = false
        @State private var isResetConfirmationPresented = false
        @State private var saveError: String?

        var body: some View {
            List {
                statusSection
                metadataSection
                blocksSection
                previewSection
            }
            .navigationTitle("Clean Up")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(viewModel.hasUnsavedChanges)
            .toolbar {
                if viewModel.hasUnsavedChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") {
                            isDiscardConfirmationPresented = true
                        }
                        .frame(minHeight: 44)
                        .accessibilityHint("Offers to discard unsaved cleanup changes")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        save()
                    }
                    .frame(minHeight: 44)
                    .disabled(viewModel.hasUnsavedChanges == false)
                }
            }
            .sheet(isPresented: $isMetadataPresented) {
                MetadataCorrectionView(
                    draft: $metadataDraft,
                    original: viewModel.source.metadata,
                    onApply: applyMetadata)
            }
            .confirmationDialog(
                "Discard cleanup changes?",
                isPresented: $isDiscardConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(
                    "The original capture is safe. Only these unsaved cleanup choices will be discarded."
                )
            }
            .confirmationDialog(
                "Reset to the original capture?",
                isPresented: $isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Reset Cleanup", role: .destructive) {
                    viewModel.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes all cleanup choices from the preview. Save to publish the reset as a new revision."
                )
            }
            .alert("Cleanup Could Not Be Saved", isPresented: saveErrorPresented) {
                Button("OK") {
                    saveError = nil
                }
            } message: {
                Text(saveError ?? "")
            }
        }

        private var statusSection: some View {
            Section {
                if viewModel.conflict != nil {
                    Label(
                        "A newer cleanup was saved elsewhere. Your unsaved choices are still here. To review it, go back and reopen Clean Up.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .foregroundStyle(.primary)
                    .accessibilityLabel(
                        "Cleanup conflict. A newer cleanup was saved elsewhere. Your unsaved choices are still here. To review it, go back and reopen Clean Up."
                    )
                } else if viewModel.hasUnsavedChanges {
                    Label("Unsaved cleanup changes", systemImage: "circle.dashed")
                        .foregroundStyle(.primary)
                } else {
                    Label("Cleanup is saved", systemImage: "checkmark.circle")
                }
            } header: {
                Text("Status")
                    .accessibilityAddTraits(.isHeader)
            }
        }

        private var metadataSection: some View {
            Section {
                LabeledContent("Title", value: viewModel.preview.metadata.title)
                if let author = nonempty(viewModel.preview.metadata.author) {
                    LabeledContent("Author", value: author)
                }
                if let site = nonempty(viewModel.preview.metadata.siteName) {
                    LabeledContent("Site", value: site)
                }
                Button {
                    metadataDraft = MetadataDraft(
                        overrides: viewModel.recipe.metadataOverrides)
                    isMetadataPresented = true
                } label: {
                    Label("Correct Metadata", systemImage: "pencil")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Metadata")
                    .accessibilityAddTraits(.isHeader)
            }
        }

        private var blocksSection: some View {
            Section {
                ForEach(viewModel.source.blocks) { block in
                    blockRow(block)
                        .swipeActions {
                            if viewModel.isExcluded(block.id) {
                                Button("Restore", systemImage: "arrow.uturn.backward") {
                                    viewModel.restore(blockID: block.id)
                                }
                                .tint(.green)
                            } else {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    viewModel.exclude(blockID: block.id)
                                }
                            }
                        }
                        .contextMenu {
                            blockActions(block)
                        }
                        .accessibilityAction(
                            named: viewModel.isExcluded(block.id) ? "Restore" : "Remove"
                        ) {
                            if viewModel.isExcluded(block.id) {
                                viewModel.restore(blockID: block.id)
                            } else {
                                viewModel.exclude(blockID: block.id)
                            }
                        }
                        .accessibilityAction(named: "Trim everything above") {
                            viewModel.trimBefore(blockID: block.id)
                        }
                        .accessibilityAction(named: "Trim everything below") {
                            viewModel.trimAfter(blockID: block.id)
                        }
                }
            } header: {
                Text("Original Structure")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text(
                    "Removed rows stay here so you can restore them. Trimming keeps the selected row."
                )
            }
        }

        private var previewSection: some View {
            Section {
                LabeledContent(
                    "Included blocks",
                    value: "\(viewModel.preview.blocks.count) of \(viewModel.source.blocks.count)")
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Label("Reset to Original", systemImage: "arrow.counterclockwise")
                        .frame(minHeight: 44)
                }
                .disabled(viewModel.recipe == ArticleEditRecipe())
            } header: {
                Text("Preview")
                    .accessibilityAddTraits(.isHeader)
            }
        }

        @ViewBuilder
        private func blockRow(_ block: ArticleBlock) -> some View {
            let presentation =
                viewModel.presentation(for: block.id)
                ?? ArticleCleanupBlockPresentation(
                    state: .included,
                    startsHere: false,
                    endsHere: false)
            let excluded = presentation.state == .explicitlyRemoved
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(blockLabel(block.kind), systemImage: blockIcon(block.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    blockStatus(presentation)
                }
                if excluded {
                    Button("Restore") {
                        viewModel.restore(blockID: block.id)
                    }
                    .frame(minHeight: 44)
                } else {
                    if let text = nonempty(block.text) {
                        Text(text)
                            .font(block.kind == .heading ? .headline : .body)
                            .lineLimit(nil)
                    }
                    if let caption = nonempty(block.caption) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    }
                    Menu {
                        blockActions(block)
                    } label: {
                        Label("Structural Actions", systemImage: "ellipsis.circle")
                            .frame(minHeight: 44)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityValue(presentation.accessibilityValue)
        }

        @ViewBuilder
        private func blockStatus(_ presentation: ArticleCleanupBlockPresentation) -> some View {
            VStack(alignment: .trailing, spacing: 4) {
                switch presentation.state {
                case .included:
                    EmptyView()
                case .explicitlyRemoved:
                    Label("Removed", systemImage: "minus.circle")
                case .trimmedAbove:
                    Label("Trimmed above", systemImage: "arrow.up.to.line")
                case .trimmedBelow:
                    Label("Trimmed below", systemImage: "arrow.down.to.line")
                }
                if presentation.startsHere {
                    Label("Starts here", systemImage: "arrow.right.to.line")
                }
                if presentation.endsHere {
                    Label("Ends here", systemImage: "arrow.left.to.line")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        @ViewBuilder
        private func blockActions(_ block: ArticleBlock) -> some View {
            if viewModel.isExcluded(block.id) {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    viewModel.restore(blockID: block.id)
                }
            } else {
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    viewModel.exclude(blockID: block.id)
                }
            }
            Button("Trim everything above", systemImage: "arrow.up.to.line") {
                viewModel.trimBefore(blockID: block.id)
            }
            Button("Trim everything below", systemImage: "arrow.down.to.line") {
                viewModel.trimAfter(blockID: block.id)
            }
        }

        private var saveErrorPresented: Binding<Bool> {
            Binding(
                get: { saveError != nil },
                set: { isPresented in
                    if isPresented == false { saveError = nil }
                })
        }

        private func applyMetadata(_ draft: MetadataDraft) {
            viewModel.updateMetadata(draft.overrides)
        }

        private func save() {
            do {
                _ = try viewModel.save(deviceName: UIDevice.current.name)
                saveError = nil
            } catch {
                saveError = ArticleCleanupUserMessage.save(error)
            }
        }

        private func nonempty(_ value: String?) -> String? {
            guard
                let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                value.isEmpty == false
            else {
                return nil
            }
            return value
        }

        private func blockLabel(_ kind: ArticleBlockKind) -> String {
            switch kind {
            case .heading: "Heading"
            case .paragraph: "Paragraph"
            case .listItem: "List item"
            case .quote: "Quote"
            case .code: "Code"
            case .image: "Image"
            case .separator: "Separator"
            }
        }

        private func blockIcon(_ kind: ArticleBlockKind) -> String {
            switch kind {
            case .heading: "textformat.size"
            case .paragraph: "text.alignleft"
            case .listItem: "list.bullet"
            case .quote: "quote.opening"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .image: "photo"
            case .separator: "minus"
            }
        }
    }

    private struct MetadataDraft: Equatable {
        var title = ""
        var author = ""
        var siteName = ""
        var language = ""
        var publishedTime = ""

        init() {}

        init(overrides: ArticleMetadataOverrides) {
            title = overrides.title ?? ""
            author = overrides.author ?? ""
            siteName = overrides.siteName ?? ""
            language = overrides.language ?? ""
            publishedTime = overrides.publishedTime ?? ""
        }

        var overrides: ArticleMetadataOverrides {
            ArticleMetadataOverrides(
                title: optional(title),
                author: optional(author),
                siteName: optional(siteName),
                language: optional(language),
                publishedTime: optional(publishedTime))
        }

        private func optional(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private struct MetadataCorrectionView: View {
        @Environment(\.dismiss) private var dismiss
        @Binding var draft: MetadataDraft
        let original: ArticleMetadata
        let onApply: (MetadataDraft) -> Void

        var body: some View {
            NavigationStack {
                Form {
                    Section("Correct Metadata") {
                        TextField(original.title, text: $draft.title)
                            .textInputAutocapitalization(.sentences)
                        TextField(original.author ?? "Author", text: $draft.author)
                            .textContentType(.name)
                        TextField(original.siteName ?? "Site", text: $draft.siteName)
                        TextField(original.language ?? "Language", text: $draft.language)
                            .textInputAutocapitalization(.never)
                        TextField(
                            original.publishedTime ?? "Published date",
                            text: $draft.publishedTime)
                    }
                }
                .navigationTitle("Metadata")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .frame(minHeight: 44)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            onApply(draft)
                            dismiss()
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }
#endif
