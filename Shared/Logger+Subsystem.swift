import Foundation
import os.log

extension Logger {
    /// Shared subsystem identifier used by all loggers in the app.
    /// Use `Logger(subsystem: .orbitSubsystem, category: "...")` to keep
    /// the subsystem string consistent across every file.
    static nonisolated let orbitSubsystem = "com.orbitaudiobooks"

    /// Convenience initializer that fills in the shared subsystem.
    init(category: String) {
        self.init(subsystem: Logger.orbitSubsystem, category: category)
    }
}
