// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WatchKit
import os.log

/// Uses the same native text-input controller as MacroMark. Accepting dictation
/// (including the system's double-tap action) saves immediately, with no second
/// Send screen. Only a durable local save earns the success haptic/dismissal.
struct WatchInboxCaptureView: View {
    let viewModel: WatchViewModel
    private let logger = Logger(category: "WatchInboxCapture")
    @Environment(\.scenePhase) private var scenePhase
    @State private var didPresent = false
    @State private var text: String?
    @State private var capture: WatchInboxCapture?
    @State private var errorMessage: String?
    @State private var context: WatchInboxCapture.Context?

    var body: some View {
        VStack(spacing: 12) {
            if let text {
                ScrollView { Text(text) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
                Button(capture == nil ? "Try Dictation Again" : "Try Sending Again") {
                    if capture == nil { presentDictation() } else { save() }
                }
                    .handGestureShortcut(.primaryAction)
            } else {
                ProgressView("Dictation…")
                Text("Finish dictation to send to your inbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { close() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .task(id: scenePhase) {
            guard scenePhase == .active, !didPresent else { return }
            logger.info("Inbox capture appeared.")
            context = nil
            if let book = viewModel.bookmarkStorageKey, !book.isEmpty,
                !viewModel.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                context = .init(title: viewModel.bookTitle, position: max(0, viewModel.currentTime))
            }
            // Let the capture view appear before WatchKit takes over input.
            // A cancelled startup remains eligible when the app becomes active.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !didPresent else { return }
            didPresent = true
            viewModel.beginInboxDictation()
            presentDictation()
        }
    }

    private func presentDictation() {
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            text = text ?? ""
            errorMessage = "Dictation could not open. Please try again."
            WKInterfaceDevice.current().play(.failure)
            return
        }
        logger.info("Presenting system inbox dictation.")
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { result in
            let words = (result as? [String])?.first
            Task { @MainActor in
                logger.info("System inbox dictation completed; has text: \(words?.isEmpty == false, privacy: .public)")
                guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    close()
                    return
                }
                text = words
                do {
                    capture = try WatchInboxCapture(text: words, context: context)
                    save()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        logger.info("System inbox dictation presentation returned.")
    }

    private func close() {
        viewModel.isShowingInbox = false
    }

    private func save() {
        guard let capture else { return }
        do {
            try viewModel.inbox.save(capture)
            WKInterfaceDevice.current().play(.success)
            close()
        } catch {
            errorMessage = "Could not save your message. Your words are still here; try again."
        }
    }
}
