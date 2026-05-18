import SwiftUI

struct PlayheadLineView: View {
    let positionFraction: Double // 0...1 across total book duration

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer().frame(width: geo.size.width * positionFraction)

                    Rectangle()
                        .fill(.blue)
                        .frame(width: 2, height: 24)

                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.leading, 2)
                }
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 16)
        .accessibilityLabel("Current playback position")
    }
}
