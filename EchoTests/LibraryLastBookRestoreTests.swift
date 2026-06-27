// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct LibraryLastBookRestoreTests {
    @Test func lastLibraryBookPointerRoundTrips() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = Persistence(defaults: defaults)

        #expect(persistence.lastLibraryBookID() == nil)

        persistence.saveLastLibraryBook(id: "file:///Lib/Dune/")

        #expect(persistence.lastLibraryBookID() == "file:///Lib/Dune/")
    }
}
