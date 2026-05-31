import SwiftUI

struct ReaderHeaderView: View {
    @Binding var searchText: String
    let chapterTitle: String
    let onScrollToActiveTap: () -> Void
    let onTOCTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(chapterTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                
                Button {
                    onScrollToActiveTap()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel(Text("Scroll to current playback position"))
                .padding(.trailing, 8)

                Button {
                    onTOCTap()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                }
                .accessibilityLabel(Text("Table of Contents"))
                .padding(.trailing, 8)
                
                Button {
                    onSettingsTap()
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 16))
                }
                .accessibilityLabel(Text("Reader settings"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in book...", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()
        }
    }
}
