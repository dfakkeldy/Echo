// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized) struct ABSAuthLifecycleSourceTests {
    private func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func connectRollbackClearsTokenStoreForLoginAndSaveFailures() throws {
        let src = try source("EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift")

        #expect(
            src.contains(
                "tokens.clear()\n            Self.absLogger.warning(\n                \"ABS login failed"
            ))
        #expect(
            src.contains(
                "tokens.clear()\n            Self.absLogger.error(\n                \"ABS server record save failed"
            ))
        #expect(!src.contains("if pinnedSHA256 != nil { tokens.clear() }"))
    }

    @Test func disconnectExposesRemoteSignOutFailureWarning() throws {
        let modelSrc = try source("EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift")
        let stateSrc = try source("EchoCore/ViewModels/PlayerModel.swift")

        #expect(modelSrc.contains("async throws -> ABSSignOutResult"))
        #expect(modelSrc.contains("absRemoteSignOutWarning ="))
        #expect(modelSrc.contains("case .remoteRevokeFailed"))
        #expect(modelSrc.contains("case .remoteRevokeUnknown"))
        #expect(modelSrc.contains("local disconnect continuing"))
        #expect(stateSrc.contains("var absRemoteSignOutWarning: String?"))
    }

    @Test func connectionsViewShowsRemoteSignOutWarningAfterLocalDisconnect() throws {
        let src = try source("EchoCore/Views/ABSConnectionsSettingsView.swift")

        #expect(src.contains("@State private var warningMessage: String?"))
        #expect(src.contains("try await model.disconnectAudiobookshelf(server)"))
        #expect(src.contains("result.didRemoteRevokeFail"))
        #expect(src.contains("Text(\"Warning\")"))
        #expect(src.contains("server session may remain active until it expires"))
    }

    @Test func disconnectWithUnbuildableServiceWarnsWhenRefreshTokenMayRemainRemote() async throws {
        let model = PlayerModel()
        let database = try DatabaseService(inMemory: ())
        model.databaseService = database
        let server = ABSServerRecord(
            id: "disconnect-unknown-\(UUID().uuidString)",
            baseURL: "",
            username: "reader",
            defaultLibraryId: nil,
            addedAt: Date.now.formatted(.iso8601))
        try ABSServerDAO(db: database.writer).upsert(server)

        let tokens = ABSTokenStore(serverID: server.id)
        tokens.accessToken = "access"
        tokens.refreshToken = "refresh"
        defer { tokens.clear() }

        let result = try await model.disconnectAudiobookshelf(server)

        guard case .remoteRevokeUnknown = result else {
            Issue.record(
                "Expected remoteRevokeUnknown when a refresh token exists but no service can be built"
            )
            return
        }
        #expect(result.didRemoteRevokeFail)
        #expect(model.absRemoteSignOutWarning?.contains("server session may remain active") == true)
        let reloadedTokens = ABSTokenStore(serverID: server.id)
        #expect(reloadedTokens.refreshToken == nil)
        #expect(try ABSServerDAO(db: database.writer).current() == nil)
    }

    @Test func disconnectPropagatesLocalServerDeleteFailure() async throws {
        let model = PlayerModel()
        let database = try DatabaseService(inMemory: ())
        model.databaseService = database
        let server = ABSServerRecord(
            id: "delete-failure-\(UUID().uuidString)",
            baseURL: "http://homelab.local:13378",
            username: "reader",
            defaultLibraryId: nil,
            addedAt: Date.now.formatted(.iso8601))
        try ABSServerDAO(db: database.writer).upsert(server)
        try database.write { db in
            try db.execute(sql: "DROP TABLE abs_server")
        }

        await #expect {
            _ = try await model.disconnectAudiobookshelf(server)
        } throws: { _ in
            true
        }
    }
}
