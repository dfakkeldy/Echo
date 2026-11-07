// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NarrationNudgeView: View {
    /// Headline. Defaults to the per-book phrasing (a book with no audiobook);
    /// callers in an idle/empty context pass a more general invitation.
    var title: LocalizedStringKey = "No audiobook for this one"
    var message: LocalizedStringKey =
        "Echo can narrate it on-device so you can study hands-free."
    var buttonTitle: LocalizedStringKey = "Listen"
    /// SF Symbol drawn before the button title; `nil` (the default, used by
    /// the Mac's "Choose Document…" invitation) for a title-only button.
    var buttonSystemImage: String? = nil
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                onListen()
            } label: {
                Group {
                    if let buttonSystemImage {
                        Label(buttonTitle, systemImage: buttonSystemImage)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .bold()
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding()
        // A tint of the surface it sits on (the player's cover wash on iPhone),
        // not an opaque grey card laid over a coloured room.
        .background(Color.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 16))
    }
}
