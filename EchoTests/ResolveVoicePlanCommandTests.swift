// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct ResolveVoicePlanCommandTests {
    @Test func resolverReturnsCanonicalPlanWithoutLeavingWorkFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try archive(expanded, at: epub)
        let sourceSHA256 = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("plan.json")
        try Data(
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA256)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"}],"assignments":[]}
            """.utf8).write(to: planURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted()

        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)

        #expect(resolved.sourceEPUBSHA256 == sourceSHA256)
        #expect(resolved.defaultSpeakerID == "narrator")
        #expect(!resolved.blocks.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted() == before)
    }

    @Test func resolverRejectsNonEPUBSource() throws {
        let source = URL(fileURLWithPath: "/tmp/source.pdf")
        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.resolveVoicePlan(
                epubURL: source, voicePlanURL: URL(fileURLWithPath: "/tmp/plan.json"))
        }
    }

    private func archive(_ directory: URL, at destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
        for relativePath in files {
            let source = directory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let data = try Data(contentsOf: source)
            try archive.addEntry(
                with: relativePath, type: .file, uncompressedSize: Int64(data.count)) {
                    position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<min(start + size, data.count))
                }
        }
    }
}
