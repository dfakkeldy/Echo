// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case timeline
    // .stats removed — Stats now opens as a sheet from the More menu (UnifiedTopHeader).

    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        case .timeline: return "list.bullet.rectangle"
        }
    }

    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read"
        case .timeline: return "Study"
        }
    }
}
