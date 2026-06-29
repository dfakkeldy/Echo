// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import os.log

struct MockMediaProvider {
    static let sampleFileName = "EchoScreenshotSample.m4b"
    static let sampleBookDirectoryName = "The Great Gatsby"
    static let sampleBookFileName = "f-scott-fitzgerald_the-great-gatsby.epub"
    private static let sampleResourceName = "EchoScreenshotSample"
    private static let sampleBookResourceName = "f-scott-fitzgerald_the-great-gatsby"
    private static let sampleBookBundleSubdirectory = "standardebooks_great_gatsby"
    private static let logger = Logger(category: "MockMediaProvider")

    static func seedSampleMediaIfNeeded() {
        seedSampleAudiobookIfNeeded()
        seedSampleBookIfNeeded()
    }

    static func seedSampleAudiobookIfNeeded() {
        let fm = FileManager.default
        let documents = URL.documentsDirectory
        let destination = documents.appendingPathComponent(sampleFileName)

        if fm.fileExists(atPath: destination.path) { return }

        guard let bundleURL = Bundle.main.url(forResource: sampleResourceName, withExtension: "m4b")
        else {
            logger.info("Local screenshot sample audiobook not found in bundle.")
            return
        }

        do {
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            logger.error("Failed to copy sample audiobook: \(error)")
        }
    }

    static func seedSampleBookIfNeeded() {
        let fm = FileManager.default
        let documents = URL.documentsDirectory
        let bookDirectory = documents.appendingPathComponent(
            sampleBookDirectoryName, isDirectory: true)
        let destination = bookDirectory.appendingPathComponent(sampleBookFileName)

        if fm.fileExists(atPath: destination.path) { return }

        guard let bundleURL = bundledSampleBookURL() else {
            logger.info("Local screenshot sample EPUB not found in bundle.")
            return
        }

        do {
            try fm.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            logger.error("Failed to copy sample EPUB: \(error)")
        }
    }

    static func sampleAudiobookURL() -> URL? {
        let documents = URL.documentsDirectory
        let url = documents.appendingPathComponent(sampleFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sampleBookURL() -> URL? {
        let documents = URL.documentsDirectory
        let url = documents
            .appendingPathComponent(sampleBookDirectoryName, isDirectory: true)
            .appendingPathComponent(sampleBookFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sampleMediaURL() -> URL? {
        sampleAudiobookURL() ?? sampleBookURL()
    }

    private static func bundledSampleBookURL() -> URL? {
        Bundle.main.url(
            forResource: sampleBookResourceName,
            withExtension: "epub",
            subdirectory: sampleBookBundleSubdirectory)
            ?? Bundle.main.url(
                forResource: sampleBookResourceName,
                withExtension: "epub",
                subdirectory: "Development Assets/\(sampleBookBundleSubdirectory)")
            ?? Bundle.main.url(forResource: sampleBookResourceName, withExtension: "epub")
    }
}
#endif
