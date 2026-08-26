// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryStatusDot: View {
    let processing: ProcessingStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                Circle().stroke(.background, lineWidth: 1.5)
            }
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        if processing.contains(.aligned) { return .green }
        if processing.contains(.narrated) { return .blue }
        if processing.contains(.transcribed) { return .orange }
        return .gray
    }

    private var label: String {
        if processing.contains(.aligned) { return "Aligned" }
        if processing.contains(.narrated) { return "Narrated" }
        if processing.contains(.transcribed) { return "Transcribed" }
        return "Not processed"
    }
}
