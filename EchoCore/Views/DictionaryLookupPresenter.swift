// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Presents the on-device dictionary (`UIReferenceLibraryViewController`) for a term.
enum DictionaryLookupPresenter {
    /// Trims leading/trailing punctuation and symbols (keeping internal hyphens
    /// and apostrophes) so attached punctuation from the tokenizer — `"world."`,
    /// `"“Hello”"`, `"mother-in-law,"` — doesn't fail dictionary lookup or
    /// pollute saved vocabulary cards / their dedupe key.
    static func sanitizedTerm(_ term: String) -> String {
        DictionaryLookupTerm.sanitized(term)
    }

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
