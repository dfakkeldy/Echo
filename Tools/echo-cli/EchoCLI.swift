// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

@main
struct EchoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo-cli",
        abstract: "Echo narration/alignment tools.",
        subcommands: [NarrateCommand.self])

    /// A bare command-line tool has no .app bundle, so point the narration
    /// resource loaders (NarrationResources / ECHO_RESOURCE_DIR) at the
    /// resources copied next to this binary, unless the caller set the override.
    static func configureResources() {
        guard ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil else { return }
        let dir = Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources")
        setenv("ECHO_RESOURCE_DIR", dir.path, 1)
    }
}
