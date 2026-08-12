// SPDX-License-Identifier: GPL-3.0-or-later
import Observation
import UIKit
import os.log

// MARK: - BookmarkArtworkCoordinator

/// Manages artwork display selection, caching, and thumbnail generation for
/// the Now Playing UI and Watch sync. Resolves whether to show base audio
/// artwork or a bookmark-specific image based on playback position.
@MainActor @Observable
final class BookmarkArtworkCoordinator {

    // MARK: - Artwork cache state

    @ObservationIgnored var baseWatchThumbnailData: Data? = nil
    @ObservationIgnored var currentDisplayArtworkKey: String?
    @ObservationIgnored var bookmarkArtworkCache: [String: (image: UIImage, watchData: Data?)] = [:]

    /// Display scale for thumbnail rendering. Set from the SwiftUI environment.
    var displayScale: CGFloat = 2.0

    // MARK: - Dependencies (set by PlayerModel)

    @ObservationIgnored var state: PlaybackState?
    @ObservationIgnored var bookmarkProvider: (() -> [Bookmark])?
    private let logger = Logger(category: "BookmarkArtwork")
    @ObservationIgnored var folderURLProvider: (() -> URL?)?
    @ObservationIgnored var trackIDProvider: (() -> String?)?
    @ObservationIgnored var isPlayingProvider: (() -> Bool)?
    @ObservationIgnored var currentPlaybackTimeProvider: (() -> TimeInterval)?
    @ObservationIgnored var onUpdateNowPlaying: ((Bool) -> Void)?
    @ObservationIgnored var onSyncToWatch: (() -> Void)?

    // MARK: - Derived state

    /// Key used to deduplicate artwork sent to the Watch.
    var currentArtworkSyncKey: String? {
        guard let trackId = trackIDProvider?() else { return nil }
        return "\(trackId)#\(currentDisplayArtworkKey ?? "base")"
    }

    /// True while a bookmark-specific image (not the base cover) is displayed.
    /// Theming extracts from the displayed bookmark image in that case instead
    /// of using the stored source-cover signature.
    var isShowingBookmarkArtwork: Bool {
        currentDisplayArtworkKey?.hasPrefix("bookmark:") == true
    }

    // MARK: - Thumbnail generation

    func generateThumbnail(for url: URL) async {
        let sourceImage: UIImage?
        if let embedded = await ArtworkCache.embeddedArtworkImage(for: url) {
            sourceImage = embedded
        } else if let folderImage = await ArtworkCache.folderArtworkImage(near: url) {
            sourceImage = folderImage
        } else {
            sourceImage = loadAppIconImage()
        }

        guard !Task.isCancelled, trackIDProvider?() == url.absoluteString else { return }

        guard let sourceImage else {
            clearUnavailableArtwork()
            return
        }

        let scale = displayScale
        let result = ArtworkCache.generateThumbnails(from: sourceImage, displayScale: scale)

        applyBaseArtwork(
            thumbnail: result.0, watchData: result.1,
            signature: DominantColorExtractor.signature(from: sourceImage))
    }

    func applyBaseArtwork(_ sourceImage: UIImage) {
        let result = ArtworkCache.generateThumbnails(from: sourceImage, displayScale: displayScale)
        applyBaseArtwork(
            thumbnail: result.0, watchData: result.1,
            signature: DominantColorExtractor.signature(from: sourceImage))
    }

    /// The signature is extracted from the SOURCE cover, never from the square
    /// blur-fill composite: the composite's margins and scrim dilute small vivid
    /// counter-colours below the accent-promotion floor.
    private func applyBaseArtwork(thumbnail: UIImage, watchData: Data?, signature: CoverSignature) {
        state?.thumbnailImage = thumbnail
        state?.sourceCoverSignature = signature
        baseWatchThumbnailData = watchData
        let currentTime = currentPlaybackTimeProvider?() ?? 0
        updateCurrentDisplayArtwork(at: currentTime, force: true)
    }

    // MARK: - Display artwork selection

