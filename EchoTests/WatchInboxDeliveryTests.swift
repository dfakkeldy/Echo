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

    @Test func correctedCredentialsReplaceTheOldScheduledRequestImmediately() throws {
        let destination = UUID()
        let old = try WatchInboxWebhookConfiguration(
            id: destination, url: "https://example.com/inbox", key: "old-fixture")
        let corrected = try WatchInboxWebhookConfiguration(
            id: destination, url: old.url.absoluteString, key: "corrected-fixture")
        let capture = try WatchInboxCapture(text: "Keep the original capture")
        var entry = WatchInboxDeliveryQueue.Pending(capture: capture, configurationID: destination)
        entry.attempts = 7
        entry.nextAttemptAt = .now.addingTimeInterval(1200)
        let task = WatchInboxUploadPlan.ScheduledTask(
            identifier: 17, captureID: capture.id, request: try old.request(for: capture),
            isActive: true)

        let plan = try WatchInboxUploadPlan(
            pending: [entry], configurations: [corrected], tasks: [task])

        #expect(plan.taskIdentifiersToCancel == [17])
        let upload = try #require(plan.uploads.first)
        #expect(upload.entry == entry)
        #expect(upload.sendImmediately)
        #expect(
            upload.request.value(forHTTPHeaderField: "Authorization") == "Bearer corrected-fixture")
        #expect(
            upload.request.value(forHTTPHeaderField: "Idempotency-Key") == capture.id.uuidString)
    }

    @Test func explicitRetryPersistsAnImmediateAttemptWithoutMovingOtherDestinations() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let destination = UUID()
        let otherDestination = UUID()
        let capture = try WatchInboxCapture(text: "Retry this original")
        let other = try WatchInboxCapture(text: "Keep this route")
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try queue.enqueue(capture, configurationID: destination)
        try queue.enqueue(other, configurationID: otherDestination)
        let failedAt = Date(timeIntervalSince1970: 100)
        try queue.recordFailure(capture.id, at: failedAt)
        try queue.recordFailure(other.id, at: failedAt)
        let retryAt = Date(timeIntervalSince1970: 101)

        let ids = try queue.retryPending(configurationID: destination, at: retryAt)
        let restored = try WatchInboxDeliveryQueue(fileURL: url)

        #expect(ids == [capture.id])
        let entry = try #require(restored.pending.first { $0.id == capture.id })
        #expect(entry.capture == capture)
        #expect(entry.configurationID == destination)
        #expect(entry.attempts == 1)
        #expect(entry.nextAttemptAt == retryAt)
        let unchanged = try #require(restored.pending.first { $0.id == other.id })
        #expect(unchanged.configurationID == otherDestination)
        #expect(unchanged.nextAttemptAt > retryAt)
    }

    @Test func explicitRetryReplacesEvenACurrentRequestWaitingInBackoff() throws {
        let config = try WatchInboxWebhookConfiguration(
            url: "https://example.com/inbox", key: "fixture")
        let capture = try WatchInboxCapture(text: "Retry without dictating again")
        let entry = WatchInboxDeliveryQueue.Pending(capture: capture, configurationID: config.id)
        let task = WatchInboxUploadPlan.ScheduledTask(
            identifier: 23, captureID: capture.id, request: try config.request(for: capture),
            isActive: true)

        let plan = try WatchInboxUploadPlan(
            pending: [entry], configurations: [config], tasks: [task], retrying: [capture.id])

        #expect(plan.taskIdentifiersToCancel == [23])
        #expect(plan.uploads.map(\.entry.capture) == [capture])
        #expect(plan.uploads.first?.sendImmediately == true)
    }

    @Test func explicitDestinationRepairKeepsCapturesAndDoesNotResendReceipts() throws {
        let url = try queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = try WatchInboxWebhookConfiguration(url: "https://example.com/incorrect", key: "old-fixture")
        let current = try WatchInboxWebhookConfiguration(url: "https://example.com/inbox", key: "fixture")
        let capture = try WatchInboxCapture(text: "Keep these original words")
        let accepted = try WatchInboxCapture(text: "Already delivered")
        let queue = try WatchInboxDeliveryQueue(fileURL: url)
        try queue.enqueue(capture, configurationID: old.id)
        try queue.recordFailure(capture.id)
        try queue.enqueue(accepted, configurationID: current.id)
        try queue.accept(accepted.id)
        let retryAt = Date(timeIntervalSince1970: 200)

        let ids = try queue.useCurrentInboxForPending(current.id, at: retryAt)
        let restored = try WatchInboxDeliveryQueue(fileURL: url)
        let entry = try #require(restored.pending.first)
        #expect(ids == [capture.id])
        #expect(entry.capture == capture)
        #expect(entry.configurationID == current.id)
        #expect(entry.attempts == 0)
        #expect(entry.nextAttemptAt == retryAt)
        #expect(restored.hasAccepted(accepted.id))

        let task = WatchInboxUploadPlan.ScheduledTask(
            identifier: 42, captureID: capture.id, request: try old.request(for: capture), isActive: true)
        let plan = try WatchInboxUploadPlan(
            pending: restored.pending, configurations: [old, current], tasks: [task], retrying: ids)
        #expect(plan.taskIdentifiersToCancel == [42])
        #expect(plan.uploads.map(\.entry.id) == [capture.id])
        #expect(plan.uploads.first?.request.url == current.url)
        #expect(plan.uploads.first?.request.value(forHTTPHeaderField: "Idempotency-Key") == capture.id.uuidString)
    }

    @Test func ordinaryChecksRespectActiveRequestsAndOriginalDestinations() throws {
        let original = try WatchInboxWebhookConfiguration(
            url: "https://example.com/first", key: "fixture")
        let current = try WatchInboxWebhookConfiguration(
            url: "https://example.com/second", key: "fixture")
        let capture = try WatchInboxCapture(text: "Stay with the original destination")
        var entry = WatchInboxDeliveryQueue.Pending(capture: capture, configurationID: original.id)
        entry.nextAttemptAt = .now.addingTimeInterval(600)
        let task = WatchInboxUploadPlan.ScheduledTask(
            identifier: 31, captureID: capture.id, request: try original.request(for: capture),
            isActive: true)
        let active = try WatchInboxUploadPlan(
            pending: [entry], configurations: [original, current], tasks: [task])
        #expect(active.uploads.isEmpty)
        #expect(active.taskIdentifiersToCancel.isEmpty)

        let retry = try WatchInboxUploadPlan(
            pending: [entry], configurations: [original, current], tasks: [])
        #expect(retry.uploads.first?.request.url == original.url)
        #expect(retry.uploads.first?.sendImmediately == false)
        #expect(retry.uploads.first?.entry.nextAttemptAt == entry.nextAttemptAt)
    }
}
