// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct WatchThumbnailTransferPolicyTests {
    @Test("changed data is sent even when the logical artwork key is unchanged")
    func changedDataWithSameKeyIsSent() throws {
        var policy = WatchThumbnailTransferPolicy()

        let firstPayload = policy.payload(
            artworkKey: "track#base", data: Data([0x01]), artworkSequence: 10)
        let first = try #require(firstPayload)
        let duplicate = policy.payload(
            artworkKey: "track#base", data: Data([0x01]), artworkSequence: 10)
        let replacementPayload = policy.payload(
            artworkKey: "track#base", data: Data([0x02]), artworkSequence: 12)
        let replacement = try #require(replacementPayload)

        #expect(first["thumbnailData"] as? Data == Data([0x01]))
        #expect(first["artworkSeq"] as? Double == 10)
        #expect(duplicate == nil)
        #expect(replacement["thumbnailData"] as? Data == Data([0x02]))
    }

    @Test("resend clears dedupe only when the watch reports an older transfer")
    func resendPayloadForBehindWatch() throws {
        var policy = WatchThumbnailTransferPolicy()

        #expect(
            policy.payload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 30) != nil)
        // The normal path dedups the identical transfer…
        #expect(
            policy.payload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 30) == nil)
        // …but a watch that reports holding nothing gets it again.
        // (#require can't wrap the mutating call directly: the macro closes
        // over the policy as an immutable value.)
        let resentPayload = policy.resendPayload(
            artworkKey: "track#base", data: Data([0x01]), artworkSequence: 30,
            watchHeldArtworkSequence: 0)
        let resent = try #require(resentPayload)
        #expect(resent["artworkSeq"] as? Double == 30)
        #expect(resent["thumbnailData"] as? Data == Data([0x01]))
        // A watch already holding the current artwork does not.
        #expect(
            policy.resendPayload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 30,
                watchHeldArtworkSequence: 30) == nil)
        // And the resend re-arms dedupe for the normal path.
        #expect(
            policy.payload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 30) == nil)
    }

    @Test("explicit absence resets dedupe so regenerated artwork can be sent")
    func absenceResetsDedupe() {
        var policy = WatchThumbnailTransferPolicy()

        #expect(
            policy.payload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 20) != nil)
        #expect(
            policy.payload(artworkKey: "track#base", data: nil, artworkSequence: 21) == nil)
        #expect(
            policy.payload(
                artworkKey: "track#base", data: Data([0x01]), artworkSequence: 22) != nil)
    }
}
