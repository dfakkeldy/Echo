import Foundation
import ZIPFoundation

/// Handles one-time downloading of the Kokoro CoreML models.
actor ModelDownloader {
    enum DownloadState {
        case notDownloaded
        case downloading(progress: Double)
        case completed(url: URL)
        case failed(Error)
    }
    
    private(set) var state: DownloadState = .notDownloaded
    
    /// The local URL where the model should reside.
    var modelURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Kokoro-82M.mlpackage")
    }
    
    /// The remote URL for the model bundle (ZIP)
    private let remoteModelURL = URL(string: "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/main/Kokoro-82M.mlpackage.zip")!
    
    /// Starts the download process.
    func downloadModel() async throws {
        if FileManager.default.fileExists(atPath: modelURL.path) {
            state = .completed(url: modelURL)
            return
        }
        
        state = .downloading(progress: 0.0)
        
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteModelURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            // Extract the zip
            state = .downloading(progress: 1.0)
            
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            
            // Unzip to application support
            try fileManager.unzipItem(at: tempURL, to: appSupport)
            
            // Cleanup temp zip
            try? fileManager.removeItem(at: tempURL)
            
            state = .completed(url: modelURL)
        } catch {
            state = .failed(error)
            throw error
        }
    }
}
