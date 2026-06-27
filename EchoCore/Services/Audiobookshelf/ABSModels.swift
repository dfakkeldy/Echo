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
    case untrustedCertificate(host: String, sha256: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "No Audiobookshelf server connected."
        case .unauthorized: return "Authentication failed. Sign in again."
        case .network(let e):
            if (e as? URLError)?.code == .appTransportSecurityRequiresSecureConnection {
                return
                    "App Transport Security blocked plain HTTP. Reinstall the latest app build, or use an HTTPS Audiobookshelf URL."
            }
            return e.localizedDescription
        case .http(let code, _): return "Server returned HTTP \(code)."
        case .serverMessage(let m): return m
        case .missingField(let f): return "Response missing required field: \(f)."
        case .untrustedCertificate(let host, _):
            return "\"\(host)\" is using a self-signed certificate that isn't trusted yet."
        }
    }
}

extension ABSError {
    /// If `error` is a TLS server-trust failure (`URLError.serverCertificateUntrusted`) and the
    /// trust delegate captured a leaf fingerprint, surface it as `.untrustedCertificate` so the UI
    /// can offer to pin it. Every other error passes through unchanged. Pure — unit-tested.
    static func mappingTrustFailure(
        _ error: ABSError, capturedFingerprint: String?, host: String
    ) -> ABSError {
        guard case .network(let underlying) = error,
            (underlying as? URLError)?.code == .serverCertificateUntrusted,
            let fingerprint = capturedFingerprint
        else { return error }
        return .untrustedCertificate(host: host, sha256: fingerprint)
    }

    var privacySafeLogDescription: String {
        switch self {
        case .notConnected:
            return "not connected"
        case .unauthorized:
            return "unauthorized"
        case .network(let error):
            if let urlError = error as? URLError {
                return "network error \(urlError.code.rawValue)"
            }
            return "network error"
        case .http(let code, _):
            return "HTTP \(code)"
        case .serverMessage:
            return "server message"
        case .missingField(let field):
            return "missing field \(field)"
        case .untrustedCertificate:
            return "untrusted certificate"
        }
    }
}

enum ABSSignOutResult {
    case noRemoteToken
    case remoteRevoked
    case remoteRevokeFailed(ABSError)
    case remoteRevokeUnknown

    var didRemoteRevokeFail: Bool {
        switch self {
        case .remoteRevokeFailed, .remoteRevokeUnknown:
            return true
        case .noRemoteToken, .remoteRevoked:
            return false
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
            case title, author, authors, narrator, narrators, series, description, genres,
                publisher,
                isbn, asin, language, explicit
            case authorName = "authorName"
            case narratorName = "narratorName"
            case seriesName = "seriesName"
            case publishedYear = "publishedYear"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            title = Self.string(in: container, forKey: .title)
            author =
                Self.string(in: container, forKey: .author)
                ?? Self.string(in: container, forKey: .authorName)
                ?? Self.joined(Self.namedValues(in: container, forKey: .authors))
            narrator =
                Self.string(in: container, forKey: .narrator)
                ?? Self.string(in: container, forKey: .narratorName)
                ?? Self.joined(Self.namedValues(in: container, forKey: .narrators))
            series =
                Self.string(in: container, forKey: .series)
                ?? Self.string(in: container, forKey: .seriesName)
                ?? Self.joined(Self.namedValues(in: container, forKey: .series))
            description = Self.string(in: container, forKey: .description)
            genres = Self.stringArray(in: container, forKey: .genres)
            publishedYear = Self.string(in: container, forKey: .publishedYear)
            publisher = Self.string(in: container, forKey: .publisher)
            isbn = Self.string(in: container, forKey: .isbn)
            asin = Self.string(in: container, forKey: .asin)
            language = Self.string(in: container, forKey: .language)
            explicit = try? container.decodeIfPresent(Bool.self, forKey: .explicit)
        }

        private struct NamedValue: Decodable {
            let name: String?
        }

        private static func string(
            in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
        ) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
                return nil
            }
            return normalized(value)
        }

        private static func stringArray(
            in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
        ) -> [String]? {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                let normalizedValues = values.compactMap(normalized)
                return normalizedValues.isEmpty ? nil : normalizedValues
            }
            if let value = string(in: container, forKey: key) { return [value] }
            return nil
        }

        private static func namedValues(
            in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
        ) -> [String] {
            if let values = stringArray(in: container, forKey: key) { return values }
            if let values = try? container.decodeIfPresent([NamedValue].self, forKey: key) {
                return values.compactMap { normalized($0.name) }
            }
            if let value = try? container.decodeIfPresent(NamedValue.self, forKey: key),
                let name = normalized(value.name)
            {
                return [name]
            }
            return []
        }

        private static func joined(_ values: [String]) -> String? {
            values.isEmpty ? nil : values.joined(separator: ", ")
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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
    let podcast: [ABSSearchBookResult]

    var libraryItems: [ABSLibraryItem] { book.map(\.libraryItem) + podcast.map(\.libraryItem) }

    enum CodingKeys: String, CodingKey {
        case book, podcast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        book = try container.decodeIfPresent([ABSSearchBookResult].self, forKey: .book) ?? []
        podcast = try container.decodeIfPresent([ABSSearchBookResult].self, forKey: .podcast) ?? []
    }
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

/// Focused PATCH body for pushing local playback progress to ABS.
struct ABSMediaProgressPatch: Encodable {
    let currentTime: Double
    let duration: Double
    let progress: Double
    let isFinished: Bool
}
