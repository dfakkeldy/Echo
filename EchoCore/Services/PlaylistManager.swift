import Foundation
import Observation

/// Manages playlist operations: track/chapter ordering, enabled-state toggling,
/// playlist reset, and track enumeration from a folder URL.
///
/// Owned by PlayerModel; injected with shared PlaybackState and Persistence.
@MainActor @Observable
final class PlaylistManager {
    let state: PlaybackState
    let persistence: Persistence

    /// Called after a playlist reset to refresh chapter tracking from the
    /// current player time. Wired by PlayerModel.
    @ObservationIgnored var coordinator_postResetRefresh: (() -> Void)?

    init(state: PlaybackState, persistence: Persistence) {
        self.state = state
        self.persistence = persistence
    }

    // MARK: - Audio File Types

    /// The audio container extensions Echo plays. Single source of truth so the
    /// folder scan and the single-file open path agree on what counts as audio —
    /// and, by exclusion, what is a document (EPUB/PDF) that opens as an
    /// audio-less study book instead of a playable track.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b"]

    /// Whether `url` points at a file Echo can play as an audio track.
    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Document types that open as an audio-less study book (reader + narration)
    /// rather than as a playable track.
    static let documentExtensions: Set<String> = ["epub", "pdf"]

    /// Whether `url` is a study document opened directly (vs an audio file).
    /// Used so a picked EPUB/PDF becomes an audio-less book while every other
    /// file — including non-default audio like `.wav`/`.aiff`/`.aac` — is still
    /// treated as a playable track.
    static func isDocumentFile(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Track Loading

    func loadTracks(from folder: URL) -> [Track] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]

        guard
            let urls = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var loadedTracks: [Track] = urls.compactMap { url in
            guard Self.isAudioFile(url) else { return nil }
            return Track(url: url, title: url.deletingPathExtension().lastPathComponent)
        }

        loadedTracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let folderKey = folder.absoluteString
        if let savedStates = persistence.loadEnabledState(for: folderKey, folderURL: folder) {
            for i in 0..<loadedTracks.count {
                if let isEnabled = savedStates[loadedTracks[i].id] {
                    loadedTracks[i].isEnabled = isEnabled
                }
            }
        }

        if let savedOrder = persistence.loadOrder(for: folderKey, folderURL: folder) {
            var orderedTracks: [Track] = []
            var remainingTracks = loadedTracks
            for id in savedOrder {
                if let idx = remainingTracks.firstIndex(where: { $0.id == id }) {
                    orderedTracks.append(remainingTracks.remove(at: idx))
                }
            }
            orderedTracks.append(contentsOf: remainingTracks)
            loadedTracks = orderedTracks
        }

        return loadedTracks
    }

    // MARK: - Reorder

    func moveTracks(from source: IndexSet, to destination: Int) {
        let currentURL =
            state.tracks.indices.contains(state.currentIndex)
            ? state.tracks[state.currentIndex].url : nil
        applyMove(&state.tracks, from: source, to: destination)
        if let currentURL, let newIdx = state.tracks.firstIndex(where: { $0.url == currentURL }) {
            state.currentIndex = newIdx
        }
        if let folderURL = state.folderURL {
            persistence.saveOrder(
                for: folderURL.absoluteString, ids: state.tracks.map { $0.id },
                tracks: state.tracks, folderURL: folderURL)
        }
    }

    func moveChapters(from source: IndexSet, to destination: Int) {
        let currentID: String? = {
            guard let idx = state.currentChapterIndex, state.chapters.indices.contains(idx) else {
                return nil
            }
            return state.chapters[idx].id
        }()
        applyMove(&state.chapters, from: source, to: destination)
        if let currentID, let newIdx = state.chapters.firstIndex(where: { $0.id == currentID }) {
            state.currentChapterIndex = newIdx
        }
        if let currentTrackURL = state.tracks.indices.contains(state.currentIndex)
            ? state.tracks[state.currentIndex].url : nil
        {
            persistence.saveOrder(
                for: currentTrackURL.absoluteString, ids: state.chapters.map { $0.id })
        }
    }

    /// Manual replacement for SwiftUI's `RangeReplaceableCollection.move(fromOffsets:toOffset:)`,
    /// which is unavailable without importing SwiftUI. Removes the elements at `source` offsets
    /// (preserving relative order) and re-inserts them at `destination`.
    private func applyMove<T>(_ array: inout [T], from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { array[$0] }
        for offset in source.sorted(by: >) {
            array.remove(at: offset)
        }
        let adjusted = destination - source.filter { $0 < destination }.count
        array.insert(contentsOf: moving, at: min(adjusted, array.count))
    }

    // MARK: - Toggle Enabled

    func toggleTrackEnabled(at index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        state.tracks[index].isEnabled.toggle()
        if let folderURL = state.folderURL {
            var states =
                persistence.loadEnabledState(for: folderURL.absoluteString, folderURL: folderURL)
                ?? [:]
            states[state.tracks[index].id] = state.tracks[index].isEnabled
            persistence.saveEnabledState(
                for: folderURL.absoluteString, states: states, folderURL: folderURL)
        }
    }

    func toggleChapterEnabled(at index: Int) {
        guard state.chapters.indices.contains(index) else { return }
        state.chapters[index].isEnabled.toggle()
        if let currentTrackURL = state.tracks.indices.contains(state.currentIndex)
            ? state.tracks[state.currentIndex].url : nil
        {
            var states = persistence.loadEnabledState(for: currentTrackURL.absoluteString) ?? [:]
            states[state.chapters[index].id] = state.chapters[index].isEnabled
            persistence.saveEnabledState(for: currentTrackURL.absoluteString, states: states)
        }
    }

    // MARK: - Reset

    func resetPlaylist() {
        if state.chapters.count >= 2 {
            state.chapters.sort { $0.startSeconds < $1.startSeconds }
            for i in 0..<state.chapters.count {
                state.chapters[i].isEnabled = true
            }
            if let currentTrackURL = state.tracks.indices.contains(state.currentIndex)
                ? state.tracks[state.currentIndex].url : nil
            {
                persistence.saveOrder(
                    for: currentTrackURL.absoluteString, ids: state.chapters.map { $0.id })
                var states: [String: Bool] = [:]
                for c in state.chapters { states[c.id] = true }
                persistence.saveEnabledState(for: currentTrackURL.absoluteString, states: states)
            }
            coordinator_postResetRefresh?()
        } else {
            let currentURL =
                state.tracks.indices.contains(state.currentIndex)
                ? state.tracks[state.currentIndex].url : nil
            state.tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for i in 0..<state.tracks.count {
                state.tracks[i].isEnabled = true
            }
            if let folderURL = state.folderURL {
                persistence.saveOrder(
                    for: folderURL.absoluteString, ids: state.tracks.map { $0.id })
                var states: [String: Bool] = [:]
                for t in state.tracks { states[t.id] = true }
                persistence.saveEnabledState(for: folderURL.absoluteString, states: states)
            }
            if let currentURL, let newIdx = state.tracks.firstIndex(where: { $0.url == currentURL })
            {
                state.currentIndex = newIdx
            }
        }
    }
}
