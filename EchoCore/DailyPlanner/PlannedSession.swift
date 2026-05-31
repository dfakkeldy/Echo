import Foundation

struct PlannedSession: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var audiobookID: String
    var title: String
    var startTime: Date
    var endTime: Date
    var startPosition: TimeInterval?
    var endPosition: TimeInterval?
    var targetSpeed: Double
    var isCompleted: Bool
    var createdAt: Date

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

extension PlannedSession {
    init(from record: PlannedSessionRecord) {
        let fmt = ISO8601DateFormatter()
        self.id = record.id
        self.audiobookID = record.audiobookID
        self.title = record.title
        self.startTime = fmt.date(from: record.startTime) ?? Date()
        self.endTime = fmt.date(from: record.endTime) ?? Date()
        self.startPosition = record.startPosition
        self.endPosition = record.endPosition
        self.targetSpeed = record.targetSpeed
        self.isCompleted = record.isCompleted
        self.createdAt = fmt.date(from: record.createdAt) ?? Date()
    }

    func toRecord() -> PlannedSessionRecord {
        PlannedSessionRecord(
            id: id,
            audiobookID: audiobookID,
            title: title,
            startTime: startTime.ISO8601Format(),
            endTime: endTime.ISO8601Format(),
            startPosition: startPosition,
            endPosition: endPosition,
            targetSpeed: targetSpeed,
            isCompleted: isCompleted,
            createdAt: createdAt.ISO8601Format()
        )
    }
}
