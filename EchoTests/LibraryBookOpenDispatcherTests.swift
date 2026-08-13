// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite("Library book opening")
struct LibraryBookOpenDispatcherTests {
    @Test("audio folders keep the audio route")
    func audioFolder() throws {
        try withTemporaryDirectory { folder in
            try Data("audio".utf8).write(to: folder.appendingPathComponent("chapter.m4b"))

            let route = try LibraryBookOpenDispatcher().route(
                for: LibraryOpenTarget(url: folder, scopedRoot: nil))

            #expect(route == .audioFolder(folder))
        }
    }

    @Test("generated anthology opens book.epub with its directory identity")
    func generatedAnthologyDirectoryIdentity() throws {
        try withTemporaryDirectory { editionDirectory in
            let epub = editionDirectory.appendingPathComponent("book.epub")
            try Data("epub".utf8).write(to: epub)

            let route = try LibraryBookOpenDispatcher().route(
                for: LibraryOpenTarget(url: editionDirectory, scopedRoot: nil))

            #expect(
                route == .audiolessDocument(
                    documentURL: epub,
                    audiobookIdentityURL: editionDirectory))
        }
    }

    @Test("standalone supported documents keep their own identity", arguments: [
        "epub", "pdf", "md", "markdown", "txt", "text",
    ])
    func standaloneDocument(fileExtension: String) throws {
        try withTemporaryDirectory { folder in
            let document = folder.appendingPathComponent("Study Book.\(fileExtension)")
            try Data("document".utf8).write(to: document)

            let route = try LibraryBookOpenDispatcher().route(
                for: LibraryOpenTarget(url: document, scopedRoot: nil))

            #expect(
                route == .audiolessDocument(
                    documentURL: document,
                    audiobookIdentityURL: document))
        }
    }

    @Test("mixed audio and companion document folders keep the audio route")
    func mixedFolder() throws {
        try withTemporaryDirectory { folder in
            try Data("audio".utf8).write(to: folder.appendingPathComponent("chapter.mp3"))
            try Data("epub".utf8).write(to: folder.appendingPathComponent("book.epub"))

            let route = try LibraryBookOpenDispatcher().route(
                for: LibraryOpenTarget(url: folder, scopedRoot: nil))

            #expect(route == .audioFolder(folder))
        }
    }

    @Test("missing targets fail instead of returning an audio route")
    func missingTarget() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoMissing-\(UUID().uuidString)")

        #expect(throws: LibraryBookOpenError.self) {
            _ = try LibraryBookOpenDispatcher().route(
                for: LibraryOpenTarget(url: missing, scopedRoot: nil))
        }
    }

    @Test("empty directories fail instead of silently returning")
    func emptyDirectory() throws {
        _ = try withTemporaryDirectory { folder in
            #expect(throws: LibraryBookOpenError.self) {
                _ = try LibraryBookOpenDispatcher().route(
                    for: LibraryOpenTarget(url: folder, scopedRoot: nil))
            }
        }
    }

    @Test("unreadable targets report a routing error")
    func unreadableTarget() {
        let targetURL = URL(fileURLWithPath: "/Library/Unreadable")
        let files = LibraryOpenFileAccess(
            kind: { _ in .directory },
            isReadable: { _ in false },
            directoryContents: { _ in [] })

        #expect(throws: LibraryBookOpenError.unreadable(targetURL)) {
            _ = try LibraryBookOpenDispatcher(files: files).route(
                for: LibraryOpenTarget(url: targetURL, scopedRoot: nil))
        }
    }

    @Test("successful dispatch retains the Library root for the player")
    func securityScopeSuccess() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Book", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appendingPathComponent("chapter.m4b"))
            var events: [String] = []

            try LibraryBookOpenDispatcher().open(
                LibraryOpenTarget(url: folder, scopedRoot: root),
                retainSecurityScope: { events.append("retain:\($0.path)") },
                releaseSecurityScope: { events.append("release") },
                openAudioFolder: { events.append("audio:\($0.path)") },
                openAudiolessDocument: { _, _ in events.append("document") })

            #expect(events == ["retain:\(root.path)", "audio:\(folder.path)"])
        }
    }

    @Test("failed dispatch balances the retained Library root")
    func securityScopeFailure() throws {
        try withTemporaryDirectory { root in
            let missing = root.appendingPathComponent("Missing")
            var events: [String] = []

            #expect(throws: LibraryBookOpenError.missing(missing)) {
                try LibraryBookOpenDispatcher().open(
                    LibraryOpenTarget(url: missing, scopedRoot: root),
                    retainSecurityScope: { _ in events.append("retain") },
                    releaseSecurityScope: { events.append("release") },
                    openAudioFolder: { _ in events.append("audio") },
                    openAudiolessDocument: { _, _ in events.append("document") })
            }

            #expect(events == ["retain", "release"])
        }
    }

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryBookOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }
}
