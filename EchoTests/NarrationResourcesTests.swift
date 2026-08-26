// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationResourcesTests {
    @Test func envDirTakesPrecedenceWhenFileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("widget.json")
        try Data("{}".utf8).write(to: file)

        setenv("ECHO_RESOURCE_DIR", tmp.path, 1)
        defer { unsetenv("ECHO_RESOURCE_DIR") }

        let url = NarrationResources.url(forResource: "widget", withExtension: "json")
        #expect(url?.path == file.path)
    }

    @Test func fallsBackToBundleWhenEnvUnset() {
        unsetenv("ECHO_RESOURCE_DIR")
        // _kokoro_vocab.json is a real app-bundle resource.
        let url = NarrationResources.url(forResource: "_kokoro_vocab", withExtension: "json")
        #expect(url != nil)
    }

    @Test func echoCLICopiesCatalogVoiceResources() throws {
        let root = try Self.root()
        let project = try String(
            contentsOf: root.appending(path: "Echo.xcodeproj/project.pbxproj"),
            encoding: .utf8)

        #expect(project.contains("Copy all Kokoro voice resources"))
        #expect(project.contains("EchoCore/Resources"))
        #expect(project.contains("EchoNarrationResources"))

        for voice in VoiceCatalog.all {
            for ext in ["f32", "rows"] {
                let url = root.appending(path: "EchoCore/Resources/\(voice.id.rawValue).\(ext)")
                #expect(
                    FileManager.default.fileExists(atPath: url.path),
                    "\(voice.id.rawValue).\(ext) must exist for echo-cli resource packaging.")
            }
        }
    }

    private static func root() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appending(path: "Echo.xcodeproj").path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
