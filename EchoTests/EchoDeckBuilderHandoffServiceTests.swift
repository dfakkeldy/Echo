// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EchoDeckBuilderHandoffServiceTests {
    @Test("Uses the directly opened EPUB when Echo still has that source URL")
    func usesPreferredEPUB() throws {
        let fixture = try TemporaryBookFolder()
        let sourceEPUB = try fixture.writeFile(named: "Opened Book.epub")
        _ = try fixture.writeFile(named: "Other Book.epub")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(
            bookURL: fixture.url,
            preferredEPUBURL: sourceEPUB
        )

        #expect(resolved == sourceEPUB)
    }

    @Test("Returns a standalone EPUB book URL")
    func returnsStandaloneEPUB() throws {
        let fixture = try TemporaryBookFolder()
        let epubURL = try fixture.writeFile(named: "Standalone.epub")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: epubURL)

        #expect(resolved == epubURL)
    }

    @Test("Returns the only sibling EPUB in an audiobook folder")
    func returnsOnlySiblingEPUB() throws {
        let fixture = try TemporaryBookFolder()
        let epubURL = try fixture.writeFile(named: "Companion.epub")
        _ = try fixture.writeFile(named: "chapter-01.m4b")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: fixture.url)

        #expect(resolved == epubURL)
    }

    @Test("Prefers the EPUB whose base name matches the current track")
    func prefersCurrentTrackNameMatch() throws {
        let fixture = try TemporaryBookFolder()
        _ = try fixture.writeFile(named: "Anthology.epub")
        let matchedEPUB = try fixture.writeFile(named: "Chapter 02.epub")
        let currentTrackURL = try fixture.writeFile(named: "Chapter 02.m4b")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(
            bookURL: fixture.url,
            currentTrackURL: currentTrackURL
        )

        #expect(resolved == matchedEPUB)
    }

    @Test("Throws when no EPUB can be found")
    func throwsWhenNoEPUBExists() throws {
        let fixture = try TemporaryBookFolder()
        _ = try fixture.writeFile(named: "chapter-01.m4b")

        #expect(throws: EchoDeckBuilderHandoffError.noEPUBFound(fixture.url)) {
            try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: fixture.url)
        }
    }

    @Test("Throws when multiple EPUBs are possible and none match playback")
    func throwsWhenMultipleCandidatesAreAmbiguous() throws {
        let fixture = try TemporaryBookFolder()
        _ = try fixture.writeFile(named: "A.epub")
        _ = try fixture.writeFile(named: "B.epub")
        _ = try fixture.writeFile(named: "chapter-01.m4b")

        #expect(throws: EchoDeckBuilderHandoffError.multipleEPUBCandidates(["A.epub", "B.epub"])) {
            try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: fixture.url)
        }
    }
}

private final class TemporaryBookFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "EchoDeckBuilderHandoff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func writeFile(named name: String) throws -> URL {
        let fileURL = url.appending(path: name)
        try Data(name.utf8).write(to: fileURL)
        return fileURL
    }
}
