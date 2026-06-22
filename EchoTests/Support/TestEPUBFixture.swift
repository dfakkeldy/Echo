// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimal expanded EPUB directories for integration tests that need a real EPUB
/// (e.g. HeadlessNarrationRunnerTests). The content is intentionally tiny — two
/// chapters, two `<p>` blocks each — so the importer and parser are exercised but
/// narration finishes fast.
enum TestEPUBFixture {

    /// Write a minimal two-chapter expanded EPUB under `dir` and return its URL.
    ///
    /// Layout mirrors the structure under `/tmp/gh-epub` (a known-good Echo-authored
    /// EPUB): `mimetype`, `META-INF/container.xml`, `OEBPS/content.opf` with a
    /// two-chapter spine, `OEBPS/chap01.xhtml` + `OEBPS/chap02.xhtml` (each with
    /// two `<p>` blocks), and `OEBPS/nav.xhtml`.
    static func twoChapters(in dir: URL) throws -> URL {
        let epubDir = dir.appendingPathComponent("fixture.epub-expanded", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: epubDir, withIntermediateDirectories: true)

        // mimetype (no BOM, no newline at end per EPUB spec)
        try "application/epub+zip".data(using: .utf8)!
            .write(to: epubDir.appendingPathComponent("mimetype"))

        // META-INF/container.xml
        let metaInf = epubDir.appendingPathComponent("META-INF", isDirectory: true)
        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.data(using: .utf8)!
        .write(to: metaInf.appendingPathComponent("container.xml"))

        // OEBPS/
        let oebps = epubDir.appendingPathComponent("OEBPS", isDirectory: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)

        // content.opf — 2-chapter spine
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:fixture-epub-two-chapters</dc:identifier>
        <dc:title>Fixture Book</dc:title>
        <dc:creator>Tester</dc:creator>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="chap01" href="chap01.xhtml" media-type="application/xhtml+xml"/>
        <item id="chap02" href="chap02.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine>
        <itemref idref="chap01"/>
        <itemref idref="chap02"/>
        </spine>
        </package>
        """.data(using: .utf8)!
        .write(to: oebps.appendingPathComponent("content.opf"))

        // nav.xhtml
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><meta charset="utf-8"/><title>Table of Contents</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol>
        <li><a href="chap01.xhtml">Chapter 1 - First Chapter</a></li>
        <li><a href="chap02.xhtml">Chapter 2 - Second Chapter</a></li>
        </ol></nav></body></html>
        """.data(using: .utf8)!
        .write(to: oebps.appendingPathComponent("nav.xhtml"))

        // chap01.xhtml — 2 paragraphs
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><meta charset="utf-8"/><title>Chapter 1 - First Chapter</title></head>
        <body><section epub:type="chapter">
        <h1>Chapter 1 - First Chapter</h1>
        <p>This is the first paragraph of the first chapter. It contains enough words for narration synthesis to produce a non-trivial output.</p>
        <p>This is the second paragraph of the first chapter. The stub engine will synthesize silence for each of these blocks during the integration test.</p>
        </section></body></html>
        """.data(using: .utf8)!
        .write(to: oebps.appendingPathComponent("chap01.xhtml"))

        // chap02.xhtml — 2 paragraphs
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><meta charset="utf-8"/><title>Chapter 2 - Second Chapter</title></head>
        <body><section epub:type="chapter">
        <h1>Chapter 2 - Second Chapter</h1>
        <p>This is the first paragraph of the second chapter. It provides a second chapter so resume logic can be exercised.</p>
        <p>This is the second paragraph of the second chapter. After both chapters are captured the runner exports the m4b and sidecar.</p>
        </section></body></html>
        """.data(using: .utf8)!
        .write(to: oebps.appendingPathComponent("chap02.xhtml"))

        return epubDir
    }
}
