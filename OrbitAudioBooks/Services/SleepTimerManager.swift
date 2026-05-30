import Foundation
import Observation

/// Manages the sleep timer: countdown, end-of-chapter mode, and fire callback.
@MainActor @Observable
final class SleepTimerManager: SleepTimerManagerProtocol {
    private(set) var mode: SleepTimerMode = .off
    private(set) var remainingSeconds: Int = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var endDate: Date?

    /// Called on the main thread when the timer fires or end-of-chapter triggers.
    @ObservationIgnored var onFire: (() -> Void)?
    /// Called on each 1-second tick, for Watch sync.
    @ObservationIgnored var onTick: (() -> Void)?

    deinit {
        timer?.invalidate()
    }

    func setTimer(_ mode: SleepTimerMode) {
        cancelInternal()
        self.mode = mode

        switch mode {
        case .off:
            remainingSeconds = 0
            endDate = nil
        case .minutes(let minutes):
            let total = max(1, minutes) * 60
            remainingSeconds = total
            endDate = Date().addingTimeInterval(TimeInterval(total))
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let end = self.endDate else { return }
                    let remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
                    self.remainingSeconds = remaining
                    if remaining <= 0 {
                        self.fire()
                    } else {
                        self.onTick?()
                    }
                }
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        case .endOfChapter:
            remainingSeconds = 0
            endDate = nil
        }
    }

    func cancel() {
        setTimer(.off)
    }

    func evaluateAtChapterEnd() {
        guard case .endOfChapter = mode else { return }
        fire()
    }

    private func cancelInternal() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        cancelInternal()
        mode = .off
        remainingSeconds = 0
        endDate = nil
        onFire?()
    }
}
