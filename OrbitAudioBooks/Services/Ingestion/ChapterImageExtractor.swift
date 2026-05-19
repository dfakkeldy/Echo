import Foundation
import AVFoundation
import os.log

/// Extracts per-chapter artwork images from M4B chapter metadata groups.
///
/// Returns a dictionary keyed by chapter index (0-based, matching the order
/// chapters are parsed by `ChapterService`), so ingestion strategies can
/// pair artwork with chapter markers without re-parsing audio metadata.
enum ChapterImageExtractor {
    private static let logger = Logger(
        subsystem: "com.orbitaudiobooks",
        category: "ChapterImageExtractor"
    )

    /// Extracts artwork data for each chapter that has an embedded image.
    /// Chapters without artwork are simply absent from the returned dictionary.
    static func extract(from asset: AVAsset) async -> [Int: Data] {
        var result: [Int: Data] = [:]

        guard let groups = await loadChapterGroups(from: asset) else { return result }

        for (index, group) in groups.enumerated() {
            for item in group.items where item.commonKey == .commonKeyArtwork {
                guard let data = try? await item.load(.dataValue) else {
                    logger.debug("Failed to load artwork data at chapter \(index)")
                    continue
                }
                result[index] = data
                break // One artwork per chapter group.
            }
        }

        return result
    }

    // MARK: - Private

    private static func loadChapterGroups(from asset: AVAsset) async -> [AVTimedMetadataGroup]? {
        do {
            let locales = try await asset.load(.availableChapterLocales)
            let locale = locales.first ?? Locale.current
            return try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyArtwork]
            )
        } catch {
            logger.error("Failed to load chapter metadata: \(error.localizedDescription)")
            return nil
        }
    }
}
