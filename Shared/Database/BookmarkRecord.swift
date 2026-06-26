// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

// MARK: - Bridging from the app-level Bookmark model

/// GRDB record for the `bookmark` table.
struct BookmarkRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var trackID: String?
    var title: String
    var mediaTimestamp: TimeInterval
    var note: String?
    var voiceMemoPath: String?
    var imagePath: String?
    var isEnabled: Bool
    var playlistPosition: Double?
    var pdfViewStateJSON: String?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "bookmark"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case trackID = "track_id"
        case title
        case mediaTimestamp = "media_timestamp"
        case note
        case voiceMemoPath = "voice_memo_path"
        case imagePath = "image_path"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case pdfViewStateJSON = "pdf_view_state_json"
        case latitude
        case longitude
        case placeName = "place_name"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

// MARK: - Conversion from app-level Bookmark model (iOS only)

#if os(iOS) || os(macOS)
    extension BookmarkRecord {
        private static let logger = Logger(category: "BookmarkRecord")

        struct JSONCodingFailure: Error, CustomStringConvertible, LocalizedError, Sendable {
            let column: String
            let bookmarkID: String
            let audiobookID: String
            let operation: String
            let underlyingDescription: String

            var description: String {
                """
                Failed to \(operation) \(column) JSON for bookmark \(bookmarkID) \
                in audiobook \(audiobookID): \(underlyingDescription)
                """
            }

            var errorDescription: String? { description }
        }

        init(from model: Bookmark) throws {
            self.id = model.id.uuidString
            self.audiobookID = model.folderKey ?? ""
            self.trackID = model.trackId
            self.title = model.title
            self.mediaTimestamp = model.timestamp
            self.note = model.note
            self.voiceMemoPath = model.voiceMemoFileName
            self.imagePath = model.bookmarkImageFileName
            self.isEnabled = model.isEnabled
            self.playlistPosition = nil
            self.latitude = model.latitude
            self.longitude = model.longitude
            self.placeName = model.placeName
            self.createdAt = Date().ISO8601Format()
            self.modifiedAt = Date().ISO8601Format()
            self.pdfViewStateJSON = try Self.encodePDFViewState(
                model.pdfViewState,
                bookmarkID: self.id,
                audiobookID: self.audiobookID
            )
        }

        /// Convert to the app-level Bookmark domain model.
        func toModel() throws -> Bookmark {
            Bookmark(
                id: UUID(uuidString: id) ?? UUID(),
                title: title,
                folderKey: audiobookID,
                trackId: trackID,
                timestamp: mediaTimestamp,
                note: note,
                voiceMemoFileName: voiceMemoPath,
                bookmarkImageFileName: imagePath,
                pdfViewState: try decodePDFViewState(),
                isEnabled: isEnabled,
                latitude: latitude,
                longitude: longitude,
                placeName: placeName
            )
        }

        private func decodePDFViewState() throws -> PDFViewState? {
            guard let pdfViewStateJSON else { return nil }

            do {
                return try JSONDecoder().decode(
                    PDFViewState.self, from: Data(pdfViewStateJSON.utf8))
            } catch {
                let failure = JSONCodingFailure(
                    column: "pdf_view_state_json",
                    bookmarkID: id,
                    audiobookID: audiobookID,
                    operation: "decode",
                    underlyingDescription: String(describing: error)
                )
                Self.logJSONCodingFailure(failure)
                throw failure
            }
        }

        private static func encodePDFViewState(
            _ state: PDFViewState?,
            bookmarkID: String,
            audiobookID: String
        ) throws -> String? {
            guard let state else { return nil }

            do {
                let data = try JSONEncoder().encode(state)
                guard let json = String(data: data, encoding: .utf8) else {
                    let failure = JSONCodingFailure(
                        column: "pdf_view_state_json",
                        bookmarkID: bookmarkID,
                        audiobookID: audiobookID,
                        operation: "encode",
                        underlyingDescription: "Encoded data was not valid UTF-8"
                    )
                    logJSONCodingFailure(failure)
                    throw failure
                }
                return json
            } catch {
                if let failure = error as? JSONCodingFailure {
                    throw failure
                }
                let failure = JSONCodingFailure(
                    column: "pdf_view_state_json",
                    bookmarkID: bookmarkID,
                    audiobookID: audiobookID,
                    operation: "encode",
                    underlyingDescription: String(describing: error)
                )
                logJSONCodingFailure(failure)
                throw failure
            }
        }

        private static func logJSONCodingFailure(_ failure: JSONCodingFailure) {
            logger.error(
                """
                Failed to \(failure.operation, privacy: .public) persisted bookmark JSON column \(failure.column, privacy: .public) \
                for bookmark \(failure.bookmarkID, privacy: .private) \
                audiobook \(failure.audiobookID, privacy: .private): \
                \(failure.underlyingDescription, privacy: .private)
                """
            )
        }
    }
#endif
