// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct EPUBSourceAnchorResolver: Sendable {
    private let dbReader: any DatabaseReader

    init(dbReader: any DatabaseReader) {
        self.dbReader = dbReader
    }

    func hasBlocks(for targetMediaID: String) throws -> Bool {
        try dbReader.read { db in
            try Self.hasBlocks(for: targetMediaID, in: db)
        }
    }

    static func hasBlocks(for targetMediaID: String, in db: Database) throws -> Bool {
        try EPubBlockRecord
            .filter(Column("audiobook_id") == targetMediaID)
            .fetchCount(db) > 0
    }

    func resolve(
        sourceAnchor: String?,
        targetMediaID: String,
        cardReference: String
    ) throws -> EPUBSourceAnchorResolution {
        try dbReader.read { db in
            try Self.resolve(
                sourceAnchor: sourceAnchor,
                targetMediaID: targetMediaID,
                cardReference: cardReference,
                in: db
            )
        }
    }

    static func resolve(
        sourceAnchor: String?,
        targetMediaID: String,
        cardReference: String,
        in db: Database
    ) throws -> EPUBSourceAnchorResolution {
        guard let rawAnchor = sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawAnchor.isEmpty
        else {
            return .none
        }

        let portableSuffix = AlignmentSidecar.portableSuffix(of: rawAnchor)
        guard Self.isValidPortableSuffix(portableSuffix) else {
            return .unresolved(
                .sourceAnchorMalformed(cardReference: cardReference, sourceAnchor: rawAnchor))
        }

        let localBlockID = AlignmentSidecar.localBlockID(portableSuffix, audiobookID: targetMediaID)

        if try Self.blockExists(db, id: localBlockID, audiobookID: targetMediaID) {
            return .resolved(localBlockID)
        }

        if rawAnchor.hasPrefix("epub-"),
            try Self.blockExistsInDifferentBook(db, id: rawAnchor, targetMediaID: targetMediaID)
        {
            return .unresolved(
                .sourceAnchorWrongBook(cardReference: cardReference, sourceAnchor: rawAnchor))
        }

        return .unresolved(
            .sourceAnchorUnresolved(cardReference: cardReference, sourceAnchor: rawAnchor))
    }

    private static func isValidPortableSuffix(_ suffix: String) -> Bool {
        suffix.range(of: #"^s[0-9]+-b[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func blockExists(_ db: Database, id: String, audiobookID: String) throws -> Bool
    {
        try EPubBlockRecord
            .filter(Column("id") == id && Column("audiobook_id") == audiobookID)
            .fetchOne(db) != nil
    }

    private static func blockExistsInDifferentBook(
        _ db: Database, id: String, targetMediaID: String
    ) throws -> Bool {
        try EPubBlockRecord
            .filter(Column("id") == id && Column("audiobook_id") != targetMediaID)
            .fetchOne(db) != nil
    }
}

enum EPUBSourceAnchorResolution: Equatable, Sendable {
    case none
    case resolved(String)
    case unresolved(ImportDeckWarning)
}
