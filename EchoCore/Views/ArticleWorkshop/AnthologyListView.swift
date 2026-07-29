// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct AnthologyListView: View {
        let viewModel: AnthologyListViewModel
        let service: AnthologyService
        let buildService: AnthologyBuildService
        let openBook: (LibraryOpenTarget) -> Void
        let cleanupContext: ArticleCleanupContext?

        var body: some View {
            Group {
                if viewModel.projects.isEmpty, viewModel.isLoading == false {
                    ContentUnavailableView(
                        "No Anthologies",
                        systemImage: "text.book.closed",
                        description: Text(
                            "Select articles in Inbox, then choose New Anthology."
                        )
                    )
                } else {
                    List(viewModel.projects, id: \.id) { anthology in
                        NavigationLink {
                            AnthologyDetailView(
                                anthologyID: anthology.id,
                                service: service,
                                buildService: buildService,
                                openBook: openBook,
                                cleanupContext: cleanupContext)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(
                                    anthology.title,
                                    systemImage: "text.book.closed"
                                )
                                .font(.headline)

                                if let subtitle = anthology.subtitle,
                                    subtitle.isEmpty == false
                                {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityLabel("Anthology: \(anthology.title)")
                        .accessibilityHint("Opens anthology details and chapter editing")
                    }
                    .refreshable {
                        await viewModel.reload()
                    }
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading anthologies…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .alert("Anthologies", isPresented: errorPresented) {
                Button("Try Again") {
                    Task { await viewModel.reload() }
                }
                Button("OK", role: .cancel) {
                    viewModel.dismissMessage()
                }
            } message: {
                Text(viewModel.userMessage ?? "")
            }
            .onAppear {
                Task { await viewModel.reload() }
            }
        }

        private var errorPresented: Binding<Bool> {
            Binding(
                get: { viewModel.userMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        viewModel.dismissMessage()
                    }
                })
        }
    }
#endif
