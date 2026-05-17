import Foundation

/// Shared time formatting utility. Formats a TimeInterval as [H:]MM:SS.
/// Returns "--:--" for non-finite or NaN values.
public func formatHMS(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, !seconds.isNaN else { return "--:--" }
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
