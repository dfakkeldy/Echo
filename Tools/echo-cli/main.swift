// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// A bare command-line tool has no .app bundle, so point the narration resource
// loaders (see NarrationResources / ECHO_RESOURCE_DIR) at the resources copied
// next to this binary, unless the caller already set the override.
if ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil {
    let dir = Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources")
    setenv("ECHO_RESOURCE_DIR", dir.path, 1)
}
print("echo-cli 0.1")
