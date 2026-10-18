// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import os.log

@MainActor
@Observable
final class LibraryViewModel {
    var sections: [LibrarySection] = []
    var statusMap: [String: LibraryBookStatus] = [:]
    var selectedAxis: LibraryAxis = .recentlyAdded
    var showUnavailable = false
    var isScanning = false
    var errorMessage: String?
    var pendingRecoveryBook: AudiobookRecord?

    @ObservationIgnored let database: DatabaseService
    @ObservationIgnored private let service: LibraryService
    @ObservationIgnored private let mergeService: ReadAlongMergeService
    @ObservationIgnored private let openBook: (LibraryOpenTarget) throws -> Void
    @ObservationIgnored private let logger = Logger(category: "LibraryViewModel")
    @ObservationIgnored private var siblingEditionsByBookID: [String: [AudiobookRecord]] = [:]
    @ObservationIgnored private var booksWithText: Set<String> = []
    @ObservationIgnored private var regroupTask: Task<Void, Never>?
    @ObservationIgnored private var mergeTask: Task<Void, Never>?

    init(db: DatabaseService, openBook: @escaping (LibraryOpenTarget) throws -> Void) {
        self.database = db
        self.service = LibraryService(db: db)
        self.mergeService = ReadAlongMergeService(db: db)
        self.openBook = openBook
    }

    var isEmpty: Bool {
        sections.allSatisfy { $0.books.isEmpty }
    }

    static func smartLandingTab(hasCurrentBook: Bool) -> TabSelection {
        hasCurrentBook ? .nowPlaying : .library
    }

    func reload() {
        applyFetch()
        scheduleShelfRegroup()
    }

    /// Fetches and publishes sections/status/siblings. Split from `reload()` so
    /// the background regroup pass can re-publish without re-triggering itself.
    private func applyFetch() {
        do {
            sections = try service.sections(by: selectedAxis, includeUnavailable: showUnavailable)
            let visibleBooks = sections.flatMap(\.books)
            let bookIDs = visibleBooks.map(\.id)
            siblingEditionsByBookID = try service.siblingEditionsMap(for: visibleBooks)
            let siblingIDs = siblingEditionsByBookID.values.flatMap { $0.map(\.id) }
            statusMap = LibraryService.foldingSiblingStatuses(
                into: try service.statusMap(for: bookIDs + siblingIDs),
                visibleIDs: bookIDs,
                siblings: siblingEditionsByBookID)
            booksWithText = mergeService.audiobookIDsWithText().intersection(bookIDs)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            siblingEditionsByBookID = [:]
            booksWithText = []
            logger.error("Library reload failed: \(error.localizedDescription)")
        }
    }

    /// Awaits the in-flight shelf regroup pass, if any. Deterministic seam for
    /// tests; production callers rely on the pass re-publishing by itself.
    func awaitShelfRegroup() async {
        await regroupTask?.value
    }

    /// Single-flight enrichment + edition-regroup pass: overlapping reloads
    /// (axis switch, scan finish) must not stack passes; the running one
    /// re-fetches when it reports changes.
    private func scheduleShelfRegroup() {
        guard regroupTask == nil else { return }
        regroupTask = Task {
            defer { regroupTask = nil }
            if await service.regroupForShelfLoad() {
                applyFetch()
            }
        }
    }

    func selectAxis(_ axis: LibraryAxis) {
        selectedAxis = axis
        reload()
    }

    func setShowUnavailable(_ showUnavailable: Bool) {
        self.showUnavailable = showUnavailable
        reload()
    }

    func open(_ book: AudiobookRecord) {
        guard book.isAvailable else {
            pendingRecoveryBook = book
            return
        }
        do {
            let target = try service.urlForOpening(book)
            try openBook(target)
            errorMessage = nil
        } catch {
            if let openingError = error as? LibraryBookOpenError {
                errorMessage = openingError.localizedDescription
            } else {
                errorMessage = "This book can't be opened. Its folder may have moved."
            }
            logger.error("Open failed for \(book.id): \(error.localizedDescription)")
        }
    }

    func siblingEditions(of book: AudiobookRecord) -> [AudiobookRecord] {
        siblingEditionsByBookID[book.id] ?? []
    }

    /// Sibling TEXT editions eligible for "Use as Read-Along Text". Offered
    /// only on an audio card that has no `epub_block` rows yet: the import
    /// coordinator runs `force: true`, which would wipe existing text blocks
    /// and companion documents (spec Amendment A1 visibility guard).
    func readAlongCandidates(of book: AudiobookRecord) -> [AudiobookRecord] {
        let hasAudio = (book.fileCount ?? 0) > 0 || book.duration > 0
        guard hasAudio, !booksWithText.contains(book.id) else { return [] }
        return siblingEditions(of: book).filter {
            ($0.fileCount ?? 0) == 0 && $0.duration <= 0
        }
    }

    /// Imports `text`'s epub under `book`'s id so read-along works for the
    /// pair. The standalone text row is left untouched (cascade-delete risk).
    func useAsReadAlongText(_ text: AudiobookRecord, for book: AudiobookRecord) {
        isScanning = true
        mergeTask = Task {
            defer {
                isScanning = false
                mergeTask = nil
            }
            do {
                try await mergeService.merge(text: text, intoAudio: book, libraryService: service)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                logger.error(
                    "Read-along merge failed for \(book.id): \(error.localizedDescription)")
            }
        }
    }

    /// Awaits the in-flight read-along merge, if any. Deterministic seam for
    /// tests, mirroring `awaitShelfRegroup()`.
    func awaitReadAlongMerge() async {
        await mergeTask?.value
    }

    func separateEdition(_ book: AudiobookRecord) {
        do {
            try service.separateEdition(book)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Separate edition failed for \(book.id): \(error.localizedDescription)")
        }
    }

    func removePendingRecoveryBook() async {
        guard let book = pendingRecoveryBook else { return }
        do {
            try AudiobookDAO(db: database.writer).delete(book.id)
            pendingRecoveryBook = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Remove missing book failed: \(error.localizedDescription)")
        }
    }

    func relocatePendingRecoveryBook(to url: URL) async {
        guard let book = pendingRecoveryBook else { return }
        guard let rootID = book.sourceRootID else {
            errorMessage = "This book is no longer linked to a library root."
            return
        }
        isScanning = true
        defer { isScanning = false }
        do {
            try service.relocateRoot(rootID: rootID, to: url)
            if let root = try LibraryRootDAO(db: database.writer).get(rootID) {
                _ = try await service.rescan(
                    root: root,
                    readMetadata: { await LibraryScanner.readMetadata(for: $0) },
                    coversDir: FileLocations.libraryCoversDirectory)
            }
            pendingRecoveryBook = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Relocate missing book failed: \(error.localizedDescription)")
        }
    }

    func addRoot(url: URL) async {
        isScanning = true
        defer { isScanning = false }
        do {
            let root = try service.registerRoot(url: url)
            _ = try await service.rescan(
                root: root,
                readMetadata: { await LibraryScanner.readMetadata(for: $0) },
                coversDir: FileLocations.libraryCoversDirectory)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("addRoot failed: \(error.localizedDescription)")
        }
    }
}
