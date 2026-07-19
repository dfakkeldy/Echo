// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private nonisolated final class MacVideoExportSidecarPresenter: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(primaryURL: URL, sidecarURL: URL) {
        primaryPresentedItemURL = primaryURL
        presentedItemURL = sidecarURL

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        presentedItemOperationQueue = operationQueue
        super.init()
    }
}

nonisolated enum MacVideoExportPublisher {
    private static let copyChunkSize = 1_048_576

    private enum BundleItem: Hashable, Sendable {
        case movie
        case subtitles
        case chapters
    }

    private struct PublicationSnapshot: Sendable {
        let item: BundleItem
        let finalURL: URL
        let existed: Bool
        let backupURL: URL
    }

    private final class MutationTracker {
        var items: Set<BundleItem> = []
    }

    static func makeStagingDirectory() throws -> URL {
        try makeTemporaryDirectory(prefix: "video-export")
    }

    static func publish(
        stagedOutput: VideoExportService.Output,
        to destination: VideoExportDestination
    ) throws -> VideoExportService.Output {
        let backupDirectory = try makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        let presenters = [
            MacVideoExportSidecarPresenter(
                primaryURL: destination.videoURL, sidecarURL: destination.srtURL),
            MacVideoExportSidecarPresenter(
                primaryURL: destination.videoURL, sidecarURL: destination.chaptersURL),
        ]
        for presenter in presenters {
            NSFileCoordinator.addFilePresenter(presenter)
        }
        defer {
            for presenter in presenters.reversed() {
                NSFileCoordinator.removeFilePresenter(presenter)
            }
        }

        let snapshots = try snapshotBundle(
            destination: destination,
            backupDirectory: backupDirectory,
            presenters: presenters)
        let mutationTracker = MutationTracker()

        do {
            try Task.checkCancellation()
            mutationTracker.items.insert(.movie)
            try replaceItem(at: destination.videoURL, with: stagedOutput.videoURL)
            try Task.checkCancellation()
            try coordinateCopy(
                from: stagedOutput.srtURL,
                to: destination.srtURL,
                presenter: presenters[0],
                item: .subtitles,
                mutationTracker: mutationTracker)
            try Task.checkCancellation()
            try coordinateCopy(
                from: stagedOutput.chaptersURL,
                to: destination.chaptersURL,
                presenter: presenters[1],
                item: .chapters,
                mutationTracker: mutationTracker)
        } catch let publicationError {
            do {
                try restoreBundle(
                    snapshots: snapshots,
                    modifiedItems: mutationTracker.items,
                    presenters: presenters)
            } catch let rollbackError {
                throw MacVideoExportPublishingError.rollbackFailed(
                    publicationError: publicationError,
                    rollbackError: rollbackError)
            }
            throw publicationError
        }

        return VideoExportService.Output(
            videoURL: destination.videoURL,
            srtURL: destination.srtURL,
            chaptersURL: destination.chaptersURL)
    }

    private static func makeBackupDirectory() throws -> URL {
        try makeTemporaryDirectory(prefix: "video-export-backup")
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func snapshotBundle(
        destination: VideoExportDestination,
        backupDirectory: URL,
        presenters: [MacVideoExportSidecarPresenter]
    ) throws -> [PublicationSnapshot] {
        let movie = try snapshotItem(
            .movie,
            at: destination.videoURL,
            backupURL: backupDirectory.appending(path: "movie"))
        let subtitles = try snapshotRelatedItem(
            .subtitles,
            at: destination.srtURL,
            backupURL: backupDirectory.appending(path: "subtitles"),
            presenter: presenters[0])
        let chapters = try snapshotRelatedItem(
            .chapters,
            at: destination.chaptersURL,
            backupURL: backupDirectory.appending(path: "chapters"),
            presenter: presenters[1])
        return [movie, subtitles, chapters]
    }

    private static func snapshotItem(
        _ item: BundleItem,
        at finalURL: URL,
        backupURL: URL
    ) throws -> PublicationSnapshot {
        let existed = FileManager.default.fileExists(
            atPath: finalURL.path(percentEncoded: false))
        if existed {
            try chunkedCopy(from: finalURL, to: backupURL)
        }
        return PublicationSnapshot(
            item: item, finalURL: finalURL, existed: existed, backupURL: backupURL)
    }

    private static func snapshotRelatedItem(
        _ item: BundleItem,
        at finalURL: URL,
        backupURL: URL,
        presenter: MacVideoExportSidecarPresenter
    ) throws -> PublicationSnapshot {
        try coordinateRead(at: finalURL, presenter: presenter) { coordinatedURL in
            try snapshotItem(item, at: coordinatedURL, backupURL: backupURL)
        }
    }

    private static func coordinateCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        presenter: MacVideoExportSidecarPresenter,
        item: BundleItem,
        mutationTracker: MutationTracker
    ) throws {
        try coordinateWrite(at: destinationURL, options: .forReplacing, presenter: presenter) {
            coordinatedURL in
            mutationTracker.items.insert(item)
            try replaceItem(at: coordinatedURL, with: sourceURL)
        }
    }

    private static func restoreBundle(
        snapshots: [PublicationSnapshot],
        modifiedItems: Set<BundleItem>,
        presenters: [MacVideoExportSidecarPresenter]
    ) throws {
        var firstError: Error?

        for snapshot in snapshots {
            guard modifiedItems.contains(snapshot.item) else { continue }
            do {
                switch snapshot.item {
                case .movie:
                    try restore(snapshot)
                case .subtitles:
                    try coordinateRestore(snapshot, presenter: presenters[0])
                case .chapters:
                    try coordinateRestore(snapshot, presenter: presenters[1])
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private static func coordinateRestore(
        _ snapshot: PublicationSnapshot,
        presenter: MacVideoExportSidecarPresenter
    ) throws {
        let options: NSFileCoordinator.WritingOptions =
            snapshot.existed ? .forReplacing : .forDeleting
        try coordinateWrite(at: snapshot.finalURL, options: options, presenter: presenter) {
            coordinatedURL in
            try restore(snapshot, finalURL: coordinatedURL)
        }
    }

    private static func restore(
        _ snapshot: PublicationSnapshot,
        finalURL: URL? = nil
    ) throws {
        let destinationURL = finalURL ?? snapshot.finalURL
        if snapshot.existed {
            try replaceItem(
                at: destinationURL,
                with: snapshot.backupURL,
                checkingCancellation: false)
        } else {
            try removeItemIfPresent(at: destinationURL)
        }
    }

    private static func replaceItem(
        at destinationURL: URL,
        with sourceURL: URL,
        checkingCancellation: Bool = true
    ) throws {
        if checkingCancellation {
            try Task.checkCancellation()
        }
        try removeItemIfPresent(at: destinationURL)
        if checkingCancellation {
            try Task.checkCancellation()
        }
        try chunkedCopy(
            from: sourceURL,
            to: destinationURL,
            checkingCancellation: checkingCancellation)
    }

    private static func chunkedCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        checkingCancellation: Bool = true
    ) throws {
        if checkingCancellation {
            try Task.checkCancellation()
        }
        guard
            FileManager.default.createFile(
                atPath: destinationURL.path(percentEncoded: false), contents: nil)
        else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: destinationURL.path(percentEncoded: false)])
        }

        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }

        while let data = try source.read(upToCount: copyChunkSize), !data.isEmpty {
            if checkingCancellation {
                try Task.checkCancellation()
            }
            try destination.write(contentsOf: data)
        }
        try destination.synchronize()
    }

    private static func removeItemIfPresent(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func coordinateRead<Result>(
        at url: URL,
        presenter: MacVideoExportSidecarPresenter,
        operation: (URL) throws -> Result
    ) throws -> Result {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var operationResult: Swift.Result<Result, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            operationResult = Swift.Result { try operation(coordinatedURL) }
        }
        return try coordinatedResult(
            operationResult, coordinationError: coordinationError, url: url)
    }

    private static func coordinateWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        presenter: MacVideoExportSidecarPresenter,
        operation: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var operationResult: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            coordinatedURL in
            operationResult = Result { try operation(coordinatedURL) }
        }
        _ = try coordinatedResult(
            operationResult, coordinationError: coordinationError, url: url)
    }

    private static func coordinatedResult<Result>(
        _ operationResult: Swift.Result<Result, Error>?,
        coordinationError: NSError?,
        url: URL
    ) throws -> Result {
        if let coordinationError {
            throw coordinationError
        }
        guard let operationResult else {
            throw MacVideoExportPublishingError.coordinationDidNotRun(url)
        }
        return try operationResult.get()
    }
}

private nonisolated enum MacVideoExportPublishingError: LocalizedError {
    case coordinationDidNotRun(URL)
    case rollbackFailed(publicationError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .coordinationDidNotRun:
            String(localized: .videoExportErrorRelatedFileAccess)
        case .rollbackFailed(let publicationError, let rollbackError):
            String(localized: .videoExportErrorRollbackFailed) + " "
                + publicationError.localizedDescription + " "
                + rollbackError.localizedDescription
        }
    }
}
