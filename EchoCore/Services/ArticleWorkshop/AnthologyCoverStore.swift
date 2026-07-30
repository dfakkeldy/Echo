import CryptoKit
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct AnthologyCoverStore: Sendable {
    enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case invalidAnthologyID
        case unsafeSource
        case imageTooLarge
        case invalidImage
        case dimensionsTooLarge
        case unsafeDestination

        var errorDescription: String? {
            switch self {
            case .invalidAnthologyID:
                return "This anthology has an invalid identifier."
            case .unsafeSource:
                return "The selected cover could not be read safely."
            case .imageTooLarge:
                return "The selected cover file is too large."
            case .invalidImage:
                return "The selected file is not a supported image."
            case .dimensionsTooLarge:
                return "The selected cover dimensions are too large."
            case .unsafeDestination:
                return "The cover could not be stored safely."
            }
        }
    }

    static let productionMaximumBytes = 12 * 1_024 * 1_024
    static let productionMaximumDimension = 8_192
    static let productionMaximumPixelCount = 16_777_216

    let root: URL
    let maximumBytes: Int
    let maximumDimension: Int
    let maximumPixelCount: Int

    init(
        root: URL = FileLocations.articleWorkshopRootDirectory,
        maximumBytes: Int = AnthologyCoverStore.productionMaximumBytes,
        maximumDimension: Int = AnthologyCoverStore.productionMaximumDimension,
        maximumPixelCount: Int = AnthologyCoverStore.productionMaximumPixelCount
    ) {
        self.root = root
        self.maximumBytes = maximumBytes
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
    }

    func importCover(from source: URL, anthologyID: UUID) throws -> String {
        guard maximumBytes > 0, maximumDimension > 0, maximumPixelCount > 0 else {
            throw Error.unsafeSource
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let data = try boundedRegularFileData(at: source)
        let fileExtension = try validatedImageExtension(for: data)

        let directory =
            root
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
        try prepareManagedDirectory(directory)
        let filename = "cover-\(Self.sha256(data)).\(fileExtension)"
        let destination = directory.appending(path: filename)
        guard destination.deletingLastPathComponent() == directory else {
            throw Error.unsafeDestination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try boundedRegularFileData(at: destination) == data else {
                throw Error.unsafeDestination
            }
            return filename
        }
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            guard try validateManagedCover(named: filename, anthologyID: anthologyID) == filename
            else {
                throw Error.unsafeDestination
            }
        } catch {
            throw Error.unsafeDestination
        }
        return filename
    }

    func contentVersion(for source: URL) throws -> String {
        let data = try boundedRegularFileData(at: source)
        _ = try validatedImageExtension(for: data)
        return "sha256:\(Self.sha256(data))"
    }

    func validateManagedCover(named filename: String, anthologyID: UUID) throws -> String {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
            filename != ".",
            filename != ".."
        else {
            throw Error.unsafeDestination
        }
        let directory =
            root
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
        let destination = directory.appending(path: filename)
        guard destination.deletingLastPathComponent() == directory else {
            throw Error.unsafeDestination
        }
        do {
            try validateManagedDirectory(root)
            try validateManagedDirectory(directory.deletingLastPathComponent())
            try validateManagedDirectory(directory)
            let data = try boundedRegularFileData(at: destination)
            let fileExtension = try validatedImageExtension(for: data)
            guard filename == "cover-\(Self.sha256(data)).\(fileExtension)" else {
                throw Error.unsafeDestination
            }
            return filename
        } catch {
            throw Error.unsafeDestination
        }
    }

    private func imageSource(for data: Data) throws -> CGImageSource {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1
        else {
            throw Error.invalidImage
        }
        return source
    }

    private func validatedImageExtension(for data: Data) throws -> String {
        let imageSource = try imageSource(for: data)
        guard let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
            let type = UTType(typeIdentifier),
            type.conforms(to: .image),
            let fileExtension = Self.safeExtension(for: type)
        else {
            throw Error.invalidImage
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
            let width = Self.intValue(properties[kCGImagePropertyPixelWidth]),
            let height = Self.intValue(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            throw Error.invalidImage
        }
        guard width <= maximumDimension,
            height <= maximumDimension,
            width <= maximumPixelCount / height
        else {
            throw Error.dimensionsTooLarge
        }
        guard
            CGImageSourceCreateImageAtIndex(
                imageSource,
                0,
                [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) != nil
        else {
            throw Error.invalidImage
        }
        return fileExtension
    }

    private func prepareManagedDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        do {
            let normalizedRoot = root.standardizedFileURL
            let normalizedDirectory = directory.standardizedFileURL
            let anthologies = normalizedRoot.appending(
                path: "Anthologies",
                directoryHint: .isDirectory)
            guard normalizedDirectory.deletingLastPathComponent() == anthologies else {
                throw Error.unsafeDestination
            }
            try validateManagedDirectory(normalizedRoot)
            try createManagedDirectoryIfNeeded(anthologies, fileManager: fileManager)
            try createManagedDirectoryIfNeeded(normalizedDirectory, fileManager: fileManager)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.unsafeDestination
        }
    }

    private func createManagedDirectoryIfNeeded(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try validateManagedDirectory(directory)
            return
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        try validateManagedDirectory(directory)
    }

    private func validateManagedDirectory(_ directory: URL) throws {
        let normalized = directory.standardizedFileURL
        let value = try metadata(at: normalized, followLeaf: false)
        guard value.kind == S_IFDIR,
            normalized.resolvingSymlinksInPath().standardizedFileURL == normalized
        else {
            throw Error.unsafeDestination
        }
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        let pathBefore = try metadata(at: url, followLeaf: false)
        guard pathBefore.kind == S_IFREG else {
            throw Error.unsafeSource
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Error.unsafeSource
        }
        defer { try? handle.close() }
        let before = try metadata(descriptor: handle.fileDescriptor)
        guard before == pathBefore, before.size >= 0 else {
            throw Error.unsafeSource
        }
        guard before.size <= Int64(maximumBytes) else {
            throw Error.imageTooLarge
        }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            throw Error.unsafeSource
        }
        guard data.count <= maximumBytes else {
            throw Error.imageTooLarge
        }
        let after = try metadata(descriptor: handle.fileDescriptor)
        let pathAfter = try metadata(at: url, followLeaf: false)
        guard before == after,
            after == pathAfter,
            after.size == Int64(data.count)
        else {
            throw Error.unsafeSource
        }
        return data
    }

    private func metadata(descriptor: Int32) throws -> FileMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw Error.unsafeSource
        }
        return FileMetadata(value)
    }

    private func metadata(at url: URL, followLeaf: Bool) throws -> FileMetadata {
        var value = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return followLeaf ? stat(path, &value) : lstat(path, &value)
        }
        guard result == 0 else {
            throw Error.unsafeSource
        }
        return FileMetadata(value)
    }

    private static func safeExtension(for type: UTType) -> String? {
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .heic) { return "heic" }
        return nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let value as Int:
            return value
        default:
            return nil
        }
    }
}

private nonisolated struct FileMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt16
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        kind = value.st_mode & S_IFMT
        size = Int64(value.st_size)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}
