import SwiftUI

struct NowLineView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Empty space for the timestamp column
            Spacer().frame(width: 64 + 8)

            // Red "NOW" line
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 2)

                Text("NOW")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Rectangle()
                    .fill(Color.red)
                    .frame(height: 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Current time")
    }
}
