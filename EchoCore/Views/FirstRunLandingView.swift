// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Action-first first-run surface shown whenever no book is open. Replaces the
/// dismissible onboarding slideshow with a "do something now" screen: open a
/// folder (primary), optionally play the bundled manual, connect a server, plus
/// the no-copy reassurance every new user must see.  (Design spec §3.2)
struct FirstRunLandingView: View {
    let onOpenFolder: () -> Void
    let onOpenHelp: () -> Void
    let onConnectServer: () -> Void
    /// Non-nil once the bundled manual is seeded (phase 2). When nil, the manual
    /// action is hidden so phase 1 never shows a non-functional button.
    var onPlayManual: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Welcome to Echo")
                    .font(.title2.weight(.semibold))
                Text("Start listening in seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button("Open a Folder", systemImage: "folder", action: onOpenFolder)
                    .buttonStyle(.borderedProminent)

                if let onPlayManual {
                    Button(
                        "Play the Welcome Manual",
                        systemImage: "headphones",
                        action: onPlayManual
                    )
                    .buttonStyle(.bordered)
                }

                Button(
                    "Connect a Server",
                    systemImage: "externaldrive.connected.to.line.below",
                    action: onConnectServer
                )
                .buttonStyle(.bordered)
            }

            VStack(spacing: 6) {
                Label(
                    "Echo plays your files where they live — it never copies them. Keep the originals where they are.",
                    systemImage: "shield.checkered"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

                Button("How do I add books?", action: onOpenHelp)
                    .font(.footnote)
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: 420)
    }
}
