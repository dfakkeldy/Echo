// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Synchronization

/// Inputs outside the synthesis plan that still change the engine's output.
/// A different value for any field means no cached chunk is reused.
nonisolated struct NarrationSynthesisCacheContext: Sendable, Equatable {
    /// `NarrationFileNaming.renderVersion` of the running renderer.
    let renderVersion: Int
    /// SHA-256 of the running renderer build (the `echo-cli` executable), so a
    /// rebuilt or re-promoted renderer never replays audio from another build.
    let rendererBuildDigest: String
    /// Whether the engine was asked for duration-head word timings.
    let includesWordTimings: Bool

    init(
        renderVersion: Int = NarrationFileNaming.renderVersion,
        rendererBuildDigest: String,
        includesWordTimings: Bool
    ) {
        self.renderVersion = renderVersion
        self.rendererBuildDigest = rendererBuildDigest
        self.includesWordTimings = includesWordTimings
    }
}

/// Content-addressed cache of synthesized narration chunks.
///
/// The reuse unit is one `PlannedSynthesisChunk`: the frozen, fully resolved
/// input that `NarrationService` hands to the engine (at most one block's text,
/// already normalized, rewritten for inline `ssml:ph`/PLS markup, user and
/// occurrence overrides, homographs and contextual choices, then phonemized).
/// Keying on that plan, not on block text, means every upstream pronunciation
/// input is covered without tracking which lexicon entries a block used: if an
/// edit anywhere changes what this chunk would say, its phoneme IDs change and
/// the key misses. Chunks are already independent engine calls that the
/// renderer splices, so replaying a cached chunk adds no new audio seam.
nonisolated enum NarrationSynthesisCache {
    static let formatVersion = 1

    /// Stable key for one engine call.
    static func key(
        for chunk: PlannedSynthesisChunk,
        voice: VoiceID,
        context: NarrationSynthesisCacheContext
    ) -> String {
        let groupCounts = chunk.authoredWordGroupCounts.map {
            $0.map(String.init).joined(separator: ",")
        }
        let fallbackEncoder = JSONEncoder()
        fallbackEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fallbackJSON =
            (try? fallbackEncoder.encode(chunk.pronunciationFallbackHits))
            .map { String(decoding: $0, as: UTF8.self) } ?? "unencodable"
        return framedSHA256([
            "echo-synthesis-cache=\(formatVersion)",
            "render-version=\(context.renderVersion)",
            "renderer-build=\(context.rendererBuildDigest)",
            "renderer=\(VoiceCatalog.rendererIdentity(for: [voice]))",
            "voice=\(voice.rawValue)",
            "word-timings=\(context.includesWordTimings)",
            "display=\(chunk.displayText)",
            "g2p=\(chunk.g2pInputText)",
            "phonemes=\(chunk.phonemes)",
            "phoneme-ids=\(chunk.phonemeIDs.map(String.init).joined(separator: ","))",
            "word-count=\(chunk.wordCount)",
            "word-groups=\(groupCounts ?? "none")",
            "fallback-hits=\(fallbackJSON)",
        ])
    }

    static func framedSHA256(_ components: [String]) -> String {
        var hasher = SHA256()
        for component in components {
            let data = Data(component.utf8)
            hasher.update(data: Data("\(data.count):".utf8))
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// On-disk store for `NarrationSynthesisCache` entries.
///
/// Layout: `<root>/<key[0..<2]>/<key>.echosyn`. Each file is a magic line, a
/// JSON header, then the exact Float32 little-endian PCM the engine returned,
/// so a hit replays the same samples a fresh synthesis wrote. Entries are
/// written atomically and verified on read (key, sample count and PCM SHA-256);
/// anything malformed is a miss and is synthesized again.
nonisolated final class NarrationSynthesisCacheStore: Sendable {
    private static let magic = Data("ECHOSYN1\n".utf8)

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private struct Header: Codable {
        struct Word: Codable {
            let wordIndex: Int
            let start: TimeInterval
            let end: TimeInterval
        }
        let key: String
        let sampleRate: Double
        let duration: TimeInterval
        let sampleCount: Int
        let pcmSHA256: String
        let wordTimings: [Word]?
        let pronunciationFallbackHits: [PronunciationFallbackHit]
    }

    func url(forKey key: String) -> URL {
        rootURL
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).echosyn")
    }

    func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forKey: key).path)
    }

    /// Returns the stored chunk, or nil when it is absent or fails verification.
    func read(key: String) -> TTSChunk? {
        guard let data = try? Data(contentsOf: url(forKey: key)),
            data.starts(with: Self.magic)
        else { return nil }
        var offset = Self.magic.count
        guard data.count >= offset + 4 else { return nil }
        let headerLength = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        offset += 4
        guard headerLength > 0, data.count >= offset + headerLength,
            let header = try? JSONDecoder().decode(
                Header.self, from: data.subdata(in: offset..<(offset + headerLength)))
        else { return nil }
        offset += headerLength
        let pcm = data.subdata(in: offset..<data.count)
        guard header.key == key,
            header.sampleCount >= 0,
            pcm.count == header.sampleCount * MemoryLayout<UInt32>.size,
            NarrationSynthesisCache.hex(SHA256.hash(data: pcm)) == header.pcmSHA256,
            header.sampleRate.isFinite, header.sampleRate > 0,
            header.duration.isFinite, header.duration >= 0
        else { return nil }
        let samples: [Float] = pcm.withUnsafeBytes { raw in
            (0..<header.sampleCount).map { index in
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(
                            fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        return TTSChunk(
            samples: samples,
            sampleRate: header.sampleRate,
            duration: header.duration,
            wordTimings: header.wordTimings?.map {
                ChunkWordTiming(wordIndex: $0.wordIndex, start: $0.start, end: $0.end)
            },
            pronunciationFallbackHits: header.pronunciationFallbackHits)
    }

    /// Atomically stores `chunk` under `key`. Failures are reported to the
    /// caller, which treats the cache as best-effort.
    func write(_ chunk: TTSChunk, key: String) throws {
        var pcm = Data(capacity: chunk.samples.count * 4)
        for sample in chunk.samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let header = Header(
            key: key,
            sampleRate: chunk.sampleRate,
            duration: chunk.duration,
            sampleCount: chunk.samples.count,
            pcmSHA256: NarrationSynthesisCache.hex(SHA256.hash(data: pcm)),
            wordTimings: chunk.wordTimings?.map {
                Header.Word(wordIndex: $0.wordIndex, start: $0.start, end: $0.end)
            },
            pronunciationFallbackHits: chunk.pronunciationFallbackHits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)
        var file = Self.magic
        withUnsafeBytes(of: UInt32(headerData.count).littleEndian) {
            file.append(contentsOf: $0)
        }
        file.append(headerData)
        file.append(pcm)

        let destination = url(forKey: key)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.atomic` writes a temporary sibling and renames it, so concurrent
        // workers and crashes never leave a torn entry under the final name.
        try file.write(to: destination, options: .atomic)
    }
}

/// Hit and miss counts for one run's synthesis cache.
nonisolated struct NarrationSynthesisCacheStats: Sendable, Equatable {
    var hits = 0
    var misses = 0
    var writeFailures = 0
}

/// Engine wrapper that replays cached chunks and stores fresh ones.
///
/// Only the plan-based `synthesize(_:voice:)` requirement is cached: it is the
/// one `NarrationService` uses for every chunk and every quality-retry slice.
/// Text synthesis and model lifecycle pass straight through.
nonisolated final class CachingTTSEngine: TTSEngine {
    let base: TTSEngine
    let store: NarrationSynthesisCacheStore
    let context: NarrationSynthesisCacheContext
    private let counters: Mutex<NarrationSynthesisCacheStats>

    init(
        base: TTSEngine,
        store: NarrationSynthesisCacheStore,
        context: NarrationSynthesisCacheContext
    ) {
        self.base = base
        self.store = store
        self.context = context
        self.counters = Mutex(NarrationSynthesisCacheStats())
    }

    var stats: NarrationSynthesisCacheStats { counters.withLock { $0 } }

    func prepare() async throws { try await base.prepare() }

    func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws {
        try await base.prepare(progress: progress)
    }

    func prepare(
        voice: VoiceID, progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
    ) async throws {
        try await base.prepare(voice: voice, progress: progress)
    }

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        try await base.synthesize(text, voice: voice)
    }

    func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
        let key = NarrationSynthesisCache.key(for: chunk, voice: voice, context: context)
        if let cached = store.read(key: key) {
            counters.withLock { $0.hits += 1 }
            return cached
        }
        let fresh = try await base.synthesize(chunk, voice: voice)
        counters.withLock { $0.misses += 1 }
        do {
            try store.write(fresh, key: key)
        } catch {
            counters.withLock { $0.writeFailures += 1 }
        }
        return fresh
    }

    func unload() async { await base.unload() }
}

/// Dry-run report: which blocks an edited book would re-synthesize.
nonisolated struct NarrationRerenderPreview: Sendable, Equatable {
    struct Block: Sendable, Equatable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        /// Portable `s<i>-b<j>` block id, as in sidecars and `export-blocks`.
        let blockID: String
        let voice: VoiceID
        let text: String
        let chunkCount: Int
        let cachedChunkCount: Int

        /// Every engine call for this block replays cached audio.
        var isReused: Bool { cachedChunkCount == chunkCount }
    }

    let blocks: [Block]

    var blocksToRender: [Block] { blocks.filter { !$0.isReused } }
    var chunkCount: Int { blocks.reduce(0) { $0 + $1.chunkCount } }
    var cachedChunkCount: Int { blocks.reduce(0) { $0 + $1.cachedChunkCount } }

    /// Human-readable lines for `echo-cli narrate --dry-run`. One line per
    /// block that would be synthesized, then a one-line summary.
    func reportLines(previewLength: Int = 60) -> [String] {
        var lines = blocksToRender.map { block in
            let flat = block.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let preview =
                flat.count > previewLength ? String(flat.prefix(previewLength)) + "…" : flat
            return
                "RENDER ch\(block.chapterDisplayNumber) \(block.blockID) [\(block.voice.rawValue)] "
                + "\(block.chunkCount - block.cachedChunkCount)/\(block.chunkCount) chunk(s): \(preview)"
        }
        let chapters = Set(blocksToRender.map(\.chapterDisplayNumber)).sorted()
        lines.append(
            "DRY_RUN \(blocksToRender.count) of \(blocks.count) blocks to render "
                + "(\(chunkCount - cachedChunkCount) of \(chunkCount) chunks); "
                + "chapters with changes: "
                + (chapters.isEmpty ? "none" : chapters.map(String.init).joined(separator: ",")))
        return lines
    }
}
