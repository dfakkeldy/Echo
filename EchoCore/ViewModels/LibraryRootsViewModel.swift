// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import os.log

@MainActor
@Observable
final class LibraryRootsViewModel {
    var roots: [LibraryRootRecord] = []
    var isWorking = false
    var errorMessage: String?

    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private let service: LibraryService
    @ObservationIgnored private let logger = Logger(category: "LibraryRootsViewModel")

    init(db: DatabaseService) {
        self.db = db
        self.service = LibraryService(db: db)
    }

    func reload() {
        do {
            roots = try LibraryRootDAO(db: db.writer).all()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Library roots reload failed: \(error.localizedDescription)")
        }
    }

    func rescanAll() async {
        let ids = roots.map(\.id)
        for id in ids {
            await rescan(rootID: id)
        }
    }

    func rescan(rootID: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let root = try LibraryRootDAO(db: db.writer).get(rootID) else {
                reload()
                return
            }
            _ = try await service.rescan(
                root: root,
                readMetadata: { await LibraryScanner.readMetadata(for: $0) },
                coversDir: FileLocations.libraryCoversDirectory)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Library root rescan failed: \(error.localizedDescription)")
        }
    }

    func remove(rootID: String, forgetBooks: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try service.removeRoot(rootID: rootID, forgetBooks: forgetBooks)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Library root remove failed: \(error.localizedDescription)")
        }
    }

    func relocate(rootID: String, to newURL: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try service.relocateRoot(rootID: rootID, to: newURL)
            await rescan(rootID: rootID)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Library root relocate failed: \(error.localizedDescription)")
        }
    }
}
