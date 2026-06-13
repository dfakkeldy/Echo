import CarPlay
import SwiftUI
import os.log

// MARK: - CarPlay Manager

/// Manages the full CarPlay Pro experience with capture buttons on the Now
/// Playing template and browseable Library / Chapters / Bookmarks tabs.
///
/// All template population runs on the main actor because CarPlay templates
/// must be configured there and PlayerModel is @MainActor.
@MainActor
final class CarPlayManager: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private var libraryTemplate: CPListTemplate?
    private var chaptersTemplate: CPListTemplate?
    private var bookmarksTemplate: CPListTemplate?

    private let logger = Logger(category: "CarPlayManager")

    // MARK: - Lifecycle

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let nowPlaying = makeNowPlayingTemplate()
        libraryTemplate = makeLibraryTemplate()
        chaptersTemplate = makeChaptersTemplate()
        bookmarksTemplate = makeBookmarksTemplate()

        let tabBar = CPTabBarTemplate(templates: [
            nowPlaying,
            libraryTemplate!,
            chaptersTemplate!,
            bookmarksTemplate!
        ])
        interfaceController.setRootTemplate(tabBar, animated: false)

        // Populate lists with current data immediately.
        refreshLibrary()
        refreshChapters()
        refreshBookmarks()
    }

    func disconnect() {
        interfaceController = nil
        libraryTemplate = nil
        chaptersTemplate = nil
        bookmarksTemplate = nil
    }

    // MARK: - Now Playing with Capture Buttons

    private func makeNowPlayingTemplate() -> CPNowPlayingTemplate {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false

        // Fire-and-forget: create a bookmark at the current playback position.
        let bookmarkButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "bookmark")!,
            handler: { _ in
                NotificationCenter.default.post(name: .carPlayAddBookmark, object: nil)
            }
        )

        // Fire-and-forget: create a bookmark + start a voice memo recording.
        let memoButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "mic")!,
            handler: { _ in
                NotificationCenter.default.post(name: .carPlayVoiceMemo, object: nil)
            }
        )

        // Fire-and-forget: mark a passage at the current position.
        let markButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "rectangle.and.pencil.and.ellipsis")!,
            handler: { _ in
                NotificationCenter.default.post(name: .carPlayMarkPassage, object: nil)
            }
        )

        template.updateNowPlayingButtons([bookmarkButton, memoButton, markButton])
        return template
    }

    // MARK: - Library (parked only)

    private func makeLibraryTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Library"), sections: [CPListSection(items: [])])
        template.tabTitle = String(localized: "Library")
        template.tabImage = UIImage(systemName: "books.vertical")
        template.emptyViewTitleVariants = [String(localized: "No Books")]
        template.emptyViewSubtitleVariants = [String(localized: "Import an audiobook to get started")]
        return template
    }

    // MARK: - Chapters (parked only)

    private func makeChaptersTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Chapters"), sections: [])
        template.tabTitle = String(localized: "Chapters")
        template.tabImage = UIImage(systemName: "list.dash")
        template.emptyViewTitleVariants = [String(localized: "No Chapters")]
        template.emptyViewSubtitleVariants = [String(localized: "Chapters will appear while playing a book")]
        return template
    }

    // MARK: - Bookmarks (parked only)

    private func makeBookmarksTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Bookmarks"), sections: [])
        template.tabTitle = String(localized: "Bookmarks")
        template.tabImage = UIImage(systemName: "bookmark")
        template.emptyViewTitleVariants = [String(localized: "No Bookmarks")]
        template.emptyViewSubtitleVariants = [String(localized: "Add a bookmark from Now Playing")]
        return template
    }

    // MARK: - Data Population

    /// Queries the `audiobook` table and populates the Library tab.
    /// Displays title/author immediately, then loads cover thumbnails
    /// asynchronously via ArtworkCache and updates the template once done.
    func refreshLibrary() {
        guard let model = EchoCoreApp.playerModel,
              let db = model.databaseService else {
            showEmptyLibrary()
            return
        }

        let dao = AudiobookDAO(db: db.writer)
        let records: [AudiobookRecord]
        do {
            records = try dao.all()
        } catch {
            logger.error("Failed to query audiobooks: \(error.localizedDescription)")
            showEmptyLibrary()
            return
        }

        guard !records.isEmpty else {
            showEmptyLibrary()
            return
        }

        let items: [CPListItem] = records.map { record in
            let item = CPListItem(
                text: record.title,
                detailText: record.author ?? NowPlayingController.formatTime(record.duration)
            )
            // Selecting a book from the library loads it for playback.
            item.handler = { [weak model] _ in
                guard let model, let url = URL(string: record.id) else { return }
                model.loadFolder(url, autoplay: true)
            }
            return item
        }

        // Show text-only list immediately.
        libraryTemplate?.updateSections([CPListSection(items: items)])

        // Load cover thumbnails in the background and refresh when done.
        Task { @MainActor [weak self] in
            await self?.loadLibraryCoverThumbnails(records: records, items: items)
        }
    }

    /// Loads cover artwork thumbnails for each audiobook in the library using
    /// ArtworkCache (folder scan + embedded artwork), then updates the template.
    /// Concurrency is serial deliberately — each load may hit the file system
    /// or AVAsset, so one-at-a-time keeps memory pressure low on 16 GB machines.
    private func loadLibraryCoverThumbnails(records: [AudiobookRecord], items: [CPListItem]) async {
        for (index, record) in records.enumerated() {
            guard index < items.count else { break }
            guard let url = URL(string: record.id) else { continue }

            // ArtworkCache.folderArtworkImage takes a URL inside the folder and
            // uses deletingLastPathComponent() to derive the folder to scan.
            // We pass a synthetic child URL to trigger the folder scan correctly.
            let probeURL = url.appendingPathComponent("cover.jpg")
            guard let thumbnail = await ArtworkCache.folderArtworkImage(near: probeURL) else {
                continue
            }
            items[index].setImage(thumbnail)
        }

        // Single bulk update after all thumbnails are loaded.
        libraryTemplate?.updateSections([CPListSection(items: items)])
    }

    private func showEmptyLibrary() {
        let emptyItem = CPListItem(
            text: String(localized: "No Books"),
            detailText: String(localized: "Import an audiobook to get started")
        )
        emptyItem.isEnabled = false
        libraryTemplate?.updateSections([CPListSection(items: [emptyItem])])
    }

    /// Reads the current book's chapters and populates the Chapters tab.
    /// Supports both single-M4B and multi-M4B (aggregated) chapter lists.
    func refreshChapters() {
        guard let model = EchoCoreApp.playerModel else {
            showEmptyChapters()
            return
        }

        let chapterItems: [CPListItem]

        if model.isMultiM4B, !model.aggregatedChapters.isEmpty {
            chapterItems = model.aggregatedChapters.map { agg -> CPListItem in
                let title = agg.chapterTitle.isEmpty ? "Chapter \(agg.chapterIndex + 1)" : agg.chapterTitle
                let detail = "\(agg.bookTitle) · \(NowPlayingController.formatTime(agg.endSeconds - agg.startSeconds))"
                let item = CPListItem(text: title, detailText: detail)
                item.handler = { _ in
                    model.seekToAggregatedChapterPosition(
                        bookIndex: agg.bookIndex,
                        startSeconds: agg.startSeconds
                    )
                }
                return item
            }
        } else {
            chapterItems = model.chapters.filter { $0.isEnabled }.map { ch -> CPListItem in
                let title = ch.title ?? "Chapter \(ch.index + 1)"
                let detail = NowPlayingController.formatTime(ch.endSeconds - ch.startSeconds)
                let item = CPListItem(text: title, detailText: detail)
                item.handler = { _ in
                    model.seek(toSeconds: ch.startSeconds)
                }
                return item
            }
        }

        if chapterItems.isEmpty {
            showEmptyChapters()
            return
        }

        chaptersTemplate?.updateSections([CPListSection(items: chapterItems)])
    }

    private func showEmptyChapters() {
        let emptyItem = CPListItem(
            text: String(localized: "No Chapters"),
            detailText: String(localized: "Chapters will appear while playing a book")
        )
        emptyItem.isEnabled = false
        chaptersTemplate?.updateSections([CPListSection(items: [emptyItem])])
    }

    /// Reads the most recent 20 bookmarks for the current book.
    func refreshBookmarks() {
        guard let model = EchoCoreApp.playerModel else {
            showEmptyBookmarks()
            return
        }

        // Show up to 20 most recent bookmarks (suffix since they're sorted by timestamp).
        let recent = model.bookmarks.suffix(20)

        guard !recent.isEmpty else {
            showEmptyBookmarks()
            return
        }

        let items = recent.map { bm -> CPListItem in
            let item = CPListItem(
                text: bm.title,
                detailText: NowPlayingController.formatTime(bm.timestamp)
            )
            item.handler = { _ in
                model.jumpToBookmark(bm)
            }
            return item
        }

        bookmarksTemplate?.updateSections([CPListSection(items: items)])
    }

    private func showEmptyBookmarks() {
        let emptyItem = CPListItem(
            text: String(localized: "No Bookmarks"),
            detailText: String(localized: "Add a bookmark from Now Playing")
        )
        emptyItem.isEnabled = false
        bookmarksTemplate?.updateSections([CPListSection(items: [emptyItem])])
    }
}
