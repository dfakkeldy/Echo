// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct TrackDAO {
    let db: DatabaseWriter

    func tracks(for audiobookID: String) throws -> [TrackRecord] {
        try db.read { db in
            try tracks(for: audiobookID, in: db)
        }
    }

    func tracks(for audiobookID: String, in db: Database) throws -> [TrackRecord] {
        try TrackRecord
            .filter(Column("audiobook_id") == audiobookID)
            .order(Column("sort_order"))
            .fetchAll(db)
    }

    func insertAll(_ tracks: [TrackRecord], audiobookID: String) throws {
        try db.write { db in
            try insertAll(tracks, audiobookID: audiobookID, in: db)
        }
    }

    func insertAll(_ tracks: [TrackRecord], audiobookID: String, in db: Database) throws {
        for var track in tracks {
            try track.save(db)
        }
    }

    func refreshAll(_ refreshedTracks: [TrackRecord], audiobookID: String) throws {
        try db.write { db in
            try refreshAll(refreshedTracks, audiobookID: audiobookID, in: db)
        }
    }

    func refreshAll(_ refreshedTracks: [TrackRecord], audiobookID: String, in db: Database) throws {
        let persistedTracks: [TrackRecord] = try self.tracks(for: audiobookID, in: db)
        let incomingIDs = Set(refreshedTracks.map(\.id))
        let obsoleteIDs = persistedTracks.map(\.id).filter { !incomingIDs.contains($0) }

        try insertAll(refreshedTracks, audiobookID: audiobookID, in: db)

        guard !obsoleteIDs.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: obsoleteIDs.count).joined(separator: ", ")
        func obsoleteTrackArguments() -> StatementArguments {
            var arguments = StatementArguments([audiobookID])
            for trackID in obsoleteIDs {
                arguments += StatementArguments([trackID])
            }
            return arguments
        }

        try db.execute(
            sql: """
                UPDATE bookmark
                SET track_id = NULL
                WHERE audiobook_id = ?
                  AND track_id IN (\(placeholders))
                """,
            arguments: obsoleteTrackArguments()
        )
        try db.execute(
            sql: """
                UPDATE playback_event
                SET track_id = NULL
                WHERE audiobook_id = ?
                  AND track_id IN (\(placeholders))
                """,
            arguments: obsoleteTrackArguments()
        )
        try db.execute(
            sql: """
                DELETE FROM track
                WHERE audiobook_id = ?
                  AND id IN (\(placeholders))
                """,
            arguments: obsoleteTrackArguments()
        )
    }

    func updateEnabled(id: String, isEnabled: Bool) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE track SET is_enabled = ? WHERE id = ?",
                arguments: [isEnabled, id]
            )
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try TrackRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
