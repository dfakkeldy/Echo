// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import GRDB
import PDFKit
import SwiftUI
import os.log

/// Page-faithful PDF reading surface — the macOS counterpart to the iOS
/// `PDFDocumentView`. Renders the *original* PDF pages (vs. `MacReaderFeedView`'s
/// reflowed block text, which already works for PDFs since `PDFAutoImportScanner`
/// writes into the same `epub_block` table) and auto-follows the page containing
/// the currently-playing block.
///
/// Reuses the shared, macOS-clean `PDFReadAlongController` (no UIKit; already
/// compiled into this target) for all timeline/page/word resolution — no
/// duplicated caching logic.
struct MacPDFReaderView: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService

    @State private var document: PDFDocument?
    @State private var readAlong = PDFReadAlongController()
    @State private var activePageIndex: Int?
    @State private var highlightTerm: String?
    @State private var loadError: String?
    private let logger = Logger(subsystem: "com.echo.audiobooks", category: "MacPDFReader")

    var body: some View {
        Group {
            if let document {
                MacPDFKitRepresentable(
                    document: document,
                    activePageIndex: activePageIndex,
                    highlightTerm: highlightTerm,
                    isPlaying: player.isPlaying,
                    onSaveVocabulary: { performSaveVocabulary($0) },
                    onBookmarkHere: { player.addBookmarkAtCurrentTime() }
                )
            } else {
                ContentUnavailableView(
                    "No PDF Page Data", systemImage: "doc.text",
                    description: Text(loadError ?? "This book has no source PDF to display."))
            }
        }
        .task(id: player.audiobookID) { await load() }
        .task(id: player.audiobookID) { await trackCurrentPage() }
    }

    // MARK: Load

    /// The source PDF lives at the document's own URL — `loadAudiolessDocument`
    /// sets `folderURL` to the picked file itself for a standalone PDF (there is
    /// no audio track / containing folder for an audio-less book).
    private func load() async {
        loadError = nil
        guard let audiobookID = player.audiobookID, let url = player.folderURL,
            url.pathExtension.lowercased() == "pdf"
        else {
            document = nil
            return
        }
        guard let doc = PDFDocument(url: url) else {
            document = nil
            loadError = "The source PDF could not be opened."
            return
        }
        document = doc
        readAlong.load(audiobookID: audiobookID, db: dbService.writer)
    }

    // MARK: Auto-follow

    /// Polls playback position and resolves the active page/word via the shared
    /// read-along controller — same cadence pattern as `MacReaderFeedView`'s
    /// `trackCurrentBlock()`.
    private func trackCurrentPage() async {
        while !Task.isCancelled {
            if player.isPlaying, player.currentTime > 0, readAlong.isLoaded {
                if let active = readAlong.activeBlock(at: player.currentTime) {
                    activePageIndex = readAlong.pageIndex(forBlock: active.blockID)
                    if let wordIndex = active.wordIndex {
                        highlightTerm = readAlong.wordText(
                            blockID: active.blockID, wordIndex: wordIndex)
                    } else {
                        highlightTerm = nil
                    }
                } else {
                    highlightTerm = nil
                }
            } else {
                highlightTerm = nil
            }
            try? await Task.sleep(for: player.isPlaying ? .milliseconds(150) : .milliseconds(500))
        }
    }

    // MARK: Save vocabulary

    /// Anchors the card to the currently-playing block (per-word timing is
    /// unavailable in the page context, mirroring the iOS PDF fallback), falling
    /// back to the raw playback time when nothing is resolved.
    private func performSaveVocabulary(_ rawWord: String) {
        guard let audiobookID = player.audiobookID else { return }
        let word = DictionaryLookupTerm.sanitized(rawWord)
        guard !word.isEmpty else { return }
        let time = player.currentTime
        Task {
            do {
                let dao = FlashcardDAO(db: dbService.writer)
                guard try dao.vocabularyCard(for: audiobookID, word: word) == nil else { return }
                let active = readAlong.activeBlock(at: time)
                let anchorStart =
                    active.flatMap { readAlong.blockStartTime(forBlock: $0.blockID) } ?? time
                let card = VocabularyCardBuilder.make(
                    id: UUID().uuidString, audiobookID: audiobookID, word: word,
                    contextSentence: nil, blockID: active?.blockID, audioStart: anchorStart,
                    audioEnd: nil, createdAt: Date().ISO8601Format())
                try dao.insert(card)
            } catch {
                logger.error(
                    "Failed to save PDF vocabulary word: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

// MARK: - AppKit bridge

/// Wraps AppKit's `PDFView` (the same PDFKit class iOS uses) for SwiftUI.
private struct MacPDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let activePageIndex: Int?
    let highlightTerm: String?
    let isPlaying: Bool
    let onSaveVocabulary: (String) -> Void
    let onBookmarkHere: () -> Void

    func makeNSView(context: Context) -> MacPDFInteractiveView {
        let view = MacPDFInteractiveView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.onSaveVocabulary = onSaveVocabulary
        view.onBookmarkHere = onBookmarkHere
        return view
    }

    func updateNSView(_ nsView: MacPDFInteractiveView, context: Context) {
        if nsView.document !== document { nsView.document = document }
        nsView.onSaveVocabulary = onSaveVocabulary
        nsView.onBookmarkHere = onBookmarkHere

        // Auto-follow only while playing, mirroring the iOS guard against
        // fighting the user's manual scroll while paused.
        if isPlaying, let pageIndex = activePageIndex,
            let page = document.page(at: pageIndex), nsView.currentPage !== page
        {
            nsView.go(to: page)
        }

        if let term = highlightTerm, let currentPage = nsView.currentPage,
            let selection = document.findString(term, withOptions: .caseInsensitive).first(
                where: { $0.pages.contains(currentPage) })
        {
            nsView.highlightedSelections = [selection]
        } else {
            nsView.highlightedSelections = nil
        }
    }
}

/// `PDFView` subclass that resolves the right-clicked word and offers Look Up /
/// Save as Flashcard / Bookmark Here — the macOS counterpart to the iOS reader's
/// long-press menu. Look Up uses the system Dictionary popover directly
/// (`NSView.showDefinition`), so it needs no SwiftUI round-trip.
final class MacPDFInteractiveView: PDFView {
    var onSaveVocabulary: ((String) -> Void)?
    var onBookmarkHere: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: true) else { return super.menu(for: event) }
        let pagePoint = convert(location, to: page)
        guard let wordSelection = page.selectionForWord(at: pagePoint),
            let word = wordSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            !word.isEmpty
        else {
            return bookmarkOnlyMenu()
        }

        let menu = NSMenu()
        let lookUpItem = NSMenuItem(
            title: "Look Up “\(word)”", action: #selector(handleLookUp(_:)), keyEquivalent: "")
        lookUpItem.representedObject = LookUpContext(word: word, point: location)
        lookUpItem.target = self
        menu.addItem(lookUpItem)

        let saveItem = NSMenuItem(
            title: "Save as Flashcard", action: #selector(handleSaveVocabulary(_:)),
            keyEquivalent: "")
        saveItem.representedObject = word
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(.separator())
        appendBookmarkItem(to: menu)
        return menu
    }

    private func bookmarkOnlyMenu() -> NSMenu {
        let menu = NSMenu()
        appendBookmarkItem(to: menu)
        return menu
    }

    private func appendBookmarkItem(to menu: NSMenu) {
        let bookmarkItem = NSMenuItem(
            title: "Bookmark Here", action: #selector(handleBookmark), keyEquivalent: "")
        bookmarkItem.target = self
        menu.addItem(bookmarkItem)
    }

    @objc private func handleLookUp(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LookUpContext else { return }
        showDefinition(for: NSAttributedString(string: context.word), at: context.point)
    }

    @objc private func handleSaveVocabulary(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        onSaveVocabulary?(word)
    }

    @objc private func handleBookmark() {
        onBookmarkHere?()
    }

    private struct LookUpContext {
        let word: String
        let point: NSPoint
    }
}
