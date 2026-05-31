import Foundation

/// Shared animation timing constants to replace magic-number literals
/// scattered across view bodies.  Tuning animation feel no longer requires
/// hunting down every inline `0.2` or `0.5` — change it here once.
enum AnimationDurations {
    /// Quick micro-interaction (button highlight, toggle switch).
    static let micro: TimeInterval = 0.15

    /// Standard transition (view appear/disappear, sheet presentation).
    static let standard: TimeInterval = 0.25

    /// Emphasized transition (major navigation, full-screen changes).
    static let emphasized: TimeInterval = 0.35

    /// Slow, deliberate reveal (onboarding, first-time hints).
    static let slow: TimeInterval = 0.5

    /// Auto-scroll delay before snapping to the active position.
    static let autoScrollDelay: TimeInterval = 0.2

    /// Header show/hide animation duration.
    static let headerTransition: TimeInterval = 0.25

    /// Transcript overlay fade.
    static let overlayFade: TimeInterval = 0.25

    /// Overlay auto-dismiss delay.
    static let overlayAutoDismiss: TimeInterval = 3.0
}
