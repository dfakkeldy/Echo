// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// Drives the per-book narration-QA review screen: loads open issues and applies
/// ignore/resolve status changes (override + regenerate actions land in M4). Pure
/// Foundation (no UIKit), so it bundles into every target without exclusion.
@MainActor
@Observable
final class NarrationQAReviewModel {
    var issues: [NarrationQualityIssueRecord] = []

    private let db: DatabaseWriter
    private let audiobookID: String
    private let logger = Logger(category: "NarrationQAReview")
    private static let iso = ISO8601DateFormatter()

    init(db: DatabaseWriter, audiobookID: String) {
        self.db = db
        self.audiobookID = audiobookID
    }

    func load() {
        do {
            issues = try NarrationQualityIssueDAO(db: db)
                .issues(for: audiobookID, status: NarrationQAIssueStatus.open.rawValue)
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
            issues = []
        }
    }

    func ignore(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .ignored, resolvedAt: nil)
    }

    func markResolved(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .resolved, resolvedAt: Self.iso.string(from: Date()))
    }

    private func update(
        _ issue: NarrationQualityIssueRecord, status: NarrationQAIssueStatus, resolvedAt: String?
    ) {
        do {
            try NarrationQualityIssueDAO(db: db)
                .updateStatus(id: issue.id, status: status.rawValue, resolvedAt: resolvedAt)
            issues.removeAll { $0.id == issue.id }
        } catch {
            logger.error("update status failed: \(error.localizedDescription)")
        }
    }
}
