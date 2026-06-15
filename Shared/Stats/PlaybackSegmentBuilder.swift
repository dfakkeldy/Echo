import Foundation

/// One contiguous stretch of listening at constant (track, speed) with no seeks.
struct OpenSegment: Equatable, Sendable {
    var audiobookID: String
    var trackID: String?
    var startedAt: Date
    var startPosition: TimeInterval
    var lastKnownPosition: TimeInterval
    var lastKnownAt: Date
    var speed: Double
    var source: String
}

/// Events yielded from main-actor playback seams. All carry their own clock.
enum RecorderEvent: Sendable {
    case opened(
        audiobookID: String, trackID: String?, position: TimeInterval, speed: Double,
        source: String, at: Date)
    case progressTick(position: TimeInterval, at: Date)
    case speedChanged(newSpeed: Double, at: Date)
    case seeked(toPosition: TimeInterval, at: Date)
    case closed(position: TimeInterval?, at: Date)
    case heartbeat(at: Date)
}

/// IO instructions for the recorder actor, in order.
enum SegmentAction: Equatable, Sendable {
    case finalize(endedAt: Date, endPosition: TimeInterval)  // extend() the current row one last time
    case discard  // delete() the current row (micro-segment)
    case begin(OpenSegment)  // insertOpen() a new row
    case extendOpen(endedAt: Date, endPosition: TimeInterval)  // heartbeat extend()
}

nonisolated struct PlaybackSegmentBuilder: Sendable {
    /// Segments shorter than this wall-clock duration are noise (accidental
    /// taps, instant track skips) and are deleted rather than finalized.
    static let minimumSegmentDuration: TimeInterval = 5

    nonisolated init() {}

    private(set) var open: OpenSegment?

    mutating func handle(_ event: RecorderEvent) -> [SegmentAction] {
        switch event {
        case .opened(let audiobookID, let trackID, let position, let speed, let source, let at):
            var actions: [SegmentAction] = []
            if let current = open {
                actions.append(
                    closeAction(endPosition: current.lastKnownPosition, at: at, isSplit: true))
            }
            let segment = OpenSegment(
                audiobookID: audiobookID, trackID: trackID, startedAt: at,
                startPosition: position, lastKnownPosition: position, lastKnownAt: at,
                speed: speed, source: source
            )
            open = segment
            actions.append(.begin(segment))
            return actions

        case .progressTick(let position, let at):
            open?.lastKnownPosition = position
            open?.lastKnownAt = at
            return []

        case .speedChanged(let newSpeed, let at):
            guard let current = open else { return [] }
            let close = closeAction(endPosition: current.lastKnownPosition, at: at, isSplit: true)
            var next = current
            next.startedAt = at
            next.startPosition = current.lastKnownPosition
            next.lastKnownAt = at
            next.speed = newSpeed
            open = next
            return [close, .begin(next)]

        case .seeked(let toPosition, let at):
            guard let current = open else { return [] }
            let close = closeAction(endPosition: current.lastKnownPosition, at: at, isSplit: true)
            var next = current
            next.startedAt = at
            next.startPosition = toPosition
            next.lastKnownPosition = toPosition
            next.lastKnownAt = at
            open = next
            return [close, .begin(next)]

        case .closed(let position, let at):
            guard let current = open else { return [] }
            open = nil
            return [
                closeAction(
                    endPosition: position ?? current.lastKnownPosition, at: at, isSplit: false,
                    segment: current)
            ]

        case .heartbeat(let at):
            guard let current = open else { return [] }
            return [.extendOpen(endedAt: at, endPosition: current.lastKnownPosition)]
        }
    }

    /// Splits always finalize (discarding would punch coverage holes);
    /// explicit closes discard micro-segments below the minimum duration.
    private func closeAction(
        endPosition: TimeInterval, at: Date, isSplit: Bool, segment: OpenSegment? = nil
    ) -> SegmentAction {
        guard let seg = segment ?? open else {
            return .discard
        }
        let duration = at.timeIntervalSince(seg.startedAt)
        if !isSplit && duration < Self.minimumSegmentDuration {
            return .discard
        }
        return .finalize(endedAt: at, endPosition: endPosition)
    }
}
