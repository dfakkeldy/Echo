// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

@main
struct EchoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo-cli",
        abstract: "Echo narration/alignment tools.",
        subcommands: [
            NarrateCommand.self,
            RetagCommand.self,
            NarrationQACommand.self,
            GenerateDeckCommand.self,
        ])

    /// A bare command-line tool has no .app bundle, so point the narration
    /// resource loaders (NarrationResources / ECHO_RESOURCE_DIR) at the
    /// resources copied next to this binary, unless the caller set the override.
    static func configureResources() {
        guard ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil else { return }
        let dir = Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources")
        setenv("ECHO_RESOURCE_DIR", dir.path, 1)
    }

    /// Builds the QA classifier for `echo-cli qa`, mirroring
    /// `DivergenceClassifierFactory.make()` so FM enriches labels and
    /// suggests IPA pronunciations when available on macOS 26+.
    @MainActor
    static func makeQAClassifier() -> DivergenceClassifier {
        let preference =
            UserDefaults.standard.string(forKey: "narrationQAClassifier")
            ?? "auto"
        #if canImport(FoundationModels)
            if preference == "auto", #available(macOS 26, *) {
                return FoundationModelsDivergenceClassifier(
                    fallback: DeterministicDivergenceClassifier())
            }
        #endif
        return DeterministicDivergenceClassifier()
    }
}
