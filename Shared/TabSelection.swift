// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case library
    // .timeline removed — the Study playlist is gone; the Read feed IS the study surface.
    // .stats removed — Stats now opens as a sheet from the More menu (UnifiedTopHeader).

    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        case .library: return "books.vertical"
        }
    }

    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read & Study"
        case .library: return "Library"
        }
    }
}
