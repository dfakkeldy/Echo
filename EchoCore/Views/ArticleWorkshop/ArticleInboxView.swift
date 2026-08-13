// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct ArticleInboxView: View {
        let viewModel: ArticleInboxViewModel

        @State private var pendingDeletion: ArticleInboxItem?
        @State private var deletionImpact: ArticleDeletionImpact?

        var body: some View {
            VStack(spacing: 0) {
                Toggle("Show Used Captures", isOn: showsUsedCaptures)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .accessibilityHint(
                        "Shows captured source articles already used in a successful EPUB build")

                Divider()

                Group {
                    if viewModel.articles.isEmpty, viewModel.isImporting == false {
                        ContentUnavailableView(
                            viewModel.showsUsedCaptures ? "No Article Captures" : "Inbox is Clear",
                            systemImage: "tray",
                            description: Text(
                                viewModel.showsUsedCaptures
                                    ? "Articles you capture from Safari will appear here."
                                    : "New captures and captures not yet built into an EPUB appear here."
                            )
                        )
                    } else {
                        List(viewModel.articles) { article in
                            articleRow(article)
                                .swipeActions {
                                    Button(
                                        "Delete",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        prepareDeletion(article)
                                    }
                                }
                                .accessibilityAction(named: "Delete") {
                                    prepareDeletion(article)
                                }
                        }
                        .navigationDestination(for: ArticleInboxItem.self) { article in
                            ArticleDetailView(
                                article: article,
                                cleanupContext: viewModel.cleanupContext)
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isImporting {
                    ProgressView("Importing articles…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .alert("Article Inbox", isPresented: errorPresented) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: deletionPresented,
                presenting: pendingDeletion
            ) { article in
                if deletionImpact?.isReferenced == false {
                    Button("Delete Article", role: .destructive) {
                        Task {
                            await viewModel.delete(id: article.id)
                            clearDeletion()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    clearDeletion()
                }
            } message: { _ in
                Text(deletionMessage)
            }
        }

        private func articleRow(_ article: ArticleInboxItem) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    viewModel.toggleSelection(article.id)
                } label: {
                    Image(
                        systemName: viewModel.selectedIDs.contains(article.id)
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.title2)
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    viewModel.selectedIDs.contains(article.id)
                        ? "Deselect \(article.title)" : "Select \(article.title)"
                )
                .accessibilityValue(
                    viewModel.selectedIDs.contains(article.id) ? "Selected" : "Not selected"
                )
                .accessibilityHint(
                    article.isAnthologyEligible
                        ? "Adds or removes this article from the anthology selection"
                        : "This article must be captured successfully before it can be added"
                )
                .disabled(article.isAnthologyEligible == false)

                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: article) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(article.title)
                                .font(.headline)
                                .lineLimit(nil)

                            if let site = article.siteName, site.isEmpty == false {
                                Text(site)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Label(article.state.title, systemImage: article.state.systemImage)
                                .font(.subheadline)

                            if article.isUsed {
                                Label("Used in EPUB", systemImage: "archivebox")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityHint("Opens article details and cleanup")

                    if article.isPossibleDuplicate {
                        Label(
                            "Possible duplicate — Keep Both is available",
                            systemImage: "doc.on.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    NavigationLink(value: article) {
                        Label("Clean Up", systemImage: "wand.and.stars")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Opens cleanup details; cleanup is on demand")
                }
            }
            .padding(.vertical, 4)
        }

        private var errorPresented: Binding<Bool> {
            Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        viewModel.errorMessage = nil
                    }
                }
            )
        }

        private var showsUsedCaptures: Binding<Bool> {
            Binding(
                get: { viewModel.showsUsedCaptures },
                set: { viewModel.setShowsUsedCaptures($0) }
            )
        }

        private var deletionPresented: Binding<Bool> {
            Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if isPresented == false {
                        clearDeletion()
                    }
                }
            )
        }

        private var deletionTitle: String {
            deletionImpact?.isReferenced == true
                ? "Article is used by an anthology"
                : "Delete this article?"
        }

        private var deletionMessage: String {
            guard let impact = deletionImpact, impact.isReferenced else {
                return "This removes the article from Echo and deletes its managed package."
            }
            return
                "Remove this article from \(impact.projectNames.joined(separator: ", ")) before deleting it."
        }

        private func prepareDeletion(_ article: ArticleInboxItem) {
            do {
                deletionImpact = try viewModel.deletionImpact(for: article.id)
                pendingDeletion = article
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }

        private func clearDeletion() {
            pendingDeletion = nil
            deletionImpact = nil
        }
    }
#endif
