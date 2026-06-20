// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ExportMetadata {
    /// "Good enough to export silently": both an author and a cover are present.
    /// When false, the export flow shows a small pre-filled confirm sheet.
    var isComplete: Bool {
        (author?.isEmpty == false) && coverArt != nil
    }
}
