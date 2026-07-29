// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    nonisolated struct AnthologyEPUBPresentation: Equatable, Sendable {
        let status: AnthologyEPUBStatus
        let hasChapters: Bool
        let isSaving: Bool
        let hasValidatedOutput: Bool
        let hasPendingSaveFailure: Bool

        init(
            status: AnthologyEPUBStatus,
            hasChapters: Bool,
            isSaving: Bool,
            hasValidatedOutput: Bool,
            hasPendingSaveFailure: Bool = false
        ) {
            self.status = status
            self.hasChapters = hasChapters
            self.isSaving = isSaving
            self.hasValidatedOutput = hasValidatedOutput
            self.hasPendingSaveFailure = hasPendingSaveFailure
        }

        var primaryActionTitle: String? {
            switch status {
            case .notBuilt, .failed(previousRevision: nil):
                return "Build EPUB"
            case .ready, .changesAvailable, .failed(previousRevision: .some):
                return "Rebuild EPUB"
            case .building:
                return nil
            }
        }

        var canBuild: Bool {
            primaryActionTitle != nil
                && hasChapters
                && isSaving == false
                && hasPendingSaveFailure == false
        }

        var canOpen: Bool {
            hasValidatedOutput && status != .building
        }

        var canShare: Bool {
            hasValidatedOutput && status != .building
        }

        var showsProgress: Bool {
            status == .building
        }

        var statusTitle: String {
            switch status {
            case .notBuilt:
                return "EPUB Not Built"
            case .building:
                return "Building EPUB"
            case .ready(let revision):
                return "EPUB Ready · Edition \(revision)"
            case .changesAvailable:
                return "EPUB Changes Available"
            case .failed(previousRevision: nil):
                return "EPUB Build Failed"
            case .failed(previousRevision: .some):
                return "EPUB Build Failed · Previous Edition Available"
            }
        }

        var statusSystemImage: String {
            switch status {
            case .notBuilt:
                return "doc"
            case .building:
                return "hourglass"
            case .ready:
                return "checkmark.circle"
            case .changesAvailable:
                return "arrow.triangle.2.circlepath"
            case .failed:
                return "exclamationmark.triangle"
            }
        }

        var accessibilityLabel: String {
            "EPUB status"
        }

        var accessibilityValue: String {
            switch status {
            case .notBuilt:
                return "Not built"
            case .building:
                return "Building"
            case .ready(let revision):
                return "Ready, revision \(revision)"
            case .changesAvailable(let revision):
                return "Changes available after revision \(revision)"
            case .failed(previousRevision: nil):
                return "Build failed"
            case .failed(previousRevision: .some(let revision)):
                return "Build failed. Revision \(revision) remains available"
            }
        }
    }

    struct AnthologyDetailGeneration {
        private var nextGeneration = 0
        private var activeLoad: Int?
        private var activeBuild: Int?

        mutating func beginLoad() -> Int {
            nextGeneration += 1
            activeLoad = nextGeneration
            activeBuild = nil
            return nextGeneration
        }

        func acceptsLoad(_ generation: Int) -> Bool {
            activeLoad == generation
        }

        mutating func finishLoad(_ generation: Int) -> Bool {
            guard activeLoad == generation else { return false }
            activeLoad = nil
            return true
        }

        mutating func beginBuild() -> Int {
            nextGeneration += 1
            activeBuild = nextGeneration
            activeLoad = nil
            return nextGeneration
        }

        func acceptsBuild(_ generation: Int) -> Bool {
            activeBuild == generation
        }

        func acceptedBuildResult<Value>(
            _ value: Value,
            generation: Int
        ) -> Value? {
            acceptsBuild(generation) ? value : nil
        }

        mutating func finishBuild(_ generation: Int) -> Bool {
            guard activeBuild == generation else { return false }
            activeBuild = nil
            return true
        }
    }

    struct AnthologyDetailView: View {
        let anthologyID: String
        let service: AnthologyService
        let buildService: AnthologyBuildService
        let openBook: (LibraryOpenTarget) -> Void
        let cleanupContext: ArticleCleanupContext?

        @State private var viewModel: AnthologyBuilderViewModel?
        @State private var userMessage: String?
        @State private var epubMessage: String?
        @State private var isLoading = false
        @State private var epubStatus = AnthologyEPUBStatus.notBuilt
        @State private var finalEPUBURL: URL?
        @State private var detailGeneration = AnthologyDetailGeneration()

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
            .safeAreaInset(edge: .bottom) {
                if let viewModel {
                    epubActions(viewModel: viewModel)
                }
            }
            .navigationTitle(viewModel?.project.anthology.title ?? "Anthology")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: anthologyID) {
                await load()
            }
            .alert("EPUB Build Failed", isPresented: epubErrorPresented) {
                Button("Try Again") {
                    epubMessage = nil
                    Task { await buildEPUB() }
                }
                Button("Dismiss", role: .cancel) {
                    epubMessage = nil
                }
            } message: {
                Text(epubMessage ?? "")
            }
        }

        private func load() async {
            let generation = detailGeneration.beginLoad()
            isLoading = true
            defer {
                if detailGeneration.finishLoad(generation) {
                    isLoading = false
                }
            }
            do {
                let project = try await Task.detached {
                    try service.loadProject(id: anthologyID)
                }.value
                let snapshot = try await buildService.snapshot(
                    anthologyID: anthologyID,
                    changesAvailable: project.changesAvailable)
                guard Task.isCancelled == false,
                    detailGeneration.acceptsLoad(generation)
                else {
                    return
                }
                viewModel = AnthologyBuilderViewModel(
                    project: project,
                    service: service)
                apply(snapshot)
                userMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard detailGeneration.acceptsLoad(generation) else { return }
                userMessage = "This anthology could not be loaded. Try again."
            }
        }

        @ViewBuilder
        private func epubActions(
            viewModel: AnthologyBuilderViewModel
        ) -> some View {
            let presentation = presentation(for: viewModel)
            VStack(alignment: .leading, spacing: 10) {
                if presentation.showsProgress {
                    ProgressView("Building EPUB…")
                        .accessibilityLabel("Building EPUB")
                } else {
                    Label(
                        presentation.statusTitle,
                        systemImage: presentation.statusSystemImage
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(nil)
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        epubActionButtons(presentation)
                    }
                    VStack(alignment: .leading) {
                        epubActionButtons(presentation)
                    }
                }
                .controlSize(.regular)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
        }

        @ViewBuilder
        private func epubActionButtons(
            _ presentation: AnthologyEPUBPresentation
        ) -> some View {
            if let title = presentation.primaryActionTitle {
                Button(title, systemImage: "hammer") {
                    Task { await buildEPUB() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(presentation.canBuild == false)
                .frame(minHeight: 44)
                .accessibilityHint(
                    "Creates a validated EPUB from the saved anthology chapters")
            }

            if presentation.canOpen, let finalURL = finalEPUBURL {
                Button("Open in Echo", systemImage: "book") {
                    openBook(
                        LibraryOpenTarget(
                            url: finalURL.deletingLastPathComponent(),
                            scopedRoot: nil))
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Opens the built edition in Echo")
            }

            if presentation.canShare, let finalURL = finalEPUBURL {
                ShareLink(item: finalURL) {
                    Label("Share EPUB", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Shares the validated EPUB file")
            }
        }

        private func presentation(
            for viewModel: AnthologyBuilderViewModel
        ) -> AnthologyEPUBPresentation {
            let displayedStatus: AnthologyEPUBStatus
            if case .ready(let revision) = epubStatus,
                viewModel.project.changesAvailable
            {
                displayedStatus = .changesAvailable(builtRevision: revision)
            } else {
                displayedStatus = epubStatus
            }
            return AnthologyEPUBPresentation(
                status: displayedStatus,
                hasChapters: viewModel.project.entries.isEmpty == false,
                isSaving: viewModel.isSaving,
                hasValidatedOutput: finalEPUBURL != nil,
                hasPendingSaveFailure: viewModel.retryActionAvailable)
        }

        private func buildEPUB() async {
            guard let viewModel,
                presentation(for: viewModel).canBuild
            else {
                return
            }
            let generation = detailGeneration.beginBuild()
            let priorRevision = validatedRevision
            epubStatus = .building
            defer {
                _ = detailGeneration.finishBuild(generation)
            }

            do {
                _ = try await buildService.build(anthologyID: anthologyID)
                let project = try await Task.detached {
                    try service.loadProject(id: anthologyID)
                }.value
                let snapshot = try await buildService.snapshot(
                    anthologyID: anthologyID,
                    changesAvailable: project.changesAvailable)
                guard Task.isCancelled == false,
                    detailGeneration.acceptsBuild(generation)
                else {
                    return
                }
                self.viewModel = AnthologyBuilderViewModel(
                    project: project,
                    service: service)
                apply(snapshot)
                epubMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard detailGeneration.acceptsBuild(generation) else { return }
                let refreshedSnapshot: AnthologyEPUBSnapshot?
                if let project = self.viewModel?.project {
                    refreshedSnapshot = try? await buildService.snapshot(
                        anthologyID: anthologyID,
                        changesAvailable: project.changesAvailable)
                } else {
                    refreshedSnapshot = nil
                }
                guard
                    let acceptedSnapshot = detailGeneration.acceptedBuildResult(
                        refreshedSnapshot,
                        generation: generation)
                else {
                    return
                }
                if let acceptedSnapshot {
                    apply(acceptedSnapshot)
                } else {
                    epubStatus = .failed(previousRevision: priorRevision)
                }
                epubMessage =
                    (error as? AnthologyBuildService.Error)?.errorDescription
                    ?? "The EPUB could not be built. Try again."
            }
        }

        private var validatedRevision: Int? {
            switch epubStatus {
            case .ready(let revision), .changesAvailable(let revision):
                return revision
            case .failed(previousRevision: let revision):
                return revision
            case .notBuilt, .building:
                return nil
            }
        }

        private func apply(_ snapshot: AnthologyEPUBSnapshot) {
            epubStatus = snapshot.status
            finalEPUBURL = snapshot.finalURL
        }

        private var epubErrorPresented: Binding<Bool> {
            Binding(
                get: { epubMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        epubMessage = nil
                    }
                })
        }
    }
#endif
