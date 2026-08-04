// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct EnglishPronunciationAuditPackTests {
    @Test func bundledAuditPackLoadsOnlyShadowCandidates() throws {
        let url = try #require(NarrationResources.url(
            forResource: "us_pronunciation_audit_pack", withExtension: "json"))
        let pack = try EnglishPronunciationAuditPack(data: Data(contentsOf: url))

        #expect(pack.auditPackVersion.hasPrefix("sha256:"))
        #expect(pack.auditPackVersion != EnglishPronunciationAuditPack.empty.auditPackVersion)
        #expect(pack.entryCount > 0)
        #expect(pack.candidateCount >= pack.entryCount)
        #expect(pack.alternatives(for: "record").allSatisfy {
            $0.authority == "uncertain"
                && $0.validation == "shadow"
                && !$0.automaticEligible
        })
    }

    @Test func malformedAuditPackFailsClosed() {
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(data: Data("not-json".utf8))
        }
    }

    @Test func auditVersionCannotChangeProductionPolicySignature() async {
        let production = EnglishPronunciationPack.empty
        let before = production.productionPolicySignature
        let audit = await EnglishPronunciationAuditPack.bundledOrEmpty()
        let after = production.productionPolicySignature

        #expect(audit.auditPackVersion != "")
        #expect(after == before)
    }
}
