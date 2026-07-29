// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct AnthologyDetailView: View {
        let anthologyID: String
        let service: AnthologyService
        let cleanupContext: ArticleCleanupContext?

        @State private var viewModel: AnthologyBuilderViewModel?
        @State private var userMessage: String?
        @State private var isLoading = false

        var body: some View {
            Group {
                if let viewModel {
                    AnthologyBuilderView(
                        viewModel: viewModel,
                        cleanupContext: cleanupContext)
                } else if let userMessage {
                    ContentUnavailableView {
                        Label(
                            "Anthology Unavailable",
                            systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(userMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    ProgressView("Loading anthology…")
                }
            }
            .navigationTitle(viewModel?.project.anthology.title ?? "Anthology")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: anthologyID) {
                await load()
            }
        }

        private func load() async {
            guard isLoading == false else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let project = try await Task.detached {
                    try service.loadProject(id: anthologyID)
                }.value
                guard Task.isCancelled == false else { return }
                viewModel = AnthologyBuilderViewModel(
                    project: project,
                    service: service)
                userMessage = nil
            } catch is CancellationError {
                return
            } catch {
                userMessage = "This anthology could not be loaded. Try again."
            }
        }
    }
#endif
