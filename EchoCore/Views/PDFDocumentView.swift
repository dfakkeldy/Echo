// SPDX-License-Identifier: GPL-3.0-or-later
import PDFKit
import SwiftUI
import os.log

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

struct PDFDocumentView: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model

    @State private var pdfDocument: PDFDocument?
    @State private var pdfLoadToken = 0
    @State private var showingAlignmentOptions = false
    @State private var showingManualAlignment = false
    @State private var capturedState: PDFViewState?
    @State private var currentPDFViewState: PDFViewState?

    var body: some View {
        ZStack {
            if let document = pdfDocument {
                PDFKitView(
                    document: document,
                    restoreState: Binding(
                        get: { model.pendingPDFViewStateRestore },
                        set: { if $0 == nil { model.pendingPDFViewStateRestore = nil } }
                    ),
                    onStateChange: { state in
                        updateCurrentPDFState(state)
                    },
                    onLongPress: { state in
                        capturedState = state
                        showingAlignmentOptions = true
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
        }
        .confirmationDialog("Align PDF View", isPresented: $showingAlignmentOptions) {
            ForEach(PDFDocumentAction.allCases) { action in
                Button(action.title) {
                    _ = performPDFAction(action, state: capturedState)
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
        }
    }

    private func loadPDF(for folderURL: URL) async {
        do {
            let pdfURL = try await Self.firstPDFURL(in: folderURL)
            try Task.checkCancellation()
            guard self.folderURL == folderURL else { return }

            let document = pdfURL.flatMap(PDFDocument.init(url:))
            try Task.checkCancellation()
            pdfDocument = document
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Failed to load PDF: \(error.localizedDescription)")
        }
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
        model.currentPDFViewState = state
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
    private static func firstPDFURL(in folderURL: URL) async throws -> URL? {
        try Task.checkCancellation()
        let files = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        try Task.checkCancellation()
        return files
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .first
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
                    from: draft, title: String(localized: "PDF Bookmark"), timestamp: draft.timestamp, note: nil,
                    voiceMemoFileName: nil, bookmarkImageFileName: imageName)
                return true
            }
        }

        return false
    }

    private struct PDFLoadRequest: Equatable {
        let folderURL: URL
        let reloadToken: Int
    }

    private static let logger = Logger(category: "PDFDocumentView")
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var restoreState: PDFViewState?
    let onStateChange: (PDFViewState) -> Void
    let onLongPress: (PDFViewState) -> Void
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var pdfView: PDFView?

        init(_ parent: PDFKitView) {
            self.parent = parent
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
            if gesture.state == .began, let state = currentState() {
                parent.onLongPress(state)
            }
        }

        @objc func handlePageChange() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
        }

        @objc func handleScaleChange() {
            if let state = currentState() {
                parent.onStateChange(state)
            }
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
