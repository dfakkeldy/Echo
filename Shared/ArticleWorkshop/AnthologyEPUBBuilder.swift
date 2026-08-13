// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

#if canImport(ZIPFoundation)
    import ZIPFoundation

    nonisolated struct AnthologyEPUBBuildResult: Equatable, Sendable {
        let temporaryURL: URL
        let epubSHA256: String
        let manifestSHA256: String
        let identifier: String
        let revision: Int
    }

    nonisolated struct AnthologyEPUBBuilder: Sendable {
        enum Error: Swift.Error, Equatable, Sendable {
            case invalidManifest
            case unsafeAsset
            case missingImageAssetMapping
            case destinationExists
            case archiveWriteFailed
            case preflightFailed
        }

        let workshopRoot: URL

        init(workshopRoot: URL = FileLocations.articleWorkshopRootDirectory) {
            self.workshopRoot = workshopRoot
        }

        func build(
            manifest: AnthologyBuildManifest,
            to destination: URL
        ) throws -> AnthologyEPUBBuildResult {
            guard FileManager.default.fileExists(atPath: destination.path) == false else {
                throw Error.destinationExists
            }
            try validate(manifest)
            let manifestData = try encodedManifest(manifest)
            let manifestDigest = Self.sha256(manifestData)
            let cover = try coverAsset(for: manifest)
            let articleImages = try articleImageAssets(for: manifest)
            let chapters = manifest.chapters.sorted { $0.order < $1.order }
            let entries = archiveEntries(
                manifest: manifest,
                manifestSHA256: manifestDigest,
                chapters: chapters,
                cover: cover,
                articleImages: articleImages)

            do {
                let archive = try Archive(url: destination, accessMode: .create)
                for entry in entries {
                    try archive.addEntry(
                        with: entry.path,
                        type: .file,
                        uncompressedSize: Int64(entry.data.count),
                        modificationDate: manifest.modifiedAt,
                        permissions: 0o644,
                        compressionMethod: entry.compressed ? .deflate : .none
                    ) { position, size in
                        let lower = Int(position)
                        return entry.data.subdata(
                            in: lower..<min(lower + size, entry.data.count))
                    }
                }
                return try AnthologyEPUBPreflight().validate(
                    epubAt: destination,
                    against: manifest)
            } catch let error as Error {
                try? FileManager.default.removeItem(at: destination)
                throw error
            } catch is AnthologyEPUBPreflight.Error {
                try? FileManager.default.removeItem(at: destination)
                throw Error.preflightFailed
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw Error.archiveWriteFailed
            }
        }

        private func validate(_ manifest: AnthologyBuildManifest) throws {
            guard [1, 2].contains(manifest.schemaVersion),
                manifest.revision > 0,
                manifest.epubIdentifier == "urn:uuid:\(manifest.anthologyID.uuidString)",
                manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                manifest.creator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                manifest.language.range(
                    of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#,
                    options: .regularExpression) != nil,
                manifest.chapters.isEmpty == false,
                allText(in: manifest).allSatisfy(EPUBXMLWriter.isXMLSafe)
            else {
                throw Error.invalidManifest
            }
            let orders = manifest.chapters.map(\.order)
            let slots = manifest.chapters.map(\.stableSlot)
            let entryIDs = manifest.chapters.map(\.entryID)
            let captureIDs = manifest.chapters.map(\.captureID)
            let revisionIDs = manifest.chapters.map(\.articleRevisionID)
            guard Set(orders) == Set(0..<manifest.chapters.count),
                Set(slots).count == slots.count,
                Set(entryIDs).count == entryIDs.count,
                Set(captureIDs).count == captureIDs.count,
                Set(revisionIDs).count == revisionIDs.count
            else {
                throw Error.invalidManifest
            }
            for chapter in manifest.chapters {
                guard chapter.stableSlot >= 0,
                    chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    Self.isSafeHTTPURL(chapter.sourceURL),
                    chapter.readableContentSHA256
                        == ArticleWorkshopDigest.readableContent(blocks: chapter.blocks)
                else {
                    throw Error.invalidManifest
                }
                var ordinals = Set<Int>()
                var blockIDs = Set<String>()
                for block in chapter.blocks {
                    guard block.stableOrdinal >= 0,
                        block.stableOrdinal < 899_000,
                        ordinals.insert(block.stableOrdinal).inserted,
                        blockIDs.insert(block.id).inserted,
                        block.sourceURL.map(Self.isSafeHTTPURL) ?? true,
                        block.imageCandidateURL.map(Self.isSafeHTTPURL) ?? true
                    else {
                        throw Error.invalidManifest
                    }
                    if block.kind == .image {
                        guard manifest.schemaVersion == 2 else {
                            throw Error.missingImageAssetMapping
                        }
                    }
                }
            }
            if manifest.schemaVersion == 1 {
                guard manifest.imageAssets == nil, manifest.imageFailures == nil else {
                    throw Error.invalidManifest
                }
                return
            }
            let imageBlocks = manifest.chapters.flatMap(\.blocks).filter { $0.kind == .image }
            let assets = manifest.imageAssets ?? []
            guard assets.count == imageBlocks.count,
                Set(assets.map(\.owningBlockID)).count == assets.count,
                Set(assets.map(\.owningBlockID)) == Set(imageBlocks.map(\.id))
            else { throw Error.invalidManifest }
            let blocksByID = Dictionary(uniqueKeysWithValues: imageBlocks.map { ($0.id, $0) })
            var archiveEvidence: [String: String] = [:]
            for asset in assets {
                let fileExtension = asset.mediaType == "image/png" ? "png" : "jpg"
                guard let block = blocksByID[asset.owningBlockID],
                    block.imageCandidateURL == asset.sourceURL,
                    block.altText == asset.altText,
                    block.caption == asset.caption,
                    Self.validAssetPath(asset.managedPath),
                    Self.validArchiveImagePath(asset.archivePath),
                    ["image/jpeg", "image/png"].contains(asset.mediaType),
                    asset.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                    asset.managedPath == "images/\(asset.sha256).\(fileExtension)",
                    asset.archivePath
                        == "EPUB/images/article-\(asset.sha256).\(fileExtension)",
                    asset.byteCount > 0,
                    asset.byteCount <= ArticleWorkshopLimits.maxSingleImageBytes,
                    asset.pixelWidth.map({ $0 > 0 && $0 <= 16_384 }) ?? true,
                    asset.pixelHeight.map({ $0 > 0 && $0 <= 16_384 }) ?? true,
                    Self.isSafeHTTPURL(asset.sourceURL)
                else { throw Error.invalidManifest }
                let evidence = "\(asset.sha256):\(asset.byteCount):\(asset.mediaType)"
                if let prior = archiveEvidence[asset.archivePath], prior != evidence {
                    throw Error.invalidManifest
                }
                archiveEvidence[asset.archivePath] = evidence
            }
            let failureIDs = (manifest.imageFailures ?? []).map(\.owningBlockID)
            guard Set(failureIDs).count == failureIDs.count,
                Set(failureIDs).isDisjoint(with: Set(assets.map(\.owningBlockID))),
                (manifest.imageFailures ?? []).allSatisfy({ Self.isSafeHTTPURL($0.sourceURL) })
            else { throw Error.invalidManifest }
        }

        private func archiveEntries(
            manifest: AnthologyBuildManifest,
            manifestSHA256: String,
            chapters: [AnthologyChapterManifest],
            cover: EPUBXMLWriter.CoverAsset,
            articleImages: [LoadedArticleImage]
        ) -> [ArchiveEntry] {
            let descriptors = articleImages.map(\.descriptor)
            var entries = [
                ArchiveEntry(
                    path: "mimetype",
                    data: Data("application/epub+zip".utf8),
                    compressed: false),
                ArchiveEntry(
                    path: "META-INF/container.xml",
                    data: Data(EPUBXMLWriter.container.utf8)),
                ArchiveEntry(
                    path: "EPUB/package.opf",
                    data: Data(
                        EPUBXMLWriter.package(
                            manifest: manifest,
                            manifestSHA256: manifestSHA256,
                            chapters: chapters,
                            cover: cover,
                            articleImages: descriptors
                        ).utf8)),
                ArchiveEntry(
                    path: "EPUB/nav.xhtml",
                    data: Data(
                        EPUBXMLWriter.navigation(
                            manifest: manifest,
                            chapters: chapters
                        ).utf8)),
                ArchiveEntry(
                    path: "EPUB/styles.css",
                    data: Data(EPUBXMLWriter.stylesheet.utf8)),
                ArchiveEntry(
                    path: "EPUB/cover.xhtml",
                    data: Data(
                        EPUBXMLWriter.coverPage(
                            manifest: manifest,
                            cover: cover
                        ).utf8)),
                ArchiveEntry(
                    path: "EPUB/images/\(cover.filename)",
                    data: cover.data),
            ]
            entries.append(
                contentsOf: chapters.map {
                    ArchiveEntry(
                        path: "EPUB/articles/article-s\($0.stableSlot).xhtml",
                        data: Data(
                            EPUBXMLWriter.chapter(
                                $0,
                                language: manifest.language,
                                articleImages: descriptors
                            ).utf8))
                })
            var emitted = Set<String>()
            for image in articleImages where emitted.insert(image.descriptor.archivePath).inserted {
                entries.append(ArchiveEntry(path: image.descriptor.archivePath, data: image.data))
            }
            return entries
        }

        private func coverAsset(
            for manifest: AnthologyBuildManifest
        ) throws -> EPUBXMLWriter.CoverAsset {
            guard let name = manifest.coverPath else {
                return EPUBXMLWriter.CoverAsset(
                    filename: "cover.svg",
                    mediaType: "image/svg+xml",
                    data: AnthologyCoverRenderer.generatedCover(manifest: manifest))
            }
            do {
                let store = AnthologyCoverStore(root: workshopRoot)
                guard
                    try store.validateManagedCover(
                        named: name,
                        anthologyID: manifest.anthologyID) == name
                else {
                    throw Error.unsafeAsset
                }
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                let mediaType: String
                switch ext {
                case "png": mediaType = "image/png"
                case "jpg", "jpeg": mediaType = "image/jpeg"
                default: throw Error.unsafeAsset
                }
                let url =
                    workshopRoot
                    .appending(path: "Anthologies", directoryHint: .isDirectory)
                    .appending(path: manifest.anthologyID.uuidString, directoryHint: .isDirectory)
                    .appending(path: name)
                let data = try readRegularFileWithoutFollowingSymlink(
                    at: url,
                    maximumBytes: AnthologyCoverStore.productionMaximumBytes)
                let expectedName = "cover-\(Self.sha256(data)).\(ext)"
                guard name == expectedName else { throw Error.unsafeAsset }
                return EPUBXMLWriter.CoverAsset(
                    filename: "cover.\(ext)",
                    mediaType: mediaType,
                    data: data)
            } catch let error as Error {
                throw error
            } catch {
                throw Error.unsafeAsset
            }
        }

        private func articleImageAssets(
            for manifest: AnthologyBuildManifest
        ) throws -> [LoadedArticleImage] {
            guard manifest.schemaVersion == 2 else { return [] }
            let captureByBlockID = Dictionary(uniqueKeysWithValues: manifest.chapters.flatMap { chapter in
                chapter.blocks.map { ($0.id, chapter.captureID) }
            })
            var loaded: [LoadedArticleImage] = []
            var totalBytes = 0
            var dataByManagedPath: [String: Data] = [:]
            for descriptor in manifest.imageAssets ?? [] {
                guard let captureID = captureByBlockID[descriptor.owningBlockID] else {
                    throw Error.unsafeAsset
                }
                let url = workshopRoot
                    .appending(path: "Captures", directoryHint: .isDirectory)
                    .appending(path: captureID.uuidString, directoryHint: .isDirectory)
                    .appending(path: descriptor.managedPath)
                let isNewPath = dataByManagedPath[descriptor.managedPath] == nil
                let data = try dataByManagedPath[descriptor.managedPath]
                    ?? readRegularFileWithoutFollowingSymlink(
                        at: url,
                        maximumBytes: ArticleWorkshopLimits.maxSingleImageBytes)
                guard data.count == descriptor.byteCount,
                    Self.sha256(data) == descriptor.sha256,
                    ArticleImageValidator.isValid(
                        data: data,
                        mediaType: descriptor.mediaType),
                    isNewPath == false
                        || totalBytes <= ArticleWorkshopLimits.maxTotalImageBytes - data.count
                else { throw Error.unsafeAsset }
                if isNewPath {
                    dataByManagedPath[descriptor.managedPath] = data
                    totalBytes += data.count
                }
                loaded.append(LoadedArticleImage(descriptor: descriptor, data: data))
            }
            return loaded
        }

        private func readRegularFileWithoutFollowingSymlink(
            at url: URL,
            maximumBytes: Int
        ) throws -> Data {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw Error.unsafeAsset }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_size >= 0,
                metadata.st_size <= maximumBytes
            else {
                throw Error.unsafeAsset
            }
            let data = try handle.readToEnd() ?? Data()
            guard data.count == Int(metadata.st_size) else { throw Error.unsafeAsset }
            return data
        }

        private func allText(in manifest: AnthologyBuildManifest) -> [String] {
            var values = [
                manifest.epubIdentifier,
                manifest.title,
                manifest.creator,
                manifest.language,
            ]
            if let subtitle = manifest.subtitle { values.append(subtitle) }
            for chapter in manifest.chapters {
                values.append(contentsOf: [
                    chapter.title,
                    chapter.siteName ?? "",
                    chapter.author ?? "",
                    chapter.sourceURL.absoluteString,
                ])
                for block in chapter.blocks {
                    values.append(contentsOf: [
                        block.id,
                        block.text ?? "",
                        block.caption ?? "",
                        block.altText ?? "",
                        block.codeLanguage ?? "",
                        block.sourceURL?.absoluteString ?? "",
                        block.imageCandidateURL?.absoluteString ?? "",
                    ])
                }
            }
            return values
        }

        private func encodedManifest(_ manifest: AnthologyBuildManifest) throws -> Data {
            let encoder = JSONEncoder.articleWorkshop
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(manifest)
        }

        private static func isSafeHTTPURL(_ url: URL) -> Bool {
            guard
                let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false),
                let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                components.host?.isEmpty == false,
                components.user == nil,
                components.password == nil
            else {
                return false
            }
            return true
        }

        private static func validAssetPath(_ path: String) -> Bool {
            safeRelativePath(path) && path.hasPrefix("images/")
                && path.split(separator: "/").count == 2
        }

        private static func validArchiveImagePath(_ path: String) -> Bool {
            safeRelativePath(path) && path.hasPrefix("EPUB/images/article-")
                && (path.hasSuffix(".jpg") || path.hasSuffix(".png"))
        }

        private static func safeRelativePath(_ path: String) -> Bool {
            path.isEmpty == false && path.hasPrefix("/") == false && path.contains("\\") == false
                && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                    $0.isEmpty == false && $0 != "." && $0 != ".."
                }
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private struct ArchiveEntry {
            let path: String
            let data: Data
            let compressed: Bool

            init(path: String, data: Data, compressed: Bool = true) {
                self.path = path
                self.data = data
                self.compressed = compressed
            }
        }

        private struct LoadedArticleImage {
            let descriptor: ArticleImageAssetDescriptor
            let data: Data
        }
    }
#endif