    func updateCurrentDisplayArtwork(at currentTime: TimeInterval, force: Bool = false) {
        let bookmarks = bookmarkProvider?() ?? []
        let trackId = trackIDProvider?()
        let folderURL = folderURLProvider?()

        let activeBookmark = BookmarkStore.activeArtworkBookmark(
            from: bookmarks, at: currentTime, trackId: trackId)
        let nextKey =
            activeBookmark.flatMap { bookmark -> String? in
                guard let fileName = bookmark.bookmarkImageFileName else { return nil }
                return "bookmark:\(bookmark.id.uuidString):\(fileName)"
            } ?? "base"

        guard force || nextKey != currentDisplayArtworkKey else { return }
        currentDisplayArtworkKey = nextKey

        if let activeBookmark,
            let fileName = activeBookmark.bookmarkImageFileName,
            let imageURL = activeBookmark.bookmarkImageURL(in: folderURL)
        {
            let cacheKey = imageURL.path
            if let cached = bookmarkArtworkCache[cacheKey] {
                state?.currentDisplayArtwork = cached.image
                state?.watchThumbnailData = cached.watchData
            } else if let image = UIImage(contentsOfFile: imageURL.path) {
                let watchData = makeWatchThumbnailData(from: image)
                bookmarkArtworkCache[cacheKey] = (image, watchData)
                state?.currentDisplayArtwork = image
                state?.watchThumbnailData = watchData
            } else {
                logger.error("Failed to load bookmark artwork: \(fileName)")
                healBaseWatchThumbnailIfNeeded()
                state?.currentDisplayArtwork = state?.thumbnailImage
                state?.watchThumbnailData = baseWatchThumbnailData
            }
        } else {
            healBaseWatchThumbnailIfNeeded()
            state?.currentDisplayArtwork = state?.thumbnailImage
            state?.watchThumbnailData = baseWatchThumbnailData
        }

        state?.currentDisplayArtworkVersion += 1
        onUpdateNowPlaying?(!(isPlayingProvider?() ?? false))
        onSyncToWatch?()
    }

    // MARK: - Helpers

    func makeWatchThumbnailData(from image: UIImage) -> Data? {
        ArtworkCache.makeWatchThumbnailData(from: image)
    }

    func invalidateCache() {
        bookmarkArtworkCache.removeAll()
        baseWatchThumbnailData = nil
        clearDisplayArtwork()
    }

    /// Invalidates only bookmark-derived artwork, preserving the base cover's
    /// watch payload. Bookmark edits cannot change the base cover, and
    /// `baseWatchThumbnailData` is only regenerated on track load — a full
    /// `invalidateCache()` on every bookmark change left it nil mid-book, so
    /// every later watch context said `hasThumbnail: false` and the watch
    /// deleted its cover until the book was reloaded on the phone.
    func invalidateBookmarkArtwork() {
        bookmarkArtworkCache.removeAll()
    }

    /// Publishes the absence of artwork after all source fallbacks fail.
    /// Internal so tests can pin callback ordering without depending on app-icon
    /// resources in the unit-test host.
    func clearUnavailableArtwork() {
        state?.thumbnailImage = nil
        state?.sourceCoverSignature = nil
        baseWatchThumbnailData = nil
        clearDisplayArtwork()
        onUpdateNowPlaying?(!(isPlayingProvider?() ?? false))
        onSyncToWatch?()
    }

    /// Rebuilds the base cover's watch payload from the phone thumbnail when an
    /// earlier full invalidation dropped it mid-book (regeneration otherwise
    /// only happens on track load). Without this, the phone keeps showing its
    /// cover while telling the watch there is none. Runs at most once per
    /// display-key change, so the encode cost is not on the tick path.
    private func healBaseWatchThumbnailIfNeeded() {
        guard baseWatchThumbnailData == nil, let base = state?.thumbnailImage else { return }
        baseWatchThumbnailData = makeWatchThumbnailData(from: base)
    }

    private func clearDisplayArtwork() {
        currentDisplayArtworkKey = nil
        state?.currentDisplayArtwork = nil
        state?.watchThumbnailData = nil
        state?.currentDisplayArtworkVersion += 1
    }
}
