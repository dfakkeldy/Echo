import Foundation
import AppKit
import UniformTypeIdentifiers
import os.log

struct TranscriptionLogEntry: Identifiable, Equatable {
    enum Kind: String {
        case status
        case progress
        case segment
        case completed
        case error
        case debug
        case stderr
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

private enum TranscriptionCLIEvent: Codable {
    case status(message: String)
    case progress(Double)
    case segment(TranscriptionSegment)
    case wordFrequencies(words: [WordFrequency])
    case completed(outputPath: String, segmentCount: Int, wordFrequencyPath: String?)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case progress
        case segment
        case words
        case outputPath
        case segmentCount
        case wordFrequencyPath
    }

    private enum EventType: String, Codable {
        case status
        case progress
        case segment
        case wordFrequencies
        case completed
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .status:
            self = .status(message: try container.decode(String.self, forKey: .message))
        case .progress:
            self = .progress(try container.decode(Double.self, forKey: .progress))
        case .segment:
            self = .segment(try container.decode(TranscriptionSegment.self, forKey: .segment))
        case .wordFrequencies:
            self = .wordFrequencies(words: try container.decode([WordFrequency].self, forKey: .words))
        case .completed:
            self = .completed(
                outputPath: try container.decode(String.self, forKey: .outputPath),
                segmentCount: try container.decode(Int.self, forKey: .segmentCount),
                wordFrequencyPath: try container.decodeIfPresent(String.self, forKey: .wordFrequencyPath)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .status(let message):
            try container.encode(EventType.status, forKey: .type)
            try container.encode(message, forKey: .message)
        case .progress(let progress):
            try container.encode(EventType.progress, forKey: .type)
            try container.encode(progress, forKey: .progress)
        case .segment(let segment):
            try container.encode(EventType.segment, forKey: .type)
            try container.encode(segment, forKey: .segment)
        case .wordFrequencies(let words):
            try container.encode(EventType.wordFrequencies, forKey: .type)
            try container.encode(words, forKey: .words)
        case .completed(let outputPath, let segmentCount, let wordFrequencyPath):
            try container.encode(EventType.completed, forKey: .type)
            try container.encode(outputPath, forKey: .outputPath)
            try container.encode(segmentCount, forKey: .segmentCount)
            try container.encodeIfPresent(wordFrequencyPath, forKey: .wordFrequencyPath)
        case .error(let message):
            try container.encode(EventType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

@MainActor
@Observable
class TranscriptionManager {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "TranscriptionManager")
    var progress: Double = 0
    var isTranscribing: Bool = false
    var status: String = ""
    var liveLogStream: [TranscriptionLogEntry] = []
    var liveSegments: [TranscriptionSegment] = []
    var liveWordCloud: [WordFrequency] = []

    private var currentProcess: Process?
    private var completedTranscriptURL: URL?

    func exportTranscript(for audioURL: URL, segments: [TranscriptionSegment]) throws {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = audioURL.deletingPathExtension().appendingPathExtension("transcript.json").lastPathComponent
        savePanel.directoryURL = audioURL.deletingLastPathComponent()

        if savePanel.runModal() == .OK, let url = savePanel.url {
            let data = try JSONEncoder().encode(segments)
            try data.write(to: url, options: .atomic)
#if DEBUG
            logger.debug("Successfully exported transcript to: \(url.lastPathComponent)")
#endif
        }
    }

    func cancelTranscription() {
        currentProcess?.terminate()
        currentProcess = nil
        isTranscribing = false
        appendLog(.status, "Transcription cancelled.")
    }

    func transcribe(url: URL) async throws -> URL? {
        isTranscribing = true
        progress = 0
        status = "Starting CLI..."
        liveLogStream = []
        liveSegments = []
        liveWordCloud = []
        completedTranscriptURL = nil
        defer {
            isTranscribing = false
            currentProcess = nil
        }

        let appSupport = FileLocations.applicationSupportDirectory
        let transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: transcriptDir.path) {
            try? FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }

        let hash = url.sha256Hash
        let transcriptURL = transcriptDir.appendingPathComponent("\(hash).transcript.json")

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Check for existing transcript before launching CLI.
        if let cachedURL = findExistingTranscript(audioURL: url, cacheURL: transcriptURL) {
            appendLog(.status, "Found existing transcript: \(cachedURL.lastPathComponent)")
            if let loaded = loadTranscriptFromDisk(cachedURL) {
                liveSegments = loaded
                progress = 1.0
                status = "Loaded \(loaded.count) segments from cache"
                appendLog(.completed, "Loaded \(loaded.count) segments from existing transcript.")
                completedTranscriptURL = cachedURL

                // Also load word frequencies sidecar if available.
                let freqSidecar = cachedURL
                    .deletingPathExtension()
                    .appendingPathExtension("word_frequencies.json")
                if let freq = loadWordFrequenciesFromDisk(freqSidecar) {
                    liveWordCloud = freq
                    appendLog(.status, "Loaded \(freq.count) word frequencies from sidecar.")
                } else {
                    liveWordCloud = TranscriptStore.computeWordFrequencies(from: loaded)
                }

                NotificationCenter.default.post(name: NSNotification.Name("TranscriptDidUpdate"), object: nil)
                return cachedURL
            }
        }

        guard let cliURL = resolveCLIBinary() else {
            appendLog(.error, "OrbitTranscriptionCLI binary not found.")
            appendLog(.status, "Build it with: cd Tools/OrbitTranscriptionCLI && swift build")
            return nil
        }

        appendLog(.status, "Launching CLI: \(cliURL.lastPathComponent)")
        appendLog(.status, "Audio: \(url.lastPathComponent)")

        let process = Process()
        process.executableURL = cliURL
        process.arguments = [url.path, "--output-path", transcriptURL.path]
        currentProcess = process

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            appendLog(.error, "Failed to launch CLI: \(error.localizedDescription)")
            return nil
        }

        status = "Transcribing..."

        // Read stdout and stderr concurrently via AsyncSequence.
        // Use a continuation to await process exit without blocking a
        // cooperative thread (replaces the synchronous waitUntilExit).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        await MainActor.run {
                            self.handleCLIOutputLine(line)
                        }
                    }
                } catch {
                    // Pipe closed or read error — expected when process exits.
                }
            }
            group.addTask {
                do {
                    for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                        await MainActor.run {
                            self.appendLog(.stderr, line)
                        }
                    }
                } catch {
                    // Pipe closed or read error — expected when process exits.
                }
            }
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                }
            }
        }

        if process.terminationStatus == 0 {
            progress = 1.0
            appendLog(.completed, "Transcription complete.")
            NotificationCenter.default.post(name: NSNotification.Name("TranscriptDidUpdate"), object: nil)
            return completedTranscriptURL ?? transcriptURL
        } else {
            appendLog(.error, "CLI exited with code \(process.terminationStatus)")
            return nil
        }
    }

    // MARK: - Existing transcript detection

    /// Checks for an existing transcript file: first the central cache, then a sidecar
    /// alongside the audio file. Returns the URL if found, nil otherwise.
    private func findExistingTranscript(audioURL: URL, cacheURL: URL) -> URL? {
        // 1. Central cache (hash-keyed in Application Support).
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // 2. Sidecar file alongside the audio (<audio_stem>.transcript.json).
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            return sidecarURL
        }

        return nil
    }

    /// Loads transcription segments from a JSON file on disk.
    private func loadTranscriptFromDisk(_ url: URL) -> [TranscriptionSegment]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TranscriptionSegment].self, from: data)
    }

    /// Loads word frequencies from a JSON file on disk.
    private func loadWordFrequenciesFromDisk(_ url: URL) -> [WordFrequency]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WordFrequency].self, from: data)
    }

    // MARK: - Binary resolution

    private func resolveCLIBinary() -> URL? {
        // 1. Embedded in app bundle (production).
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "OrbitTranscriptionCLI") {
            log("Found bundled CLI: \(bundled.path)")
            return bundled
        }

        // 2. Resolve project root (works for both Xcode dev builds and Finder launches).
        let projectRoot: URL? = {
            // 2a. #filePath gives the compile-time absolute path of this source file.
            //     Navigating up from the source tree gives the project root.
            //     This works when the app is launched from Xcode (debug builds).
            let fromSource = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // TranscriptionManager.swift
                .deletingLastPathComponent()  // Views
                .deletingLastPathComponent()  // Orbit Audiobooks macOS
            log("Trying project root from #filePath: \(fromSource.path)")
            if FileManager.default.fileExists(atPath: fromSource.appendingPathComponent("Tools").path) {
                return fromSource
            }

            // 2b. Fallback: navigate up from the built app bundle through DerivedData
            //     to find the project root. Bundle path looks like:
            //     .../DerivedData/.../Build/Products/Debug/Orbit Audiobooks.app
            var url = Bundle.main.bundleURL
            for _ in 0..<8 {
                url = url.deletingLastPathComponent()
                let candidate = url.appendingPathComponent("Tools")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    log("Trying project root from bundle walk: \(url.path)")
                    return url
                }
            }

            return nil
        }()

        guard let root = projectRoot else {
            log("Could not resolve project root")
            return nil
        }

        // 3. Look for the CLI binary under Tools/OrbitTranscriptionCLI/.build/
        for buildConfig in ["debug", "release"] {
            let url = root
                .appendingPathComponent("Tools/OrbitTranscriptionCLI/.build/\(buildConfig)/OrbitTranscriptionCLI")
            let exists = FileManager.default.isExecutableFile(atPath: url.path)
            log("Checking: \(url.path) — \(exists ? "FOUND" : "not found")")
            if exists {
                return url
            }
        }

        return nil
    }

    private func log(_ message: String) {
        appendLog(.debug, message)
    }

    private func handleCLIOutputLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(TranscriptionCLIEvent.self, from: data)
        else {
            appendLog(.status, line)
            status = line
            return
        }

        switch event {
        case .status(let message):
            status = message
            appendLog(.status, message)
        case .progress(let value):
            progress = min(1, max(0, value))
            appendLog(.progress, "\(Int(progress * 100))%")
        case .segment(let segment):
            liveSegments.append(segment)
            appendLog(.segment, "\(formatHMS(segment.startTime)) \(segment.text)")
        case .wordFrequencies(let words):
            liveWordCloud = words
            appendLog(.status, "Received \(words.count) word frequencies")
        case .completed(let outputPath, let segmentCount, let wordFrequencyPath):
            completedTranscriptURL = URL(fileURLWithPath: outputPath)
            status = "Wrote \(segmentCount) segments"
            progress = 1.0
            appendLog(.completed, "Wrote \(segmentCount) segments to \(URL(fileURLWithPath: outputPath).lastPathComponent)")
            if let freqPath = wordFrequencyPath {
                appendLog(.status, "Word frequencies saved to \(URL(fileURLWithPath: freqPath).lastPathComponent)")
            }
        case .error(let message):
            status = "Transcription failed"
            appendLog(.error, message)
        }
    }

    private func appendLog(_ kind: TranscriptionLogEntry.Kind, _ message: String) {
        liveLogStream.append(TranscriptionLogEntry(kind: kind, message: message))
    }

}
