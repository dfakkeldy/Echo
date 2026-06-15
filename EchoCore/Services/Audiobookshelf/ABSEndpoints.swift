import Foundation

/// All Audiobookshelf URL/path construction in one place.
enum ABSEndpoints {
    /// Full base URL for the connected server, validated on login.
    /// Strips a trailing slash from user input; the individual endpoint
    /// functions prepend the leading slash they need.
    static func baseURL(from raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    // MARK: - Auth

    static func login(_ base: String) -> URL {
        URL(string: "\(base)/login")!
    }

    // MARK: - Libraries

    static func libraries(_ base: String) -> URL {
        URL(string: "\(base)/api/libraries")!
    }

    // MARK: - Library Items

    /// List items in a library, paged.
    static func libraryItems(_ base: String, libraryID: String, limit: Int = 25, page: Int = 0)
        -> URL
    {
        var components = URLComponents(
            string: "\(base)/api/libraries/\(libraryID)/items")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort", value: "media.metadata.title"),
            URLQueryItem(name: "minified", value: "0"),
        ]
        return components.url!
    }

    /// Single item detail.
    static func itemDetail(_ base: String, itemID: String) -> URL {
        URL(string: "\(base)/api/items/\(itemID)?expanded=1")!
    }

    /// Item cover image.
    static func itemCover(_ base: String, itemID: String, coverPath: String?, width: Int = 400)
        -> URL?
    {
        guard let path = coverPath else { return nil }
        return URL(string: "\(base)/api/items/\(itemID)/cover/\(path)?width=\(width)")
    }

    // MARK: - Download

    /// Download the item's full audio as a single file.
    static func downloadItem(_ base: String, itemID: String) -> URL {
        URL(string: "\(base)/api/items/\(itemID)/download")!
    }

    // MARK: - Media Progress (Milestone D)

    static func mediaProgress(
        _ base: String, libraryItemID: String, episodeID: String? = nil
    ) -> URL {
        let escapedItem =
            libraryItemID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? libraryItemID
        var url = URL(string: "\(base)/api/me/progress/\(escapedItem)")!
        if let ep = episodeID {
            url = url.appending(queryItems: [URLQueryItem(name: "episodeId", value: ep)])
        }
        return url
    }

    /// Batch sync multiple progress records.
    static func batchProgressSync(_ base: String) -> URL {
        URL(string: "\(base)/api/me/progress/batch/update")!
    }
}
