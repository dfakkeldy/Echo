// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderPDFViewModePreferenceTests {
    /// An isolated UserDefaults suite so tests never touch the shared domain.
    private func makeStore() -> UserDefaults {
        let name = "test.pdfviewmode.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func defaultsToPageWhenUnset() {
        let store = makeStore()
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func roundTripsSavedMode() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .reflow)
    }

    @Test func clearingRestoresDefault() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        BookPreferencesService.savePDFViewMode(nil, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func ignoresUnrecognisedRawValue() {
        let store = makeStore()
        store.set("garbage", forKey: BookPreferencesService.readerPDFViewModeKey(for: "book-1"))
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-1", store: store) == .page)
    }

    @Test func keysAreScopedPerBook() {
        let store = makeStore()
        BookPreferencesService.savePDFViewMode(.reflow, for: "book-1", store: store)
        #expect(BookPreferencesService.loadPDFViewMode(for: "book-2", store: store) == .page)
    }

    @Test func standaloneDocumentBookmarkRestoresOnlyWithinItsContainer() throws {
        let store = makeStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let pdf = container.appendingPathComponent("study.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)

        BookPreferencesService.saveSourceDocumentURL(
            pdf, for: container.absoluteString, store: store)

        #expect(
            BookPreferencesService.reopenDocumentURL(for: container, store: store) == pdf)
        let otherContainer = container.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(
            BookPreferencesService.reopenDocumentURL(for: otherContainer, store: store) == nil)
    }

    @Test func clearingStandaloneDocumentBookmarkRemovesReopenTarget() {
        let store = makeStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pdf = container.appendingPathComponent("study.pdf")
        BookPreferencesService.saveSourceDocumentURL(
            pdf, for: container.absoluteString, store: store)

        BookPreferencesService.saveSourceDocumentURL(
            nil, for: container.absoluteString, store: store)

        #expect(
            BookPreferencesService.reopenDocumentURL(for: container, store: store) == nil)
    }

    @Test func bookmarkCreationFailurePreservesLastWorkingBookmark() {
        let store = makeStore()
        let bookID = "book"
        let key = BookPreferencesService.sourceDocumentBookmarkKey(for: bookID)
        let workingBookmark = Data([0x01, 0x02, 0x03])
        store.set(workingBookmark, forKey: key)

        BookPreferencesService.saveSourceDocumentURL(
            URL(fileURLWithPath: "/provider/book.pdf"),
            for: bookID,
            store: store,
            makeBookmark: { _ in nil })

        #expect(store.data(forKey: key) == workingBookmark)
    }

    @Test func staleBookmarkIsRefreshedAfterResolution() throws {
        let store = makeStore()
        let bookID = "book"
        let key = BookPreferencesService.sourceDocumentBookmarkKey(for: bookID)
        let staleBookmark = Data([0xFF])
        store.set(staleBookmark, forKey: key)
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }

        let resolved = BookPreferencesService.sourceDocumentURL(
            for: bookID,
            store: store,
            resolveBookmark: { receivedData in
                #expect(receivedData == staleBookmark)
                return (pdf, true)
            })

        #expect(resolved == pdf)
        #expect(store.data(forKey: key) != staleBookmark)
    }
}
