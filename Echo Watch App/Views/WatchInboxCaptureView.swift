// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WatchKit

/// Uses the same native text-input controller as MacroMark. Accepting dictation
/// (including the system's double-tap action) saves immediately, with no second
/// Send screen. Only a durable local save earns the success haptic/dismissal.
struct WatchInboxCaptureView: View {
    let viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss
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
                Button("Try Sending Again", action: save)
                    .handGestureShortcut(.primaryAction)
            } else {
                ProgressView("Dictation…")
                Text("Finish dictation to send to your inbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Inbox")
        .task {
            guard !didPresent else { return }
            didPresent = true
            if let book = viewModel.bookmarkStorageKey, !book.isEmpty {
                context = .init(title: viewModel.title, position: max(0, viewModel.currentTime))
            }
            viewModel.beginInboxDictation()
            // Let the sheet finish presentation before asking WatchKit to present
            // its system input controller, just as MacroMark does.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let controller = WKExtension.shared().visibleInterfaceController else {
                errorMessage = "Dictation could not open. Please try Inbox again."
                dismiss()
                return
            }
            controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { result in
                let words = (result as? [String])?.first
                Task { @MainActor in
                    guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        dismiss()
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
        }
    }

    private func save() {
        guard let capture else { return }
        do {
            try viewModel.inbox.save(capture)
            WKInterfaceDevice.current().play(.success)
            dismiss()
        } catch {
            errorMessage = "Could not save your message. Your words are still here; try again."
        }
    }
}
