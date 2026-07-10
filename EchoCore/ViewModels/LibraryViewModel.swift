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
    @ObservationIgnored private let openBook: (LibraryOpenTarget) -> Void
    @ObservationIgnored private let logger = Logger(category: "LibraryViewModel")
    @ObservationIgnored private var siblingEditionsByBookID: [String: [AudiobookRecord]] = [:]
    @ObservationIgnored private var regroupTask: Task<Void, Never>?

    init(db: DatabaseService, openBook: @escaping (LibraryOpenTarget) -> Void) {
        self.database = db
        self.service = LibraryService(db: db)
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
            let bookIDs = sections.flatMap(\.books).map(\.id)
            statusMap = try service.statusMap(for: bookIDs)
            siblingEditionsByBookID = try service.siblingEditionsMap(
                for: sections.flatMap(\.books))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            siblingEditionsByBookID = [:]
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
            openBook(target)
            errorMessage = nil
        } catch {
            errorMessage = "This book can't be opened. Its folder may have moved."
            logger.error("Open failed for \(book.id): \(error.localizedDescription)")
        }
    }

    func siblingEditions(of book: AudiobookRecord) -> [AudiobookRecord] {
        siblingEditionsByBookID[book.id] ?? []
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
