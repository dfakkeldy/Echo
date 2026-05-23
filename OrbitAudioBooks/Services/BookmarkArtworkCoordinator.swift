import UIKit
import Observation

// MARK: - BookmarkArtworkCoordinator

/// Manages artwork display selection, caching, and thumbnail generation for
/// the Now Playing UI and Watch sync. Resolves whether to show base audio
/// artwork or a bookmark-specific image based on playback position.
@Observable
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

        guard let sourceImage else {
            await MainActor.run {
                state?.thumbnailImage = nil
                state?.currentDisplayArtwork = nil
                state?.watchThumbnailData = nil
                baseWatchThumbnailData = nil
                currentDisplayArtworkKey = nil
                onUpdateNowPlaying?(!(isPlayingProvider?() ?? false))
                onSyncToWatch?()
            }
            return
        }

        let scale = displayScale
        let result = ArtworkCache.generateThumbnails(from: sourceImage, displayScale: scale)

        await MainActor.run {
            state?.thumbnailImage = result.0
            baseWatchThumbnailData = result.1
            let currentTime = currentPlaybackTimeProvider?() ?? 0
            updateCurrentDisplayArtwork(at: currentTime, force: true)
        }
    }

    // MARK: - Display artwork selection

    func updateCurrentDisplayArtwork(at currentTime: TimeInterval, force: Bool = false) {
        let bookmarks = bookmarkProvider?() ?? []
        let trackId = trackIDProvider?()
        let folderURL = folderURLProvider?()

        let activeBookmark = BookmarkStore.activeArtworkBookmark(from: bookmarks, at: currentTime, trackId: trackId)
        let nextKey = activeBookmark.flatMap { bookmark -> String? in
            guard let fileName = bookmark.bookmarkImageFileName else { return nil }
            return "bookmark:\(bookmark.id.uuidString):\(fileName)"
        } ?? "base"

        guard force || nextKey != currentDisplayArtworkKey else { return }
        currentDisplayArtworkKey = nextKey

        if let activeBookmark,
           let fileName = activeBookmark.bookmarkImageFileName,
           let imageURL = activeBookmark.bookmarkImageURL(in: folderURL) {
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
                print("Failed to load bookmark artwork: \(fileName)")
                state?.currentDisplayArtwork = state?.thumbnailImage
                state?.watchThumbnailData = baseWatchThumbnailData
            }
        } else {
            state?.currentDisplayArtwork = state?.thumbnailImage
            state?.watchThumbnailData = baseWatchThumbnailData
        }

        onUpdateNowPlaying?(!(isPlayingProvider?() ?? false))
        onSyncToWatch?()
        state?.currentDisplayArtworkVersion += 1
    }

    // MARK: - Helpers

    func makeWatchThumbnailData(from image: UIImage) -> Data? {
        ArtworkCache.makeWatchThumbnailData(from: image)
    }

    func invalidateCache() {
        bookmarkArtworkCache.removeAll()
        baseWatchThumbnailData = nil
        currentDisplayArtworkKey = nil
        state?.currentDisplayArtwork = nil
        state?.watchThumbnailData = nil
    }
}
