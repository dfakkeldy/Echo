// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct ExportVideoPreferredVoiceRequestTests {
    @Test func nondefaultVoiceResolvesFromCallerInput() throws {
        #expect(try ExportVideoPreferredVoiceRequest.resolve("bf_emma") == VoiceID("bf_emma"))
    }

    @Test func unknownVoiceIsRejected() {
        #expect(throws: ExportVideoPreferredVoiceRequestError.unknownVoice("not-a-voice")) {
            try ExportVideoPreferredVoiceRequest.resolve("not-a-voice")
        }
    }

    @Test func omittedOrEmptyVoiceResolvesToDefault() throws {
        #expect(try ExportVideoPreferredVoiceRequest.resolve(nil) == VoiceCatalog.default.id)
        #expect(try ExportVideoPreferredVoiceRequest.resolve("") == VoiceCatalog.default.id)
        #expect(try ExportVideoPreferredVoiceRequest.resolve("   ") == VoiceCatalog.default.id)
    }
}
