import ArgumentParser
import Foundation
import OrbitEPUBAligner
import WhisperKit

@main
struct OrbitTranscriptionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Orbit Audiobooks transcription and EPUB alignment tools.",
        subcommands: [TranscribeCommand.self, AlignCommand.self],
        defaultSubcommand: TranscribeCommand.self
    )
}
