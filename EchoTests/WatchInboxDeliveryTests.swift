// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

@MainActor
struct WatchInboxDeliveryTests {
    private func queueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("inbox.json")
    }

    @Test func webhookPreservesWordsIdentityAndCaptureTimeWithoutABook() throws {
        let capture = try WatchInboxCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000277")!,
            text: "  Remember the milk.\nAnd eggs.  ",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), utcOffset: 3600)
        let body = try #require(JSONSerialization.jsonObject(with: capture.webhookData()) as? [String: Any])
        #expect(body["id"] as? String == "00000000-0000-0000-0000-000000000277")
        #expect(body["text"] as? String == "  Remember the milk.\nAnd eggs.  ")
        #expect(body["capturedAt"] as? String == "2023-11-14T23:13:20+01:00")
        #expect(body["source"] as? String == "echo-watch")
        #expect(body["context"] == nil)
    }

    @Test func emptyOrOversizedDictationCannotBecomeAQueuedMessage() throws {
        #expect(throws: WatchInboxError.self) { try WatchInboxCapture(text: " \n ") }
        #expect(throws: WatchInboxError.self) {
            try WatchInboxCapture(text: String(repeating: "a", count: 32_769))
        }
    }

    @Test func phoneHandoffSurvivesRestartAndDoesNotConfirmWebhookAcceptance() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = try WatchInboxCapture(text: "A thought without a book")
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try queue.enqueue(capture)
        try queue.markOnPhone(capture.id)
        let restored = try WatchInboxDeliveryQueue(fileURL: url)
        #expect(restored.pending.map(\.capture) == [capture])
        #expect(restored.pending.first?.isOnPhone == true)
        #expect(restored.lastAcceptedAt == nil)
    }

    @Test func acceptedCaptureIsNotSentAgainAndConflictingReuseIsRejected() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = try WatchInboxCapture(text: "Call the garage")
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try queue.enqueue(capture)
        try queue.accept(capture.id, at: Date(timeIntervalSince1970: 100))
        let restored = try WatchInboxDeliveryQueue(fileURL: url)
        #expect(try restored.enqueue(capture) == false)
        #expect(restored.pending.isEmpty)
        #expect(restored.lastAcceptedAt == Date(timeIntervalSince1970: 100))
        let conflict = try WatchInboxCapture(id: capture.id, text: "Different words")
        #expect(throws: WatchInboxError.self) { try restored.enqueue(conflict) }
    }

    @Test func failedSaveLeavesTheMessageAvailableForAnotherAttempt() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let capture = try WatchInboxCapture(text: "Keep these words")
        #expect(throws: (any Error).self) { try queue.enqueue(capture) }
        #expect(queue.pending.isEmpty)
        try FileManager.default.removeItem(at: url)
        #expect(try queue.enqueue(capture))
    }

    @Test func corruptQueueIsPreservedInsteadOfOverwritten() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data("unfinished queue".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) { try WatchInboxDeliveryQueue(fileURL: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func retryKeepsCaptureAndDestinationAndBacksOffAcrossRestart() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let destination = UUID()
        let capture = try WatchInboxCapture(text: "Try again later")
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try queue.enqueue(capture, configurationID: destination)
        try queue.recordFailure(capture.id, at: Date(timeIntervalSince1970: 100))
        try queue.bindUnconfigured(to: UUID())
        let restored = try WatchInboxDeliveryQueue(fileURL: url)
        let entry = try #require(restored.pending.first)
        #expect(entry.capture == capture)
        #expect(entry.configurationID == destination)
        #expect(entry.attempts == 1)
        #expect(entry.nextAttemptAt > Date(timeIntervalSince1970: 100))
    }

    @Test func webhookRequiresHTTPSAndOnlyTheOriginalPostCanConfirmDelivery() throws {
        #expect(throws: WatchInboxError.self) {
            try WatchInboxWebhookConfiguration(url: "http://example.com/inbox", key: "fixture")
        }
        let config = try WatchInboxWebhookConfiguration(url: "https://example.com/inbox", key: "fixture")
        let capture = try WatchInboxCapture(text: "Send this once")
        let request = try config.request(for: capture)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == capture.id.uuidString)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.httpBody == nil) // Background uploads use the durable file.
        #expect(config.accepts(status: 202, url: config.url, method: "POST"))
        #expect(!config.accepts(status: 500, url: config.url, method: "POST"))
        #expect(!config.accepts(status: 200, url: URL(string: "https://example.com/login"), method: "POST"))
        #expect(!config.accepts(status: 200, url: config.url, method: "GET"))
    }
}
