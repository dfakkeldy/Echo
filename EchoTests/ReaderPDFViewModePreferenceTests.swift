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
}
