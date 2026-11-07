// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Reusable stats metric card used across StatsView sections.
///
/// Every tile shares one accent so colour can carry meaning: callers pass a
/// different tint only for a real signal (an overdue count above zero).
struct StatCardView: View {
    let title: String
    let value: String
    let subtitle: String?
    let systemImage: String
    /// nil uses the app tint; pass a colour only for a real signal.
    let tint: Color?

    init(title: String, value: String, subtitle: String? = nil,
         systemImage: String = "chart.bar", tint: Color? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
