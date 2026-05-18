import Foundation

struct EPUBStructure {
    let title: String
    let author: String?
    let spine: [SpineItem]
}

struct SpineItem {
    let id: String
    let href: String
    let mediaType: String
    let rawText: String
    let markers: [SyncMarker]
    let textFormats: [TextFormat]
}
