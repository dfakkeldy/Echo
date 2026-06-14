import Foundation
import GRDB
import os.log

/// Thread-safe count tracker for the test drain.
private nonisolated final class SafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    nonisolated init() {}

    nonisolated var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    nonisolated func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

    nonisolated func decrement() {
        lock.lock()
        _value -= 1
        lock.unlock()
    }
}

/// Consumes RecorderEvents from playback seams and persists listening
/// segments to playback_event via PlaybackSegmentBuilder policy.
///
/// Concurrency shape (audit §3.2/§3.3 compliant):
/// - Main-actor call sites use the synchronous, non-blocking `yield`.
/// - One long-lived consumer Task (stored, cancellable) does async GRDB writes.
/// - The 30s heartbeat ticks from inside the recorder, not the caller.
actor PlaybackSessionRecorder {
    static let heartbeatInterval: TimeInterval = 30

    private let writer: any DatabaseWriter
    private let logger: Logger
    private let pendingCount: SafeCounter

    private var builder: PlaybackSegmentBuilder
    private var openRowID: Int64?
    private var knownAudiobookIDs: Set<String>

    private let stream: AsyncStream<RecorderEvent>
    private let continuation: AsyncStream<RecorderEvent>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(writer: any DatabaseWriter) {
        self.writer = writer
        self.logger = Logger(category: "PlaybackSessionRecorder")
        self.pendingCount = SafeCounter()
        self.builder = PlaybackSegmentBuilder()
        self.knownAudiobookIDs = []
        let (stream, continuation) = AsyncStream.makeStream(of: RecorderEvent.self)
        self.stream = stream
        self.continuation = continuation
        Task { await self.start() }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
        heartbeatTask?.cancel()
    }

    /// Synchronous and non-blocking — safe from the main actor and deinit.
    nonisolated func yield(_ event: RecorderEvent) {
        pendingCount.increment()
        continuation.yield(event)
    }

    private func start() {
        guard consumerTask == nil else { return }
        let continuation = self.continuation
        let stream = self.stream
        consumerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await handle(event)
            }
        }
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                continuation.yield(.heartbeat(at: Date()))
            }
        }
    }

    func shutdown() {
        continuation.finish()
        heartbeatTask?.cancel()
    }

    /// Test hook: wait until every yielded event so far has been persisted.
    func drain() async {
        while pendingCount.value > 0 {
            await Task.yield()
        }
    }

    private func handle(_ event: RecorderEvent) async {
        defer { pendingCount.decrement() }
        var localBuilder = self.builder
        let actions = localBuilder.handle(event)
        self.builder = localBuilder

        for action in actions {
            await perform(action)
        }
    }

    private func perform(_ action: SegmentAction) async {
        do {
            switch action {
            case .begin(let segment):
                try await ensureAudiobookRow(id: segment.audiobookID)
                openRowID = try await insertOpen(segment)
            case .extendOpen(let endedAt, let endPosition),
                .finalize(let endedAt, let endPosition):
                guard let id = openRowID else { return }
                try await writer.write { db in
                    try db.execute(
                        sql:
                            "UPDATE playback_event SET ended_at = ?, end_position = ? WHERE id = ?",
                        arguments: [endedAt.ISO8601Format(), endPosition, id]
                    )
                }
                if case .finalize = action { openRowID = nil }
            case .discard:
                guard let id = openRowID else { return }
                openRowID = nil
                try await writer.write { db in
                    try db.execute(sql: "DELETE FROM playback_event WHERE id = ?", arguments: [id])
                }
            }
        } catch {
            logger.error("Segment action failed: \(error.localizedDescription)")
        }
    }

    private func insertOpen(_ segment: OpenSegment) async throws -> Int64 {
        do {
            return try await insertOpenRow(segment, trackID: segment.trackID)
        } catch {
            // track_id FK can fail if ingestion hasn't written track rows yet;
            // the segment is still valid analytics data without it.
            logger.warning("insertOpen retrying without track_id: \(error.localizedDescription)")
            return try await insertOpenRow(segment, trackID: nil)
        }
    }

    private func insertOpenRow(_ s: OpenSegment, trackID: String?) async throws -> Int64 {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_event
                    (audiobook_id, track_id, started_at, ended_at, start_position, end_position, speed, event_type, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'play', ?)
                    """,
                arguments: [
                    s.audiobookID, trackID,
                    s.startedAt.ISO8601Format(), s.startedAt.ISO8601Format(),
                    s.startPosition, s.startPosition, s.speed, s.source,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// playback_event.audiobook_id is a NOT NULL FK; ingestion normally
    /// creates the row, but play-before-ingest must not lose data. The stub's
    /// title/duration get overwritten by TimelineIngestionService.save later.
    private func ensureAudiobookRow(id: String) async throws {
        guard !knownAudiobookIDs.contains(id) else { return }
        let title = URL(string: id)?.lastPathComponent ?? id
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO audiobook (id, title, duration, added_at)
                    VALUES (?, ?, 0, ?)
                    """,
                arguments: [id, title, Date().ISO8601Format()]
            )
        }
        knownAudiobookIDs.insert(id)
    }
}
