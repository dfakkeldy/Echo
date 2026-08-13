// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Book-level tags embedded in the exported file. Cover art is raw image data
/// (JPEG/PNG bytes) so the type stays cross-platform (no UIImage/NSImage). The
/// fields are mapped into `swift-audio-marker`'s metadata model by
/// `ChapterMarkerWriter` during the export's chapter-write pass.
nonisolated struct ExportMetadata: Equatable, Sendable {
    var title: String
    var author: String?
    var coverArt: Data?
    /// Free-text provenance written to the `©cmt` atom (e.g. the narration version
    /// stamp). `nil` leaves any existing comment untouched.
    var comment: String? = nil
}
