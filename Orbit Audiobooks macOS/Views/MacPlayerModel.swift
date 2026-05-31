//
//  MacPlayerModel.swift
//  Orbit Audiobooks macOS
//
//  Minimal macOS-native audiobook playback model. Wraps AVPlayer for playback
//  and persists a simple list of bookmarks to UserDefaults.
//

import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import os.log

struct MacBookmark: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileBookmark: Data?     // security-scoped bookmark for the audiobook file
    var fileDisplayName: String
    var timestamp: TimeInterval
    var note: String?
    var createdAt: Date = Date()

    /// Resolves the on-disk URL for the `[BookName].json` bookmark sidecar
    /// that lives alongside the audiobook file.
    static func sidecarURL(for fileURL: URL) -> URL {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).json")
    }
}

@MainActor
@Observable
final class MacPlayerModel {

    // MARK: Published state

    private(set) var currentURL: URL?
    private(set) var currentTitle: String = "No audiobook loaded"
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = playbackRate }
        }
    }
    private(set) var bookmarks: [MacBookmark] = []
    var openFileRequestToken: UUID = UUID() // bumped to ask UI to show opener
    private(set) var tracks: [URL] = []
    private(set) var currentTrackIndex: Int = 0

    private static let audioExtensions: Set<String> = ["mp3", "m4b", "m4a", "wav", "flac"]

    var hasMedia: Bool { currentURL != nil }
    var hasMultipleTracks: Bool { tracks.count > 1 }
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    // MARK: Internal

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentScopedURL: URL?
    private let defaults = AppGroupDefaults.shared
    private let bookmarksKey = "mac.bookmarks.v1"
    private let lastFileKey = "mac.lastFileBookmark.v1"

    init() {
        migrateFromStandardUserDefaults()
        restoreLastFile()
    }

    /// One-time migration from `UserDefaults.standard` to the shared App Group
    /// suite so bookmarks and last-file data are visible to iOS/watchOS/widgets.
    private func migrateFromStandardUserDefaults() {
        let migrationFlag = "mac.migratedToAppGroup.v1"
        guard !defaults.bool(forKey: migrationFlag) else { return }

        let standard = UserDefaults.standard
        for key in [bookmarksKey, lastFileKey] {
            if let data = standard.data(forKey: key) {
                defaults.set(data, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationFlag)
    }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        currentScopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Async helpers

    /// Awaits the AVPlayerItem becoming `.readyToPlay` with a valid duration,
    /// using KVO instead of a fragile hardcoded sleep. Times out after 10 s.
    private func waitForReadyToPlay() async {
        guard let item = player?.currentItem else { return }
        if item.status == .readyToPlay, duration > 0 { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var observer: NSKeyValueObservation?
            observer = item.observe(\.status, options: [.new]) { observedItem, _ in
                if observedItem.status == .readyToPlay {
                    observer?.invalidate()
                    continuation.resume()
                } else if observedItem.status == .failed {
                    observer?.invalidate()
                    continuation.resume()
                }
            }
            // Safety timeout — resume after 10 s if status never settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                observer?.invalidate()
                continuation.resume()
            }
        }
    }

    // MARK: File loading

    /// UI calls this to be told to present an open panel; we rely on a token bump
    /// so menu commands can drive the UI.
    func requestOpenFile() {
        openFileRequestToken = UUID()
    }

    func open(url: URL) {
        // Stop any current playback before swapping files.
        stop()

        currentURL = url
        currentTitle = url.deletingPathExtension().lastPathComponent
        // If tracks is empty (single-file open, not folder), populate with this file.
        if tracks.isEmpty {
            tracks = [url]
            currentTrackIndex = 0
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        // Time observer for UI progress.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }

        // Persist a security-scoped bookmark so we can reopen on next launch.
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: lastFileKey)
        }

        loadBookmarks(for: url)
    }

    func loadFolder(url folderURL: URL) {
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
            return
        }

        let audioFiles = contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !audioFiles.isEmpty else { return }

        tracks = audioFiles
        currentTrackIndex = 0
        open(url: audioFiles[0])
    }

    func nextTrack() {
        guard hasMultipleTracks else { return }
        let nextIndex = currentTrackIndex + 1
        guard nextIndex < tracks.count else { return }
        currentTrackIndex = nextIndex
        open(url: tracks[nextIndex])
    }

    func previousTrack() {
        guard hasMultipleTracks else { return }
        let prevIndex = currentTrackIndex - 1
        guard prevIndex >= 0 else { return }
        currentTrackIndex = prevIndex
        open(url: tracks[prevIndex])
    }

    private func restoreLastFile() {
        guard let data = defaults.data(forKey: lastFileKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }

        if url.startAccessingSecurityScopedResource() {
            currentScopedURL?.stopAccessingSecurityScopedResource()
            currentScopedURL = url
        }
        open(url: url)
    }

    // MARK: Playback controls

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        player.rate = playbackRate
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        let target = max(0, min(duration, currentTime + seconds))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        guard let player = self.player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
            }
        }
    }

    // MARK: Bookmarks

    @discardableResult
    func addBookmarkAtCurrentTime(note: String? = nil) -> MacBookmark? {
        guard let url = currentURL else { return nil }
        let scopedBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let bm = MacBookmark(
            title: "Bookmark \(bookmarks.count + 1)",
            fileBookmark: scopedBookmark,
            fileDisplayName: url.lastPathComponent,
            timestamp: currentTime,
            note: note
        )
        bookmarks.append(bm)
        saveBookmarks()
        return bm
    }

    func deleteBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    func deleteBookmark(_ bookmark: MacBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }

    func updateBookmark(_ bookmark: MacBookmark) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[idx] = bookmark
        saveBookmarks()
    }

    /// Resolves bookmark file (using its security-scoped data) and seeks to it,
    /// loading the file if necessary.
    func jumpTo(_ bookmark: MacBookmark) {
        let proceed: (URL) -> Void = { [weak self] resolvedURL in
            guard let self else { return }
            if self.currentURL != resolvedURL {
                self.open(url: resolvedURL)
                // Await the player item becoming ready before seeking,
                // instead of a fragile hardcoded 300ms sleep.
                Task { @MainActor in
                    await self.waitForReadyToPlay()
                    self.seek(to: bookmark.timestamp)
                }
            } else {
                self.seek(to: bookmark.timestamp)
            }
        }

        if let data = bookmark.fileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    currentScopedURL?.stopAccessingSecurityScopedResource()
                    currentScopedURL = url
                }
                proceed(url)
                return
            }
        }
        // Fallback: seek in current file if names match.
        if let current = currentURL, current.lastPathComponent == bookmark.fileDisplayName {
            proceed(current)
        }
    }

    /// Writes the current `bookmarks` array to the `[BookName].json` sidecar
    /// alongside the audiobook file (primary store), and mirrors them into
    /// `mac.bookmarks.v1` UserDefaults as a backup (merged with bookmarks
    /// belonging to other audiobooks so we don't clobber them).
    private func saveBookmarks() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let url = currentURL {
            let sidecar = MacBookmark.sidecarURL(for: url)
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try encoder.encode(bookmarks)
                try data.write(to: sidecar, options: .atomic)
            } catch {
#if DEBUG
                let logger = Logger(subsystem: "com.orbitaudiobooks", category: "MacPlayerModel")
                logger.error("Bookmark sidecar write failed at \(sidecar.lastPathComponent): \(error.localizedDescription)")
#endif
            }
        }

        // Backup: rewrite the global UserDefaults list by replacing all
        // entries that belong to the current file with the in-memory list.
        let currentName = currentURL?.lastPathComponent
        var allBookmarks: [MacBookmark] = []
        if let data = defaults.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([MacBookmark].self, from: data) {
            allBookmarks = decoded.filter { $0.fileDisplayName != currentName }
        }
        allBookmarks.append(contentsOf: bookmarks)
        if let data = try? encoder.encode(allBookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    /// Loads bookmarks for the given audiobook URL. Prefers the
    /// `[BookName].json` sidecar; falls back to filtering the legacy
    /// `mac.bookmarks.v1` UserDefaults entry by display name. If a sidecar
    /// is missing but legacy data exists for the file, the sidecar is
    /// created so future loads are sidecar-driven.
    private func loadBookmarks(for url: URL) {
        let sidecar = MacBookmark.sidecarURL(for: url)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: sidecar.path),
           let data = try? Data(contentsOf: sidecar),
           let decoded = try? JSONDecoder().decode([MacBookmark].self, from: data) {
            bookmarks = decoded
            return
        }

        // Migrate from legacy global UserDefaults bucket.
        let displayName = url.lastPathComponent
        guard let data = defaults.data(forKey: bookmarksKey),
              let all = try? JSONDecoder().decode([MacBookmark].self, from: data) else {
            bookmarks = []
            return
        }
        let migrated = all.filter { $0.fileDisplayName == displayName }
        bookmarks = migrated

        if !migrated.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let migratedData = try? encoder.encode(migrated) {
                try? migratedData.write(to: sidecar, options: .atomic)
            }
        }
    }
}
