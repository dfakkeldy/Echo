// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct HeadlessNarrationQAInputTests {
    @Test func manifestBuildsChapterInputsFromCaptureFilesWithoutSourceText() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-qa-work-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let capture = """
            {
              "duration": 2.5,
              "anchors": [
                { "suffix": "s0-b1", "time": 0.1 },
                { "suffix": "s0-b2", "time": 1.2 }
              ]
            }
            """
        try capture.write(
            to: folder.appending(path: ".anchors-ch3.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: folder.appending(path: "runner_Fixture_epub-ch3-af_heart-v7.m4a"))

        let chapters = try HeadlessNarrationQAManifest.chapters(
            audiobookID: "file:///Fixture/",
            workDir: folder
        )

        let chapter = try #require(chapters.first)
        #expect(chapters.count == 1)
        #expect(chapter.chapterIndex == 3)
        #expect(chapter.fileURL.lastPathComponent == "runner_Fixture_epub-ch3-af_heart-v7.m4a")
        #expect(chapter.spokenBlockIDs == [
            "epub-file:///Fixture/-s0-b1",
            "epub-file:///Fixture/-s0-b2",
        ])
    }
}
