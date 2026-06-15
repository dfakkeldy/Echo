import Testing
import Foundation
@testable import Echo

struct KokoroBenchmarkTests {
    
    @Test
    func testKokoroRTFBenchmark() async throws {
        let engine = KokoroTTSEngine()
        
        let sampleText = """
        The Kokoro-82M model is highly optimized for Apple Neural Engine. 
        It provides high-quality speech synthesis while using a small amount of memory, 
        making it perfect for offline, on-device audiobooks.
        """
        
        // This will download the model to cache on first run (takes network time)
        // and compile for ANE (takes ~15s on first run).
        try await engine.prepare()
        
        // Run synthesis
        let chunk = try await engine.synthesize(sampleText, voice: VoiceCatalog.default.id)
        
        // Check that duration makes sense and samples actually generated
        #expect(chunk.duration > 0)
        #expect(chunk.samples.count > 0)
        
        // This test simulates the benchmark. In a real physical device run,
        // we would see the RTF output in the console.
    }
}
