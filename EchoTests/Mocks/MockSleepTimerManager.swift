import Foundation
@testable import Echo

/// Configurable SleepTimerManager for unit testing.
final class MockSleepTimerManager: SleepTimerManagerProtocol {
    var mode: SleepTimerMode = .off
    var remainingSeconds: Int = 0

    var setTimerCallCount = 0
    var setTimerModes: [SleepTimerMode] = []
    var cancelCallCount = 0

    func setTimer(_ mode: SleepTimerMode) {
        setTimerCallCount += 1
        setTimerModes.append(mode)
        self.mode = mode
    }

    func cancel() {
        cancelCallCount += 1
        mode = .off
    }
}
