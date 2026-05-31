import ArgumentParser
import Foundation
import EchoEPUBAligner
import WhisperKit

@main
struct EchoTranscriptionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Echo transcription and EPUB alignment tools.",
        subcommands: [TranscribeCommand.self, AlignCommand.self],
        defaultSubcommand: TranscribeCommand.self
    )
}
