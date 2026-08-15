// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V18 — Audiobookshelf: the single connected server's non-secret identity.
/// Tokens are NEVER stored here; the refresh token lives in the Keychain
/// (see `ABSTokenStore`). One row for v1; multi-server is post-1.0.
enum Schema_V18 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "abs_server") { t in
            t.column("id", .text).primaryKey()  // stable server UUID we mint
            t.column("base_url", .text).notNull()  // e.g. http://host:13378
            t.column("username", .text).notNull()
            t.column("default_library_id", .text)  // from login response, optional
            t.column("added_at", .text).notNull()
        }
    }
}
