// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NarrationNudgeView: View {
    /// Headline. Defaults to the per-book phrasing (a book with no audiobook);
    /// callers in an idle/empty context pass a more general invitation.
    var title: LocalizedStringKey = "No audiobook for this one"
    var message: LocalizedStringKey =
        "Echo can narrate it on-device so you can study hands-free."
    var buttonTitle: LocalizedStringKey = "Listen \u{25B8}"
    let onListen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "headphones")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                onListen()
            } label: {
                Text(buttonTitle)
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding()
        #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
        #else
            .background(Color(.secondarySystemBackground))
        #endif
        .clipShape(.rect(cornerRadius: 16))
    }
}
