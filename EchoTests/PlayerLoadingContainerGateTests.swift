// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// The container-pick gate in `loadFolder`: a picked directory that yields no
/// tracks and directly holds no study document must not persist an audiobook
/// row (it is a container whose books live in subfolders — the exact source of
/// the dead, coverless Library cards).
@Suite struct PlayerLoadingContainerGateTests {
    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func trackLessFolderOfSubfoldersIsAContainerPick() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Audio exists only one level down — the shallow track scan misses it.
        let sub = folder.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("a.m4b").path, contents: Data())

        #expect(
            PlayerLoadingCoordinator.isContainerFolderPick(
                url: folder, isDirectory: true, hasTracks: false))
    }

    @Test func folderWithAStudyDocumentIsNotAContainerPick() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("book.epub").path, contents: Data())

        #expect(
            !PlayerLoadingCoordinator.isContainerFolderPick(
                url: folder, isDirectory: true, hasTracks: false))
    }

    @Test func folderWithTracksIsNotAContainerPick() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(
            !PlayerLoadingCoordinator.isContainerFolderPick(
                url: folder, isDirectory: true, hasTracks: true))
    }

    @Test func filePickIsNeverAContainerPick() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("weird.aiff")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(
            !PlayerLoadingCoordinator.isContainerFolderPick(
                url: file, isDirectory: false, hasTracks: false))
    }
}
