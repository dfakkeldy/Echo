import PDFKit
import SwiftUI
import os.log

struct PDFDocumentView: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model

    @State private var pdfDocument: PDFDocument?
    @State private var showingAlignmentOptions = false
    @State private var showingManualAlignment = false
    @State private var capturedState: PDFViewState?

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
                        model.currentPDFViewState = state
                    },
                    onLongPress: { state in
                        capturedState = state
                        showingAlignmentOptions = true
                    }
                )
                .ignoresSafeArea(edges: .top)
                .padding(.bottom, model.bottomInset)
            } else {
                ProgressView()
                    .onAppear {
                        loadPDF()
                    }
            }
        }
        .confirmationDialog("Align PDF View", isPresented: $showingAlignmentOptions) {
            Button("Align to Now") {
                if let state = capturedState {
                    model.currentPDFViewState = state
                    model.addBookmarkAtCurrentTime()
                }
            }
            Button("Align to Specific Time") {
                if let state = capturedState {
                    model.currentPDFViewState = state
                    showingManualAlignment = true
                }
            }
            Button("Create Bookmark / Anki Card") {
                if let state = capturedState {
                    model.currentPDFViewState = state
                    createBookmarkWithScreenshot(state: state)
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
            loadPDF()
        }
    }

    private func loadPDF() {
        Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
                if let pdfFile = files.first(where: { $0.lowercased().hasSuffix(".pdf") }) {
                    let pdfURL = folderURL.appendingPathComponent(pdfFile)
                    if let doc = PDFDocument(url: pdfURL) {
                        await MainActor.run {
                            self.pdfDocument = doc
                        }
                    }
                }
            } catch {
                let logger = Logger(category: "PDFDocumentView")
                logger.error("Failed to load PDF: \(error.localizedDescription)")
            }
        }
    }

    private func createBookmarkWithScreenshot(state: PDFViewState) {
        guard let document = pdfDocument,
            let page = document.page(at: state.pageIndex)
        else { return }

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
                    from: draft, title: "PDF Bookmark", timestamp: draft.timestamp, note: nil,
                    voiceMemoFileName: nil, bookmarkImageFileName: imageName)
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var restoreState: PDFViewState?
    let onStateChange: (PDFViewState) -> Void
    let onLongPress: (PDFViewState) -> Void

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
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document != document {
            uiView.document = document
        }

        if let state = restoreState {
            if let page = document.page(at: state.pageIndex) {
                uiView.go(
                    to: CGRect(x: state.offsetX, y: state.offsetY, width: 1, height: 1), on: page)
                uiView.scaleFactor = CGFloat(state.zoomScale)
            }

            Task { @MainActor in
                restoreState = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        let parent: PDFKitView
        weak var pdfView: PDFView?

        init(_ parent: PDFKitView) {
            self.parent = parent
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
