// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Error

enum ABSError: Error, LocalizedError {
    case notConnected
    case unauthorized
    case network(Error)
    case http(Int, body: String?)
    case serverMessage(String)
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "No Audiobookshelf server connected."
        case .unauthorized: return "Authentication failed. Sign in again."
        case .network(let e): return e.localizedDescription
        case .http(let code, _): return "Server returned HTTP \(code)."
        case .serverMessage(let m): return m
        case .missingField(let f): return "Response missing required field: \(f)."
        }
    }
}

// MARK: - Auth

struct ABSLoginRequest: Encodable {
    let username: String
    let password: String
}

struct ABSLoginResponse: Decodable {
    let user: ABSUser
    let userDefaultLibraryId: String?
    let serverSettings: ABSServerSettings?
    struct ABSUser: Decodable {
        let id: String
        let token: String?  // legacy permanent token (pre-2.26)
        let accessToken: String?  // new short-lived JWT
        let refreshToken: String?  // new rotating refresh token
    }

    /// Prefer the new short-lived JWT; fall back to the legacy permanent token.
    var access: String? { user.accessToken ?? user.token }
    var refresh: String? { user.refreshToken }
}

struct ABSServerSettings: Decodable {
    let id: String?
}

// MARK: - Libraries

struct ABSLibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

struct ABSLibrary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayOrder: Int?
    let mediaType: String?  // "book", "podcast", etc.

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayOrder = "displayOrder"
        case mediaType = "mediaType"
    }
}

struct ABSLibraryItemsResponse: Decodable {
    let results: [ABSLibraryItem]
    let total: Int?
    let limit: Int?
    let page: Int?
    let numPages: Int?
}

// MARK: - Library Item

struct ABSLibraryItem: Decodable, Identifiable {
    let id: String
    let ino: String?  // library item inode
    let libraryId: String
    let folderId: String?
    let path: String?
    let relPath: String?
    let isFile: Bool?
    let mimeType: String?
    let size: Int64?
    let media: ABSMedia?

    // If media.metadata is present, these convenience accessors surface the
    // relevant metadata fields.
    var title: String? { media?.metadata?.title }
    var author: String? { media?.metadata?.authorName }
    var publishedYear: String? { media?.metadata?.publishedYear }
    var numTracks: Int? { media?.numTracks }
    var duration: Double? { media?.duration }
    var coverPath: String? { media?.coverPath }

    /// Genre + tag + series, deduped — the "topics" Echo persists on import.
    var topics: [String] {
        var set = Set<String>()
        media?.metadata?.genres?.forEach { set.insert($0) }
        media?.tags?.forEach { set.insert($0) }
        if let series = media?.metadata?.series { set.insert(series) }
        return set.sorted()
    }

    struct ABSMedia: Decodable {
        let id: String?
        let metadata: ABSMetadata?
        let coverPath: String?
        let tags: [String]?
        let numTracks: Int?
        let duration: Double?
        let tracks: [ABSTrack]?
        let chapters: [ABSChapter]?

        enum CodingKeys: String, CodingKey {
            case id, metadata, coverPath, tags, numTracks, duration, tracks, chapters
        }
    }

    struct ABSMetadata: Decodable {
        let title: String?
        let author: String?
        let narrator: String?
        let series: String?
        let description: String?
        let genres: [String]?
        let publishedYear: String?
        let publisher: String?
        let isbn: String?
        let asin: String?
        let language: String?
        let explicit: Bool?

        var authorName: String? { author }

        enum CodingKeys: String, CodingKey {
            case title, author, narrator, series, description, genres, publisher, isbn, asin,
                language, explicit
            case publishedYear = "publishedYear"
        }
    }

    struct ABSTrack: Decodable {
        let index: Int?
        let startOffset: Double?
        let duration: Double?
        let title: String?
        let contentUrl: String?
        let mimeType: String?
        let metadata: ABSTrackMetadata?
    }

    struct ABSTrackMetadata: Decodable {
        let embeddedCoverArt: String?
        let tagTitle: String?
        let tagArtist: String?
        let tagAlbum: String?
    }

    struct ABSChapter: Decodable {
        let id: Int?
        let start: Double?
        let end: Double?
        let title: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, ino, libraryId, folderId, path, relPath, isFile, mimeType, size, media
    }
}

// MARK: - Search

struct ABSSearchResponse: Decodable {
    let book: [ABSSearchBookResult]
}

struct ABSSearchBookResult: Decodable {
    let libraryItem: ABSLibraryItem
}

// MARK: - Media Progress (Milestone D)

struct ABSMediaProgress: Encodable {
    let libraryItemId: String
    let episodeId: String?
    let duration: Double?
    let progress: Double?  // 0.0–1.0 fraction complete
    let currentTime: Double?
    let isFinished: Bool?
    let hideFromContinueListening: Bool?
    let ebookLocation: String?
    let ebookProgress: Double?
}

struct ABSMediaProgressResponse: Decodable {
    let libraryItemId: String?
    let episodeId: String?
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Int64?
    let ebookLocation: String?
    let ebookProgress: Double?
}
