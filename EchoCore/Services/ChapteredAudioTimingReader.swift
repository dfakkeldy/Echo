// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Reads chapter spans from an existing chaptered audiobook file, or estimates
/// chapter spans from a directory of per-chapter audio files.
nonisolated enum ChapteredAudioTimingReader {
    struct Result: Equatable, Sendable {
        let chapterTimings: [EstimatedAlignmentSidecar.ChapterTiming]
        let duration: TimeInterval
    }

    enum TimingError: Error, Equatable, LocalizedError {
        case missingInput(URL)
        case noAudioFiles(URL)
        case invalidDuration(URL)

        var errorDescription: String? {
            switch self {
            case .missingInput(let url):
                return "Audio input does not exist: \(url.path)"
            case .noAudioFiles(let url):
                return "No supported audio files were found in: \(url.path)"
            case .invalidDuration(let url):
                return "Could not read a usable audio duration from: \(url.path)"
            }
        }
    }

    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "aif", "m4a", "m4b", "mp3", "wav",
    ]

    @concurrent
    static func timings(at url: URL) async throws -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TimingError.missingInput(url)
        }

        if isDirectory.boolValue {
            return try await timings(fromAudioDirectory: url)
        }
        return try await timings(fromAudioFile: url)
    }

    @concurrent
    private static func timings(fromAudioFile url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await validDuration(for: asset, sourceURL: url)
        let chapters = await ChapterService.parseChapters(from: asset)
        let timings: [EstimatedAlignmentSidecar.ChapterTiming]
        if chapters.isEmpty {
            timings = [EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: duration)]
        } else {
            timings = chapters.map {
                EstimatedAlignmentSidecar.ChapterTiming(
                    index: $0.index,
                    start: $0.startSeconds,
                    end: min($0.endSeconds, duration)
                )
            }
        }
        return Result(chapterTimings: timings, duration: duration)
    }

    @concurrent
    private static func timings(fromAudioDirectory url: URL) async throws -> Result {
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { file in
            let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                ?? false
            return isRegular && audioExtensions.contains(file.pathExtension.lowercased())
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        guard !files.isEmpty else { throw TimingError.noAudioFiles(url) }

        var cursor: TimeInterval = 0
        var timings: [EstimatedAlignmentSidecar.ChapterTiming] = []
        timings.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            let duration = try await validDuration(for: AVURLAsset(url: file), sourceURL: file)
            timings.append(
                EstimatedAlignmentSidecar.ChapterTiming(
                    index: index,
                    start: cursor,
                    end: cursor + duration
                )
            )
            cursor += duration
        }

        return Result(chapterTimings: timings, duration: cursor)
    }

    @concurrent
    private static func validDuration(for asset: AVURLAsset, sourceURL: URL) async throws -> TimeInterval {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw TimingError.invalidDuration(sourceURL)
        }
        return duration
    }
}
