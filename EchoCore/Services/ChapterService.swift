import Foundation
import AVFoundation

/// Stateless helper that parses chapters from AVAsset metadata and provides
/// chapter lookup and navigation primitives. Does not own mutable state —
/// PlayerModel remains the single source of truth.
struct ChapterService {

    /// Parses the chapter metadata groups from an audiobook AVAsset.
    /// Returns an empty array for non-M4B/M4A files or files without chapter markers.
    /// - Parameter asset: The audio file to parse.
    /// - Returns: Chronologically ordered chapters with correct zero-based indices.
    static func parseChapters(from asset: AVAsset) async -> [Chapter] {
        var groups: [AVTimedMetadataGroup] = []

        do {
            let locales = try await asset.load(.availableChapterLocales)
            if let firstLocale = locales.first {
                groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: firstLocale,
                    containingItemsWithCommonKeys: []
                )
            } else {
                groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: Locale.current,
                    containingItemsWithCommonKeys: []
                )
            }
        } catch {
            return []
        }

        var built: [Chapter] = []
        built.reserveCapacity(groups.count)

        for g in groups {
            let start = g.timeRange.start.seconds
            let end = (g.timeRange.start + g.timeRange.duration).seconds

            var title: String? = nil
            if let item = g.items.first(where: { $0.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue }) {
                title = try? await item.load(.stringValue)
            } else if let item = g.items.first {
                title = try? await item.load(.stringValue)
            }

            if start.isFinite, end.isFinite, end > start {
                built.append(Chapter(index: 0, title: title, startSeconds: start, endSeconds: end))
            }
        }

        built.sort { $0.startSeconds < $1.startSeconds }
        for i in 0..<built.count {
            built[i] = Chapter(index: i, title: built[i].title, startSeconds: built[i].startSeconds, endSeconds: built[i].endSeconds)
        }

        // Single-chapter files are treated as having no chapters.
        return built.count >= 2 ? built : []
    }

    /// Returns the chapter containing the given time, preferring the most specific match.
    /// - Parameters:
    ///   - time: The playback time in seconds.
    ///   - chapters: The chapter list, expected to have 2+ entries.
    /// - Returns: The matched chapter, or nil.
    static func chapter(forTime t: Double, in chapters: [Chapter]) -> Chapter? {
        guard chapters.count >= 2 else { return nil }
        let matching = chapters.filter { t >= $0.startSeconds && t < $0.endSeconds }
        return matching.min(by: { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) })
    }

    /// Returns the index of the chapter containing the given time.
    static func chapterIndex(forTime t: Double, in chapters: [Chapter]) -> Int? {
        guard let chapter = chapter(forTime: t, in: chapters) else { return nil }
        return chapters.firstIndex(of: chapter)
    }

    /// Finds the next enabled chapter index after the given index.
    static func nextEnabledIndex(after idx: Int, in chapters: [Chapter]) -> Int? {
        guard chapters.count >= 2 else { return nil }
        for i in (idx + 1)..<chapters.count {
            if chapters[i].isEnabled { return i }
        }
        return nil
    }

    /// Finds the previous enabled chapter index before the given index.
    static func prevEnabledIndex(before idx: Int, in chapters: [Chapter]) -> Int? {
        guard chapters.count >= 2 else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            if chapters[i].isEnabled { return i }
        }
        return nil
    }
}
