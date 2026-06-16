// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Centralized constants for image encoding across the app.
enum ImageEncoding {
    /// Maximum dimension for bookmark artwork JPEGs.
    static let bookmarkMaxDimension: CGFloat = 1600
    /// Compression quality for bookmark artwork JPEGs.
    static let bookmarkJPEGQuality: CGFloat = 0.84
    /// Compression quality for watch transfer JPEG thumbnails.
    static let watchTransferJPEGQuality: CGFloat = 0.75
}
