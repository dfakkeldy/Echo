// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

nonisolated struct AnthologyNarrationManifestResolver: Sendable {
    let db: DatabaseWriter

    func resolve(
        audiobookID: String,
        epubURL: URL? = nil
    ) throws -> AnthologyBuildManifest? {
        let epubPath = epubURL?.standardizedFileURL.path
        let build = try db.read { database in
            try AnthologyBuildRecord.fetchOne(
                database,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE status = 'succeeded'
                      AND (audiobook_id = ? OR (? IS NOT NULL AND epub_path = ?))
                    ORDER BY revision DESC, created_at DESC, id DESC
                    LIMIT 1
                    """,
                arguments: [audiobookID, epubPath, epubPath]
            )
        }
        return try build.map(AnthologyBuildManifestValidator.validate)
    }
}
