// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Book-level tags embedded in the exported file. Cover art is raw image data
/// (JPEG/PNG bytes) so the type stays cross-platform (no UIImage/NSImage). The
/// fields are mapped into `swift-audio-marker`'s metadata model by
/// `ChapterMarkerWriter` during the export's chapter-write pass.
struct ExportMetadata: Equatable {
    var title: String
    var author: String?
    var coverArt: Data?
}
