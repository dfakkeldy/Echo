// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An audio track (file) in the playback queue.
struct Track: Identifiable, Equatable, Sendable {
    var id: String { url.absoluteString }
    /// The file URL of the audio track.
    let url: URL
    /// The display title derived from the file name.
    let title: String
    /// Whether the track is included during sequential playback.
    var isEnabled: Bool = true
}
