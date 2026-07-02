// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacPlayerModel.swift
//  Echo macOS
//
//  macOS-native audiobook playback model. Wraps AVPlayer for playback and
//  delegates bookmark persistence to the shared BookmarkStore + DatabaseService.
//
//  The legacy MacBookmark type is retained for migration from the old JSON
//  sidecar format. Once migrated, bookmarks live in the shared database and
//  are visible to iOS/watchOS.

import AVFoundation
import AppKit
import Foundation
import GRDB
import ImageIO
import Observation
import Security
import Synchronization
import UniformTypeIdentifiers
import os.log

// MARK: - Legacy (migration source only)

/// Legacy bookmark format persisted as JSON sidecars + UserDefaults.
/// Retained ONLY for migration to the shared `Bookmark` + database store.
/// Do NOT add new functionality here — use `BookmarkStore` instead.
struct MacBookmark: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileBookmark: Data?
    var fileDisplayName: String
    var timestamp: TimeInterval
    var note: String?
    var createdAt: Date = Date()

    static func sidecarURL(for fileURL: URL) -> URL {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).json")
    }
}

// MARK: - MacPlayerModel

@MainActor
@Observable
final class MacPlayerModel {

    // MARK: Published state

    private(set) var currentURL: URL?
    private(set) var currentTitle: String = "No audiobook loaded"
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Cover art for the current file, surfaced to the macOS Now Playing (Media
    /// Center) info. Sourced from the audio file's embedded artwork with a
    /// folder-cover fallback — the same embedded→folder priority iOS uses (see
    /// `ArtworkCache`, which is UIKit-only and excluded from the macOS target).
    /// `nil` until loaded, or when neither source has artwork.
    private(set) var coverImage: NSImage?
    /// Author/artist for the current book, surfaced as the Now Playing
    /// album/subtitle line. Extracted from the audio file's metadata alongside
    /// the cover art. `nil` when the file has no artist metadata.
    private(set) var currentAuthor: String?
    /// The folder URL that contains the audiobook files. Used as the
    /// `audiobookID` for GRDB queries against the shared database.
    private(set) var folderURL: URL?
    /// The audiobook ID used for database lookups — derived from the folder URL.
    var audiobookID: String? { folderURL?.absoluteString }
    var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = playbackRate }
        }
    }
    /// Active loop behavior, both enforced by polling in the periodic time
    /// observer (macOS has no `AVAudioEngine` callbacks). `.chapter` repeats the
    /// current chapter (see `handleChapterBoundary`); `.bookmark` repeats the
    /// segment between consecutive bookmarks — A→B repeat — (see
    /// `handleBookmarkLoop`). The Playback Options popover demotes `.bookmark`
    /// to `.off` when the book has no bookmarks. `.off` is the default.
    var loopMode: LoopMode = .off
    /// Seconds for the back/forward skip transport buttons and the Playback-menu
    /// skip commands. User-configurable via the macOS Playback Options sheet
    /// (default 15). The fixed ±30s "long skip" menu commands ignore this.
    var skipInterval: Int = 15
    /// Seconds for the *backward* skip transport button / menu command, sourced
    /// from `settings.seekBackwardDuration`. iOS keeps forward/backward intervals
    /// independent; macOS previously reused `skipInterval` for both and silently
    /// ignored the persisted Skip-Backward setting.
    var skipBackInterval: Int = 15
    /// Injected once by `MacTriPaneView.task` (same pattern as `dbService`).
    /// On assignment we adopt the user's persisted skip interval and default
    /// speed so the macOS Settings → Playback pane (WS-J) actually drives playback.
    var settings: SettingsManager? {
        didSet { applySettings() }
    }

    private func applySettings() {
        guard let settings else { return }
        skipInterval = settings.seekForwardDuration
        skipBackInterval = settings.seekBackwardDuration
        // Drive the output-boost gain from settings (was hardcoded at +9 dB); the
        // `volumeBoostGain` didSet re-applies the audio mix when boost is enabled.
        volumeBoostGain = settings.volumeBoostGain
        // playbackRate's setter only touches `player.rate` while playing, so it is
        // safe to seed before play(); play() re-applies `playbackRate` on start.
        if !isPlaying {
            playbackRate = Float(settings.defaultPlaybackSpeed)
        }
    }
    /// Whether the +N dB output boost is applied to the AVPlayer audio path.
    /// Read/written on `UserDefaults.standard` under the same `global_volumeBoostEnabled`
    /// key the iOS `PlayerModel.isVolumeBoostEnabled` and the J2 Settings toggle use, so all
    /// three share one store (device-local; not iCloud-synced).
    var isVolumeBoostEnabled: Bool = UserDefaults.standard.bool(forKey: "global_volumeBoostEnabled")
    {
        didSet {
            UserDefaults.standard.set(isVolumeBoostEnabled, forKey: "global_volumeBoostEnabled")
            applyVolumeBoost()
        }
    }
    /// Boost amount in dB. Default +9 dB mirrors the iOS `setVolumeBoost` default.
    var volumeBoostGain: Float = 9.0 {
        didSet { if isVolumeBoostEnabled { applyVolumeBoost() } }
    }
    /// Shared linear-gain box read by the C process callback of the audio tap.
    private let boostGainBox = MacVolumeBoostGainBox()
    /// Shared bookmark store backed by the database.
    private(set) var bookmarkStore = BookmarkStore()
    /// Database service for bookmark persistence. Set by the app entry point.
    var dbService: DatabaseService? {
        didSet { configureStudyCheckpoint() }
    }

    // MARK: - Shared Services (Phase 3)

    /// Sleep timer with phase-based triggers (end-of-chapter, custom duration).
    let sleepTimer = SleepTimerManager()
    /// Chapter-checkpoint state machine. Created when the database arrives; the
    /// tri-pane panel observes its state.
    private(set) var checkpointCoordinator: StudyCheckpointCoordinator?
    @ObservationIgnored private let checkpointAnnouncer = StudyCheckpointAnnouncer()
    // Smart rewind is built per-resume from `settings` and gated on
    // `isRewindEnabled` (default OFF, matching iOS) — see `smartRewindAmount`.
    // The previous hardcoded policy ran unconditionally and used seconds where the
    // minute/hour tiers expect minutes/hours, so those tiers never fired.
    /// When playback was last paused (for smart-rewind calculation).
    private var pausedAt: Date?
    /// macOS Media Center / Now Playing metadata bridge.
    private let nowPlayingController = NowPlayingController()
    /// Whether sleep timer is active (set via UI).
    var sleepTimerMode: SleepTimerMode = .off {
        didSet {
            if sleepTimerMode != .off {
                sleepTimer.setTimer(sleepTimerMode)
            } else {
                sleepTimer.cancel()
            }
        }
    }
    /// Legacy bookmarks from the old JSON sidecar format (pre-migration).
    private(set) var legacyBookmarks: [MacBookmark] = []
    var openFileRequestToken: UUID = UUID()
    private(set) var tracks: [URL] = []
    private(set) var currentTrackIndex: Int = 0

    // MARK: Chapters (M4B markers within the current file)

    /// Chapters parsed from the currently-open file's M4B/M4A markers.
    /// Empty when the file has no markers (or only one) — see `ChapterService`.
    private(set) var chapters: [Chapter] = []
    /// Index of the chapter containing `currentTime`. 0 when `chapters` is empty.
    private(set) var currentChapterIndex: Int = 0
    /// Token guarding async chapter loads against a file swapped mid-load.
    private var chapterLoadToken = UUID()
    /// Token guarding async cover-art loads against a file swapped mid-load.
    private var artworkLoadToken = UUID()
    /// Title of the open file, captured before chapters override `currentTitle`.
    /// Restored when chapters are absent so the UI never shows a stale chapter name.
    private var fileTitle: String = "No audiobook loaded"

    /// True when the open file exposes navigable M4B chapters.
    /// When false, callers fall back to across-file track navigation.
    var hasChapters: Bool { chapters.count >= 2 }
    /// True when bookmark looping has at least one enabled A/B segment.
    var canBookmarkLoop: Bool {
        bookmarkStore.bookmarks.filter { $0.isEnabled && $0.timestamp.isFinite }.count >= 2
    }
    /// True when a previous chapter exists for in-file navigation.
    var hasPreviousChapter: Bool { hasChapters && currentChapterIndex > 0 }
    /// True when a next chapter exists for in-file navigation.
    var hasNextChapter: Bool { hasChapters && currentChapterIndex < chapters.count - 1 }

    private static let audioExtensions: Set<String> = ["mp3", "m4b", "m4a", "wav", "flac"]

    var hasMedia: Bool { currentURL != nil }
    var hasMultipleTracks: Bool { tracks.count > 1 }

    // MARK: Reader-source routing

    /// Monotonically increasing counter bumped after transcript materialization
    /// so `hasEPUB` (which observes it via SwiftUI's `@Observable` tracking)
    /// re-evaluates and the reader pane switches from "no content" to "blocks
    /// available".
    var documentIngestionTrigger = 0

    /// True when the loaded book has EPUB/PDF source text (visible blocks exist).
    /// Accesses `documentIngestionTrigger` so the observation system tracks it
    /// and SwiftUI views re-evaluate on bump.
    var hasEPUB: Bool {
        _ = documentIngestionTrigger
        guard let db = dbService, let id = audiobookID else { return false }
        return ((try? EPubBlockDAO(db: db.writer).count(for: id)) ?? 0) > 0
    }

    /// Call after transcript materialization or any other event that creates
    /// `epub_block` rows for a previously audio-only book. Increments the trigger
    /// counter so `hasEPUB` observers re-compute.
    func bumpDocumentIngestionTrigger() {
        documentIngestionTrigger += 1
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    // MARK: Internal

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentScopedURL: URL?
    private var libraryRootScopedURL: URL?
    private var hasLibraryRootScope = false
    private let defaults = AppGroupDefaults.shared
    private let bookmarksKey = "mac.bookmarks.v1"
    nonisolated private static let lastFileKey = "mac.lastFileBookmark.v1"
    nonisolated private static let lastFileBookmarkAccount = "macLastFileBookmark"
    private let resumeStateKey = MacPlaybackResumeState.storageKey
    private let resumePersistInterval: TimeInterval = 5
    private var lastResumePersistDate: Date?
    private var didStartLastFileRestore = false
    private var pendingCompanionDocumentImport: PendingCompanionDocumentImport?

    private struct PendingCompanionDocumentImport: Sendable {
        let folderURL: URL
        let audioFiles: [URL]
        let triggerAudioURL: URL
        let audiobookID: String
    }

    private struct CompanionDocumentImportContext: Sendable {
        let chapters: [Chapter]
        let duration: TimeInterval?
    }

    // MARK: - Audiobookshelf two-way sync (see MacPlayerModel+Audiobookshelf.swift)
    @ObservationIgnored var absService: AudiobookshelfService?
    @ObservationIgnored var absServiceServerID: String?
    @ObservationIgnored var absSyncRemoteItemID: String?
    @ObservationIgnored var absLastPushAt: TimeInterval?

    init() {
        migrateFromStandardUserDefaults()
        configureBookmarkStore()
        configureSleepTimer()
    }

    func restoreLastFileAfterLaunch() {
        guard !didStartLastFileRestore else { return }
        didStartLastFileRestore = true

        Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                Self.lastFileBookmarkData()
            }.value
            guard let data else { return }
            self?.restoreLastFile(from: data)
        }
    }

    private func configureSleepTimer() {
        sleepTimer.onFire = { [weak self] in
            self?.pause()
        }
    }

    /// Wires the BookmarkStore closures for DB-backed persistence.
    private func configureBookmarkStore() {
        bookmarkStore.onPersist = { [weak self] bookmarks in
            self?.persistBookmarks(bookmarks)
        }
        bookmarkStore.onBookmarksChanged = { [weak self] in
            self?.loadBookmarksFromDB()
        }
    }

    /// One-time migration from `UserDefaults.standard` to the shared App Group
    /// suite so bookmark records are visible to iOS/watchOS/widgets.
    ///
    /// Security-scoped last-file bookmarks are migrated directly to Keychain in
    /// `restoreLastFileAfterLaunch()` so they do not get copied into another plaintext
    /// defaults store.
    private func migrateFromStandardUserDefaults() {
        let migrationFlag = "mac.migratedToAppGroup.v1"
        guard !defaults.bool(forKey: migrationFlag) else { return }

        let standard = UserDefaults.standard
        for key in [bookmarksKey] {
            if let data = standard.data(forKey: key) {
                defaults.set(data, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationFlag)
    }

    deinit {
        // AVPlayer observer cleanup — assumes the main actor is still valid
        // during deinit (which holds for @MainActor classes).
        MainActor.assumeIsolated {
            persistResumeState()
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            currentScopedURL?.stopAccessingSecurityScopedResource()
            stopLibraryRootScope()
        }
    }

    // MARK: - Async helpers

    /// Awaits the AVPlayerItem becoming `.readyToPlay` with a valid duration,
    /// using KVO instead of a fragile hardcoded sleep. Times out after 10 s.
    private func waitForReadyToPlay() async {
        guard let item = player?.currentItem else { return }
        if item.status == .readyToPlay, duration > 0 { return }

        // The KVO status callback and the timeout below are two independent
        // resumers of the same continuation — a CheckedContinuation traps on
        // double resume. `ReadyToPlayGuard` is a Sendable Mutex-backed once-flag
        // that owns the continuation + observer so a single resume (and observer
        // invalidation) happens exactly once; KVO is not guaranteed to deliver on
        // the main thread (audit §3.8). The guard is Sendable because both the
        // @Sendable KVO closure and the timeout Task cross isolation to reach it
        // (Swift 6 strict concurrency).
        let guardBox = ReadyToPlayGuard()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = item.observe(\.status, options: [.new]) { observedItem, _ in
                guard observedItem.status == .readyToPlay || observedItem.status == .failed else {
                    return
                }
                guardBox.resume()
            }
            // Safety timeout — resume after 10 s if status never settles.
            // Swift Concurrency (cancellable Task) instead of GCD asyncAfter.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                guardBox.resume()
            }
            guardBox.arm(continuation: continuation, observer: observer, timeout: timeout)
        }
    }

    // MARK: File loading

    /// UI calls this to be told to present an open panel; we rely on a token bump
    /// so menu commands can drive the UI.
    func requestOpenFile() {
        openFileRequestToken = UUID()
    }

    func open(url: URL, preserveLibraryRoot: Bool = false) {
        if !preserveLibraryRoot {
            stopLibraryRootScope()
        }
        // Stop any current playback before swapping files.
        stop()

        currentURL = url
        let baseTitle = url.deletingPathExtension().lastPathComponent
        fileTitle = baseTitle
        currentTitle = baseTitle
        // Clear the previous file's chapter axis synchronously; the new file's
        // chapters are loaded asynchronously just below.
        chapters = []
        currentChapterIndex = 0
        // Drop stale cover art / author immediately so Now Playing never shows the
        // previous book's art; the new file's art is loaded asynchronously below.
        coverImage = nil
        currentAuthor = nil
        // Infer folder from the file's parent directory if not already set.
        if folderURL == nil {
            folderURL = url.deletingLastPathComponent()
        }
        refreshABSSyncIdentity()
        // If tracks is empty (single-file open, not folder), populate with this file.
        if tracks.isEmpty {
            tracks = [url]
            currentTrackIndex = 0
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        // Apply the persisted boost to this newly-loaded item.
        applyVolumeBoost()

        // Time observer for UI progress.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
                // Detect chapter boundary with the pre-advancement index, THEN
                // refresh the active chapter/title for the (possibly looped) position.
                self.handleChapterBoundary()
                self.handleBookmarkLoop()
                self.refreshCurrentChapter()
                self.updateNowPlayingElapsed()
                self.persistResumeStateThrottled()
                self.maybePushABSProgress()
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
                self.persistResumeState()
            }
        }

        saveLastFileBookmark(for: url)

        loadBookmarksFromDB()
        migrateLegacyBookmarksIfNeeded()
        loadChapters(for: url)
        loadCoverArt(for: url)
        restoreResumePositionIfNeeded()
        reconcileABSProgressOnLoad()
    }

    /// Asynchronously parses M4B chapter markers for `url` and installs them.
    /// Guarded by `chapterLoadToken` so a file swapped mid-load is ignored.
    private func loadChapters(for url: URL) {
        let token = UUID()
        chapterLoadToken = token
        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            let parsed = await ChapterService.parseChapters(from: asset)
            let loadedDuration = try? await asset.load(.duration).seconds
            guard let self = self, self.chapterLoadToken == token else { return }
            self.chapters = parsed
            if let loadedDuration, loadedDuration.isFinite, loadedDuration > 0 {
                self.duration = loadedDuration
            }
            // Re-derive the active chapter for the current playhead.
            self.refreshCurrentChapter()
            self.importPendingCompanionDocumentsIfNeeded(for: url, loadedChapters: parsed, loadedDuration: loadedDuration)
        }
    }

    /// Recomputes `currentChapterIndex` from `currentTime` and keeps
    /// `currentTitle` in sync with the active chapter when chapters exist.
    /// When chapters are absent, restores the plain file title.
    private func refreshCurrentChapter() {
        guard hasChapters else {
            currentChapterIndex = 0
            if currentTitle != fileTitle {
                currentTitle = fileTitle
                updateNowPlaying()
            }
            return
        }
        let idx =
            ChapterService.chapterIndex(forTime: currentTime, in: chapters)
            ?? currentChapterIndex
        if idx != currentChapterIndex {
            currentChapterIndex = idx
        }
        let chapterTitle = chapters[idx].title ?? fileTitle
        if currentTitle != chapterTitle {
            currentTitle = chapterTitle
            updateNowPlaying()
        }
    }

    func loadFolder(url folderURL: URL, preserveLibraryRoot: Bool = false) {
        if !preserveLibraryRoot {
            stopLibraryRootScope()
        }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil)
        else {
            return
        }

        let audioFiles =
            contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }

        guard !audioFiles.isEmpty else { return }

        self.folderURL = folderURL
        tracks = audioFiles
        persistFolderAudiobookToSQL(folderURL: folderURL, audioFiles: audioFiles)
        currentTrackIndex =
            loadResumeState()?
            .matchingTrackIndex(in: audioFiles, audiobookID: folderURL.absoluteString) ?? 0
        prepareCompanionDocumentImport(folderURL: folderURL, audioFiles: audioFiles)
        open(url: audioFiles[currentTrackIndex], preserveLibraryRoot: preserveLibraryRoot)
    }

    /// Recreates the checkpoint coordinator when the database arrives. Remote
    /// command reinterpretation does not apply on macOS, so remote grading stays
    /// off even if the shared settings store has an iOS value.
    private func configureStudyCheckpoint() {
        guard let db = dbService else {
            checkpointCoordinator = nil
            return
        }

        let coordinator = StudyCheckpointCoordinator(
            database: db,
            settingsProvider: { [weak self] in
                guard let settings = self?.settings else {
                    return StudyCheckpointSettings(
                        timeoutSeconds: SettingsManager.Defaults.checkpointTimeoutSeconds,
                        timeoutBehavior: .wait,
                        autoAdvance: SettingsManager.Defaults.checkpointAutoAdvance,
                        remoteGrading: false
                    )
                }
                return StudyCheckpointSettings(
                    timeoutSeconds: settings.checkpointTimeoutSeconds,
                    timeoutBehavior: CheckpointTimeoutBehavior(
                        rawValue: settings.checkpointTimeoutBehavior
                    ) ?? .wait,
                    autoAdvance: settings.checkpointAutoAdvance,
                    remoteGrading: false,
                    globalNewChapterLimit: settings.studyGlobalNewChapterLimit
                )
            },
            replayChapter: { [weak self] in
                guard let self else { return }
                self.seekToChapter(self.currentChapterIndex)
                self.play()
            },
            advance: { [weak self] item in
                self?.playCheckpointItem(item)
            },
            announce: { [weak self] cue in
                self?.checkpointAnnouncer.announce(cue)
            }
        )
        coordinator.pausePlayback = { [weak self] in self?.pause() }
        coordinator.isSleepStopRequested = { [weak self] in
            self?.sleepTimer.mode == .endOfChapter
        }
        coordinator.fireSleepStop = { [weak self] in
            self?.sleepTimer.evaluateAtChapterEnd()
        }
        coordinator.isPlayable = { item in
            guard let url = URL(string: item.audiobookID), url.isFileURL else { return true }
            return (try? url.checkResourceIsReachable()) ?? false
        }
        checkpointCoordinator = coordinator
    }

    /// Advances to a playable study item, loading its book first if needed.
    func playCheckpointItem(_ item: StudyPlayableItem) {
        let bookURL = URL(string: item.audiobookID) ?? URL(fileURLWithPath: item.audiobookID)
        if audiobookID != item.audiobookID {
            loadFolder(url: bookURL)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.seek(to: max(0, item.startTime + 0.05))
            self.play()
        }
    }

    private func persistFolderAudiobookToSQL(folderURL: URL, audioFiles: [URL]) {
        guard let db = dbService else { return }

        let audiobookID = folderURL.absoluteString
        let title = folderURL.deletingPathExtension().lastPathComponent
        do {
            let existing = try? AudiobookDAO(db: db.writer).get(audiobookID)
            let isABS = existing?.sourceType == "audiobookshelf"
            var audiobook =
                existing
                ?? AudiobookRecord(
                    id: audiobookID,
                    title: title,
                    author: nil,
                    duration: 0,
                    fileCount: audioFiles.count,
                    addedAt: Date().ISO8601Format()
                )
            if !isABS {
                audiobook.title = title
            }
            audiobook.fileCount = audioFiles.count
            audiobook.isAvailable = true

            let records = audioFiles.enumerated().map { index, audioURL in
                TrackRecord(
                    id: audioURL.absoluteString,
                    audiobookID: audiobookID,
                    title: audioURL.deletingPathExtension().lastPathComponent,
                    duration: 0,
                    filePath: audioURL.absoluteString,
                    isEnabled: true,
                    sortOrder: index,
                    playlistPosition: nil
                )
            }
            let trackDAO = TrackDAO(db: db.writer)
            try db.writer.write { database in
                var audiobookRecord = audiobook
                try audiobookRecord.save(database)
                try trackDAO.refreshAll(records, audiobookID: audiobookID, in: database)
            }
        } catch {
            Logger(category: "MacPlayerModel").error(
                "Failed to persist folder audiobook: \(error.localizedDescription)")
        }
    }

    private func prepareCompanionDocumentImport(folderURL: URL, audioFiles: [URL]) {
        guard dbService != nil else {
            pendingCompanionDocumentImport = nil
            return
        }
        guard audioFiles.indices.contains(currentTrackIndex) else {
            pendingCompanionDocumentImport = nil
            return
        }
        pendingCompanionDocumentImport = PendingCompanionDocumentImport(
            folderURL: folderURL,
            audioFiles: audioFiles,
            triggerAudioURL: audioFiles[currentTrackIndex],
            audiobookID: folderURL.absoluteString
        )
    }

    private func importPendingCompanionDocumentsIfNeeded(
        for audioURL: URL,
        loadedChapters: [Chapter],
        loadedDuration: TimeInterval?
    ) {
        guard let pending = pendingCompanionDocumentImport, pending.triggerAudioURL == audioURL else {
            return
        }
        pendingCompanionDocumentImport = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = pending.folderURL.startAccessingSecurityScopedResource()
            defer { if didStart { pending.folderURL.stopAccessingSecurityScopedResource() } }

            let context = await self.companionDocumentImportContext(
                audioFiles: pending.audioFiles,
                loadedAudioURL: audioURL,
                loadedChapters: loadedChapters,
                loadedDuration: loadedDuration
            )
            await self.importCompanionDocumentsIfNeeded(
                folderURL: pending.folderURL,
                audiobookID: pending.audiobookID,
                context: context
            )
        }
    }

    private func companionDocumentImportContext(
        loadedChapters: [Chapter],
        loadedDuration: TimeInterval?
    ) -> CompanionDocumentImportContext {
        let currentDuration = Self.finitePositiveDuration(duration)
        let finiteLoadedDuration = Self.finitePositiveDuration(loadedDuration)
        return CompanionDocumentImportContext(
            chapters: loadedChapters,
            duration: currentDuration ?? finiteLoadedDuration
        )
    }

    private func companionDocumentImportContext(
        audioFiles: [URL],
        loadedAudioURL: URL,
        loadedChapters: [Chapter],
        loadedDuration: TimeInterval?
    ) async -> CompanionDocumentImportContext {
        if audioFiles.count <= 1 {
            return companionDocumentImportContext(
                loadedChapters: loadedChapters,
                loadedDuration: loadedDuration
            )
        }

        var wholeBookChapters: [Chapter] = []
        var totalDuration: TimeInterval = 0

        for audioFile in audioFiles {
            let asset = AVURLAsset(url: audioFile)
            let parsedChapters: [Chapter]
            let measuredDuration: TimeInterval?
            if audioFile == loadedAudioURL {
                parsedChapters = loadedChapters
                if let finiteLoadedDuration = Self.finitePositiveDuration(loadedDuration) {
                    measuredDuration = finiteLoadedDuration
                } else {
                    measuredDuration = Self.finitePositiveDuration(
                        try? await asset.load(.duration).seconds)
                }
            } else {
                parsedChapters = await ChapterService.parseChapters(from: asset)
                measuredDuration = Self.finitePositiveDuration(try? await asset.load(.duration).seconds)
            }

            let trackDuration = measuredDuration ?? parsedChapters.map(\.endSeconds).max() ?? 0
            let cumulativeOffset = totalDuration
            if parsedChapters.isEmpty {
                wholeBookChapters.append(
                    Chapter(
                        index: wholeBookChapters.count,
                        title: audioFile.deletingPathExtension().lastPathComponent,
                        startSeconds: cumulativeOffset,
                        endSeconds: cumulativeOffset + trackDuration,
                        isEnabled: true
                    )
                )
            } else {
                for chapter in parsedChapters {
                    wholeBookChapters.append(
                        Chapter(
                            index: wholeBookChapters.count,
                            title: chapter.title,
                            startSeconds: cumulativeOffset + chapter.startSeconds,
                            endSeconds: cumulativeOffset + chapter.endSeconds,
                            isEnabled: chapter.isEnabled
                        )
                    )
                }
            }
            totalDuration += trackDuration
        }

        return CompanionDocumentImportContext(
            chapters: wholeBookChapters,
            duration: totalDuration > 0 ? totalDuration : nil
        )
    }

    private static func finitePositiveDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private func importCompanionDocumentsIfNeeded(
        folderURL: URL,
        audiobookID: String,
        context: CompanionDocumentImportContext
    ) async {
        guard let db = dbService else { return }

        let didImportEPUB = await EPUBAutoImportScanner.scanAndImportIfNeeded(
            folderURL: folderURL,
            databaseService: db,
            chapters: context.chapters,
            duration: context.duration
        )
        let didImportPDF =
            didImportEPUB
            ? false
            : await PDFAutoImportScanner.scanAndImportIfNeeded(
                folderURL: folderURL,
                databaseService: db,
                chapters: context.chapters,
                duration: context.duration
            )
        if didImportEPUB || didImportPDF {
            guard audiobookID == self.audiobookID else { return }
            bumpDocumentIngestionTrigger()
        }
    }

    func openLibraryBook(_ target: LibraryOpenTarget) {
        if let scopedRoot = target.scopedRoot {
            startLibraryRootScope(url: scopedRoot)
        } else {
            stopLibraryRootScope()
        }
        loadFolder(url: target.url, preserveLibraryRoot: true)
    }

    /// Loads a completed narrated book for playback by reading its rendered
    /// `TrackRecord` rows from the database. The synthesized chapter files live
    /// in Application Support/Narration — outside any user-selected folder — so
    /// the filesystem-scanning `loadFolder` can't discover them; this is the
    /// DB-driven counterpart. The narration cache is app-owned, so no
    /// security-scoped access is needed. Mirrors `loadFolder`'s state setup but
    /// sources the ordered file URLs from `TrackDAO`.
    func loadNarratedBook(audiobookID: String) {
        guard let db = dbService else { return }
        let records = (try? TrackDAO(db: db.writer).tracks(for: audiobookID)) ?? []
        let urls = NarrationTrackOrdering.orderedFileURLs(records)
        guard !urls.isEmpty else { return }

        // Restore the book's id as `folderURL` so the computed `audiobookID`
        // (and any bookmark / marked-passage writes that key off it) stay correct.
        // Set before `open(url:)`, which only fills these when still nil/empty.
        folderURL = URL(string: audiobookID)
        tracks = urls
        currentTrackIndex =
            loadResumeState()?
            .matchingTrackIndex(in: urls, audiobookID: audiobookID) ?? 0
        open(url: urls[currentTrackIndex])
    }

    /// Opens a standalone document (EPUB / PDF / Markdown / plain text) as an
    /// audio-less study book: imports its blocks into the shared database keyed by
    /// the document's identity and surfaces them in the reader. No audio is loaded.
    /// Mirrors the iOS `PlayerLoadingCoordinator.importDocumentForAudiolessBook`
    /// — the macOS open path was previously audio-only.
    func loadAudiolessDocument(url: URL) {
        guard let db = dbService else { return }

        // Tear down any current audio playback, then install the audio-less book
        // state. `folderURL` is the document's identity (its `absoluteString` is the
        // `audiobookID` the reader and importers key on); there is no audio track.
        stop()
        let didStart = url.startAccessingSecurityScopedResource()

        let audiobookID = url.absoluteString
        currentURL = nil
        folderURL = url
        let baseTitle = url.deletingPathExtension().lastPathComponent
        fileTitle = baseTitle
        currentTitle = baseTitle
        tracks = []
        currentTrackIndex = 0
        chapters = []
        currentChapterIndex = 0
        coverImage = nil
        currentAuthor = nil
        duration = 0
        currentTime = 0

        let ext = url.pathExtension.lowercased()
        Task { @MainActor [weak self] in
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if ext == "epub" {
                _ = await EPUBAutoImportScanner.importEPUBFile(
                    epubURL: url, audiobookID: audiobookID, databaseService: db,
                    chapters: [], duration: nil)
            } else if ["md", "markdown", "txt", "text"].contains(ext) {
                _ = await TextAutoImportScanner.importTextFile(
                    textURL: url, audiobookID: audiobookID, databaseService: db)
            } else if ext == "pdf" {
                _ = await PDFAutoImportScanner.importPDFFile(
                    pdfURL: url, audiobookID: audiobookID, databaseService: db,
                    chapters: [], duration: nil)
            }
            // Surface the imported (or previously-imported) blocks in the reader.
            self?.bumpDocumentIngestionTrigger()
        }
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

    // MARK: Chapter navigation
    //
    // Axis-reconciliation rule: when the current file exposes M4B chapters
    // (`hasChapters`), chapter nav seeks WITHIN the file. Otherwise these
    // methods fall back to across-file track navigation so the same UI
    // buttons keep working for folder books without markers.

    /// Advances to the next chapter (in-file) or the next track (no chapters).
    func nextChapter() {
        guard hasChapters else {
            nextTrack()
            return
        }
        if let nextIdx = ChapterService.nextEnabledIndex(after: currentChapterIndex, in: chapters) {
            seekToChapter(nextIdx)
        }
    }

    /// Goes to the previous chapter (in-file) or the previous track (no chapters).
    func previousChapter() {
        guard hasChapters else {
            previousTrack()
            return
        }
        if let prevIdx = ChapterService.prevEnabledIndex(before: currentChapterIndex, in: chapters)
        {
            seekToChapter(prevIdx)
        }
    }

    /// Seeks playback to the start of the chapter at `index`. No-op when the
    /// current file has no chapters or `index` is out of range.
    func seekToChapter(_ index: Int) {
        guard hasChapters, chapters.indices.contains(index) else { return }
        currentChapterIndex = index
        let chapter = chapters[index]
        seek(to: chapter.startSeconds)
        currentTime = chapter.startSeconds
        refreshCurrentChapter()
    }

    private func restoreLastFile(from data: Data) {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        else { return }

        if url.startAccessingSecurityScopedResource() {
            currentScopedURL?.stopAccessingSecurityScopedResource()
            currentScopedURL = url
        }
        open(url: url)
    }

    private func saveLastFileBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard KeychainStore.set(bookmark, for: .macLastFileBookmark) else {
                os_log(
                    .error, "Mac last-file bookmark Keychain save failed; file must be reselected")
                return
            }
            Self.removeLegacyLastFileBookmarkDefaults()
        } catch {
            os_log(
                .error, "Mac last-file bookmark save failed: %{private}@",
                error.localizedDescription)
        }
    }

    nonisolated private static func lastFileBookmarkData() -> Data? {
        if let data = keychainData(account: lastFileBookmarkAccount) {
            return data
        }
        guard
            let legacy = AppGroupDefaults.shared.data(forKey: lastFileKey)
                ?? UserDefaults.standard.data(forKey: lastFileKey)
        else {
            return nil
        }
        guard setKeychainData(legacy, account: lastFileBookmarkAccount) else {
            os_log(.error, "Mac last-file bookmark migration failed; file must be reselected")
            return nil
        }
        removeLegacyLastFileBookmarkDefaults()
        return legacy
    }

    nonisolated private static func keychainData(
        account: String, service: String = "com.echo.audiobooks"
    ) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    nonisolated private static func setKeychainData(
        _ data: Data, account: String, service: String = "com.echo.audiobooks"
    ) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        let addQuery = baseQuery.merging(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    nonisolated private static func removeLegacyLastFileBookmarkDefaults() {
        AppGroupDefaults.shared.removeObject(forKey: lastFileKey)
        UserDefaults.standard.removeObject(forKey: lastFileKey)
    }

    // MARK: Playback controls

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        configureRemoteCommandsIfNeeded()

        // Smart rewind on resume — gated on the user setting (default OFF, matching
        // iOS) and built from the configured thresholds, not a hardcoded policy.
        if isRewindEnabled, let pausedAt, currentTime > 0 {
            applySmartRewind(forPausedDuration: Date().timeIntervalSince(pausedAt))
        }
        pausedAt = nil

        player.rate = playbackRate
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        if isPlaying { pausedAt = Date() }
        player?.pause()
        isPlaying = false
        persistResumeState()
        maybePushABSProgress(force: true)
        updateNowPlaying()
    }

    func stop() {
        persistResumeState()
        maybePushABSProgress(force: true)
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
        sleepTimer.cancel()
        updateNowPlaying()
    }

    @discardableResult
    private func startLibraryRootScope(url: URL) -> Bool {
        if hasLibraryRootScope {
            if libraryRootScopedURL == url { return true }
            stopLibraryRootScope()
        }
        libraryRootScopedURL = url
        hasLibraryRootScope = url.startAccessingSecurityScopedResource()
        return hasLibraryRootScope
    }

    private func stopLibraryRootScope() {
        guard hasLibraryRootScope, let libraryRootScopedURL else {
            self.libraryRootScopedURL = nil
            hasLibraryRootScope = false
            return
        }
        libraryRootScopedURL.stopAccessingSecurityScopedResource()
        self.libraryRootScopedURL = nil
        hasLibraryRootScope = false
    }

    /// Updates the macOS Media Center (Now Playing) with current playback info.
    /// `title` is the stable book/file title; for chaptered files the chapter
    /// title and chapter-relative timing are supplied so the chapter branch in
    /// `NowPlayingController` activates (Title = chapter, Album = book). For
    /// non-chaptered files the author becomes the album line.
    private func updateNowPlaying() {
        var params = NowPlayingController.NowPlayingParams()
        params.title = fileTitle
        params.elapsed = currentTime
        params.duration = duration
        params.isPaused = !isPlaying
        params.playbackRate = playbackRate
        params.artworkImage = coverImage

        if hasChapters, chapters.indices.contains(currentChapterIndex) {
            let chapter = chapters[currentChapterIndex]
            params.subtitle = chapter.title ?? ""
            params.chapterIndex = currentChapterIndex
            params.chapterElapsed = max(0, currentTime - chapter.startSeconds)
            params.chapterDuration = chapter.endSeconds - chapter.startSeconds
        } else if let author = currentAuthor, !author.isEmpty {
            params.albumTitle = author
        }

        nowPlayingController.updateNowPlayingInfo(params)
    }

    /// Pushes a lightweight elapsed-time update to Now Playing at the time
    /// observer's tick rate (chapter-relative when chaptered) without rebuilding
    /// the whole metadata dictionary.
    private func updateNowPlayingElapsed() {
        let offset: TimeInterval? =
            hasChapters && chapters.indices.contains(currentChapterIndex)
            ? chapters[currentChapterIndex].startSeconds : nil
        nowPlayingController.updateElapsedTime(currentTime, chapterStartOffset: offset)
    }

    /// Wires Lock Screen / Control Center / media-key remote commands to the Mac
    /// transport. Idempotent (`NowPlayingController` guards re-entry). Without it,
    /// macOS published Now Playing metadata but registered no command targets, so
    /// media keys and Control Center buttons could not drive playback.
    private func configureRemoteCommandsIfNeeded() {
        nowPlayingController.configureRemoteCommands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextTrack: { [weak self] in self?.nextChapter() },
            skipBackward: { [weak self] in self?.skipBackward() },
            skipForward: { [weak self] in self?.skipForward() },
            previousTrack: { [weak self] in self?.previousChapter() },
            seek: { [weak self] position in self?.seek(to: position) },
            skipBackwardInterval: skipBackInterval,
            skipForwardInterval: skipInterval
        )
    }

    /// Whether resume-rewind is active, from settings (default OFF, matching iOS).
    private var isRewindEnabled: Bool {
        settings?.isRewindEnabled ?? SettingsManager.Defaults.isRewindEnabled
    }

    /// Rewinds the playhead on resume by the configured amount for `pausedDuration`,
    /// jumping to the chapter start for very long (hours-level) pauses when the
    /// user opted in — mirroring the iOS smart-rewind behavior. The plain rewind is
    /// clamped to the current chapter start so it never crosses a chapter boundary.
    private func applySmartRewind(forPausedDuration pausedDuration: TimeInterval) {
        let chapterFloor =
            hasChapters && chapters.indices.contains(currentChapterIndex)
            ? chapters[currentChapterIndex].startSeconds : 0

        if shouldJumpToChapterStartForHoursLevel(pausedDuration: pausedDuration),
            hasChapters, chapters.indices.contains(currentChapterIndex)
        {
            seek(to: chapterFloor)
            return
        }

        let rewind = smartRewindAmount(forPausedDuration: pausedDuration)
        guard rewind > 0 else { return }
        seek(to: max(chapterFloor, currentTime - rewind))
    }

    private func smartRewindAmount(forPausedDuration pausedDuration: TimeInterval) -> Double {
        let policy = SmartRewindPolicy(
            secondsThreshold: settings?.rewindPauseSecondsThreshold
                ?? SettingsManager.Defaults.rewindPauseSecondsThreshold,
            secondsAmount: settings?.rewindAmountAfterSeconds
                ?? SettingsManager.Defaults.rewindAmountAfterSeconds,
            minutesThreshold: settings?.rewindPauseMinutesThreshold
                ?? SettingsManager.Defaults.rewindPauseMinutesThreshold,
            minutesAmount: settings?.rewindAmountAfterMinutes
                ?? SettingsManager.Defaults.rewindAmountAfterMinutes,
            hoursThreshold: settings?.rewindPauseHoursThreshold
                ?? SettingsManager.Defaults.rewindPauseHoursThreshold,
            hoursAmount: settings?.rewindAmountAfterHours
                ?? SettingsManager.Defaults.rewindAmountAfterHours
        )
        return Double(policy.rewindAmount(forPausedDuration: pausedDuration))
    }

    private func shouldJumpToChapterStartForHoursLevel(pausedDuration: TimeInterval) -> Bool {
        let hoursThreshold =
            settings?.rewindPauseHoursThreshold
            ?? SettingsManager.Defaults.rewindPauseHoursThreshold
        let toChapterStart =
            settings?.rewindHoursToChapterStart
            ?? SettingsManager.Defaults.rewindHoursToChapterStart
        return toChapterStart && pausedDuration >= Double(hoursThreshold * 3600)
    }

    func skip(by seconds: Double) {
        guard player != nil else { return }
        let target = max(0, min(duration, currentTime + seconds))
        seek(to: target)
    }

    /// Forward transport skip by the user's forward interval.
    func skipForward() {
        skip(by: Double(skipInterval))
    }

    /// Backward transport skip by the user's *backward* interval, clamped to the
    /// current chapter's start so a back-skip never crosses into the prior chapter
    /// (mirrors the iOS chapter-aware back-skip).
    func skipBackward() {
        guard player != nil else { return }
        let floor =
            hasChapters && chapters.indices.contains(currentChapterIndex)
            ? chapters[currentChapterIndex].startSeconds : 0
        seek(to: max(floor, currentTime - Double(skipBackInterval)))
    }

    func seek(to seconds: Double) {
        guard let player = self.player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                self.refreshCurrentChapter()
                self.updateNowPlayingElapsed()
                self.persistResumeState()
                self.maybePushABSProgress()
            }
        }
    }

    private func persistResumeStateThrottled() {
        let now = Date()
        if let lastResumePersistDate,
            now.timeIntervalSince(lastResumePersistDate) < resumePersistInterval
        {
            return
        }
        persistResumeState(updatedAt: now)
    }

    private func persistResumeState(updatedAt: Date = Date()) {
        guard let currentURL else { return }
        let bookID = audiobookID ?? currentURL.deletingLastPathComponent().absoluteString
        let state = MacPlaybackResumeState(
            audiobookID: bookID,
            trackURL: currentURL.absoluteString,
            trackIndex: currentTrackIndex,
            position: currentTime,
            updatedAt: updatedAt
        )
        state.save(to: defaults)
        lastResumePersistDate = updatedAt
    }

    private func restoreResumePositionIfNeeded() {
        guard
            let state = loadResumeState(),
            let currentURL,
            state.matches(audiobookID: audiobookID, trackURL: currentURL)
        else {
            return
        }

        let knownDuration = duration > 0 ? duration : nil
        let position = state.clampedPosition(duration: knownDuration)
        guard position > 0 else { return }
        currentTime = position
        seek(to: position)
    }

    private func loadResumeState() -> MacPlaybackResumeState? {
        guard defaults.data(forKey: resumeStateKey) != nil else { return nil }
        return MacPlaybackResumeState.load(from: defaults)
    }

    /// Evaluates chapter-loop and end-of-chapter-sleep at the current instant.
    /// Called on every periodic time-observer tick BEFORE refreshCurrentChapter()
    /// so the boundary is detected with the pre-advancement chapter index.
    /// Pure decision is delegated to `MacChapterLoopDecision`; this only applies
    /// the side effect.
    private func handleChapterBoundary() {
        // Chapter checkpoint gets first claim on a naturally played boundary.
        // Only loop-off boundaries qualify; checkpoints never fire inside an
        // intentional chapter loop.
        if loopMode == .off,
            let coordinator = checkpointCoordinator,
            let bookID = audiobookID,
            chapters.indices.contains(currentChapterIndex),
            currentTime >= chapters[currentChapterIndex].endSeconds,
            coordinator.handleChapterEnd(
                audiobookID: bookID,
                chapterIndex: currentChapterIndex,
                naturalEnd: true
            )
        {
            return
        }

        let decision = MacChapterLoopDecision.evaluate(
            currentTime: currentTime,
            chapters: chapters,
            currentChapterIndex: currentChapterIndex,
            loopMode: loopMode,
            isEndOfChapterSleep: sleepTimer.mode == .endOfChapter
        )
        switch decision {
        case .none:
            break
        case .seek(let target):
            seek(to: target)
            currentTime = target
        case .fireSleep:
            sleepTimer.evaluateAtChapterEnd()
        }
    }

    /// Enforces the `.bookmark` (A→B) loop on each time-observer tick. Pulls the
    /// enabled bookmark timestamps (ascending), delegates the seek-back decision
    /// to the pure `MacBookmarkLoopDecision`, and applies it. A no-op unless
    /// `loopMode == .bookmark` and at least two enabled bookmarks exist.
    private func handleBookmarkLoop() {
        guard loopMode == .bookmark else { return }
        guard canBookmarkLoop else { return }
        let times =
            bookmarkStore.bookmarks
            .filter { $0.isEnabled && $0.timestamp.isFinite }
            .map(\.timestamp)
            .sorted()
        if let target = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: currentTime, bookmarkTimes: times, speed: playbackRate)
        {
            seek(to: target)
            currentTime = target
        }
    }

    /// Pushes the current boost setting into the shared gain box (read live by
    /// the audio tap) and ensures the current item has the boost audio mix.
    private func applyVolumeBoost() {
        boostGainBox.gain = MacVolumeBoost.linearGain(
            enabled: isVolumeBoostEnabled, gainDB: volumeBoostGain)
        installAudioMixIfNeeded()
    }

    /// Installs the MTAudioProcessingTap audio mix on the current AVPlayerItem.
    /// Safe to call repeatedly; only attaches when an item exists and no mix is
    /// set yet. The live gain is read from `boostGainBox`, so toggling boost on
    /// an already-mixed item does not require re-installing.
    private func installAudioMixIfNeeded() {
        guard let item = player?.currentItem else { return }
        if item.audioMix == nil {
            item.audioMix = MacAudioBoostTap.makeAudioMix(for: item, gainBox: boostGainBox)
        }
    }

    // MARK: Bookmarks (shared BookmarkStore)

    @discardableResult
    func addBookmarkAtCurrentTime(note: String? = nil) -> Bookmark? {
        guard currentURL != nil else { return nil }
        let trackId =
            tracks.indices.contains(currentTrackIndex)
            ? tracks[currentTrackIndex].absoluteString : nil
        let bm = bookmarkStore.addBookmark(
            at: currentTime,
            trackId: trackId,
            folderKey: audiobookID
        )
        if let note {
            bookmarkStore.updateBookmark(
                id: bm.id, title: bm.title,
                timestamp: bm.timestamp, note: note,
                voiceMemoFileName: bm.voiceMemoFileName)
        }
        return bm
    }

    func deleteBookmarks(at offsets: IndexSet) {
        let toDelete = offsets.compactMap { idx in
            bookmarkStore.bookmarks.indices.contains(idx) ? bookmarkStore.bookmarks[idx] : nil
        }
        for bm in toDelete {
            bookmarkStore.deleteBookmark(id: bm.id, folderURL: folderURL)
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarkStore.deleteBookmark(id: bookmark.id, folderURL: folderURL)
    }

    func updateBookmark(_ bookmark: Bookmark) {
        bookmarkStore.updateBookmark(
            id: bookmark.id, title: bookmark.title,
            timestamp: bookmark.timestamp, note: bookmark.note,
            voiceMemoFileName: bookmark.voiceMemoFileName,
            bookmarkImageFileName: bookmark.bookmarkImageFileName)
    }

    /// Seeks playback to the given bookmark's timestamp. If the bookmark
    /// belongs to a different file, loads that file first.
    func jumpTo(_ bookmark: Bookmark) {
        // BookmarkStore bookmarks are scoped to the current audiobook;
        // seek directly to the timestamp.
        if currentURL != nil {
            seek(to: bookmark.timestamp)
        }
    }

    // MARK: - Bookmark Persistence (DB-backed)

    private func persistBookmarks(_ bookmarks: [Bookmark]) {
        guard let audiobookID, let db = dbService else { return }
        let dao = BookmarkDAO(db: db.writer)
        do {
            try dao.deleteAll(for: audiobookID)
            for bm in bookmarks {
                try dao.insert(BookmarkRecord(from: bm))
            }
        } catch {
            Logger(category: "MacPlayerModel").error(
                "Failed to persist bookmarks: \(error.localizedDescription)")
        }
    }

    func loadBookmarksFromDB() {
        guard let audiobookID, let db = dbService else { return }
        do {
            let dao = BookmarkDAO(db: db.writer)
            let records = try dao.bookmarks(for: audiobookID)
            bookmarkStore.bookmarks = BookmarkRecord.decodeModelsSkippingCorruptRows(
                from: records,
                logger: Logger(category: "MacPlayerModel"),
                operation: "loading bookmarks from SQL"
            )
        } catch {
            Logger(category: "MacPlayerModel").error(
                "Failed to load bookmarks: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy Migration

    /// One-time migration: reads old JSON sidecar / UserDefaults bookmarks
    /// and inserts them into the shared database. Sets a flag so it only
    /// runs once.
    func migrateLegacyBookmarksIfNeeded() {
        let migrationFlag = "mac.bookmarks.migratedToDB.v1"
        guard !defaults.bool(forKey: migrationFlag),
            let url = currentURL,
            let audiobookID
        else { return }

        let sidecar = MacBookmark.sidecarURL(for: url)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        var legacy: [MacBookmark] = []

        // Try sidecar first
        if FileManager.default.fileExists(atPath: sidecar.path),
            let data = try? Data(contentsOf: sidecar),
            let decoded = try? JSONDecoder().decode([MacBookmark].self, from: data)
        {
            legacy = decoded
        }

        // Fall back to UserDefaults bucket
        if legacy.isEmpty, let data = defaults.data(forKey: bookmarksKey),
            let all = try? JSONDecoder().decode([MacBookmark].self, from: data)
        {
            legacy = all.filter { $0.fileDisplayName == url.lastPathComponent }
        }

        guard !legacy.isEmpty else {
            defaults.set(true, forKey: migrationFlag)
            return
        }

        // Insert into shared DB
        guard let db = dbService else { return }
        let dao = BookmarkDAO(db: db.writer)
        for old in legacy {
            let bm = Bookmark(
                title: old.title,
                folderKey: audiobookID,
                trackId: nil,
                timestamp: old.timestamp,
                note: old.note
            )
            do {
                try dao.insert(BookmarkRecord(from: bm))
            } catch {
                Logger(category: "MacPlayerModel").error(
                    "Legacy bookmark migration failed for \(old.title): \(error.localizedDescription)"
                )
            }
        }

        // Mark migration complete
        defaults.set(true, forKey: migrationFlag)
        // Reload from DB so bookmarkStore reflects migrated data
        loadBookmarksFromDB()
        Logger(category: "MacPlayerModel").info(
            "Migrated \(legacy.count) legacy bookmarks to shared database")
    }
}

// MARK: - ReadyToPlayGuard

/// Single-resume guard for `waitForReadyToPlay()`. The KVO status callback and
/// the timeout `Task` are two independent resumers of one `CheckedContinuation`,
/// which traps on a double resume. This `Sendable` Mutex-backed box owns the
/// continuation, the KVO observer, and the timeout so the *first* caller wins:
/// it invalidates the observer, cancels the timeout, and resumes exactly once.
/// It is `Sendable` (not main-actor-isolated) because the `@Sendable` KVO
/// closure and the timeout `Task` both reach it across isolation boundaries
/// under Swift 6 strict concurrency.
private nonisolated final class ReadyToPlayGuard: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var observer: NSKeyValueObservation?
        var timeout: Task<Void, Never>?
        var resumed = false
        /// Set when `resume()` fires before `arm()` has stored the continuation,
        /// so `arm()` can resume immediately rather than dropping the signal.
        var pendingResume = false
    }

    private let state = Mutex(State())

    /// Stores the continuation + cancellables. If a resumer already fired before
    /// arming, resume right away (and tear down) so we never wait forever.
    func arm(
        continuation: CheckedContinuation<Void, Never>,
        observer: NSKeyValueObservation,
        timeout: Task<Void, Never>
    ) {
        let resumeNow: Bool = state.withLock { s in
            if s.pendingResume {
                s.resumed = true
                return true
            }
            s.continuation = continuation
            s.observer = observer
            s.timeout = timeout
            return false
        }
        if resumeNow {
            observer.invalidate()
            timeout.cancel()
            continuation.resume()
        }
    }

    /// Resumes the continuation exactly once and tears down the observer/timeout.
    func resume() {
        let toResume: CheckedContinuation<Void, Never>? = state.withLock { s in
            guard !s.resumed else { return nil }
            s.resumed = true
            guard let continuation = s.continuation else {
                // Fired before `arm()`; let `arm()` resume when it stores it.
                s.pendingResume = true
                s.resumed = false
                return nil
            }
            s.observer?.invalidate()
            s.observer = nil
            s.timeout?.cancel()
            s.timeout = nil
            let continuationToResume = continuation
            s.continuation = nil
            return continuationToResume
        }
        toResume?.resume()
    }
}

// MARK: - Cover art

extension MacPlayerModel {
    /// Sources cover art for `url` (embedded artwork first, then a sibling folder
    /// cover) off the main actor and republishes Now Playing when it arrives.
    /// Guarded by `artworkLoadToken` so a file swapped mid-load is ignored. iOS
    /// does the equivalent via `ArtworkCache`, which is UIKit-only and excluded
    /// from the macOS target.
    fileprivate func loadCoverArt(for url: URL) {
        let token = UUID()
        artworkLoadToken = token
        let scopedRoot = libraryRootScopedURL
        Task { @MainActor [weak self] in
            let meta = await MacArtworkLoader.load(for: url, scopedRoot: scopedRoot)
            guard let self, self.artworkLoadToken == token else { return }
            self.coverImage = meta.image
            self.currentAuthor = meta.author
            self.updateNowPlaying()
        }
    }
}

/// macOS counterpart to the iOS-only `ArtworkCache` cover sourcing. Pure helpers
/// with no shared mutable state, returning `NSImage` — the type
/// `MPMediaItemArtwork` expects on macOS.
private enum MacArtworkLoader {
    struct BookMetadata {
        let image: NSImage?
        let author: String?
    }

    /// Reads the audio file's embedded cover art (`.commonKeyArtwork`) and author
    /// (`.commonKeyArtist`) in a single metadata pass, falling back to a sibling
    /// folder cover image when the file has no embedded artwork.
    static func load(for url: URL, scopedRoot: URL?) async -> BookMetadata {
        // Keep the library root reachable while reading (folder/library books hold
        // a long-lived root scope; ad-hoc single-file opens no-op here and rely on
        // the file already being open for playback).
        let rootDidStart = scopedRoot?.startAccessingSecurityScopedResource() ?? false
        defer { if rootDidStart { scopedRoot?.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var image: NSImage?
        var author: String?
        for item in metadata {
            if image == nil, item.commonKey == .commonKeyArtwork,
                let data = try? await item.load(.dataValue)
            {
                image = downsampledImage(from: data)
            }
            if author == nil, item.commonKey == .commonKeyArtist,
                let value = try? await item.load(.stringValue), !value.isEmpty
            {
                author = value
            }
        }
        if image == nil { image = folderArtworkImage(near: url) }
        return BookMetadata(image: image, author: author)
    }

    /// Falls back to a `cover.*` (or first, name-sorted) image file alongside the
    /// audio — the same heuristic `ArtworkCache.folderArtworkImage` uses on iOS.
    static func folderArtworkImage(near url: URL) -> NSImage? {
        let folderURL = url.deletingLastPathComponent()
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff",
        ]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }

        let preferred = images.first {
            $0.deletingPathExtension().lastPathComponent.lowercased() == "cover"
        }
        let selected =
            preferred
            ?? images.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }.first
        guard let selected, let data = try? Data(contentsOf: selected) else { return nil }
        return downsampledImage(from: data)
    }

    /// Decodes `data` to a downsampled `NSImage` (max 600px on the long edge).
    static func downsampledImage(from data: Data, maxPixelSize: Int = 600) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
