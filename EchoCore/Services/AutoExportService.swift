// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Pushes deterministic Markdown mirrors of study captures into a user-picked folder.
@MainActor
@Observable
final class AutoExportService {
    nonisolated static let subfolderName = "Echo Study Notes"
    private nonisolated static let logger = Logger(category: "AutoExport")

    private(set) var destinationDisplayPath: String?
    private(set) var needsFolderRepick = false
    private(set) var lastExportAt: Date?
    private(set) var lastErrorSummary: String?

    @ObservationIgnored private let database: DatabaseService
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        database: DatabaseService,
        isEnabled: @escaping () -> Bool,
        debounce: Duration = .seconds(5)
    ) {
        self.database = database
        self.isEnabled = isEnabled
        self.debounce = debounce
        refreshStatus()
    }

    func flushNow() async {
        guard isEnabled() else { return }
        debounceTask?.cancel()
        await markDirtyAndExport()
    }

    func enableAndBaseline() async {
        guard isEnabled() else { return }
        await markDirtyAndExport()
    }

    func destinationPicked(url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmark = LibraryAccess.makeBookmark(for: url) else {
            lastErrorSummary = "Couldn't keep access to that folder - pick it again."
            return
        }

        do {
            try StudyAutoExportDAO(db: database.writer)
                .saveDestination(bookmark: bookmark, displayPath: url.path)
            needsFolderRepick = false
            destinationDisplayPath = url.path
            lastErrorSummary = nil
            if isEnabled() {
                Task { await enableAndBaseline() }
            }
        } catch {
            lastErrorSummary = "Couldn't save the folder choice."
            Self.logger.error("saveDestination failed: \(error.localizedDescription)")
        }
    }

    func clearDestination() {
        do {
            try StudyAutoExportDAO(db: database.writer).clearDestination()
            destinationDisplayPath = nil
            needsFolderRepick = false
            lastErrorSummary = nil
        } catch {
            lastErrorSummary = "Couldn't clear the export folder."
            Self.logger.error("clearDestination failed: \(error.localizedDescription)")
        }
    }

    private func refreshStatus() {
        let destination = try? StudyAutoExportDAO(db: database.writer).destination()
        destinationDisplayPath = destination?.displayPath
        needsFolderRepick = destination?.needsRepick ?? false
    }

    private func markDirtyAndExport() async {
        let writer = database.writer
        do {
            try Self.markCapturedBooksDirty(writer: writer)
        } catch {
            lastErrorSummary = "Couldn't queue study notes for export."
            Self.logger.error("markCapturedBooksDirty failed: \(error.localizedDescription)")
        }

        let outcome = await Self.runPass(writer: writer)
        if outcome.exported > 0 || outcome.skipped > 0 {
            lastExportAt = .now
        }
        needsFolderRepick = outcome.needsRepick
        if outcome.needsRepick {
            lastErrorSummary = "The export folder moved or is unavailable. Re-select it to resume."
        } else if outcome.failed > 0 {
            lastErrorSummary = "Last export failed - will retry."
        } else {
            lastErrorSummary = nil
        }
    }
}

extension AutoExportService {
    struct PassOutcome: Equatable {
        var exported = 0
        var skipped = 0
        var failed = 0
        var needsRepick = false
    }

