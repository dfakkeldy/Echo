//
//  OrbitAudioBooksTests.swift
//  OrbitAudioBooksTests
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import Testing
import Foundation
@testable import Orbit_Audiobooks

@MainActor
struct OrbitAudioBooksTests {

    @Test func playerDeepLinkParsesPlayURLWithoutTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "orbitaudio://play")!))

        #expect(link == .play(time: nil))
    }

    @Test func playerDeepLinkParsesPlayURLWithTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "orbitaudio://play?time=30")!))

        #expect(link == .play(time: 30))
    }

    @Test func playerDeepLinkRejectsUnregisteredScheme() {
        #expect(PlayerDeepLink(url: URL(string: "orbitaudiobooks://play?time=30")!) == nil)
    }

    @Test func bookmarkMarkdownUsesCanonicalDeepLinkScheme() {
        let bookmarks = [
            Bookmark(title: "Note", timestamp: 42.5, note: "Interesting", voiceMemoFileName: nil)
        ]

        let markdown = Bookmark.markdownExport(for: bookmarks)

        #expect(markdown.contains("[Play in App](orbitaudio://play?time=42.5)"))
        #expect(!markdown.contains("orbitaudiobooks://"))
    }

    @Test func bookmarkSidecarURLUsesFolderNameForDirectoryBooks() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sidecar = Bookmark.sidecarURL(for: folder)

        #expect(sidecar == folder.appendingPathComponent("\(folder.lastPathComponent).json"))
    }

    @Test func bookmarkSidecarURLUsesAudioBasenameForSingleFileBooks() {
        let file = URL(fileURLWithPath: "/tmp/Example Book.m4b")

        let sidecar = Bookmark.sidecarURL(for: file)

        #expect(sidecar.path == "/tmp/Example Book.json")
    }

    @Test func settingsRegisterLexendAsDefaultFont() {
        let suiteName = "settings-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)

        #expect(defaults.string(forKey: "appFont") == "Lexend")
    }

    @Test func settingsNormalizeLegacyHelveticaToSystemFont() {
        #expect(SettingsManager.normalizedAppFont("Helvetica") == SettingsManager.systemFontName)
    }

}
