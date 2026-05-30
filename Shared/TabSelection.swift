import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case timeline

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
        case .timeline: return "Timeline"
        }
    }
}
