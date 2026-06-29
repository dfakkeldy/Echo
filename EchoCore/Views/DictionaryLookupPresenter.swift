// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Presents the on-device dictionary (`UIReferenceLibraryViewController`) for a term.
enum DictionaryLookupPresenter {
    static func hasDefinition(for term: String) -> Bool {
        let term = DictionaryLookupTerm.sanitized(term)
        guard !term.isEmpty else { return false }
        return UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    @MainActor
    static func present(term: String) {
        let term = DictionaryLookupTerm.sanitized(term)
        guard !term.isEmpty else { return }
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(UIReferenceLibraryViewController(term: term), animated: true)
    }
}
