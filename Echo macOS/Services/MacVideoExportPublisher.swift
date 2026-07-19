// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct MacVideoExportDestination {
    let videoURL: URL
    let srtURL: URL
    let chaptersURL: URL

    init(panelURL: URL) throws {
        let baseURL = panelURL.deletingPathExtension()
        guard !baseURL.lastPathComponent.isEmpty else {
            throw MacVideoExportPublishingError.emptyFileName
        }

        videoURL = panelURL
        srtURL = baseURL.appendingPathExtension("srt")
        chaptersURL = baseURL.appendingPathExtension("chapters.txt")
    }
}

final class MacVideoExportSidecarPresenter: NSObject, NSFilePresenter {
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

enum MacVideoExportPublisher {
    static func makeStagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "video-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func publish(
        stagedOutput: VideoExportService.Output,
        to destination: MacVideoExportDestination
    ) throws -> VideoExportService.Output {
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

        do {
            try Task.checkCancellation()
            try replaceItem(at: destination.videoURL, with: stagedOutput.videoURL)
            try Task.checkCancellation()
            try coordinateCopy(
                from: stagedOutput.srtURL,
                to: destination.srtURL,
                presenter: presenters[0])
            try Task.checkCancellation()
            try coordinateCopy(
                from: stagedOutput.chaptersURL,
                to: destination.chaptersURL,
                presenter: presenters[1])
        } catch let publicationError {
            do {
                try rollback(destination: destination, presenters: presenters)
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

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func coordinateCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        presenter: MacVideoExportSidecarPresenter
    ) throws {
        try coordinateWrite(at: destinationURL, options: .forReplacing, presenter: presenter) {
            coordinatedURL in
            try replaceItem(at: coordinatedURL, with: sourceURL)
        }
    }

    private static func rollback(
        destination: MacVideoExportDestination,
        presenters: [MacVideoExportSidecarPresenter]
    ) throws {
        var firstError: Error?

        do {
            try removeItemIfPresent(at: destination.videoURL)
        } catch {
            firstError = error
        }

        for (sidecarURL, presenter) in zip(
            [destination.srtURL, destination.chaptersURL], presenters)
        {
            do {
                try coordinateWrite(
                    at: sidecarURL, options: .forDeleting, presenter: presenter
                ) { coordinatedURL in
                    try removeItemIfPresent(at: coordinatedURL)
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private static func removeItemIfPresent(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
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

        if let coordinationError {
            throw coordinationError
        }
        guard let operationResult else {
            throw MacVideoExportPublishingError.coordinationDidNotRun(url)
        }
        try operationResult.get()
    }
}

private enum MacVideoExportPublishingError: LocalizedError {
    case emptyFileName
    case coordinationDidNotRun(URL)
    case rollbackFailed(publicationError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .emptyFileName:
            String(localized: .videoExportErrorEmptyFilename)
        case .coordinationDidNotRun:
            String(localized: .videoExportErrorRelatedFileAccess)
        case .rollbackFailed(let publicationError, let rollbackError):
            String(localized: .videoExportErrorRollbackFailed) + " "
                + publicationError.localizedDescription + " "
                + rollbackError.localizedDescription
        }
    }
}
