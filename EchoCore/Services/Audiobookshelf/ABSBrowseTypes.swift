// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ABSBrowseSort: String, CaseIterable, Codable, Sendable {
    case newestAdded, title, author, series, publicationYear

    var serverField: String? {
        switch self {
        case .newestAdded: "addedAt"
        case .title: "media.metadata.title"
        case .author: "media.metadata.authorName"
        case .series: nil
        case .publicationYear: "media.metadata.publishedYear"
        }
    }

    var descending: Bool { self == .newestAdded || self == .publicationYear }
}

enum ABSFilterGroup: String, CaseIterable, Codable, Sendable {
    case authors, series, genres, tags
}

struct ABSFilterOption: Identifiable, Hashable, Sendable {
    let group: ABSFilterGroup
    let value: String
    let label: String

    var id: String { "\(group.rawValue):\(value)" }
    var encodedFilter: String {
        "\(group.rawValue).\(Data(value.utf8).base64EncodedString())"
    }
}

struct ABSFilterSelection: Equatable, Sendable {
    var options: Set<ABSFilterOption> = []
    var notAddedOnly = false
}

struct ABSLibraryFilterData: Equatable, Sendable {
    let authors: [ABSFilterOption]
    let series: [ABSFilterOption]
    let genres: [ABSFilterOption]
    let tags: [ABSFilterOption]

    static let empty = ABSLibraryFilterData(authors: [], series: [], genres: [], tags: [])
}

struct ABSLibraryItemsQuery: Equatable, Sendable {
    var page = 0
    var limit = 100
    var sort: ABSBrowseSort = .newestAdded
    var filter: ABSFilterOption?

    var sortField: String? { sort.serverField }
    var descending: Bool { sort.descending }
}
