// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import CryptoKit
    import Foundation
    import ZIPFoundation

    /// Versioned, verified Core ML assets shared by every Phonon narrator.
    actor PhononModelStore {
        static let shared = PhononModelStore()
        nonisolated static let release = VoiceCatalog.phononRelease
        nonisolated static let archiveBytes: Int64 = 137_300_950
        nonisolated static let archiveSHA256 =
            "058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76"
        nonisolated static let manifestSHA256 =
            "8c4cc8ba9619695ef231c7770938286073d3e6ea04863d4efe821c36bd9e4007"
        nonisolated static let downloadURL = URL(
            string:
                "https://github.com/gradium-ai/xn-ptts/releases/download/v0.7.1/phonon-31m-en-coreml.zip"
        )!

        nonisolated static let archiveRoot = "phonon-31m-en"

        private var delivery: Task<URL, Error>?

        func models(
            progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
        ) async throws -> URL {
            if let delivery { return try await delivery.value }
            let task = Task { try await Self.install(progress: progress) }
            delivery = task
            defer { delivery = nil }
            return try await task.value
        }

        @concurrent
        private static func install(
            progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
        ) async throws -> URL {
            let fm = FileManager.default
            progress(.checkingModel(expectedBytes: archiveBytes))
            if let override = ProcessInfo.processInfo.environment["ECHO_PHONON_MODEL_DIR"],
                !override.isEmpty
            {
                let directory = URL(fileURLWithPath: override, isDirectory: true)
                try validateBundle(at: directory)
                progress(.modelCacheHit(byteCount: archiveBytes))
                return directory
            }
            let parent = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Echo/Phonon31M", isDirectory: true)
            let directory = parent.appendingPathComponent(release, isDirectory: true)
            if (try? validateBundle(at: directory)) != nil {
                progress(.modelCacheHit(byteCount: archiveBytes))
                return directory
            }

            progress(.downloadingModel(receivedBytes: 0, totalBytes: archiveBytes))
            let (archive, response) = try await URLSession.shared.download(from: downloadURL)
            defer { try? fm.removeItem(at: archive) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw NarrationError.modelDownloadFailed(name: "Phonon 31M", underlying: nil)
            }
            progress(.validatingModel(byteCount: archiveBytes))
            guard try fileSHA256(at: archive) == archiveSHA256 else {
                throw NarrationError.modelDownloadFailed(
                    name: "Phonon 31M checksum", underlying: nil)
            }
            try Task.checkCancellation()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.unzipItem(at: archive, to: staging)
            // 0.4.0 archived the bundle as `phonon-31m-en-coreml/`; 0.7.x as `phonon-31m-en/`.
            let extracted = staging.appendingPathComponent(archiveRoot, isDirectory: true)
            try validateBundle(at: extracted)
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            try fm.moveItem(at: extracted, to: directory)
            return directory
        }

        /// Authenticate the manifest first, then every original model/voice file.
        /// Core ML's compiled copies live beside these files and are not inputs.
        nonisolated static func validateBundle(
            at directory: URL, expectedManifestSHA256: String = manifestSHA256
        ) throws {
            struct Manifest: Decodable {
                struct File: Decodable {
                    let path: String
                    let size: Int
                    let sha256: String
                }
                let files: [File]
            }
            let manifest = directory.appendingPathComponent("bundle.json")
            guard try fileSHA256(at: manifest) == expectedManifestSHA256 else {
                throw NarrationError.modelDownloadFailed(
                    name: "Phonon 31M manifest", underlying: nil)
            }
            let files = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
                .files
            guard !files.isEmpty else { throw NarrationError.engineUnavailable }
            for file in files {
                guard !file.path.hasPrefix("/"),
                    !file.path.split(separator: "/").contains("..")
                else { throw NarrationError.engineUnavailable }
                let url = directory.appendingPathComponent(file.path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size == file.size, try fileSHA256(at: url) == file.sha256 else {
                    throw NarrationError.modelDownloadFailed(
                        name: "Phonon 31M assets", underlying: nil)
                }
            }
        }

        nonisolated static func fileSHA256(at url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
                hash.update(data: bytes)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
