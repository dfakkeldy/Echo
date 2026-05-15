import Foundation
import Combine
import CryptoKit
import AppKit
import UniformTypeIdentifiers

struct TranscriptionSegment: Codable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var progress: Double = 0
    @Published var isTranscribing: Bool = false
    @Published var status: String = ""
    @Published var liveLogStream: [String] = []

    private var currentProcess: Process?

    func exportTranscript(for audioURL: URL, segments: [TranscriptionSegment]) throws {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = audioURL.deletingPathExtension().appendingPathExtension("transcript.json").lastPathComponent
        savePanel.directoryURL = audioURL.deletingLastPathComponent()

        if savePanel.runModal() == .OK, let url = savePanel.url {
            let data = try JSONEncoder().encode(segments)
            try data.write(to: url, options: .atomic)
            print("Successfully exported transcript to: \(url.path)")
        }
    }

    func cancelTranscription() {
        currentProcess?.terminate()
        currentProcess = nil
        isTranscribing = false
        liveLogStream.append("[info] Transcription cancelled.")
    }

    func transcribe(url: URL) async throws -> URL? {
        isTranscribing = true
        progress = 0
        status = "Starting CLI..."
        liveLogStream = []
        defer {
            isTranscribing = false
            currentProcess = nil
        }

        guard let cliURL = resolveCLIBinary() else {
            liveLogStream.append("[error] OrbitTranscriptionCLI binary not found.")
            liveLogStream.append("[info] Build it with: cd Tools/OrbitTranscriptionCLI && swift build")
            return nil
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: transcriptDir.path) {
            try? FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }

        let data = Data(url.path.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let transcriptURL = transcriptDir.appendingPathComponent("\(hash).transcript.json")

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        liveLogStream.append("Launching CLI: \(cliURL.lastPathComponent)")
        liveLogStream.append("Audio: \(url.lastPathComponent)")

        let process = Process()
        process.executableURL = cliURL
        process.arguments = [url.path, "--outputPath", transcriptURL.path]
        currentProcess = process

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            liveLogStream.append("[error] Failed to launch CLI: \(error.localizedDescription)")
            return nil
        }

        status = "Transcribing..."

        // Read stdout and stderr concurrently via AsyncSequence.
        // Both loops exit when the pipe's write end closes (process exits),
        // so the task group naturally waits for process completion.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        await MainActor.run {
                            self.liveLogStream.append(line)
                            self.status = line
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
                            self.liveLogStream.append("[stderr] \(line)")
                        }
                    }
                } catch {
                    // Pipe closed or read error — expected when process exits.
                }
            }
        }

        process.waitUntilExit()

        if process.terminationStatus == 0 {
            liveLogStream.append("── Transcription complete ──")
            progress = 1.0
            NotificationCenter.default.post(name: NSNotification.Name("TranscriptDidUpdate"), object: nil)
            return transcriptURL
        } else {
            liveLogStream.append("[error] CLI exited with code \(process.terminationStatus)")
            return nil
        }
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
        liveLogStream.append("[debug] \(message)")
    }
}
