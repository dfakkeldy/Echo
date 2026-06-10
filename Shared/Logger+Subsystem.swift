import Foundation
import os.log

extension Logger {
    /// Shared subsystem identifier used by all loggers in the app.
    /// Use `Logger(subsystem: .echoSubsystem, category: "...")` to keep
    /// the subsystem string consistent across every file.
    static nonisolated let echoSubsystem = "com.echo.audiobooks"

    /// Convenience initializer that fills in the shared subsystem.
    init(category: String) {
        self.init(subsystem: Logger.echoSubsystem, category: category)
    }
}
