// SPDX-License-Identifier: GPL-3.0-or-later
import PDFKit
import SwiftUI
import os.log

/// Data carried from a long-press on the PDF page.
/// `word` and `context` are resolved directly from the PDF at the touch point.
private struct PDFLongPressHit {
    let state: PDFViewState
    /// The word at the press point (from `PDFPage.selectionForWord(at:)`), or nil.
    let word: String?
    /// The line of text containing the press point (best-effort context), or nil.
    let context: String?
}

private enum PDFDocumentAction: CaseIterable, Identifiable {
    case alignToNow
    case alignToSpecificTime
    case createBookmark

    var id: Self { self }

    var title: String {
        switch self {
        case .alignToNow:
            String(localized: "Align to Now")
        case .alignToSpecificTime:
            String(localized: "Align to Specific Time")
        case .createBookmark:
            String(localized: "Create Bookmark / Anki Card")
        }
    }

    var systemImage: String {
        switch self {
        case .alignToNow:
            "location.fill"
        case .alignToSpecificTime:
            "clock.badge"
        case .createBookmark:
            "bookmark.fill"
        }
    }
}

nonisolated enum PDFCompanionSelector {
    static func preferredPDF(from urls: [URL], bookTitle: String?) -> URL? {
        let candidates = urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        guard let target = normalizedStem(bookTitle), !target.isEmpty else {
            return candidates.sorted(by: compareByCopyPenaltyThenName).first
        }

        return candidates
            .sorted { lhs, rhs in
                let lhsScore = score(lhs, target: target)
                let rhsScore = score(rhs, target: target)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return compareByCopyPenaltyThenName(lhs, rhs)
            }
            .first
    }

    private static func score(_ url: URL, target: String) -> Int {
        let stem = normalizedStem(url.deletingPathExtension().lastPathComponent) ?? ""
        if stem == target { return 0 }
        if removingCopySuffix(from: stem) == target { return 1 }
        if stem.localizedStandardContains(target) || target.localizedStandardContains(stem) {
            return 2
        }
        return 3
    }

    private static func compareByCopyPenaltyThenName(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsStem = normalizedStem(lhs.deletingPathExtension().lastPathComponent) ?? ""
        let rhsStem = normalizedStem(rhs.deletingPathExtension().lastPathComponent) ?? ""
        let lhsPenalty = lhsStem == removingCopySuffix(from: lhsStem) ? 0 : 1
        let rhsPenalty = rhsStem == removingCopySuffix(from: rhsStem) ? 0 : 1
        if lhsPenalty != rhsPenalty { return lhsPenalty < rhsPenalty }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            == .orderedAscending
    }

    private static func normalizedStem(_ value: String?) -> String? {
        guard let value else { return nil }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 4, trimmed.lowercased().hasSuffix(".pdf") {
            trimmed.removeLast(4)
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func removingCopySuffix(from stem: String) -> String {
        guard let range = stem.range(
            of: #"\s+\(\d+\)$"#,
            options: [.regularExpression, .caseInsensitive])
        else { return stem }
        return String(stem[..<range.lowerBound])
    }
}

struct PDFDocumentView: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model
    @Environment(FreeTierGate.self) private var freeTierGate

    @State private var pdfDocument: PDFDocument?
    @State private var pdfLoadToken = 0
    @State private var showingAlignmentOptions = false
    @State private var showingManualAlignment = false
    @State private var capturedState: PDFViewState?
    @State private var currentPDFViewState: PDFViewState?
    @State private var restorePDFViewState: PDFViewState?
    /// Long-press hit carrying state + resolved word + context.
    @State private var longPressHit: PDFLongPressHit?
    /// Whether to show the word-action dialog (Look Up + Save + Alignment).
    @State private var showingWordActions = false

    // MARK: - Read-along state (M3 Task 3)

    /// Controller that resolves active block → page index and word text.
    /// Nil until the DB and document are ready (or if the book has no timeline).
    @State private var readAlong: PDFReadAlongController?
    /// 0-based PDF page index to auto-follow; nil = do not move.
    @State private var activePageIndex: Int?
    /// Word text to highlight on the current page (best-effort). nil = no highlight.
    @State private var activeWordTerm: String?

    var body: some View {
        ZStack {
            if let document = pdfDocument {
                PDFKitView(
                    document: document,
                    restoreState: Binding(
                        get: { restorePDFViewState },
                        set: { newValue in
                            restorePDFViewState = newValue
                            if newValue == nil { model.pendingPDFViewStateRestore = nil }
                        }
                    ),
                    activePageIndex: activePageIndex,
                    activeWordTerm: activeWordTerm,
                    isPlaying: model.isPlaying,
                    onStateChange: { state in
                        updateCurrentPDFState(state)
                    },
                    onLongPress: { hit in
                        capturedState = hit.state
                        if let word = hit.word, !word.isEmpty {
                            // Word resolved: offer Look Up + Save + Alignment options.
                            longPressHit = hit
                            showingWordActions = true
                        } else {
                            // No word at press point: fall through to alignment dialog.
                            showingAlignmentOptions = true
                        }
                    },
                    onAction: { action, state in
                        performPDFAction(action, state: state)
                    }
                )
                .ignoresSafeArea(edges: .top)
                .padding(.bottom, model.bottomInset)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if pdfDocument != nil {
                pdfActionMenu
                    .padding(.trailing, 16)
                    .padding(.bottom, model.bottomInset + 16)
            }
        }
        .task(id: PDFLoadRequest(folderURL: folderURL, reloadToken: pdfLoadToken)) {
            await loadPDF(for: folderURL)
            // Load the read-along controller after the document is ready.
            // Uses the same databaseService the rest of the reader uses.
            if let db = model.databaseService?.writer {
                let controller = PDFReadAlongController()
                controller.load(audiobookID: folderURL.absoluteString, db: db)
                readAlong = controller
            }
        }
        .onChange(of: model.pendingPDFViewStateRestore) { _, state in
            if let state {
                restorePDFViewState = state
            }
        }
        // M3 Task 3: Page auto-follow + best-effort word highlight.
        // Only fires on playback ticks; does NOT fight PDFViewState restore or
        // user scroll/zoom (the guard below is model.isPlaying, enforced in the
        // PDFKitView coordinator's go(to:) call).
        .onChange(of: model.currentPlaybackTime) { _, time in
            guard let ra = readAlong, model.isPlaying else { return }
            guard
                let active = ra.activeBlock(
                    at: time,
                    currentTrackSegmentKey: currentTrackSegmentKey,
                    currentTrackChapterIndices: currentTrackChapterIndices)
            else {
                activeWordTerm = nil
                return
            }
            if let page = ra.pageIndex(forBlock: active.blockID) {
                activePageIndex = page
            }
            activeWordTerm = active.wordIndex.flatMap {
                ra.wordText(blockID: active.blockID, wordIndex: $0)
            }
        }
        // Clear highlight when paused so it does not persist stale.
        .onChange(of: model.isPlaying) { _, playing in
            if !playing {
                activeWordTerm = nil
            }
        }
        .confirmationDialog("Align PDF View", isPresented: $showingAlignmentOptions) {
            ForEach(PDFDocumentAction.allCases) { action in
                Button(action.title) {
                    _ = performPDFAction(action, state: capturedState)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // M3 Task 4: word-action dialog (Look Up + Save + Alignment options).
        // Only shown when a word was resolved at the long-press point.
        .confirmationDialog(
            wordActionDialogTitle,
            isPresented: $showingWordActions,
            titleVisibility: .visible
        ) {
            if let hit = longPressHit, let word = hit.word {
                let term = DictionaryLookupTerm.sanitized(word)
                if !term.isEmpty {
                    if DictionaryLookupPresenter.hasDefinition(for: term) {
                        Button("Look Up \"\(term)\"") {
                            DictionaryLookupPresenter.present(term: term)
                        }
                    }
                    Button("Save \"\(term)\"") {
                        savePDFVocabularyWord(word: term, context: hit.context)
                    }
                }
                Button("Alignment options\u{2026}") {
                    // Re-trigger the alignment dialog with the same captured state.
                    showingAlignmentOptions = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingManualAlignment) {
            ManualAlignmentSheet(folderURL: folderURL)
                .presentationDetents([.fraction(0.5)])
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) {
            notification in
            guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
                ingestedID == folderURL.absoluteString
            else { return }
            pdfLoadToken &+= 1
            // Reload the read-along controller when new timeline data arrives.
            if let db = model.databaseService?.writer {
                readAlong?.load(audiobookID: folderURL.absoluteString, db: db)
            }
        }
    }

    private func loadPDF(for folderURL: URL) async {
        do {
            let currentTitle = model.currentTitle
            let pdfURL = try await Self.preferredPDFURL(in: folderURL, bookTitle: currentTitle)
            try Task.checkCancellation()
            guard self.folderURL == folderURL else { return }

            let document = pdfURL.flatMap(PDFDocument.init(url:))
            let savedState = model.pendingPDFViewStateRestore ?? model.pdfViewState(for: folderURL)
            restorePDFViewState = savedState
            currentPDFViewState = savedState
            model.currentPDFViewState = savedState
            try Task.checkCancellation()
            pdfDocument = document
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Failed to load PDF: \(error.localizedDescription)")
        }
    }

    // MARK: - Track scoping (mirrors ReaderTab.currentTrackChapterIndices)
    // Needed so the read-along controller resolves the correct block in multi-track books.

    private var currentTrackChapterIndices: Set<Int>? {
        let tracks = model.tracks
        let currentIndex = model.currentIndex
        var playingChapterIndex: Int?
        if tracks.indices.contains(currentIndex) {
            playingChapterIndex = NarrationFileNaming.chapterIndex(
                fromFileName: tracks[currentIndex].url.lastPathComponent)
        }
        return ReaderActiveBlockResolver.trackChapterScope(
            trackCount: tracks.count,
            isMultiM4B: model.isMultiM4B,
            currentIndex: currentIndex,
            playingChapterIndex: playingChapterIndex)
    }

    private var currentTrackSegmentKey: String? {
        let tracks = model.tracks
        let currentIndex = model.currentIndex
        guard tracks.indices.contains(currentIndex),
            let location = NarrationFileNaming.segmentLocation(
                fromFileName: tracks[currentIndex].url.lastPathComponent)
        else { return nil }
        return ReaderActiveBlockResolver.segmentKey(
            forChapter: location.chapterIndex,
            segment: location.segmentIndex)
    }

    // MARK: - Action menu

    private var wordActionDialogTitle: String {
        guard let word = longPressHit?.word else { return "" }
        return "\"\(word)\""
    }

    private var pdfActionMenu: some View {
        Menu {
            ForEach(PDFDocumentAction.allCases) { action in
                Button {
                    _ = performPDFAction(action, state: currentPDFActionState)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } label: {
            Label("PDF Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
        .accessibilityLabel(Text("PDF Actions"))
        .accessibilityHint(Text("Open PDF alignment and bookmark actions"))
        .disabled(currentPDFActionState == nil)
    }

    private var currentPDFActionState: PDFViewState? {
        if let currentPDFViewState {
            return currentPDFViewState
        }
        if let modelState = model.currentPDFViewState {
            return modelState
        }
        guard pdfDocument?.pageCount ?? 0 > 0 else { return nil }
        return PDFViewState(pageIndex: 0, zoomScale: 1, offsetX: 0, offsetY: 0)
    }

    private func updateCurrentPDFState(_ state: PDFViewState) {
        if currentPDFViewState != state {
            currentPDFViewState = state
        }
        model.updatePDFViewState(state, for: folderURL)
    }

    @discardableResult
    private func performPDFAction(_ action: PDFDocumentAction, state: PDFViewState?) -> Bool {
        guard let state else { return false }

        updateCurrentPDFState(state)

        switch action {
        case .alignToNow:
            return model.addBookmarkAtCurrentTime() != nil
        case .alignToSpecificTime:
            showingManualAlignment = true
            return true
        case .createBookmark:
            return createBookmarkWithScreenshot(state: state)
        }
    }

    @concurrent
    static func preferredPDFURL(in folderURL: URL, bookTitle: String?) async throws -> URL? {
        try Task.checkCancellation()
        let files = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        try Task.checkCancellation()
        return PDFCompanionSelector.preferredPDF(
            from: files
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            },
            bookTitle: bookTitle)
    }

    @discardableResult
    private func createBookmarkWithScreenshot(state: PDFViewState) -> Bool {
        guard let document = pdfDocument,
            let page = document.page(at: state.pageIndex)
        else { return false }

        // Render PDF page to image
        let pageRect = page.bounds(for: .mediaBox)
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let image = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(pageRect)

            ctx.cgContext.translateBy(x: 0, y: pageRect.size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)

            page.draw(with: .mediaBox, to: ctx.cgContext)
        }

        let imageName = UUID().uuidString + ".jpg"
        if let data = image.jpegData(compressionQuality: 0.8) {
            let imageURL = folderURL.appendingPathComponent(imageName)
            try? data.write(to: imageURL)

            if let draft = model.bookmarkDraftAtCurrentTime() {
                model.appendBookmark(
                    from: draft, title: String(localized: "PDF Bookmark"),
                    timestamp: draft.timestamp,
                    note: nil,
                    voiceMemoFileName: nil, bookmarkImageFileName: imageName)
                return true
            }
        }

        return false
    }

    // MARK: - M3 Task 4: Vocabulary word save

    /// Saves `word` as a vocabulary flashcard, mirroring `ReaderTab.saveVocabularyWord`.
    /// Audio anchor = the active block's start time (block-level; per-word timing is
    /// unavailable in the PDF page context).
    private func savePDFVocabularyWord(word: String, context: String?) {
        let word = DictionaryLookupTerm.sanitized(word)
        guard !word.isEmpty else { return }
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString

        guard freeTierGate.canCreateFlashcards(adding: 1) else {
            model.paywallContext = .flashcardCap
            model.showPaywall = true
            return
        }

        let dao = FlashcardDAO(db: db.writer)

        // Dedupe: re-surface existing card with light haptic, no duplicate.
        if (try? dao.vocabularyCard(for: audiobookID, word: word)) != nil {
            Haptic.play(.light)
            return
        }

        // Audio anchor: active block start time, or current playback time as fallback.
        let activeBlock = readAlong?.activeBlock(
            at: model.currentPlaybackTime,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices)
        let blockID = activeBlock?.blockID
        let audioStart: TimeInterval
        if let bid = blockID,
            let t = readAlong?.blockStartTime(forBlock: bid)
        {
            audioStart = t
        } else {
            audioStart = model.currentPlaybackTime
        }

        let card = VocabularyCardBuilder.make(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            word: word,
            contextSentence: context.flatMap { $0.isEmpty ? nil : $0 },
            blockID: blockID,
            audioStart: audioStart,
            audioEnd: nil,
            createdAt: Date().ISO8601Format()
        )

        do {
            try dao.insert(card)
            Haptic.play(.medium)
        } catch {
            Self.logger.error("Failed to save PDF vocabulary word '\(word)': \(error)")
            Haptic.play(.rigid)
        }
    }

    private struct PDFLoadRequest: Equatable {
        let folderURL: URL
        let reloadToken: Int
    }

    private static let logger = Logger(category: "PDFDocumentView")
}

// MARK: - PDFKitView

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var restoreState: PDFViewState?
    /// Narration-driven page index to scroll to (nil = let user control).
    /// Only acted on while `isPlaying`; cleared to nil by the parent's onChange.
    let activePageIndex: Int?
    /// Best-effort word term to highlight on the current page.
    let activeWordTerm: String?
    /// Whether narration is actively playing. Auto-follow is suppressed when false.
    let isPlaying: Bool
    let onStateChange: (PDFViewState) -> Void
    let onLongPress: (PDFLongPressHit) -> Void
    let onAction: (PDFDocumentAction, PDFViewState) -> Bool

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.backgroundColor = .clear
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical

        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        pdfView.addGestureRecognizer(recognizer)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handlePageChange),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScaleChange),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScroll),
            name: .PDFViewVisiblePagesChanged,
            object: pdfView
        )

        context.coordinator.pdfView = pdfView
        context.coordinator.configureAccessibilityActions(for: pdfView)
        context.coordinator.publishCurrentState()

        // Add the word highlight overlay view (best-effort; hidden until a term matches).
        context.coordinator.installHighlightView(on: pdfView)

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self

        if uiView.document != document {
            uiView.document = document
            context.coordinator.publishCurrentState()
        }

        if let state = restoreState {
            if let page = document.page(at: state.pageIndex) {
                uiView.go(
                    to: CGRect(x: state.offsetX, y: state.offsetY, width: 1, height: 1), on: page)
                uiView.scaleFactor = CGFloat(state.zoomScale)
            }
            context.coordinator.publishCurrentState()

            Task { @MainActor in
                restoreState = nil
            }
        }

        // Page auto-follow: only while playing and when the desired page differs.
        // Guard: isPlaying prevents fighting user scroll/zoom while paused.
        if isPlaying, let targetPage = activePageIndex,
            let page = document.page(at: targetPage),
            uiView.currentPage != page
        {
            uiView.go(to: page)
        }

        // Best-effort word highlight: search the current page for the term.
        context.coordinator.updateWordHighlight(term: activeWordTerm, in: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var pdfView: PDFView?

        // MARK: Best-effort word highlight (M3 Task 3, secondary)
        // A single semi-transparent UIView overlaid on the PDFView. Positioned via
        // PDFKit coordinate conversion each time the active word changes.
        // Throttled: we skip the update if the term has not changed since last paint.
        private weak var highlightView: UIView?
        private var lastHighlightedTerm: String?

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Adds a reusable highlight overlay to `pdfView`. Called once from `makeUIView`.
        func installHighlightView(on pdfView: PDFView) {
            let view = UIView()
            view.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.25)
            view.layer.cornerRadius = 3
            view.isUserInteractionEnabled = false
            view.isHidden = true
            pdfView.addSubview(view)
            highlightView = view
        }

        /// Positions (or hides) the highlight overlay for `term` on the visible page.
        /// Best-effort: if the search returns no match on the current page, hides.
        /// Throttled: no-op when `term` matches `lastHighlightedTerm`.
        func updateWordHighlight(term: String?, in pdfView: PDFView) {
            // Throttle: skip if same term as last update.
            guard term != lastHighlightedTerm else { return }
            lastHighlightedTerm = term

            guard let highlightView,
                let term, !term.isEmpty,
                let currentPage = pdfView.currentPage,
                let document = pdfView.document
            else {
                highlightView?.isHidden = true
                return
            }

            // Search the document for the term; filter to the current page.
            // PDFKit's findString is synchronous and searches the whole document.
            // For short single-word terms this is fast enough at ~12 Hz.
            let selections = document.findString(term, withOptions: .caseInsensitive)
            guard
                let selection = selections.first(where: { sel in
                    // A selection can span pages; check if it touches the current page.
                    sel.pages.contains(currentPage)
                })
            else {
                highlightView.isHidden = true
                return
            }

            // Convert selection bounds (PDF page coordinates) → PDFView coordinates.
            let pageBounds = selection.bounds(for: currentPage)
            let viewBounds = pdfView.convert(pageBounds, from: currentPage)

            // Clamp to visible area — the conversion may put it off-screen during scroll.
            let visible = pdfView.bounds
            guard visible.intersects(viewBounds) else {
                highlightView.isHidden = true
                return
            }

            highlightView.frame = viewBounds
            highlightView.isHidden = false
            // Keep the highlight above PDF content but below gesture recognizers.
            pdfView.bringSubviewToFront(highlightView)
        }

        func configureAccessibilityActions(for pdfView: PDFView) {
            pdfView.accessibilityLabel = String(localized: "PDF document")
            pdfView.accessibilityCustomActions = PDFDocumentAction.allCases.map { action in
                let customAction = UIAccessibilityCustomAction(name: action.title) {
                    [weak self] _ in
                    guard let self, let state = currentState() else { return false }
                    return parent.onAction(action, state)
                }
                customAction.category = UIAccessibilityCustomAction.editCategory
                return customAction
            }
        }

        func publishCurrentState() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let pdfView, let state = currentState() else { return }

            // Resolve the word at the press point directly from PDFKit.
            // `selectionForWord(at:)` is available since PDFKit iOS 11 and
            // compiles cleanly on the iOS 18 SDK.
            let loc = gesture.location(in: pdfView)
            var word: String?
            var context: String?
            if let page = pdfView.page(for: loc, nearest: true) {
                let p = pdfView.convert(loc, to: page)
                let wordSel = page.selectionForWord(at: p)
                let raw = wordSel?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !raw.isEmpty {
                    word = raw
                    // Best-effort context sentence from the same line.
                    context = page.selectionForLine(at: p)?.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            parent.onLongPress(PDFLongPressHit(state: state, word: word, context: context))
        }

        @objc func handlePageChange() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
            // Hide highlight on page change; updateUIView will re-position if still valid.
            highlightView?.isHidden = true
            lastHighlightedTerm = nil
        }

        @objc func handleScaleChange() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
            // Reposition after zoom; force re-paint by resetting the throttle guard.
            lastHighlightedTerm = nil
        }

        @objc func handleScroll() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
        }

        private func currentState() -> PDFViewState? {
            guard let pdfView = pdfView,
                let currentPage = pdfView.currentPage,
                let pageIndex = pdfView.document?.index(for: currentPage)
            else {
                return nil
            }

            let scale = pdfView.scaleFactor
            let visibleRect = pdfView.convert(pdfView.bounds, to: currentPage)

            return PDFViewState(
                pageIndex: pageIndex,
                zoomScale: Double(scale),
                offsetX: Double(visibleRect.minX),
                offsetY: Double(visibleRect.minY)
            )
        }
    }
}
