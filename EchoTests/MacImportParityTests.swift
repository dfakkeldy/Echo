// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS document-import parity. The `Echo macOS` target is
/// not compiled into EchoTests, so we assert against source text via `MacSource`.
/// Import work reuses the shared, macOS-clean auto-import scanners.
struct MacImportParityTests {

    @Test func folderLoadPersistsAudiobookAndTrackRecords() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("persistFolderAudiobookToSQL(folderURL: folderURL, audioFiles: audioFiles)"),
            "MacPlayerModel.loadFolder must persist the opened folder to SQL after audio discovery.")
        #expect(
            src.contains("AudiobookDAO(db: db.writer)") && src.contains("TrackDAO(db: db.writer)"),
            "Folder persistence must use the shared audiobook and track DAOs.")
        #expect(
            src.contains("let audiobookID = folderURL.absoluteString"),
            "The persisted AudiobookRecord ID must match MacPlayerModel.audiobookID.")
        #expect(
            src.contains("id: audioURL.absoluteString") && src.contains("filePath: audioURL.absoluteString"),
            "Persisted TrackRecord IDs must remain compatible with macOS URL-string track IDs.")
    }

    @Test func folderLoadImportsSiblingEPUBAndPDFDocuments() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains(
                "prepareCompanionDocumentImport(folderURL: folderURL, audioURL: audioFiles[currentTrackIndex])"),
            "MacPlayerModel.loadFolder must schedule sibling document import for the selected audio file.")
        #expect(
            src.contains("EPUBAutoImportScanner.scanAndImportIfNeeded")
                && src.contains("PDFAutoImportScanner.scanAndImportIfNeeded"),
            "Folder document import must reuse the shared EPUB and PDF scanner paths.")
        #expect(
            src.contains("if didImportEPUB || didImportPDF")
                && src.contains("self?.bumpDocumentIngestionTrigger()"),
            "The document ingestion trigger must bump when either companion import succeeds.")
        #expect(
            src.contains("let didStart = folderURL.startAccessingSecurityScopedResource()")
                && src.contains("defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }"),
            "Asynchronous companion scanning must balance folder security-scoped access.")
    }

    @Test func folderCompanionImportUsesLoadedAudioContext() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        let companionImport = try sourceSection(
            in: src,
            from: "private func importCompanionDocumentsIfNeeded",
            to: "func openLibraryBook")

        #expect(
            src.contains(
                "prepareCompanionDocumentImport(folderURL: folderURL, audioURL: audioFiles[currentTrackIndex])"),
            "Folder audio import must defer companion scanning until the selected audio file has loaded context.")
        #expect(
            src.contains("CompanionDocumentImportContext")
                && src.contains(
                    "companionDocumentImportContext(loadedChapters: parsed, loadedDuration: loadedDuration)"),
            "MacPlayerModel must snapshot loaded chapters plus finite/current duration for companion import.")
        #expect(
            companionImport.contains("chapters: context.chapters")
                && companionImport.contains("duration: context.duration"),
            "EPUB/PDF companion scanners must receive the loaded audio context snapshot.")
        #expect(
            !companionImport.contains("chapters: []")
                && !companionImport.contains("duration: nil"),
            "Folder audio companion import must not call scanners with empty chapters and nil duration.")
    }

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

    private func sourceSection(in source: String, from startMarker: String, to endMarker: String)
        throws -> String
    {
        guard let start = source.range(of: startMarker) else {
            throw MacImportParitySourceError.missingMarker(startMarker)
        }
        guard let end = source[start.upperBound...].range(of: endMarker) else {
            throw MacImportParitySourceError.missingMarker(endMarker)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private enum MacImportParitySourceError: Error {
    case missingMarker(String)
}
