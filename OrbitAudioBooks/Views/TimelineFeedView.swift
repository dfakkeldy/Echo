import SwiftUI

/// Twitter-style audiobook timeline feed with sticky chapter headers,
/// playback auto-follow, and time-windowed pagination.
///
/// Uses `ScrollViewReader` for programmatic "Go to Now" jumps and
/// `LazyVStack(pinnedViews: [.sectionHeaders])` so chapter headers
/// stick to the top during scroll.
struct TimelineFeedView: View {
    @Environment(PlayerModel.self) private var model

    @State private var vm: TimelineFeedViewModel?
    @State private var isProgrammaticScroll = false

    /// Incremented by the parent when the header "Now" button is tapped.
    var recenterTrigger: Int = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let vm, !vm.chapterSections.isEmpty {
                feedContent(vm: vm)
            } else if vm != nil {
                emptyState
            } else {
                Color.clear.onAppear { bootstrapViewModel() }
            }

            // Floating "Go to Now" button — visible when user has scrolled away.
            if let vm, vm.followState == .browsing {
                jumpToNowButton(vm: vm)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onAppear { bootstrapViewModel() }
        .onChange(of: model.folderURL) { _, _ in
            vm?.configure(
                audiobookID: model.folderURL?.absoluteString,
                totalDuration: model.durationSeconds ?? 0
            )
        }
        .onChange(of: model.currentPlaybackTime) { _, newTime in
            vm?.currentPlaybackTime = newTime
        }
        .onChange(of: model.isPlaying) { _, playing in
            vm?.isPlaying = playing
        }
        .onChange(of: recenterTrigger) { _, _ in
            vm?.jumpToNow()
        }
    }

    // MARK: - Feed content

    private func feedContent(vm: TimelineFeedViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if vm.hasEarlierContent {
                        earlierTrigger(vm: vm)
                    }

                    ForEach(vm.chapterSections) { section in
                        Section {
                            ForEach(section.cards) { card in
                                TimelineFeedCard(
                                    card: card,
                                    isCurrentItem: card.id == vm.currentItemID && vm.isPlaying,
                                    totalDuration: section.totalBookDuration
                                )
                                .id(card.id)
                            }
                        } header: {
                            chapterHeader(for: section, vm: vm)
                        }
                    }

                    if vm.hasLaterContent {
                        laterTrigger(vm: vm)
                    }

                    Color.clear.frame(height: 80)
                }
            }
            .defaultScrollAnchor(.top)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    scrollToCurrent(using: proxy, vm: vm)
                }
            }
            .onChange(of: vm.followState) { _, newState in
                if newState == .following {
                    scrollToCurrent(using: proxy, vm: vm)
                }
            }
            .onChange(of: vm.currentPlaybackTime) { _, _ in
                guard vm.followState == .following else { return }
                scrollToCurrent(using: proxy, vm: vm)
            }
        }
        .simultaneousGesture(userScrollGesture)
    }

    // MARK: - Chapter header

    private func chapterHeader(for section: ChapterSection, vm: TimelineFeedViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.index == vm.currentChapterIndex
                  ? "speaker.wave.2.fill" : "text.book.closed.fill")
                .font(.caption)
                .foregroundStyle(section.index == vm.currentChapterIndex ? .blue : .secondary)

            Text(section.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)

            Spacer()

            Text(formatHMS(section.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Infinite-scroll triggers

    private func earlierTrigger(vm: TimelineFeedViewModel) -> some View {
        Color.clear
            .frame(height: 1)
            .onAppear { vm.loadEarlier() }
            .overlay {
                if vm.isLoadingEarlier {
                    ProgressView().scaleEffect(0.8)
                }
            }
    }

    private func laterTrigger(vm: TimelineFeedViewModel) -> some View {
        Color.clear
            .frame(height: 1)
            .onAppear { vm.loadLater() }
            .overlay {
                if vm.isLoadingLater {
                    ProgressView().scaleEffect(0.8)
                }
            }
    }

    // MARK: - Jump to Now

    private func jumpToNowButton(vm: TimelineFeedViewModel) -> some View {
        Button {
            vm.jumpToNow()
        } label: {
            Label(
                vm.isPlaying ? "↓ Now Playing" : "↓ Go to Now",
                systemImage: vm.isPlaying ? "play.fill" : "arrow.down.to.line.compact"
            )
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.25), value: vm.followState)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Timeline Content",
            systemImage: "list.bullet.rectangle.portrait",
            description: Text(
                "Bookmarks, chapter markers, flashcards, and transcripts will appear here as you listen."
            )
        )
    }

    // MARK: - Gesture detection

    private var userScrollGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { _ in
                if !isProgrammaticScroll {
                    vm?.userDidScroll()
                }
            }
    }

    // MARK: - Helpers

    private func bootstrapViewModel() {
        guard vm == nil else { return }
        let viewModel = TimelineFeedViewModel(databaseService: model.databaseService)
        viewModel.currentPlaybackTime = model.currentPlaybackTime
        viewModel.isPlaying = model.isPlaying
        viewModel.configure(
            audiobookID: model.folderURL?.absoluteString,
            totalDuration: model.durationSeconds ?? 0
        )
        vm = viewModel
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, vm: TimelineFeedViewModel) {
        guard let id = vm.currentItemID else { return }
        isProgrammaticScroll = true
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(id, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isProgrammaticScroll = false
        }
    }
}
