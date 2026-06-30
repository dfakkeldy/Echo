// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS document-import parity. The `Echo macOS` target is
/// not compiled into EchoTests, so we assert against source text via `MacSource`.
/// Import work reuses the shared, macOS-clean auto-import scanners.
struct MacImportParityTests {

    @Test func modelOpensAudiolessDocuments() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("func loadAudiolessDocument("),
            "MacPlayerModel must open standalone EPUB/PDF/text as audio-less study books.")
        #expect(
            src.contains("EPUBAutoImportScanner.importEPUBFile")
                && src.contains("PDFAutoImportScanner.importPDFFile")
                && src.contains("TextAutoImportScanner.importTextFile"),
            "Audio-less open must reuse the shared EPUB/PDF/text auto-import scanners.")
        #expect(
            src.contains("bumpDocumentIngestionTrigger()"),
            "After import the model must bump the ingestion trigger so the reader populates.")
    }

    @Test func openPanelAcceptsDocuments() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            src.contains("loadAudiolessDocument(url:"),
            "The Open panel must route EPUB/PDF/text files to the audio-less document loader.")
        #expect(
            src.contains("documentExtensions"),
            "The Open panel must distinguish document files from audio by extension.")
    }
}
