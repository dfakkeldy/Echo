import Foundation
import GRDB

// MARK: - Ingestion Result

struct IngestionResult {
    let audiobookID: String
    let strategyName: String
    let title: String
    let duration: TimeInterval
    let fileCount: Int
    let itemCounts: [TimelineItemType: Int]

    var totalItems: Int { itemCounts.values.reduce(0, +) }

    var summary: String {
        let parts = itemCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.rawValue)s" }
        return "\(title): \(parts.joined(separator: ", "))"
    }
}

// MARK: - Ingestion Strategy Protocol

protocol IngestionStrategy {
    /// Human-readable name for logging.
    var name: String { get }

    /// Whether this strategy's required assets exist in the given folder.
    static func canHandle(folderURL: URL) -> Bool

    /// Populates database tables from available assets.
    /// Replaces existing data for the audiobook (idempotent).
    func ingest(folderURL: URL, into db: DatabaseWriter) async throws -> IngestionResult
}

// MARK: - Ingestion Error

enum IngestionError: Error, LocalizedError {
    case noAudioFiles(folderURL: URL)
    case missingRequiredAsset(String)
    case databaseError(Error)

    var errorDescription: String? {
        switch self {
        case .noAudioFiles(let url):
            return "No M4B or M4A files found in \(url.lastPathComponent)"
        case .missingRequiredAsset(let name):
            return "Required asset not found: \(name)"
        case .databaseError(let error):
            return "Database error: \(error.localizedDescription)"
        }
    }
}
