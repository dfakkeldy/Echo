import Foundation
import AVFoundation
import Accelerate

enum AudioExtractorError: Error {
    case assetNotPlayable
    case unreadableTrack
    case noAudioTracks
    case cannotAddOutput
    case startReadingFailed
    case failedToReadNextBuffer
}

actor AudioExtractor {
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    func prepare() async throws -> TimeInterval {
        let asset = AVAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else { throw AudioExtractorError.assetNotPlayable }
        let duration = try await asset.load(.duration)
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else { throw AudioExtractorError.noAudioTracks }
        
        // 16kHz PCM is standard for Whisper
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        assetReader = try AVAssetReader(asset: asset)
        
        if assetReader!.canAdd(trackOutput!) {
            assetReader!.add(trackOutput!)
        } else {
            throw AudioExtractorError.cannotAddOutput
        }
        
        if !assetReader!.startReading() {
            throw AudioExtractorError.startReadingFailed
        }
        
        return duration.seconds
    }
    
    /// Reads a sequential chunk of audio of approximately `seconds` length, converted to floats.
    /// Returns `nil` when EOF is reached.
    func readNextChunk(durationInSeconds: TimeInterval) throws -> (pcm: [Float], timestamp: TimeInterval)? {
        guard let reader = assetReader, let output = trackOutput else { return nil }
        
        let targetSamples = Int(durationInSeconds * 16000)
        var pcmBuffer = [Float]()
        pcmBuffer.reserveCapacity(targetSamples)
        
        var chunkStartTime: TimeInterval? = nil
        
        while reader.status == .reading && pcmBuffer.count < targetSamples {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            
            if chunkStartTime == nil {
                chunkStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            }
            
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            
            if status == kCMBlockBufferNoErr, let data = dataPointer {
                let numSamples = totalLength / 2 // 16-bit
                data.withMemoryRebound(to: Int16.self, capacity: numSamples) { ptr in
                    var floats = [Float](repeating: 0, count: numSamples)
                    var currentPtr = ptr
                    for i in 0..<numSamples {
                        floats[i] = Float(currentPtr.pointee) / 32768.0
                        currentPtr += 1
                    }
                    pcmBuffer.append(contentsOf: floats)
                }
            }
        }
        
        if pcmBuffer.isEmpty {
            return nil
        }
        
        return (pcmBuffer, chunkStartTime ?? 0.0)
    }
}
