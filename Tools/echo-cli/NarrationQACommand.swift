// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// Run post-render narration QA against the per-chapter files emitted by `echo-cli narrate`.
struct NarrationQACommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qa",
        abstract: "Run narration QA over rendered chapter audio without re-rendering.")

    @Option(help: "Path to an Echo SQLite database containing the book's source blocks.")
    var db: String
    @Option(name: .customLong("audiobook-id"), help: "Audiobook id in the database.")
    var audiobookID: String
    @Option(name: .customLong("work-dir"), help: "Narration work dir containing .anchors-chN.json and .m4a files.")
    var workDir: String
    @Option(help: "Optional sanitized JSON report path. Does not include source or heard text.")
    var report: String?

    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let database = try DatabaseService(databaseURL: URL(fileURLWithPath: db))
        let chapters = try HeadlessNarrationQAManifest.chapters(
            audiobookID: audiobookID,
            workDir: URL(fileURLWithPath: workDir)
        )
        let qa = NarrationQAService(
            db: database.writer,
            classifier: DeterministicDivergenceClassifier()
        )
        try await qa.runQA(
            audiobookID: audiobookID,
            chapters: chapters.map { ($0.chapterIndex, $0.fileURL, $0.spokenBlockIDs) }
        )

        let issues = try NarrationQualityIssueDAO(db: database.writer).issues(
            for: audiobookID,
            status: NarrationQAIssueStatus.open.rawValue
        )
        if let report {
            try SanitizedNarrationQAReport(
                audiobookID: audiobookID,
                chaptersScanned: chapters.count,
                issues: issues
            )
            .write(to: URL(fileURLWithPath: report))
        }
        print("QA_DONE \(chapters.count) chapters, \(issues.count) open issues")
    }
}

private struct SanitizedNarrationQAReport: Encodable {
    let audiobookID: String
    let chaptersScanned: Int
    let openIssueCount: Int
    let issueCountsByType: [String: Int]
    let issues: [Issue]

    init(audiobookID: String, chaptersScanned: Int, issues: [NarrationQualityIssueRecord]) {
        self.audiobookID = audiobookID
        self.chaptersScanned = chaptersScanned
        self.openIssueCount = issues.count
        self.issueCountsByType = Dictionary(grouping: issues, by: \.issueType)
            .mapValues(\.count)
        self.issues = issues.map(Issue.init)
    }

    func write(to url: URL) throws {
        if let parent = url.parentDirectory {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    struct Issue: Encodable {
        let sourceBlockID: String?
        let sourceWordStart: Int?
        let sourceWordEnd: Int?
        let audioStartTime: TimeInterval
        let audioEndTime: TimeInterval
        let issueType: String
        let confidence: Double

        init(_ issue: NarrationQualityIssueRecord) {
            sourceBlockID = issue.sourceBlockID
            sourceWordStart = issue.sourceWordStart
            sourceWordEnd = issue.sourceWordEnd
            audioStartTime = issue.audioStartTime
            audioEndTime = issue.audioEndTime
            issueType = issue.issueType
            confidence = issue.confidence
        }
    }
}

private extension URL {
    var parentDirectory: URL? {
        guard !path.isEmpty else { return nil }
        return deletingLastPathComponent()
    }
}
