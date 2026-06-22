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
}
