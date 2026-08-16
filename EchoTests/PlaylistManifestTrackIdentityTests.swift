// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// `.echoplaylist.json` stores a portable relative `file` name, while `Track.id`
/// is the track's absolute URL string. Every crossing between those two key
/// spaces has to translate, or saved order and enabled state silently stop
/// round-tripping for any folder that carries a manifest.
@Suite struct PlaylistManifestTrackIdentityTests {

    @Test func manifestKeysResolveToRealTrackIdentities() throws {
        // Deliberately not alphabetical: the manifest order must be what wins.
        let files = ["02-second.mp3", "01-first.mp3"]
        let folder = try Self.makeFolder(containing: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        Self.writeManifest(for: files, to: folder)

        // Build tracks the way PlaylistManager.load does, from a directory
        // listing, so the test also covers URL standardization.
        let listed = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let tracks =
            listed
            .filter { PlaylistManager.isAudioFile($0) }
            .map { Track(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
        #expect(tracks.count == files.count)

        let persistence = Self.isolatedPersistence()
        let order = try #require(
            persistence.loadOrder(for: folder.absoluteString, folderURL: folder))
        let states = try #require(
            persistence.loadEnabledState(for: folder.absoluteString, folderURL: folder))

        #expect(order == files.map { folder.appending(path: $0).absoluteString })
        for track in tracks {
            #expect(order.contains(track.id))
            #expect(states[track.id] != nil)
        }
    }

    @Test func disablingATrackSurvivesAReload() throws {
        let files = ["01.mp3", "02.mp3"]
        let folder = try Self.makeFolder(containing: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        Self.writeManifest(for: files, to: folder)

        let persistence = Self.isolatedPersistence()
        let key = folder.absoluteString
        let firstID = folder.appending(path: "01.mp3").absoluteString
        let secondID = folder.appending(path: "02.mp3").absoluteString

        var states = try #require(persistence.loadEnabledState(for: key, folderURL: folder))
        states[secondID] = false
        persistence.saveEnabledState(for: key, states: states, folderURL: folder)

        let reloaded = try #require(persistence.loadEnabledState(for: key, folderURL: folder))
        #expect(reloaded[secondID] == false)
        #expect(reloaded[firstID] == true)

        // The manifest stays portable: it keeps the relative file name.
        let manifest = try #require(PlaylistManifestService.read(from: folder))
        let secondTrack = manifest.tracks.first { $0.file == "02.mp3" }
        #expect(secondTrack?.enabled == false)
    }

    // MARK: - Helpers

    private static func makeFolder(containing files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appending(path: name))
        }
        return folder
    }

    private static func writeManifest(for files: [String], to folder: URL) {
        let manifest = EchoPlaylistManifest(
            version: 1,
            title: folder.lastPathComponent,
            author: nil,
            tracks: files.map {
                EchoPlaylistManifest.ManifestTrack(
                    file: $0, title: $0, duration: nil, enabled: true)
            },
            playbackState: EchoPlaylistManifest.ManifestPlaybackState(),
            bookmarks: nil
        )
        PlaylistManifestService.write(manifest, to: folder)
    }

    /// Keeps the UserDefaults fallback out of the way so the assertions can only
    /// pass via the manifest path, and avoids touching the Keychain.
    private static func isolatedPersistence() -> Persistence {
        Persistence(
            defaults: UserDefaults(suiteName: "PlaylistManifestTrackIdentityTests.\(UUID())")!,
            saveSecurityScopedBookmarkData: { _ in true },
            loadSecurityScopedBookmarkData: { nil }
        )
    }
}
