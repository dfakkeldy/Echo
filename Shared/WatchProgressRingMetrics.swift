// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum WatchProgressRingMetrics {
    static let pomodoroStandardLineWidth: CGFloat = 5
    static let pomodoroCenterLineWidth: CGFloat = 6
    static let complicationLineWidth: CGFloat = 6
    static let complicationMarkerDiameter: CGFloat = 8
    static let complicationInset: CGFloat = 4
    static let complicationArtworkPadding: CGFloat = 8
    static let rectangularGaugeHeight: CGFloat = 5

    static func pomodoroLineWidth(hasSeparateRing: Bool) -> CGFloat {
        hasSeparateRing ? pomodoroCenterLineWidth : pomodoroStandardLineWidth
    }
}
