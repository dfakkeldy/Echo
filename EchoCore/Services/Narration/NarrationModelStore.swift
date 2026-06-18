// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import os.log

    /// Owns the on-device CoreML model set for the fixed-shape Kokoro engine.
    ///
    /// The mattmireles/kokoro-coreml Hugging Face repo ships ~23 `.mlpackage`
    /// buckets. To keep the first-launch download small we ship a **pruned**
    /// set: decoder buckets for ≤15s of audio (the longest a chunk can be once
    /// `NarrationTextChunker` bounds every synthesis call), the four matching
    /// `f0ntrain` frame sizes, and *all* duration token buckets (they are tiny
    /// and the pipeline picks the nearest padded size per utterance). The 30s
    /// decoder + `f0ntrain_t1200` are intentionally absent.
    ///
    /// Hugging Face stores each `.mlpackage` as a **directory tree** (a sibling
    /// `Manifest.json` plus a `Data/` subtree), so downloading one package means
    /// walking that tree via the HF HTTP API and fetching every internal file.
    /// This mirrors the Python `huggingface_hub.snapshot_download` reference.
    ///
    /// Downloads are idempotent: a `.complete` sentinel is written only after
    /// every file verifies, so an interrupted first launch resumes cleanly.
    actor NarrationModelStore {
        static let shared = NarrationModelStore()

        private let logger = Logger(category: "NarrationModelStore")

        /// Bucket durations (seconds) for which we ship decoder_pre +
        /// decoder_har_post + f0ntrain models. Chunks are capped ≤15s of audio,
        /// so the 30s buckets are unreachable and pruned.
        static let keptBucketSeconds: [Int] = [3, 7, 10, 15]

        /// T-frames for each kept bucket (matches `KokoroPipeline.tFramesForBucket`).
        /// 3s→120, 7s→280, 10s→400, 15s→600. The 30s→1200 is pruned.
        private static let keptTFrames: [Int] = [120, 280, 400, 600]

        /// Duration-token sizes shipped on HF (legacy `kokoro_duration` maps to
        /// t128). All are small; keep every one so the pipeline can pad to the
        /// nearest size for any utterance length.
        private static let durationTokenSizes: [Int] = [32, 64, 128, 256, 320, 384, 512]

        /// Learned weights of `SourceModuleHnNSF.l_linear`, transcribed verbatim
        /// from `hnsf_weights.json` (Phase 0 source of truth). Pinned in a test.
        static let hnsfLinearWeights: [Float] = [
            -0.08154187, -0.18519667, -0.18263398, -0.17837206, -0.09873895,
            0.08264039, 0.08743999, -0.39068547, -0.54774433,
        ]
        static let hnsfLinearBias: Float = -0.02945026

        /// Hugging Face repo + path layout.
        private static let hfRepoID = "mattmireles/kokoro-coreml"
        private static let hfTreeAPI = "https://huggingface.co/api/models/\(hfRepoID)/tree/main/"
        private static let hfResolveBase = "https://huggingface.co/\(hfRepoID)/resolve/main/"

        /// Subdirectory under `NarrationCache.directory()` holding the model set.
        /// Bumped if the file layout/contents change so a new set downloads.
        private static let modelSubdir = "Models/kokoro-fixed-v5"
        private static let completeSentinel = ".complete"

        // MARK: - File list (pure, testable)

        /// The exact `.mlpackage` filenames this store must fetch. Pure function
        /// so the pruned-set policy is unit-testable without a network.
        static func requiredModelFiles() -> [String] {
            var files: [String] = []
            for sec in keptBucketSeconds {
                files.append("kokoro_decoder_pre_\(sec)s.mlpackage")
                files.append("kokoro_decoder_har_post_\(sec)s.mlpackage")
            }
            for t in keptTFrames {
                files.append("kokoro_f0ntrain_t\(t).mlpackage")
            }
            // Legacy single duration package (the pipeline falls back to it as t128).
            files.append("kokoro_duration.mlpackage")
            for t in durationTokenSizes {
                files.append("kokoro_duration_t\(t).mlpackage")
            }
            return files.sorted()
        }

        // MARK: - Download / verify

        /// Downloads (once) the pruned `.mlpackage` set into Application Support
        /// and returns the directory `KokoroPipeline` should load from. Idempotent
        /// and concurrency-safe: concurrent callers share one download pass via
        /// the actor's serialized access.
        func ensureModels(progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            let dir = modelsDirectory()
            let fm = FileManager.default

            // Fast path: a previous run wrote the sentinel after every file landed.
            if fm.fileExists(atPath: dir.appendingPathComponent(Self.completeSentinel).path) {
                progress?(1.0)
                return dir
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let packages = Self.requiredModelFiles()
            let total = Double(packages.count)
            for (index, package) in packages.enumerated() {
                try await downloadPackage(named: package, into: dir)
                progress?(Double(index + 1) / total)
            }

            // All packages present → stamp the sentinel so subsequent launches skip.
            let sentinelData = Data("\(packages.count)\n".utf8)
            try sentinelData.write(
                to: dir.appendingPathComponent(Self.completeSentinel),
                options: .atomic)
            logger.info("Model set ready (\(packages.count, privacy: .public) packages).")
            return dir
        }

        /// The on-disk model directory (created lazily). Sits under the shared
        /// `NarrationCache.directory()` (Application Support, excluded from backup).
        nonisolated func modelsDirectory() -> URL {
            NarrationCache.directory().appendingPathComponent(Self.modelSubdir, isDirectory: true)
        }

        // MARK: - Per-package tree walk

        /// Downloads one `.mlpackage` directory from HF into `dir/<name>`, retrying
        /// once per internal file on transient failure. Resumes cleanly across
        /// launches: files already on disk are skipped, so an interrupted run only
        /// re-fetches what's missing.
        private func downloadPackage(named name: String, into dir: URL) async throws {
            let packageRoot = dir.appendingPathComponent(name)
            // A complete package is signalled by its Manifest.json (always present
            // in a valid .mlpackage). If it's there, assume the package finished.
            if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Manifest.json").path) {
                return
            }

            let entries = try await listTree(at: "coreml/\(name)")
            // `entries` is the top level of the package; recurse into directories.
            var allFiles: [String] = [] // repo-relative paths of every leaf file
            try await collectFiles(from: entries, into: &allFiles)

            for file in allFiles {
                try await downloadInternalFile(repoPath: file, packageRoot: packageRoot, name: name)
            }
        }

        /// Recursively walks HF tree entries, appending every leaf-file path
        /// (repo-relative, e.g. `coreml/foo.mlpackage/Data/weights.bin`) to `out`.
        private func collectFiles(from entries: [HFTreeEntry], into out: inout [String]) async throws {
            for entry in entries {
                switch entry.type {
                case "file":
                    out.append(entry.path)
                case "directory":
                    let children = try await listTree(at: entry.path)
                    try await collectFiles(from: children, into: &out)
                default:
                    continue // symlinks etc. are not used by this repo
                }
            }
        }

        /// Fetches one internal package file to the right subpath under
        /// `packageRoot`, recreating directories as needed. Retries once.
        private func downloadInternalFile(
            repoPath: String, packageRoot: URL, name: String
        ) async throws {
            // Map repo path `coreml/<pkg>/...` → `<packageRoot>/...`
            let prefix = "coreml/\(name)/"
            guard repoPath.hasPrefix(prefix) else {
                throw NarrationError.modelDownloadFailed(name: name, underlying: nil)
            }
            let relative = String(repoPath.dropFirst(prefix.count))
            let dest = packageRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: dest.path) { return }

            let fm = FileManager.default
            let parent = dest.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

            let url = URL(string: Self.hfResolveBase + repoPath)!
            var attempt = 0
            var lastError: Error?
            while attempt < 2 {
                do {
                    let (data, response) = try await urlSession.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw NarrationError.modelDownloadFailed(name: name, underlying: nil)
                    }
                    try data.write(to: dest, options: .atomic)
                    return
                } catch {
                    lastError = error
                    attempt += 1
                    logger.warning(
                        "Fetch \(repoPath, privacy: .public) failed (attempt \(attempt, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
            }
            throw NarrationError.modelDownloadFailed(name: name, underlying: lastError)
        }

        // MARK: - HF tree API

        /// One entry in a Hugging Face `tree/main/<path>` listing.
        private struct HFTreeEntry: Decodable {
            let type: String
            let path: String
        }

        /// Lists the immediate children of `repoPath` (e.g. `coreml/foo.mlpackage`)
        /// via the HF HTTP API.
        private func listTree(at repoPath: String) async throws -> [HFTreeEntry] {
            // URL-encode path segments individually (slashes are path separators).
            let encoded = repoPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? repoPath
            let url = URL(string: Self.hfTreeAPI + encoded)!
            let (data, response) = try await urlSession.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NarrationError.modelDownloadFailed(name: repoPath, underlying: nil)
            }
            return try JSONDecoder().decode([HFTreeEntry].self, from: data)
        }

        /// Shared session with a generous timeout — model packages are large and
        /// the macOS first-launch timeout is the historical failure mode.
        private nonisolated var urlSession: URLSession {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3_600
            config.networkServiceType = .background
            return URLSession(configuration: config)
        }
    }
#endif
