// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum StudyPlanCadenceUnit: String, Codable, Sendable, CaseIterable {
    case day
    case week
}

enum StudyPlanQueueMode: String, Codable, Sendable, CaseIterable {
    case bookByBook = "book_by_book"
    case mixed

    var title: String {
        switch self {
        case .bookByBook: "Book by Book"
        case .mixed: "Mixed"
        }
    }
}

enum StudyPlanCatchUpPolicy: String, Codable, Sendable, CaseIterable {
    case gentle
    case strict
}

enum StudyPlanItemKind: String, Codable, Sendable, CaseIterable {
    case chapter
    case image
}

enum StudyFlashcardType {
    static let normal = "normal"
    static let listeningAssignment = "listening_assignment"
    static let imageAssignment = "image_assignment"
}

enum StudyAssignmentGradePolicy {
    static func choices(for cardType: String?) -> [ReviewGrade] {
        cardType == StudyFlashcardType.listeningAssignment
            ? [.again, .good]
            : ReviewGrade.allCases
    }
}

struct StudyCardMedia: Codable, Equatable, Sendable {
    let imagePath: String?
}

struct StudyPlanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let kind: StudyPlanItemKind
    let sourceBlockID: String
    let chapterIndex: Int?
    let ordinal: Int
    let title: String
    let defaultIncluded: Bool
    let imagePath: String?
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval?
    let playlistPosition: TimeInterval?
}

struct StudyPlanPreview: Equatable, Sendable {
    let audiobookID: String
    let bookTitle: String
    let candidates: [StudyPlanCandidate]

    var includedByDefault: [StudyPlanCandidate] {
        candidates.filter(\.defaultIncluded)
    }
}

enum StudyQueueCategory: Int, Codable, Sendable, CaseIterable {
    case dueReview = 0
    case inProgressAssignment = 1
    case newAssignment = 2
}

struct StudyQueueEntry: Identifiable, Equatable, Sendable {
    let id: String
    let category: StudyQueueCategory
    let plan: StudyPlan?
    let item: StudyPlanItem?
    let flashcard: Flashcard

    static func == (lhs: StudyQueueEntry, rhs: StudyQueueEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.category == rhs.category
            && lhs.plan == rhs.plan
            && lhs.item == rhs.item
            && lhs.flashcard.id == rhs.flashcard.id
    }
}

struct StudyQueue: Equatable, Sendable {
    var entries: [StudyQueueEntry]

    static let empty = StudyQueue(entries: [])

    var dueReviewCount: Int {
        entries.filter { $0.category == .dueReview }.count
    }

    var inProgressAssignmentCount: Int {
        entries.filter { $0.category == .inProgressAssignment }.count
    }

    var newAssignmentCount: Int {
        entries.filter { $0.category == .newAssignment }.count
    }

    var totalCount: Int {
        entries.count
    }
}
