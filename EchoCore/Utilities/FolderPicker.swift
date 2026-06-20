// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FolderPicker: UIViewControllerRepresentable {
    let onPickFolder: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let m4bType = UTType(filenameExtension: "m4b") ?? .audio
        let epubType = UTType(filenameExtension: "epub")
        let markdownType = UTType(filenameExtension: "md")
        let types: [UTType] =
            [.folder, m4bType, .audio, .plainText]
            + [epubType, markdownType].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickFolder: onPickFolder)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickFolder: (URL) -> Void

        init(onPickFolder: @escaping (URL) -> Void) {
            self.onPickFolder = onPickFolder
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPickFolder(url)
        }
    }
}
