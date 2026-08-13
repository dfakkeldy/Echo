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
            sourceDocumentURL: sourceEPUB
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

    @Test("Does not hand off an unrelated sibling EPUB for a directly-opened non-EPUB document")
    func foreignDocumentDoesNotMatchUnrelatedSibling() throws {
        let fixture = try TemporaryBookFolder()
        _ = try fixture.writeFile(named: "Unrelated Book.epub")
        let pdfURL = try fixture.writeFile(named: "My Notes.pdf")

        #expect(throws: EchoDeckBuilderHandoffError.noEPUBFound(fixture.url)) {
            try EchoDeckBuilderHandoffService.currentEPUBURL(
                bookURL: fixture.url,
                sourceDocumentURL: pdfURL
            )
        }
    }

    @Test("Matches the sibling EPUB whose base name matches a directly-opened non-EPUB document")
    func foreignDocumentMatchesNameSibling() throws {
        let fixture = try TemporaryBookFolder()
        let matchedEPUB = try fixture.writeFile(named: "My Notes.epub")
        _ = try fixture.writeFile(named: "Other Book.epub")
        let pdfURL = try fixture.writeFile(named: "My Notes.pdf")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(
            bookURL: fixture.url,
            sourceDocumentURL: pdfURL
        )

        #expect(resolved == matchedEPUB)
    }

    @Test("Throws noLoadedBook when no book URL is available")
    func throwsNoLoadedBookWhenBookURLIsNil() {
        #expect(throws: EchoDeckBuilderHandoffError.noLoadedBook) {
            try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: nil)
        }
    }

    @Test("Falls through to a sibling when the source document URL no longer exists")
    func ignoresStaleSourceDocumentURL() throws {
        let fixture = try TemporaryBookFolder()
        let realEPUB = try fixture.writeFile(named: "Real.epub")
        let staleEPUB = fixture.url.appending(path: "Deleted.epub")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(
            bookURL: fixture.url,
            sourceDocumentURL: staleEPUB
        )

        #expect(resolved == realEPUB)
    }

    @Test("Resolves an EPUB whose extension is upper-cased")
    func matchesCaseInsensitiveEPUBExtension() throws {
        let fixture = try TemporaryBookFolder()
        let epubURL = try fixture.writeFile(named: "Standalone.EPUB")

        let resolved = try EchoDeckBuilderHandoffService.currentEPUBURL(bookURL: epubURL)

        #expect(resolved == epubURL)
    }
}

private final class TemporaryBookFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(
                path: "EchoDeckBuilderHandoff-\(UUID().uuidString)", directoryHint: .isDirectory)
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
