// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Presents the on-device dictionary (`UIReferenceLibraryViewController`) for a term.
enum DictionaryLookupPresenter {
    /// Trims leading/trailing punctuation and symbols (keeping internal hyphens
    /// and apostrophes) so attached punctuation from the tokenizer — `"world."`,
    /// `"“Hello”"`, `"mother-in-law,"` — doesn't fail dictionary lookup or
    /// pollute saved vocabulary cards / their dedupe key.
    static func sanitizedTerm(_ term: String) -> String {
        let strip = CharacterSet.punctuationCharacters.union(.symbols)
        var s = Substring(term)
        while let first = s.first, first.unicodeScalars.allSatisfy(strip.contains) {
            s = s.dropFirst()
        }
        while let last = s.last, last.unicodeScalars.allSatisfy(strip.contains) {
            s = s.dropLast()
        }
        return String(s)
    }

    static func hasDefinition(for term: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: sanitizedTerm(term))
    }

    @MainActor
    static func present(term: String) {
        let term = sanitizedTerm(term)
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
