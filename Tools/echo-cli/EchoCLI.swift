// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

@main
struct EchoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo-cli",
        abstract: "Echo narration/alignment tools.",
        version: versionString,
        subcommands: [
            NarrateCommand.self,
            RetagCommand.self,
            NarrationQACommand.self,
            GenerateDeckCommand.self,
            SidecarFromChapteredAudioCommand.self,
            VerifySidecarCommand.self,
        ])

    /// Render version + build configuration, so an overnight log (or
    /// `echo-cli --version`) reveals an accidentally slow Debug binary.
    static var versionString: String {
        "ONNX rv\(NarrationFileNaming.renderVersion) (\(buildConfiguration))"
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    /// A bare command-line tool has no .app bundle, so point the narration
    /// resource loaders (NarrationResources / ECHO_RESOURCE_DIR) at the
    /// resources copied next to this binary, unless the caller set the override.
    /// Also the per-command bootstrap hook: warns when this binary was built
    /// Debug, because -Onone makes the Swift narration stack several times
    /// slower and overnight agents have shipped whole books through it.
    static func configureResources() {
        #if DEBUG
            FileHandle.standardError.write(
                Data(
                    "warning: echo-cli was built in Debug (-Onone) — slower everywhere, drastically so outside narrate — build with `make echo-cli` (Release)\n"
                        .utf8))
        #endif
        guard ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil else { return }
        let dir = Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources")
        setenv("ECHO_RESOURCE_DIR", dir.path, 1)
    }

    /// Builds the QA classifier for `echo-cli qa` through the same
    /// `DivergenceClassifierFactory` gate the apps use — preference AND live
    /// `SystemLanguageModel` availability — so a Mac without Apple Intelligence
    /// no longer constructs an FM classifier that fails per window.
    @MainActor
    static func makeQAClassifier(preference: String) -> DivergenceClassifier {
        DivergenceClassifierFactory.make(
            preference: preference,
            availabilityIsAvailable: foundationModelsAvailable)
    }

    static var foundationModelsAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return SystemLanguageModel.default.availability == .available
            }
        #endif
        return false
    }
}
