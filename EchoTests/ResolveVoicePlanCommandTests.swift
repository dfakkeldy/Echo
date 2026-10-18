// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct ResolveVoicePlanCommandTests {
    @Test func commandPrintsTheExactCanonicalIdentity() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        try "<html><body></body></html>".write(
            to: expanded.appendingPathComponent("OEBPS/chap01.xhtml"),
            atomically: true,
            encoding: .utf8)
        try "<html><body></body></html>".write(
            to: expanded.appendingPathComponent("OEBPS/chap02.xhtml"),
            atomically: true,
            encoding: .utf8)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try archive(expanded, at: epub)
        let sourceSHA256 = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("plan.json")
        try Data(
            "{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"\(sourceSHA256)\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"voiceID\":\"af_heart\"}],\"assignments\":[]}".utf8
        ).write(to: planURL)
        let canonicalPlan = "{\"blocks\":[{\"blockID\":\"s0-b0\",\"speakerID\":\"narrator\",\"voiceID\":\"af_heart\"},{\"blockID\":\"s1-b0\",\"speakerID\":\"narrator\",\"voiceID\":\"af_heart\"}],\"defaultSpeakerID\":\"narrator\",\"schemaVersion\":1,\"sourceEPUBSHA256\":\"\(sourceSHA256)\"}"
        let voicePlanSHA256 = SHA256.hash(data: Data(canonicalPlan.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let expected = "{\"blockCount\":2,\"defaultVoice\":\"af_heart\",\"sourceEPUBSHA256\":\"\(sourceSHA256)\",\"voicePlanID\":\"plan-\(voicePlanSHA256.prefix(12))\",\"voicePlanSHA256\":\"\(voicePlanSHA256)\"}"
        var stdout: [String] = []

        try ResolveVoicePlanCommand.run(
            epubURL: epub,
            voicePlanURL: planURL,
            writeStandardOutput: { stdout.append($0) })

        #expect(stdout == [expected])
    }

    @Test func commandRejectsInvalidSourceWithoutWritingOutput() {
        var stdout: [String] = []

        #expect(throws: Error.self) {
            try ResolveVoicePlanCommand.run(
                epubURL: URL(fileURLWithPath: "/tmp/source.pdf"),
                voicePlanURL: URL(fileURLWithPath: "/tmp/plan.json"),
                writeStandardOutput: { stdout.append($0) })
        }

        #expect(stdout.isEmpty)
    }

    @Test func commandRejectsInvalidPlanWithoutWritingOutput() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try archive(expanded, at: epub)
        let planURL = tmp.appendingPathComponent("plan.json")
        try Data("not JSON".utf8).write(to: planURL)
        var stdout: [String] = []

        #expect(throws: Error.self) {
            try ResolveVoicePlanCommand.run(
                epubURL: epub,
                voicePlanURL: planURL,
                writeStandardOutput: { stdout.append($0) })
        }

        #expect(stdout.isEmpty)
    }

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

    @Test func resolverRejectsParentDirectoryContainingBoundEPUB() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let expanded = try TestEPUBFixture.twoChapters(in: parent)
        let epub = parent.appendingPathComponent("bound.epub")
        try archive(expanded, at: epub)
        let planURL = tmp.appendingPathComponent("plan.json")
        try Data(
            "{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"\(try HeadlessNarrationRunner.fileSHA256(at: epub))\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"voiceID\":\"af_heart\"}],\"assignments\":[]}".utf8
        ).write(to: planURL)

        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.resolveVoicePlan(epubURL: parent, voicePlanURL: planURL)
        }
    }

    @Test func resolverIdentityIsTheExactCompactContract() throws {
        let resolved = ResolvedBlockVoicePlan(
            sourceEPUBSHA256: String(repeating: "a", count: 64),
            defaultSpeakerID: "narrator", defaultVoiceID: VoiceID("af_heart"),
            blocks: [])
        let json = try HeadlessNarrationRunner.resolveVoicePlanIdentityJSON(resolved)
        #expect(json == "{\"blockCount\":0,\"defaultVoice\":\"af_heart\",\"sourceEPUBSHA256\":\"\(String(repeating: "a", count: 64))\",\"voicePlanID\":\"\(resolved.voicePlanID)\",\"voicePlanSHA256\":\"\(resolved.voicePlanSHA256)\"}")
    }

    @Test func archivePathsMustRemainInsideTemporaryRoot() throws {
        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.resolverArchiveDestination(
                entryPath: "../escape", temporaryRoot: URL(fileURLWithPath: "/tmp/root"))
        }
        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.resolverArchiveDestination(
                entryPath: "/escape", temporaryRoot: URL(fileURLWithPath: "/tmp/root"))
        }
    }

    @Test func resolverRejectsPlanVoicesWithoutBundledResources() throws {
        let plan = ResolvedBlockVoicePlan(
            sourceEPUBSHA256: String(repeating: "a", count: 64),
            defaultSpeakerID: "narrator",
            defaultVoiceID: VoiceID("af_heart"),
            blocks: [
                ResolvedBlockVoice(
                    blockID: "s0-b0", speakerID: "narrator", voiceID: VoiceID("af_heart"))
            ])

        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.validateVoiceResources(plan, resourceURL: { _, _ in nil })
        }
    }

    @Test func resolverUsesTOCChapterBoundariesForRangeValidation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let oebps = expanded.appendingPathComponent("OEBPS", isDirectory: true)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol>
        <li><a href="chap01.xhtml#first">First</a></li>
        <li><a href="chap01.xhtml#second">Second</a></li>
        </ol></nav></body></html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <h1 id="first">First</h1><p>First section prose.</p>
        <h1 id="second">Second</h1><p>Second section prose.</p>
        </body></html>
        """.write(to: oebps.appendingPathComponent("chap01.xhtml"), atomically: true, encoding: .utf8)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try archive(expanded, at: epub)
        let parsed = try parseEPUBBlocks(audiobookID: "test", epubURL: expanded)
        let first = try #require(parsed.blocks.first { $0.text == "First" })
        let second = try #require(parsed.blocks.first { $0.text == "Second" })
        let planURL = tmp.appendingPathComponent("plan.json")
        let sourceSHA256 = try HeadlessNarrationRunner.fileSHA256(at: epub)
        try Data("""
        {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA256)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"}],"assignments":[{"speakerID":"narrator","range":{"start":"\(AlignmentSidecar.portableSuffix(of: first.id))","end":"\(AlignmentSidecar.portableSuffix(of: second.id))"}}]}
        """.utf8).write(to: planURL)

        #expect(throws: Error.self) {
            try HeadlessNarrationRunner.resolveVoicePlan(epubURL: epub, voicePlanURL: planURL)
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
