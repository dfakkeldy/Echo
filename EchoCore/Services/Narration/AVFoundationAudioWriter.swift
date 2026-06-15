import Foundation
import AVFoundation

/// Implementation of AudioFileWriting that writes PCM samples into an M4A (AAC) file.
struct AVFoundationAudioWriter: AudioFileWriting {
    
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        guard !chunks.isEmpty else { return 0 }
        
        let sampleRate = chunks.first!.sampleRate
        
        // Define format for the output AAC file
        let outputFormatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, // Mono
            AVEncoderBitRateKey: 64000
        ]
        
        let audioFile = try AVAudioFile(forWriting: url, settings: outputFormatSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        
        // Create standard PCM format we get from our chunks
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AudioWriterError.formatCreationFailed
        }
        
        var totalDuration: TimeInterval = 0
        
        for chunk in chunks {
            let frameCount = AVAudioFrameCount(chunk.samples.count)
            guard frameCount > 0 else { continue }
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
                throw AudioWriterError.bufferCreationFailed
            }
            
            buffer.frameLength = frameCount
            
            // Copy float samples into the buffer
            if let channelData = buffer.floatChannelData?[0] {
                chunk.samples.withUnsafeBufferPointer { pointer in
                    channelData.update(from: pointer.baseAddress!, count: Int(frameCount))
                }
            }
            
            try audioFile.write(from: buffer)
            totalDuration += chunk.duration
        }
        
        return totalDuration
    }
}

enum AudioWriterError: Error {
    case formatCreationFailed
    case bufferCreationFailed
}