    static func markCapturedBooksDirty(writer: DatabaseWriter) throws {
        let bookIDs = try writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT audiobook_id FROM note
                    UNION
                    SELECT audiobook_id FROM bookmark
                    UNION
                    SELECT audiobook_id FROM flashcard
                    UNION
                    SELECT book_id FROM study_export_state
                    WHERE dirty = 1 OR file_name IS NOT NULL
                    """
            )
        }
        try StudyAutoExportDAO(db: writer).markDirty(bookIDs: bookIDs.sorted())
    }

    static func runPass(writer: DatabaseWriter) async -> PassOutcome {
        var outcome = PassOutcome()
        let dao = StudyAutoExportDAO(db: writer)

        guard let destination = try? dao.destination() else {
            return outcome
        }
        guard let resolved = LibraryAccess.resolveURL(from: destination.bookmark) else {
            try? dao.setNeedsRepick(true)
            outcome.needsRepick = true
            return outcome
        }
        if resolved.isStale, let refreshed = LibraryAccess.makeBookmark(for: resolved.url) {
            try? dao.saveDestination(bookmark: refreshed, displayPath: resolved.url.path)
        }

        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }

        let root = resolved.url.appending(path: subfolderName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            outcome.failed += max(1, ((try? dao.dirtyStates().count) ?? 0))
            logger.error("Cannot create export subfolder: \(error.localizedDescription)")
            return outcome
        }

        let source = StudyNotesExportDatabaseSource(databaseWriter: writer)
        guard let books = try? source.books(), let dirtyStates = try? dao.dirtyStates() else {
            outcome.failed += 1
            return outcome
        }
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })

        for state in dirtyStates {
            do {
                switch try await exportOne(
                    state: state,
                    booksByID: booksByID,
                    source: source,
                    dao: dao,
                    root: root
                ) {
                case .exported:
                    outcome.exported += 1
                case .skipped:
                    outcome.skipped += 1
                case .removed:
                    break
                }
            } catch {
                try? dao.recordFailure(bookID: state.bookId, error: error.localizedDescription)
                outcome.failed += 1
                logger.error("Export failed for \(state.bookId): \(error.localizedDescription)")
            }
        }

        return outcome
    }

    private enum ExportResult {
        case exported
        case skipped
        case removed
    }

    private static func exportOne(
        state: StudyExportStateRecord,
        booksByID: [String: StudyNotesExportService.Book],
        source: StudyNotesExportDatabaseSource,
        dao: StudyAutoExportDAO,
        root: URL
    ) async throws -> ExportResult {
        guard let book = booksByID[state.bookId] else {
            return try await removeMirrorAndState(state: state, dao: dao, root: root)
        }

        let bookmarks = try source.bookmarks(for: book.id)
        let notes = try source.notes(for: book.id)
        let cards = try source.cards(for: book.id)
        guard !(bookmarks.isEmpty && notes.isEmpty && cards.isEmpty) else {
            return try await removeMirrorAndState(state: state, dao: dao, root: root)
        }

        let chapters = try source.chapters(for: book.id)
        let markdown = AutoExportMarkdown.render(
            book: AutoExportMarkdown.BookContext(
                id: book.id,
                title: book.title,
                author: book.author,
                chapters: chapters
            ),
            bookmarks: bookmarks,
            notes: notes,
            cards: cards
        )
        let contentSha = AutoExportMarkdown.sha256Hex(markdown)
        let fileName = AutoExportMarkdown.fileName(bookID: book.id, title: book.title)

        if contentSha == state.contentSha256, fileName == state.fileName {
            try dao.recordSuccess(
                bookID: book.id,
                fileName: fileName,
                contentSha256: contentSha,
                at: Date.now.ISO8601Format()
            )
            return .skipped
        }

        try await writeOffMain(
            Data(markdown.utf8),
            to: root.appending(path: fileName, directoryHint: .notDirectory)
        )
        if let oldName = state.fileName, oldName != fileName {
            try? await deleteOffMain(root.appending(path: oldName, directoryHint: .notDirectory))
        }
        try dao.recordSuccess(
            bookID: book.id,
            fileName: fileName,
            contentSha256: contentSha,
            at: Date.now.ISO8601Format()
        )
        return .exported
    }

    private static func removeMirrorAndState(
        state: StudyExportStateRecord,
        dao: StudyAutoExportDAO,
        root: URL
    ) async throws -> ExportResult {
        if let fileName = state.fileName {
            try? await deleteOffMain(root.appending(path: fileName, directoryHint: .notDirectory))
        }
        try dao.removeState(bookID: state.bookId)
        return .removed
    }

    private static func writeOffMain(_ data: Data, to fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try AutoExportService.coordinatedWrite(data, to: fileURL)
        }.value
    }

    private static func deleteOffMain(_ fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try AutoExportService.coordinatedDelete(fileURL)
        }.value
    }

    private nonisolated static func coordinatedWrite(_ data: Data, to fileURL: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    private nonisolated static func coordinatedDelete(_ fileURL: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forDeleting,
            error: &coordinationError
        ) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let deleteError {
            throw deleteError
        }
    }
}
