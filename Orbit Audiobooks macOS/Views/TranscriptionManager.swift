import Foundation
import Speech
import AVFoundation
import Combine
import CryptoKit

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
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    func transcribe(url: URL) async throws -> URL? {
        isTranscribing = true
        progress = 0
        status = "Initializing..."
        defer { isTranscribing = false }
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: transcriptDir.path) {
            try? FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }
        
        let data = Data(url.path.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        print("TranscriptionManager: Saving with hash \(hash) for path \(url.path)")
        let transcriptURL = transcriptDir.appendingPathComponent("\(hash).transcript.json")
        
        // Ensure access to file
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        
        status = "Preparing recognition request..."
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        
        return try await withCheckedThrowingContinuation { continuation in
            speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    Task { @MainActor in continuation.resume(throwing: error) }
                    return
                }
                
                guard let result = result else { return }
                
                Task { @MainActor in
                    self.status = result.isFinal ? "Saving transcript..." : "Transcribing..."
                    self.progress = result.isFinal ? 1.0 : 0.5
                }
                
                if result.isFinal {
                    var segments: [TranscriptionSegment] = []
                    for segment in result.bestTranscription.segments {
                        segments.append(TranscriptionSegment(
                            text: segment.substring,
                            startTime: segment.timestamp,
                            endTime: segment.timestamp + segment.duration
                        ))
                    }
                    
                    do {
                        let data = try JSONEncoder().encode(segments)
                        try data.write(to: transcriptURL, options: .atomic)
                        print("Successfully saved transcript to: \(transcriptURL.path)")
                        
                        // Notify store to reload
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: NSNotification.Name("TranscriptDidUpdate"), object: nil)
                        }
                        
                        continuation.resume(returning: transcriptURL)
                    } catch {
                        print("Failed to save transcript: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
