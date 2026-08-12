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

enum ABSBrowseResultResolver {
    nonisolated static func combinedIDs(
        filteredBy groups: [ABSFilterGroup: [[String]]]
    ) -> Set<String> {
        var groupIDs = groups.values.map { selections in
            selections.reduce(into: Set<String>()) { ids, selection in
                ids.formUnion(selection)
            }
        }

        guard var combined = groupIDs.popLast() else { return [] }
        for ids in groupIDs {
            combined.formIntersection(ids)
        }
        return combined
    }

    nonisolated static func sorted(
        _ items: [ABSLibraryItem], by sort: ABSBrowseSort
    ) -> [ABSLibraryItem] {
        var seenIDs = Set<String>()
        let deduplicated = items.filter { seenIDs.insert($0.id).inserted }
        return deduplicated.sorted { isOrderedBefore($0, $1, by: sort) }
    }

    private nonisolated static func isOrderedBefore(
        _ lhs: ABSLibraryItem, _ rhs: ABSLibraryItem, by sort: ABSBrowseSort
    ) -> Bool {
        let comparison: ComparisonResult
        switch sort {
        case .newestAdded:
            comparison = descending(lhs.addedAt, rhs.addedAt)
        case .title:
            comparison = localized(lhs.title, rhs.title)
        case .author:
            comparison = localized(lhs.author, rhs.author)
        case .series:
            return isSeriesOrderedBefore(lhs, rhs)
        case .publicationYear:
            comparison = descendingLocalized(lhs.publishedYear, rhs.publishedYear)
        }

        if comparison != .orderedSame { return comparison == .orderedAscending }
        return isTitleThenIDOrderedBefore(lhs, rhs)
    }

    private nonisolated static func isSeriesOrderedBefore(
        _ lhs: ABSLibraryItem, _ rhs: ABSLibraryItem
    ) -> Bool {
        switch (lhs.seriesName, rhs.seriesName) {
        case let (lhsSeries?, rhsSeries?):
            let seriesComparison = localized(lhsSeries, rhsSeries)
            if seriesComparison != .orderedSame {
                return seriesComparison == .orderedAscending
            }

            let sequenceComparison = ascendingSequence(lhs.seriesSequence, rhs.seriesSequence)
            if sequenceComparison != .orderedSame {
                return sequenceComparison == .orderedAscending
            }
            return isTitleThenIDOrderedBefore(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return isTitleThenIDOrderedBefore(lhs, rhs)
        }
    }

    private nonisolated static func isTitleThenIDOrderedBefore(
        _ lhs: ABSLibraryItem, _ rhs: ABSLibraryItem
    ) -> Bool {
        let titleComparison = localized(lhs.title, rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func localized(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        (lhs ?? "").localizedStandardCompare(rhs ?? "")
    }

    private nonisolated static func descendingLocalized(
        _ lhs: String?, _ rhs: String?
    ) -> ComparisonResult {
        localized(rhs, lhs)
    }

    private nonisolated static func descending(_ lhs: Int64?, _ rhs: Int64?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs > rhs:
            return .orderedAscending
        case let (lhs?, rhs?) where lhs < rhs:
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        default:
            return .orderedSame
        }
    }

    private nonisolated static func ascendingSequence(
        _ lhs: String?, _ rhs: String?
    ) -> ComparisonResult {
        switch (numericSequence(lhs), numericSequence(rhs)) {
        case let (lhs?, rhs?) where lhs < rhs:
            return .orderedAscending
        case let (lhs?, rhs?) where lhs > rhs:
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        default:
            return .orderedSame
        }
    }

    private nonisolated static func numericSequence(_ value: String?) -> Double? {
        guard let value, let sequence = Double(value), sequence.isFinite else { return nil }
        return sequence
    }
}
